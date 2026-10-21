import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import XCTest
@testable import Compositor

private actor HDRChildGate {
    private var released = false
    private var waiting: CheckedContinuation<Void, Never>?
    func hold() async {
        if released { return }
        await withCheckedContinuation { waiting = $0 }
    }
    func release() { released = true; waiting?.resume(); waiting = nil }
}

@MainActor private final class HDRReplyBox { var value: [String: Any]? }

@MainActor private final class HDRLeaseObservation {
    var competingImportRefusal: String?
    var inheritedLease: LensWorksHDROperationLease?
    var child: Task<Bool, Never>?
}

private final class HDRRecoveryMutation: @unchecked Sendable {
    private let lock = NSLock()
    private var storedError: String?
    func record(_ error: Error) { lock.withLock { storedError = error.localizedDescription } }
    var error: String? { lock.withLock { storedError } }
}

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
                kCGImagePropertyExifISOSpeedRatings: [100],
                kCGImagePropertyExifFNumber: 1.0
            ]
            CGImageDestinationAddImage(destination, image, [kCGImagePropertyExifDictionary: exif] as CFDictionary)
            XCTAssertTrue(CGImageDestinationFinalize(destination))
            XCTAssertEqual(try XCTUnwrap(HDRFrameLoader.exposureValue(url), "generated bracket must retain time, integer ISO and aperture"), Double(stops[index]))
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
            XCTAssertTrue(sourceAssets.allSatisfy { $0.nativeOriginal == nil }, "browse filenames are not filesystem authority")
            var resolved: [URL] = []
            for asset in sourceAssets { resolved.append(try await catalog.service.resolve(asset).originalURL) }
            XCTAssertEqual(Set(resolved), Set(sources))
            let before = try sources.map(HDRMergePublisher.sha256)
            let sourceIDs = Set(sourceAssets.map(\.id))
            for (index, asset) in sourceAssets.enumerated() { await catalog.select(asset, extending: index > 0) }
            XCTAssertEqual(catalog.selection, sourceIDs)

            var options = HDRMergeOptions(); options.deghost = true
            await catalog.mergeSelectionToHDR(options: options)
            XCTAssertNil(catalog.error)

            let registered = catalog.assets.filter { !sourceIDs.contains($0.id) }
            XCTAssertEqual(registered.count, 1)
            let mergedAsset = try XCTUnwrap(registered.first)
            let dngURL = try await catalog.service.resolve(mergedAsset).originalURL
            let linkURL = dngURL.appendingPathExtension("sources.json")
            XCTAssertEqual(try sources.map(HDRMergePublisher.sha256), before)
            let stored = try JSONDecoder().decode(HDRMergeLinkRecord.self, from: Data(contentsOf: linkURL))
            let storedHashes = try Dictionary(uniqueKeysWithValues: stored.sources.map {
                (try XCTUnwrap(URL(fileURLWithPath: $0.path).physicalFileURL).path, $0.sha256)
            })
            XCTAssertEqual(storedHashes, Dictionary(uniqueKeysWithValues: zip(sources.map(\.path), before)))
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

    private func plane(_ frame: HDRFrame) throws -> LWFloatPlane {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let builder = try workspace.makeBuilder(width: frame.width, height: frame.height)
        while let range = builder.nextRange {
            let bytes = try range.validate(frameWidth: frame.width, frameHeight: frame.height)
            let lease = try workspace.workingSet.reserve(bytes)
            var pixels: [SIMD4<Float>] = []; pixels.reserveCapacity(bytes / 16)
            for y in range.y..<(range.y + range.height) { for x in range.x..<(range.x + range.width) {
                let offset = (y * frame.width + x) * 3
                pixels.append(SIMD4(frame.rgb[offset], frame.rgb[offset + 1], frame.rgb[offset + 2], 1))
            } }
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels, maximumBytes: bytes), at: range)
            withExtendedLifetime(lease) {}
        }
        return try builder.finish()
    }

    private func reference(_ result: HDRPlaneMergeResult) throws -> HDRMergeResult {
        let tile = try result.plane.read(result.plane.globalExtent)
        let rgb = tile.surface.pixels.flatMap { [$0.x, $0.y, $0.z] }
        return HDRMergeResult(width: result.width, height: result.height, rgb: rgb,
            referenceIndex: result.referenceIndex, shifts: result.shifts)
    }

    func testNativeTiledAlignmentAndDeghostingUseTheSameRadianceContract() throws {
        let frames = try bracket()
        let native = try frames.map { HDRPlaneFrame(plane: try plane($0), exposureStops: $0.exposureStops,
                                                   original: URL(fileURLWithPath: "/reference"), sha256: "") }
        var off = HDRMergeOptions(); off.align = false
        var on = off; on.deghost = true
        let ghosted = try reference(HDRMerge.merge(native, options: off))
        let clean = try reference(HDRMerge.merge(native, options: on))
        let region = (minX: 46, minY: 46, maxX: 112, maxY: 93)
        XCTAssertLessThan(HDRGhostMetric.measure(clean, reference: frames[1], region: region),
                          HDRGhostMetric.measure(ghosted, reference: frames[1], region: region))
        let control = try HDRMerge.merge(frames, options: on)
        for index in control.rgb.indices { XCTAssertEqual(clean.rgb[index], control.rgb[index], accuracy: 0.00001) }
        let moved = try frame(index: 0, shift: (3, -2))
        let shift = try HDRMerge.align(HDRPlaneFrame(plane: plane(moved), exposureStops: moved.exposureStops,
            original: URL(fileURLWithPath: "/reference"), sha256: ""), to: native[1], limit: 6)
        XCTAssertEqual(shift.x, -3); XCTAssertEqual(shift.y, 2)
    }

    /// Adds a genuine EXIF IFD without re-encoding float samples or removing
    /// any DNG tag: append a new root IFD and redirect the TIFF header to it.
    private func addExposure(to url: URL, numerator: UInt32, denominator: UInt32) throws {
        var data = try Data(contentsOf: url)
        func u16(_ offset: Int) -> Int { Int(data[offset]) | Int(data[offset + 1]) << 8 }
        func u32(_ offset: Int) -> Int { u16(offset) | u16(offset + 2) << 16 }
        func put<T: FixedWidthInteger>(_ value: T, into bytes: inout Data) {
            var little = value.littleEndian; withUnsafeBytes(of: &little) { bytes.append(contentsOf: $0) }
        }
        let ifd = u32(4), count = u16(ifd)
        var entries = (0..<count).map { Data(data[(ifd + 2 + $0 * 12)..<(ifd + 14 + $0 * 12)]) }
        if data.count % 2 != 0 { data.append(0) }
        let rootOffset = UInt32(data.count)
        let exifOffset = rootOffset + 2 + UInt32(count + 1) * 12 + 4
        let values = exifOffset + 2 + 3 * 12 + 4
        var pointer = Data(); put(UInt16(34665), into: &pointer); put(UInt16(4), into: &pointer)
        put(UInt32(1), into: &pointer); put(exifOffset, into: &pointer); entries.append(pointer)
        entries.sort { (Int($0[0]) | Int($0[1]) << 8) < (Int($1[0]) | Int($1[1]) << 8) }
        var root = Data(); put(UInt16(entries.count), into: &root)
        for entry in entries { root.append(entry) }
        put(UInt32(0), into: &root)
        var headerOffset = Data(); put(rootOffset, into: &headerOffset)
        data.replaceSubrange(4..<8, with: headerOffset)
        data.append(root)
        var exif = Data(); put(UInt16(3), into: &exif)
        for (tag, type, value) in [(UInt16(33434), UInt16(5), values), (UInt16(33437), UInt16(5), values + 8), (UInt16(34855), UInt16(3), UInt32(100))] {
            put(tag, into: &exif); put(type, into: &exif); put(UInt32(1), into: &exif); put(value, into: &exif)
        }
        put(UInt32(0), into: &exif); put(numerator, into: &exif); put(denominator, into: &exif)
        put(UInt32(1), into: &exif); put(UInt32(1), into: &exif)
        data.append(exif); try data.write(to: url)
    }

    @MainActor
    func testRAWLoaderAndPublicationPreserveFullResolutionAndHDRLatitude() async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-full-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let root = try XCTUnwrap(temporary.physicalFileURL)
        defer { try? FileManager.default.removeItem(at: root) }
        let width = 4097, height = 32
        var originals: [URL] = []
        for (index, gain) in [Float(0.25), 1, 4].enumerated() {
            let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
            let builder = try workspace.makeBuilder(width: width, height: height)
            while let range = builder.nextRange {
                let bytes = try range.validate(frameWidth: width, frameHeight: height)
                let lease = try workspace.workingSet.reserve(bytes)
                let value = SIMD4<Float>(min(1, 2 * gain), min(1, 0.3 * gain), min(1, 0.4 * gain), 1)
                try builder.append(LWLinearSurface(width: range.width, height: range.height,
                    pixels: [SIMD4<Float>](repeating: value, count: bytes / 16), maximumBytes: bytes), at: range)
                withExtendedLifetime(lease) {}
            }
            let url = root.appendingPathComponent("bracket-\(index).dng")
            try LWLinearDNGWriter.writeDNG(builder.finish(), to: url)
            try addExposure(to: url, numerator: [1, 1, 4][index], denominator: [4, 1, 1][index])
            XCTAssertEqual(try XCTUnwrap(HDRFrameLoader.exposureValue(url), "float DNG bracket must retain capture EXIF"), [-2.0, 0, 2][index])
            let (_, fixturePlane) = try await LWSourceDeveloper.shared.createPlane(original: LWCatalogNativePath(fileURL: url), rawHint: true)
            XCTAssertEqual(fixturePlane.width, width, "the metadata-bearing fixture must decode before merge admission")
            originals.append(url)
        }
        let before = try originals.map(HDRMergePublisher.sha256)
        let frames = try await HDRFrameLoader.frames(originals)
        XCTAssertTrue(frames.allSatisfy { $0.plane.width == width && $0.plane.height == height })
        XCTAssertEqual(frames.map(\.exposureStops), [-2, 0, 2])
        var options = HDRMergeOptions(); options.align = false
        let merged = try HDRMerge.merge(frames, options: options)
        XCTAssertGreaterThan(try merged.plane.sampler().pixel(x: 3000, y: 10).x, 1.99)
        let made = try HDRMergePublisher.publish(merged, sources: originals, expectedHashes: before, into: root, name: "latitude", options: options)
        let (node, decoded) = try await LWSourceDeveloper.shared.createPlane(original: LWCatalogNativePath(fileURL: made.dng), rawHint: true)
        XCTAssertEqual(node.originalWidth, width); XCTAssertEqual(decoded.width, width)
        XCTAssertGreaterThan(try decoded.sampler().pixel(x: 3000, y: 10).x, 1.99)
        XCTAssertEqual(try originals.map(HDRMergePublisher.sha256), before)
    }

    @MainActor
    func testRegisteredHDRCommandChecksImplicitSourceGrantsAndFilteredRegistration() async throws {
        let fixture = try LensWorksCatalogBrowserTests.Fixture(images: 0)
        try await fixture.run { catalog in
            let sources = try writeGeneratedBracket(into: fixture.photos)
            try await fixture.importPhotos(catalog)
            try await catalog.browse(text: "generated-bracket")
            for (index, asset) in catalog.assets.enumerated() { await catalog.select(asset, extending: index > 0) }
            let output = fixture.root.appendingPathComponent("Media")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let folders = LensWorksGrantedFolders(defaults: fixture.defaults)
            try folders.grant(output)
            let tools = LensWorksAgentTools(session: { nil }, catalog: { catalog }, folders: folders)
            let arguments: [String: Any] = ["command": "photo.mergeToHDR", "arguments": ["output": output.path, "deghost": true]]
            let refused = await tools.call("invoke_command", arguments: arguments)
            XCTAssertEqual(refused["isError"] as? Bool, true)
            XCTAssertTrue(String(describing: refused).contains("outside every folder granted to automation"))
            XCTAssertFalse(FileManager.default.fileExists(atPath: output.appendingPathComponent("HDR").path))
            try folders.grant(fixture.photos)
            let before = try sources.map(HDRMergePublisher.sha256)
            let merged = await tools.call("invoke_command", arguments: arguments)
            XCTAssertNotEqual(merged["isError"] as? Bool, true, String(describing: merged))
            XCTAssertEqual(catalog.assets.count, 3, "the active filter hides the new HDR but must not prevent registration")
            try await catalog.browse()
            let added = try XCTUnwrap(catalog.assets.first { $0.filename.hasPrefix("HDR-") })
            let url = try await catalog.service.resolve(added).originalURL
            XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
            XCTAssertEqual(try sources.map(HDRMergePublisher.sha256), before)
            let session = EditorSession()
            await session.importImages([url])
            XCTAssertNil(session.importError)
            XCTAssertNotNil(session.activeLayer?.liveSource)
            session.beginFilter(.cameraRaw)
            var settings = try XCTUnwrap(session.filterEdit).settings
            settings.cameraRaw.exposure = 0.5; session.updateFilter(settings, preview: false)
            await session.commitFilter()
            XCTAssertNil(session.brushError)
            XCTAssertEqual(session.activeLayer?.liveSource?.settings.exposure, 0.5)
            session.addBlankLayer(); XCTAssertEqual(session.document?.layers.count, 2)
        }
    }


    @MainActor
    func testHDRReservesItsImportLaneAndEscapedLeaseClosesAfterTheOperation() async throws {
        let fixture = try LensWorksCatalogBrowserTests.Fixture(images: 0)
        try await fixture.run { catalog in
            _ = try writeGeneratedBracket(into: fixture.photos)
            try await fixture.importPhotos(catalog)
            for (index, row) in catalog.assets.enumerated() { await catalog.select(row, extending: index > 0) }
            let observation = HDRLeaseObservation(), gate = HDRChildGate()
            let sourceFolder = fixture.photos.path
            catalog.continuationFixture = { [weak catalog] point in
                guard let catalog else { return }
                if point == .hdrInputsAdmitted {
                    do { try await catalog.startImport(sourceFolder) }
                    catch { await MainActor.run { observation.competingImportRefusal = error.localizedDescription } }
                } else if point == .hdrImportStarted {
                    await MainActor.run {
                        observation.inheritedLease = LensWorksHDROperationOwner.current
                        observation.child = Task { @MainActor in
                            await gate.hold()
                            do { try await catalog.startImport(sourceFolder); return false }
                            catch is CancellationError { return true }
                            catch { return false }
                        }
                    }
                }
            }
            defer { catalog.continuationFixture = nil }
            await catalog.mergeSelectionToHDR()
            XCTAssertNil(catalog.error)
            XCTAssertNotNil(observation.competingImportRefusal)
            XCTAssertFalse(catalog.isHDRMerging)
            XCTAssertFalse(catalog.isBusy)
            let imported = catalog.importProgress?.id
            _ = try XCTUnwrap(observation.inheritedLease)
            let child = try XCTUnwrap(observation.child)
            await gate.release()
            let staleWasRefused = await child.value
            XCTAssertTrue(staleWasRefused, "an escaping child must not retain an ended operation's catalog authority")
            XCTAssertEqual(catalog.importProgress?.id, imported)
        }
    }

    @MainActor
    func testHDRDoesNotCancelAnImportStartedBeforeItsReservation() async throws {
        let fixture = try LensWorksCatalogBrowserTests.Fixture(images: 0)
        try await fixture.run { catalog in
            _ = try writeGeneratedBracket(into: fixture.photos)
            try await fixture.importPhotos(catalog)
            for (index, row) in catalog.assets.enumerated() { await catalog.select(row, extending: index > 0) }
            let admission = try await catalog.admitHDRMerge()
            try await catalog.startImport(fixture.photos.path)
            let sibling = try XCTUnwrap(catalog.importProgress?.id)
            do { _ = try await catalog.performHDRMerge(admission, options: HDRMergeOptions()); XCTFail("A competing owned import must prevent HDR admission") }
            catch { XCTAssertTrue(error.localizedDescription.contains("current catalog operation")) }
            XCTAssertEqual(catalog.importProgress?.id, sibling)
            XCTAssertNotEqual(catalog.importProgress?.phase, .Canceled)
            try await catalog.waitImport(terminal: true)
            XCTAssertEqual(catalog.importProgress?.phase, .Complete)
        }
    }

    @MainActor
    func testSourceGrantRevocationDuringRegistrationRetiresOnlyItsOwnedImportAndStopsLinkWrites() async throws {
        let fixture = try LensWorksCatalogBrowserTests.Fixture(images: 0)
        try await fixture.run { catalog in
            let sources = try writeGeneratedBracket(into: fixture.photos)
            try await fixture.importPhotos(catalog)
            for (index, row) in catalog.assets.enumerated() { await catalog.select(row, extending: index > 0) }
            let output = fixture.root.appendingPathComponent("Media")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            let folders = LensWorksGrantedFolders(defaults: fixture.defaults)
            try folders.grant(output); let originalGrantID = try folders.grant(fixture.photos).id
            let before = try sources.map(HDRMergePublisher.sha256)
            catalog.continuationFixture = { point in
                if point == .hdrImportStarted { await MainActor.run { folders.revoke(originalGrantID) } }
            }
            defer { catalog.continuationFixture = nil }
            let tools = LensWorksAgentTools(session: { nil }, catalog: { catalog }, folders: folders)
            let reply = await tools.call("invoke_command", arguments: ["command": "photo.mergeToHDR", "arguments": ["output": output.path]])
            XCTAssertEqual(reply["isError"] as? Bool, true)
            XCTAssertTrue(String(describing: reply).contains("outside every folder granted to automation"))
            XCTAssertFalse(catalog.isImporting, "a revoked operation must join cancellation/terminal state of its own import")
            XCTAssertTrue(catalog.groups.isEmpty && catalog.organizationUndo.isEmpty, "no collection or source-link write follows revocation")
            XCTAssertEqual(try sources.map(HDRMergePublisher.sha256), before)
        }
    }

    @MainActor
    func testExplicitSourceLinksPagePastOneHundredAsOneAgentUndoStep() async throws {
        let fixture = try LensWorksCatalogBrowserTests.Fixture(images: 101)
        try await fixture.run { catalog in
            try await fixture.importPhotos(catalog)
            var rows = catalog.assets.compactMap { asset in asset.key.map { LensWorksSelectedRow(imageID: asset.id, key: $0) } }
            while catalog.hasMore {
                let moved = await catalog.nextPage(); XCTAssertTrue(moved)
                rows += catalog.assets.compactMap { asset in asset.key.map { LensWorksSelectedRow(imageID: asset.id, key: $0) } }
            }
            XCTAssertEqual(rows.count, 101)
            let group = try await catalog.createGroupReturningID("Paged HDR sources")
            try await catalog.organize(.addCollection(group), rows: rows, origin: .agent)
            XCTAssertEqual(catalog.organizationUndo.count, 1)
            XCTAssertEqual(catalog.organizationUndo.last?.photos, 101)
            XCTAssertEqual(catalog.organizationUndo.last?.origin, .agent)
            XCTAssertTrue(catalog.organizationUndo.last?.title.contains("(Agent)") == true)
            try await catalog.browse(collection: group)
            var linked = Set(catalog.assets.map(\.id))
            while catalog.hasMore { let moved = await catalog.nextPage(); XCTAssertTrue(moved); linked.formUnion(catalog.assets.map(\.id)) }
            XCTAssertEqual(linked, Set(rows.map(\.imageID)))
            try await catalog.undoOrganization(origin: .agent)
            XCTAssertTrue(catalog.assets.isEmpty)
        }
    }

    @MainActor
    func testRestoreConflictKeepsBytesMetadataAndSiblingAndReportsActualRecoveryPathsToTheAgent() async throws {
        let fixture = try LensWorksCatalogBrowserTests.Fixture(images: 0)
        try await fixture.run { catalog in
            try await self.checkHDRRestoreConflict(catalog: catalog, fixture: fixture)
        }
    }

    @MainActor
    private func checkHDRRestoreConflict(catalog: LensWorksCatalog, fixture: LensWorksCatalogBrowserTests.Fixture) async throws {
        let sources = try writeGeneratedBracket(into: fixture.photos)
        try await fixture.importPhotos(catalog)
        for (index, row) in catalog.assets.enumerated() { await catalog.select(row, extending: index > 0) }
        let output = fixture.root.appendingPathComponent("Media")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
        let folders = LensWorksGrantedFolders(defaults: fixture.defaults)
        try folders.grant(output); try folders.grant(fixture.photos)
        let tools = LensWorksAgentTools(session: { nil }, catalog: { catalog }, folders: folders)
        let outside = fixture.root.appendingPathComponent("NotGranted")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        let movedOriginal = outside.appendingPathComponent("owned-original-kept.dng")
        let grantsBefore = folders.grants.map(\.path)
        let replacement = Data("replacement file retained with metadata".utf8), sibling = Data("sibling must never be overwritten".utf8)
        let date = Date(timeIntervalSince1970: 1_600_000_000)
        let mutation = HDRRecoveryMutation()
        let observer: @Sendable (URL, URL) -> Void = { publicURL, candidate in
            guard publicURL.pathExtension == "dng" else { return }
            do {
                try FileManager.default.moveItem(at: candidate, to: movedOriginal)
                try replacement.write(to: candidate, options: .withoutOverwriting)
                try FileManager.default.setAttributes([.modificationDate: date, .posixPermissions: 0o640], ofItemAtPath: candidate.path)
                try sibling.write(to: publicURL, options: .withoutOverwriting)
            } catch { mutation.record(error) }
        }
        catalog.continuationFixture = { [weak catalog] point in
            if point == .hdrPublicationReady { await catalog?.clearSelection() }
        }
        defer { catalog.continuationFixture = nil }
        let before = try sources.map(HDRMergePublisher.sha256)
        let replyBox = HDRReplyBox()
        let request = Task { @MainActor in
            await LWLinearMediaCleanupTestSeam.$afterQuarantine.withValue(observer) {
                replyBox.value = await tools.call("invoke_command", arguments: ["command": "photo.mergeToHDR", "arguments": ["output": output.path]])
            }
        }
        await request.value
        let reply = try XCTUnwrap(replyBox.value)
        XCTAssertNil(mutation.error)
        XCTAssertEqual(reply["isError"] as? Bool, true)
        let structured = try XCTUnwrap(reply["structuredContent"] as? [String: Any])
        let paths = try XCTUnwrap(structured["recoveryPaths"] as? [String])
        let candidate = URL(fileURLWithPath: try XCTUnwrap(paths.first { $0.hasSuffix("/candidate") }))
        XCTAssertTrue(paths.contains(movedOriginal.path), "the retained original and quarantined replacement are both actionable")
        XCTAssertEqual(structured["recoveryAccess"] as? String, LWLinearMediaRecoveryError.accessNotice)
        XCTAssertEqual(try Data(contentsOf: candidate), replacement)
        let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
        XCTAssertEqual(attributes[.posixPermissions] as? Int, 0o640)
        XCTAssertEqual(attributes[.modificationDate] as? Date, date)
        let published = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: output.appendingPathComponent("HDR"), includingPropertiesForKeys: nil).first { $0.pathExtension == "dng" })
        XCTAssertEqual(try Data(contentsOf: published), sibling)
        XCTAssertGreaterThan(try Data(contentsOf: movedOriginal).count, 100)
        XCTAssertEqual(folders.grants.map(\.path), grantsBefore)
        let outsideAccess = await tools.call("invoke_command", arguments: ["command": "file.openProject", "arguments": ["path": movedOriginal.path]])
        XCTAssertEqual(outsideAccess["isError"] as? Bool, true)
        XCTAssertTrue(String(describing: outsideAccess).contains("outside every folder granted to automation"), "recovery paths confer no read/write permission")
        XCTAssertTrue(catalog.presentedError?.contains(candidate.path) == true)
        XCTAssertEqual(try sources.map(HDRMergePublisher.sha256), before)
        XCTAssertTrue(catalog.groups.isEmpty)
        catalog.error = nil // Prior command-error restoration cannot hide filesystem recovery.
        await catalog.connect(fixture.catalog.path, create: false)
        XCTAssertNil(catalog.error)
        XCTAssertTrue(catalog.presentedError?.contains(candidate.path) == true)
        let pending = try XCTUnwrap(tools.state()["mediaRecovery"] as? [String: Any])
        XCTAssertTrue((pending["recoveryPaths"] as? [String])?.contains(candidate.path) == true)
        XCTAssertEqual(pending["recoveryAccess"] as? String, LWLinearMediaRecoveryError.accessNotice)
        catalog.dismissPresentedError(); XCTAssertNil(catalog.presentedError)
    }

    func testNativeMergePreservesSignedHDRAndRefusesImplicitTransparencyLoss() throws {
        for alpha in [Float(1), 0.5] {
            let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
            let builder = try workspace.makeBuilder(width: 1, height: 1)
            try builder.append(LWLinearSurface(width: 1, height: 1, pixels: [SIMD4(-0.25, 4, 0.0000001, alpha)], maximumBytes: 16),
                               at: LWFloatRange(x: 0, y: 0, width: 1, height: 1))
            let frame = HDRPlaneFrame(plane: try builder.finish(), exposureStops: 0, original: URL(fileURLWithPath: "/reference"), sha256: "")
            var options = HDRMergeOptions(); options.align = false
            if alpha == 1 {
                let merged = try HDRMerge.merge([frame, frame], options: options)
                let pixel = try merged.plane.sampler().pixel(x: 0, y: 0)
                XCTAssertLessThan(pixel.x, 0); XCTAssertGreaterThan(pixel.y, 3.99)
            } else {
                XCTAssertThrowsError(try HDRMerge.merge([frame, frame], options: options)) { error in
                    XCTAssertEqual(error as? HDRMergeError, .nonOpaqueFrame)
                }
            }
        }
    }

    func testMediaDestinationRejectsCatalogAncestorsAndExistingCatalogChildren() throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("hdr-media-authority-\(UUID())")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false)
        let root = try XCTUnwrap(temporary.physicalFileURL)
        defer { try? FileManager.default.removeItem(at: root) }
        let catalog = root.appendingPathComponent("Catalog"), previews = catalog.appendingPathComponent("Previews")
        try FileManager.default.createDirectory(at: previews, withIntermediateDirectories: true)
        let marker = Data("catalog marker must stay unchanged".utf8)
        try marker.write(to: catalog.appendingPathComponent("catalog.sqlite3"))
        XCTAssertThrowsError(try LWLinearMediaDestination(output: previews, subdirectory: "HDR"))
        XCTAssertFalse(FileManager.default.fileExists(atPath: previews.appendingPathComponent("HDR").path))
        let output = root.appendingPathComponent("Media"), child = output.appendingPathComponent("HDR")
        try FileManager.default.createDirectory(at: child, withIntermediateDirectories: true)
        try marker.write(to: child.appendingPathComponent("catalog.sqlite3"))
        XCTAssertThrowsError(try LWLinearMediaDestination(output: output, subdirectory: "HDR"))
        XCTAssertEqual(try Data(contentsOf: child.appendingPathComponent("catalog.sqlite3")), marker)
    }

}
