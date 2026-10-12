import Foundation
import SwiftUI
import ImageIO
import CryptoKit

nonisolated struct LensWorksHDRMergeOutcome: Sendable {
    let dng: URL
    let provenance: LWHDRMergeProvenance
    let asset: LensWorksCatalogAsset
    let result: LWHDRMergeResult
}

extension LensWorksCatalog {
    /// Why Merge to HDR… is unavailable now, or nil when the selection can be merged.
    func hdrMergeAvailability() -> String? {
        guard catalogPath != nil, !closingRequested else { return "Open a catalog first." }
        guard !isBusy, !isImporting else { return "Finish the current catalog action first." }
        guard selectionCount >= 2 else { return "Select two or more bracketed photos." }
        guard selectionCount <= Int64(LWHDRMerger.maximumFrames) else { return "Select at most \(LWHDRMerger.maximumFrames) bracketed photos." }
        return nil
    }

    nonisolated static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Merges the selected bracket into a new linear floating-point DNG beside the first
    /// source, imports it into this catalog through the ordinary folder import and selects
    /// it. Sources are only read; their bytes are re-verified before the import.
    func mergeSelectionToHDR(deghost: Bool = true) async throws -> LensWorksHDRMergeOutcome {
        try admitCatalogWork()
        if let reason = hdrMergeAvailability() { throw LensWorksCatalogError.message(reason) }
        let scope = captureScope(), owner = selectionOwnerForCommands
        let catalogPath = self.catalogPath
        let written: (url: URL, provenance: LWHDRMergeProvenance, result: LWHDRMergeResult)
        do {
            let busy = beginBusy(); defer { finishBusy(busy) }
            status = "Merging bracketed photos to HDR…"
            let rows = try await index.selection(owner: owner)
            try checkScope(scope)
            guard rows.count >= 2, rows.count <= LWHDRMerger.maximumFrames, Int64(rows.count) == selectionCount else {
                throw LensWorksCatalogError.message(rows.count < 2 ? LWHDRMergeError.tooFewFrames.localizedDescription : LWHDRMergeError.tooManyFrames.localizedDescription)
            }
            var originals: [(row: LensWorksSelectedRow, native: LWCatalogNativePath, url: URL, hash: String)] = []
            for row in rows {
                let native = try await service.originalLocation(row.key)
                try checkScope(scope)
                let url = try native.localFileURL()
                guard (try? url.checkResourceIsReachable()) == true else {
                    throw LensWorksCatalogError.message("“\(url.lastPathComponent)” is offline. Reconnect its location before merging.")
                }
                guard (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true else {
                    throw LensWorksCatalogError.message("“\(url.lastPathComponent)” is not a photo file.")
                }
                originals.append((row, native, url, try await Task.detached { try Self.sha256(url) }.value))
            }
            var frames: [LWHDRFrame] = []
            for original in originals {
                let (_, plane) = try await LWSourceDeveloper.shared.createPlane(original: original.native, rawHint: RawImporter.matches(original.url))
                try checkScope(scope)
                frames.append(try LWHDRFrame(width: plane.width, height: plane.height, pixels: Array(try plane.read(plane.globalExtent).surface.pixels)))
            }
            let developed = frames
            let result = try await Task.detached { try LWHDRMerger.merge(developed, options: LWHDRMergeOptions(deghost: deghost)) }.value
            try checkScope(scope)
            let reference = originals[result.referenceIndex].url
            let sources = originals.indices.map { index in
                LWHDRMergeProvenance.Source(catalogImageID: originals[index].row.imageID, assetID: originals[index].row.key.asset_id,
                    variantID: originals[index].row.key.variant_id, filePath: originals[index].url.path, sha256: originals[index].hash,
                    relativeExposureEV: log2(result.exposures[index]), offset: result.offsets[index], profile: Self.profileName(originals[index].url))
            }
            let provenance = LWHDRMergeProvenance(documentID: UUID().uuidString, catalogPath: catalogPath, deghost: deghost,
                referenceIndex: result.referenceIndex, baselineExposure: Double(-log2(LWHDRDNGWriter.normalization(result))), sources: sources)
            let bytes = try await Task.detached { [reference] in
                try LWHDRDNGWriter.encode(result, provenance: provenance, reference: Self.referenceMetadata(reference))
            }.value
            let folder = originals[0].url.deletingLastPathComponent()
            let stem = reference.deletingPathExtension().lastPathComponent + "-HDR"
            var destination = folder.appendingPathComponent(stem + ".dng"), suffix = 2
            while FileManager.default.fileExists(atPath: destination.path) {
                destination = folder.appendingPathComponent("\(stem)-\(suffix).dng"); suffix += 1
            }
            try bytes.write(to: destination, options: .withoutOverwriting)
            for original in originals where try Self.sha256(original.url) != original.hash {
                try? FileManager.default.removeItem(at: destination)
                throw LensWorksCatalogError.message("“\(original.url.lastPathComponent)” changed while merging; nothing was added to the catalog.")
            }
            written = (destination, provenance, result)
        }
        try checkScope(scope)
        try await startImport(written.url.deletingLastPathComponent().path)
        try checkScope(scope)
        try await waitImport(terminal: true)
        try checkScope(scope)
        let name = written.url.lastPathComponent
        if !assets.contains(where: { $0.filename == name }) { try await browse(text: name); try checkScope(scope) }
        guard let asset = assets.first(where: { $0.filename == name }) else {
            throw LensWorksCatalogError.message("The merged photo “\(name)” was written but did not appear in the catalog.")
        }
        await select(asset)
        status = "Merged \(written.provenance.sources.count) photos to HDR: \(name)"
        return LensWorksHDRMergeOutcome(dng: written.url, provenance: written.provenance, asset: asset, result: written.result)
    }

    nonisolated static func profileName(_ url: URL) -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return nil }
        return properties[kCGImagePropertyProfileName] as? String
    }

    /// Capture metadata of the reference frame, carried into the merged photo's XMP.
    nonisolated static func referenceMetadata(_ url: URL) -> [String: String] {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else { return [:] }
        var values: [String: String] = [:]
        let tiff = properties[kCGImagePropertyTIFFDictionary] as? [CFString: Any] ?? [:]
        let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any] ?? [:]
        if let make = tiff[kCGImagePropertyTIFFMake] as? String { values["tiff:Make"] = make }
        if let model = tiff[kCGImagePropertyTIFFModel] as? String { values["tiff:Model"] = model }
        if let lens = exif[kCGImagePropertyExifLensModel] as? String { values["aux:Lens"] = lens }
        if let date = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
            // EXIF "YYYY:MM:DD HH:MM:SS" → XMP ISO 8601.
            let parts = date.split(separator: " ")
            if parts.count == 2 { values["exif:DateTimeOriginal"] = parts[0].replacingOccurrences(of: ":", with: "-") + "T" + parts[1] }
        }
        return values
    }
}

/// The catalog toolbar's registered Merge to HDR… command with its availability reason.
struct LensWorksHDRMergeButton: View {
    let catalog: LensWorksCatalog
    let workspace: ProjectWorkspace
    @State private var confirming = false
    @State private var deghost = true
    var body: some View {
        let descriptor = LensWorksCommandRegistry.descriptor(.mergeHDR)
        let reason = catalog.hdrMergeAvailability()
        Button(LensWorksCommandRegistry.menuLabel(descriptor.label, reason: reason)) { confirming = true }
            .disabled(reason != nil).help(reason ?? descriptor.label)
            .accessibilityIdentifier(descriptor.id.rawValue)
            .sheet(isPresented: $confirming) {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Merge \(catalog.selectionCount) Photos to HDR").font(.headline)
                    Text("Creates a new linear floating-point DNG beside the first photo and adds it to the catalog. The originals are not changed.")
                        .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    Toggle("Deghost moving subjects", isOn: $deghost).accessibilityIdentifier("LensWorks.hdrDeghost")
                    HStack {
                        Spacer()
                        Button("Cancel", role: .cancel) { confirming = false }.keyboardShortcut(.cancelAction)
                        Button("Merge") {
                            confirming = false
                            let deghost = deghost
                            Task {
                                let scope = catalog.captureScope()
                                do {
                                    _ = try await catalog.mergeSelectionToHDR(deghost: deghost)
                                    try catalog.checkScope(scope)
                                    await catalog.createWorkingVersion(workspace: workspace)
                                } catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
                            }
                        }.keyboardShortcut(.defaultAction).accessibilityIdentifier("LensWorks.hdrMergeConfirm")
                    }
                }.padding(20).frame(width: 380)
            }
    }
}
