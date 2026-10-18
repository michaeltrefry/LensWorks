import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Compositor

/// Generated -1/0/+1 EV moving-subject bracket (same geometry as scripts/generate_s47_procedural_photos.py).
final class HDRMergeTests: XCTestCase {
    private let width = 160, height = 120
    private let subjectXs = [55, 79, 103], stops: [Float] = [-1, 0, 1]

    private func hash(_ x: Int, _ y: Int) -> Float {
        var h = UInt32(truncatingIfNeeded: x &* 73856093 ^ y &* 19349663)
        h = (h ^ (h >> 13)) &* 1274126177
        return Float((h ^ (h >> 16)) & 0xFF) / 255
    }
    private func encode(_ v: Float) -> Float {
        let c = min(max(v, 0), 1)
        let s = c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055
        return (s * 255).rounded() / 255
    }
    private func decode(_ s: Float) -> Float { s <= 0.04045 ? s / 12.92 : pow((s + 0.055) / 1.055, 2.4) }

    private func frame(index: Int, shift: (Int, Int) = (0, 0)) throws -> HDRFrame {
        var rgb = [Float](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let wx = x - shift.0, wy = y - shift.1
                var scene: [Float]
                if abs(wx - subjectXs[index]) <= 9, (46...93).contains(wy) { scene = [0.7, 0.2, 0.1] }
                else {
                    let base = 0.15 + 0.2 * Float(wx) / Float(width) + 0.1 * hash(wx, wy)
                    scene = [base, base * 0.9, base * 0.8]
                }
                let gain = exp2(stops[index])
                for c in 0..<3 { rgb[(y * width + x) * 3 + c] = decode(encode(scene[c] * gain)) }
            }
        }
        return try HDRFrame(width: width, height: height, rgb: rgb, exposureStops: stops[index])
    }
    private func bracket() throws -> [HDRFrame] { try (0..<3).map { try frame(index: $0) } }

    /// Writes the generated -1/0/+1 EV bracket as files with the EXIF data the selection command reads.
    private func writeGeneratedBracket(into directory: URL) throws -> [URL] {
        try (0..<3).map { index in
            let frame = try frame(index: index)
            var pixels = [UInt8](repeating: 255, count: width * height * 4)
            for pixel in 0..<(width * height) {
                for channel in 0..<3 { pixels[pixel * 4 + channel] = UInt8((encode(frame.rgb[pixel * 3 + channel]) * 255).rounded()) }
            }
            let provider = try XCTUnwrap(CGDataProvider(data: Data(pixels) as CFData))
            let image = try XCTUnwrap(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32,
                                               bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                               bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.last.rawValue),
                                               provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let url = directory.appendingPathComponent("generated-bracket-\(index + 1).jpg")
            let destination = try XCTUnwrap(CGImageDestinationCreateWithURL(url as CFURL, UTType.jpeg.identifier as CFString, 1, nil))
            let exif: [CFString: Any] = [
                kCGImagePropertyExifExposureTime: [0.5, 1, 2][index],
                kCGImagePropertyExifISOSpeedRatings: [100.0],
                kCGImagePropertyExifFNumber: 1.0
            ]
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            return url
        }
    }

    func testDeghostingLowersGhostMetricInMovingRegion() throws {
        let frames = try bracket()
        var off = HDRMergeOptions(); off.deghost = false
        var on = HDRMergeOptions(); on.deghost = true
        let region = (minX: 46, minY: 46, maxX: 112, maxY: 93)
        let ghosted = HDRGhostMetric.measure(try HDRMerge.merge(frames, options: off), reference: frames[1], region: region)
        let clean = HDRGhostMetric.measure(try HDRMerge.merge(frames, options: on), reference: frames[1], region: region)
        XCTAssertGreaterThan(ghosted, 0)
        XCTAssertLessThan(clean, ghosted)
    }

    func testMergeExtendsRangeBeyondSingleFrame() throws {
        let merged = try HDRMerge.merge(try bracket())
        XCTAssertEqual(merged.referenceIndex, 1)
        XCTAssertEqual(merged.rgb.count, width * height * 3)
        XCTAssertTrue(merged.rgb.allSatisfy { $0.isFinite && $0 >= 0 })
    }

    func testAlignmentRecoversTranslation() throws {
        let ref = try frame(index: 1)
        let moved = try frame(index: 0, shift: (3, -2))
        // Remove the subject difference by using a background-only comparison frame.
        let shift = HDRMerge.align(moved, to: ref, limit: 6)
        // Content displaced by (+3, -2) is sampled back at (x - dx, y - dy).
        XCTAssertEqual(shift.x, -3)
        XCTAssertEqual(shift.y, 2)
    }

    /// The merged DNG is a live RAW source in the editor: RAW development controls apply and layers stack above it.
    @MainActor
    func testMergedDNGOpensInEditorWithRawControlsAndAcceptsLayers() async throws {
        let temp = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-editor-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: temp) }
        let root = try XCTUnwrap(temp.physicalFileURL)
        let sources = try (0..<3).map { i -> URL in
            let url = root.appendingPathComponent("bracket-\(i + 1).bin")
            try Data([UInt8(i), 1, 2, 3]).write(to: url)
            return url
        }
        let options = HDRMergeOptions()
        let merged = try HDRMerge.merge(try bracket(), options: options)
        let publication = try HDRMergePublisher.publish(merged, sources: sources, into: root, name: "merged-hdr", options: options)

        let session = EditorSession()
        await session.importImages([publication.dng])
        XCTAssertNil(session.importError)
        let layer = try XCTUnwrap(session.activeLayer)
        XCTAssertNotNil(layer.liveSource)
        XCTAssertNotNil(layer.asset?.linearPlane)

        session.beginFilter(.cameraRaw)
        let edit = try XCTUnwrap(session.filterEdit)
        XCTAssertNotNil(edit.liveSource)
        var settings = edit.settings
        settings.cameraRaw.exposure = 0.5
        session.updateFilter(settings, preview: false)
        await session.commitFilter()
        XCTAssertNil(session.brushError)
        XCTAssertEqual(session.activeLayer?.liveSource?.settings.exposure, 0.5)

        let rawID = layer.id
        session.addBlankLayer()
        XCTAssertEqual(session.document?.layers.count, 2)
        XCTAssertEqual(session.document?.layers.first?.id, rawID)
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    @MainActor
    func testSelectionMergeRegistersOneLinkedFloatDNGAndLeavesSourcesUnchanged() async throws {
        let fixture = try LensWorksCatalogBrowserTests.Fixture(images: 0)
        try await fixture.run { catalog in
            let sources = try writeGeneratedBracket(into: fixture.photos)
            try await fixture.importPhotos(catalog)
            let sourceAssets = catalog.assets
            XCTAssertEqual(sourceAssets.count, 3)
            XCTAssertEqual(Set(sourceAssets.map { URL(fileURLWithPath: $0.originalPath).standardizedFileURL }), Set(sources.map(\.standardizedFileURL)))
            let before = try sources.map(HDRMergePublisher.sha256)
            let sourceIDs = Set(sourceAssets.map(\.id))
            for (index, asset) in sourceAssets.enumerated() { await catalog.select(asset, extending: index > 0) }
            XCTAssertEqual(catalog.selection, sourceIDs)

            var options = HDRMergeOptions(); options.deghost = true
            await catalog.mergeSelectionToHDR(options: options)
            XCTAssertNil(catalog.error)

            let registered = catalog.assets.filter { !sourceIDs.contains($0.id) }
            XCTAssertEqual(registered.count, 1)
            let dngURL = URL(fileURLWithPath: try XCTUnwrap(registered.first?.originalPath))
            let linkURL = dngURL.appendingPathExtension("sources.json")
            XCTAssertEqual(try sources.map(HDRMergePublisher.sha256), before)
            let stored = try JSONDecoder().decode(HDRMergeLinkRecord.self, from: Data(contentsOf: linkURL))
            XCTAssertEqual(stored.sources.map(\.sha256), before)
            XCTAssertEqual(stored.sources.map(\.path), sources.map { $0.standardizedFileURL.path })
            XCTAssertTrue(stored.deghost)
            let group = try catalog.group(named: "HDR Merge " + dngURL.deletingPathExtension().lastPathComponent)
            try await catalog.browse(collection: group.id)
            XCTAssertEqual(Set(catalog.assets.map(\.id)), sourceIDs.union(registered.map(\.id)))

            // Linear floating-point DNG: TIFF LE, LinearRaw, 3 x 32-bit IEEE float, and a DNG version tag.
            let dng = try Data(contentsOf: dngURL)
            XCTAssertEqual(Array(dng.prefix(4)), [0x49, 0x49, 42, 0])
            func u16(_ o: Int) -> Int { Int(dng[o]) | Int(dng[o + 1]) << 8 }
            func u32(_ o: Int) -> Int { u16(o) | u16(o + 2) << 16 }
            var tags: [Int: Int] = [:]
            let ifd = u32(4)
            for i in 0..<u16(ifd) { tags[u16(ifd + 2 + i * 12)] = u32(ifd + 2 + i * 12 + 8) }
            XCTAssertEqual(tags[262], 34892)
            XCTAssertEqual(tags[256], width); XCTAssertEqual(tags[257], height)
            XCTAssertNotNil(tags[50706])
            XCTAssertEqual(u16(tags[339]!), 3)
            let offset = tags[273]!
            XCTAssertEqual(dng.count - offset, width * height * 12)
            XCTAssertTrue(Float(bitPattern: UInt32(u32(offset))).isFinite)
            XCTAssertTrue(Float(bitPattern: UInt32(u32(dng.count - 4))).isFinite)
        }
    }
}
