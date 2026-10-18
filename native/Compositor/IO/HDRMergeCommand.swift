import Foundation
import CoreGraphics
import ImageIO

/// Decodes a catalog photo into a linear frame and the exposure it was taken at.
nonisolated enum HDRFrameLoader {
    /// Longest edge decoded; keeps the alignment search and merge responsive on large bracket sets.
    static let longestEdge = 4096

    private static let linearLookup: [Float] = (0..<256).map { value in
        let s = Float(value) / 255
        return s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4)
    }

    /// Exposure value of the capture from EXIF (shutter, ISO, aperture), nil when the file does not record it.
    static func exposureValue(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let time = exif[kCGImagePropertyExifExposureTime] as? Double, time > 0 else { return nil }
        let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [Double])?.first ?? 100
        let aperture = exif[kCGImagePropertyExifFNumber] as? Double ?? 1
        guard iso > 0, aperture > 0 else { return nil }
        return log2(time * iso / 100 / (aperture * aperture))
    }

    static func linearPixels(_ url: URL) throws -> (width: Int, height: Int, rgb: [Float]) {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { throw ImageImportError.unreadable }
        let options: [CFString: Any] = [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                        kCGImageSourceCreateThumbnailWithTransform: true,
                                        kCGImageSourceThumbnailMaxPixelSize: longestEdge]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { throw ImageImportError.unreadable }
        let width = image.width, height = image.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard drawn else { throw ImageImportError.unreadable }
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for i in 0..<width * height { for c in 0..<3 { rgb[i * 3 + c] = linearLookup[Int(bytes[i * 4 + c])] } }
        return (width, height, rgb)
    }

    /// Frames for `urls`, with exposure offsets taken relative to the middle capture.
    static func frames(_ urls: [URL]) throws -> [HDRFrame] {
        let values = urls.map(exposureValue)
        guard values.allSatisfy({ $0 != nil }) else {
            throw LensWorksCatalogError.message("Every bracketed photo needs recorded exposure time, ISO and aperture to be merged.")
        }
        let evs = values.compactMap { $0 }
        let middle = evs.sorted()[evs.count / 2]
        return try zip(urls, evs).map { url, ev in
            let pixels = try linearPixels(url)
            return try HDRFrame(width: pixels.width, height: pixels.height, rgb: pixels.rgb, exposureStops: Float(ev - middle))
        }
    }
}

/// Catalog registration through the existing folder import: the merged DNG becomes a new catalog photo, and a
/// virtual folder holds it together with every source photo so the merge stays linked to its sources.
@MainActor
struct LensWorksHDRMergeRegistrar: HDRMergeCatalogRegistering {
    let catalog: LensWorksCatalog
    let sources: [LensWorksSelectedRow]

    func registerMerged(_ publication: HDRMergePublication) async throws {
        await catalog.importFolder(publication.dng.deletingLastPathComponent().path)
        let path = publication.dng.resolvingSymlinksInPath().path
        guard let merged = catalog.assets.first(where: { URL(fileURLWithPath: $0.originalPath).resolvingSymlinksInPath().path == path }),
              let key = merged.key else {
            throw LensWorksCatalogError.message("The merged photo was written but is not in the catalog's current view; add its folder to the catalog.")
        }
        let title = "HDR Merge " + publication.dng.deletingPathExtension().lastPathComponent
        try await catalog.createGroup(title)
        let group = try catalog.group(named: title)
        try await catalog.organize(.addCollection(group.id), rows: sources + [LensWorksSelectedRow(imageID: merged.id, key: key)])
    }
}

extension LensWorksCatalog {
    var hdrMergeUnavailableReason: String? {
        if catalogPath == nil { return "Open a catalog first." }
        if isBusy || isImporting { return "Finish the current catalog operation first." }
        if selection.count < 2 { return "Select two or more bracketed photos first." }
        return nil
    }

    /// Photo > Merge to HDR: aligns the selected frames, writes a linear floating-point DNG through the media folder
    /// and registers it as a new catalog photo linked to its sources. The sources are only read.
    func mergeSelectionToHDR(options: HDRMergeOptions = HDRMergeOptions()) async {
        guard hdrMergeUnavailableReason == nil else { return }
        let picked = assets.filter { selection.contains($0.id) }
        let rows = picked.compactMap { asset in asset.key.map { LensWorksSelectedRow(imageID: asset.id, key: $0) } }
        guard picked.count >= 2, rows.count == picked.count else {
            error = "Select two or more bracketed photos in the current view first."
            return
        }
        let sources = picked.map { URL(fileURLWithPath: $0.originalPath) }
        let directory = outputDirectory.map { URL(fileURLWithPath: $0) } ?? sources[0].deletingLastPathComponent()
        let base = "HDR-" + sources[0].deletingPathExtension().lastPathComponent + "-\(sources.count)frames"
        var name = base, suffix = 2
        while FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).appendingPathExtension("dng").path) {
            name = base + "-\(suffix)"; suffix += 1
        }
        status = "Merging \(sources.count) frames to HDR…"
        do {
            let result = try await Task.detached(priority: .userInitiated) {
                try HDRMerge.merge(try HDRFrameLoader.frames(sources), options: options)
            }.value
            let publication = try HDRMergePublisher.publish(result, sources: sources, into: directory, name: name, options: options)
            try await LensWorksHDRMergeRegistrar(catalog: self, sources: rows).registerMerged(publication)
            status = "Merged \(sources.count) frames into \(publication.dng.lastPathComponent)."
        } catch {
            self.error = error.localizedDescription
        }
    }
}
