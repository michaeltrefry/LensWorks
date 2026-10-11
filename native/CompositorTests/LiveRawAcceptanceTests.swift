import Foundation
import Testing
import CoreGraphics
import CryptoKit
@testable import Compositor

/// Writes small uncompressed LinearRaw DNGs. The DNG SDK in the installed decode
/// worker develops them as it would a camera DNG: as-shot neutral, camera and
/// forward matrices, orientation and white level all come from these tags.
nonisolated enum ProceduralDNG {
    /// The as-shot neutral and forward matrix of generated-linear-mask.dng.
    static let neutral: [Double] = [0.5, 1, 0.75]
    static let forward: [[Double]] = [[0.5, 0.3, 0.1643], [0.2, 0.7, 0.1], [0.05, 0.1, 0.6751]]

    /// A smooth gradient with a block of white-level camera samples top-left. After
    /// as-shot white balance that block's red channel is twice the white level.
    static func write(to url: URL, width: Int, height: Int, orientation: UInt16 = 1) throws {
        var pixels = Data(capacity: width * height * 6)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x) / Double(max(1, width - 1)), fy = Double(y) / Double(max(1, height - 1))
                var rgb = [0.05 + 0.45 * fx, 0.05 + 0.6 * fy, 0.4 - 0.3 * fx * fy]
                if x < width / 6, y < height / 6 { rgb = [1, 1, 1] }
                for value in rgb {
                    var sample = UInt16((min(1, max(0, value)) * 65535).rounded()).littleEndian
                    withUnsafeBytes(of: &sample) { pixels.append(contentsOf: $0) }
                }
            }
        }
        let camera = product(diagonal(neutral), inverse(forward))
        let entries: [(UInt16, Value)] = [
            (254, .long([0])), (256, .long([UInt32(width)])), (257, .long([UInt32(height)])),
            (258, .short([16, 16, 16])), (259, .short([1])), (262, .short([34892])),
            (273, .long([0])), (274, .short([orientation])), (277, .short([3])),
            (278, .long([UInt32(height)])), (279, .long([UInt32(pixels.count)])), (284, .short([1])),
            (339, .short([1, 1, 1])), (50706, .byte([1, 4, 0, 0])), (50707, .byte([1, 4, 0, 0])),
            (50708, .ascii("LensWorks procedural fixture")), (50713, .short([1, 1])),
            (50714, .rational([0, 0, 0])), (50717, .long([65535, 65535, 65535])),
            (50721, .srational(camera.flatMap { $0 })), (50728, .rational(neutral)),
            (50778, .short([23])), (50964, .srational(forward.flatMap { $0 })),
        ]
        let ifdSize = 2 + entries.count * 12 + 4
        var encodedEntries = entries.map { encoded($0.1) }
        var extra = Data(), extraOffsets: [Int] = []
        for item in encodedEntries {
            extraOffsets.append(8 + ifdSize + extra.count)
            if item.bytes.count > 4 { extra.append(item.bytes); if extra.count % 2 == 1 { extra.append(0) } }
        }
        let pixelOffset = 8 + ifdSize + extra.count
        if let strip = entries.firstIndex(where: { $0.0 == 273 }) { encodedEntries[strip] = encoded(.long([UInt32(pixelOffset)])) }
        var file = Data([0x49, 0x49, 42, 0])
        func put<T: FixedWidthInteger>(_ value: T) { var le = value.littleEndian; withUnsafeBytes(of: &le) { file.append(contentsOf: $0) } }
        put(UInt32(8)); put(UInt16(entries.count))
        for (index, entry) in entries.enumerated() {
            let item = encodedEntries[index]
            put(entry.0); put(item.type); put(item.count)
            if item.bytes.count > 4 { put(UInt32(extraOffsets[index])) }
            else { file.append(item.bytes); file.append(Data(repeating: 0, count: 4 - item.bytes.count)) }
        }
        put(UInt32(0))
        file.append(extra); file.append(pixels)
        try file.write(to: url, options: .withoutOverwriting)
    }
    private enum Value { case byte([UInt8]), ascii(String), short([UInt16]), long([UInt32]), rational([Double]), srational([Double]) }
    private static func encoded(_ value: Value) -> (type: UInt16, count: UInt32, bytes: Data) {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        switch value {
        case .byte(let v): data.append(contentsOf: v); return (1, UInt32(v.count), data)
        case .ascii(let s): data.append(contentsOf: Array(s.utf8) + [0]); return (2, UInt32(s.utf8.count + 1), data)
        case .short(let v): v.forEach(put); return (3, UInt32(v.count), data)
        case .long(let v): v.forEach(put); return (4, UInt32(v.count), data)
        case .rational(let v): v.forEach { put(UInt32(($0 * 1_000_000).rounded())); put(UInt32(1_000_000)) }; return (5, UInt32(v.count), data)
        case .srational(let v): v.forEach { put(Int32(($0 * 1_000_000).rounded())); put(Int32(1_000_000)) }; return (10, UInt32(v.count), data)
        }
    }
    private static func diagonal(_ v: [Double]) -> [[Double]] { (0..<3).map { i in (0..<3).map { $0 == i ? v[i] : 0 } } }
    private static func product(_ a: [[Double]], _ b: [[Double]]) -> [[Double]] {
        (0..<3).map { i in (0..<3).map { j in (0..<3).reduce(0) { $0 + a[i][$1] * b[$1][j] } } }
    }
    private static func inverse(_ m: [[Double]]) -> [[Double]] {
        let a = m.flatMap { $0 }
        let d = a[0] * (a[4] * a[8] - a[5] * a[7]) - a[1] * (a[3] * a[8] - a[5] * a[6]) + a[2] * (a[3] * a[7] - a[4] * a[6])
        let r = [a[4] * a[8] - a[5] * a[7], a[2] * a[7] - a[1] * a[8], a[1] * a[5] - a[2] * a[4],
                 a[5] * a[6] - a[3] * a[8], a[0] * a[8] - a[2] * a[6], a[2] * a[3] - a[0] * a[5],
                 a[3] * a[7] - a[4] * a[6], a[1] * a[6] - a[0] * a[7], a[0] * a[4] - a[1] * a[3]].map { $0 / d }
        return [Array(r[0..<3]), Array(r[3..<6]), Array(r[6..<9])]
    }
}

/// S08 acceptance: live RAW sources developed in float beneath editable layers.
@MainActor
struct LiveRawAcceptanceTests {
    private static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    private static let checkedInDNGs = ["generated-linear-mask.dng", "generated-calibration-mask.dng",
                                        "generated-spatial1-mask.dng", "generated-spatial2-mask.dng"]

    private struct Tolerance: Decodable {
        let schema: Int
        let per_channel_max_abs: Double
    }

    /// A private physical directory: the managed decoder admits only physical originals.
    private func folder() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LiveRawAcceptance-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        return try #require(url.physicalFileURL)
    }
    private func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }
    private func checkedIn(_ name: String, into root: URL) throws -> URL {
        let target = root.appendingPathComponent(name)
        try FileManager.default.copyItem(at: Self.repository.appendingPathComponent("engines/catalog/tests/fixtures/\(name)"), to: target)
        return target
    }
    private func pixels(_ plane: LWFloatPlane) throws -> [SIMD4<Float>] {
        Array(try plane.read(plane.globalExtent).surface.pixels)
    }
    /// The product import path: a RAW becomes a live source layer developed in float.
    private func importedSession(_ url: URL) async throws -> EditorSession {
        let session = EditorSession()
        await session.importImages([url])
        #expect(session.importError == nil, "\(session.importError ?? "")")
        let layer = try #require(session.activeLayer)
        #expect(layer.liveSource != nil && layer.asset?.linearPlane != nil)
        return session
    }
    /// Camera Raw on a live source commits through the same development the preview uses.
    private func commitCameraRaw(_ session: EditorSession, whiteBalance: LWSourceWhiteBalance,
                                 _ change: (inout CameraRawSettings) -> Void) async throws {
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        #expect(edit.liveSource != nil)
        edit.sourceWhiteBalance = whiteBalance
        var settings = edit.settings
        change(&settings.cameraRaw)
        session.updateFilter(settings, preview: false)
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.brushError == nil, "\(session.brushError ?? "")")
    }

    // AC1: RAW controls stay editable under layers across save/reopen; the original is never written.
    @Test func rawControlsStayEditableUnderLayersAfterSaveAndReopen() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("procedural.dng")
        try ProceduralDNG.write(to: original, width: 96, height: 64)
        let originalHash = try sha256(original)
        let session = try await importedSession(original)
        let rawID = try #require(session.activeLayerID)
        try await commitCameraRaw(session, whiteBalance: .temperatureTint(kelvin: 4800, tint: 12)) {
            $0.exposure = 0.75; $0.contrast = 20; $0.highlights = -30; $0.shadows = 25; $0.whites = 10; $0.blacks = -5
            $0.temperature = 8; $0.tint = -4; $0.vibrance = 15; $0.saturation = -10; $0.texture = 5; $0.clarity = 10; $0.dehaze = 5
        }
        let developed = try #require(session.activeLayer?.liveSource)
        #expect(developed.settings.exposure == 0.75 && developed.settings.clarity == 10)
        // An editable document layer above the RAW source.
        session.addBlankLayer()
        let overlay = try #require(session.activeLayerID)
        #expect(session.document?.layers.map(\.id) == [rawID, overlay])

        let file = root.appendingPathComponent("Live.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: file)
        let reopened = try await ProjectStore.shared.load(from: file)
        #expect(reopened.manifest.workingSpace == "extended-linear-sRGB" && reopened.manifest.workingSample == "float32-straight-RGBA")
        let restored = EditorSession()
        restored.installProject(reopened, from: file)
        #expect(restored.document?.layers.map(\.id) == [rawID, overlay])
        let source = try #require(restored.document?.layers.first?.liveSource)
        #expect(source == developed)
        #expect(source.whiteBalance == .temperatureTint(kelvin: 4800, tint: 12))

        // Still live after reopen: change exposure and white balance again beneath the overlay.
        restored.activeLayerID = rawID
        let before = try pixels(try #require(restored.activeLayer?.asset?.linearPlane))
        try await commitCameraRaw(restored, whiteBalance: .asShot) { $0.exposure = -0.5 }
        let edited = try #require(restored.activeLayer)
        #expect(edited.liveSource?.settings.exposure == -0.5 && edited.liveSource?.whiteBalance == .asShot)
        #expect(edited.liveSource?.settings.clarity == 10)
        #expect(try pixels(try #require(edited.asset?.linearPlane)) != before)
        #expect(restored.document?.layers.map(\.id) == [rawID, overlay])
        restored.undo()
        #expect(restored.activeLayer?.liveSource == developed)
        #expect(try sha256(original) == originalHash)
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    // AC2: float working data keeps highlight latitude; orientation applies; profile provenance survives save/reopen.
    @Test(arguments: [UInt16(1), 6])
    func floatWorkingDataKeepsLatitudeOrientationAndProfileProvenance(_ orientation: UInt16) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("oriented-\(orientation).dng")
        try ProceduralDNG.write(to: original, width: 60, height: 36, orientation: orientation)
        let session = try await importedSession(original)
        let layer = try #require(session.activeLayer)
        let node = try #require(layer.liveSource)
        let plane = try #require(layer.asset?.linearPlane)
        let expected = orientation == 6 ? (36, 60) : (60, 36)
        #expect(plane.width == expected.0 && plane.height == expected.1)
        #expect(plane.manifest.sample == "float32-le" && plane.manifest.colorSpace == "extended-linear-sRGB" && plane.manifest.alpha == "straight")
        #expect(try pixels(plane).contains { max($0.x, $0.y, $0.z) > 1.0 }, "white-level samples keep over-one headroom after as-shot white balance")
        // Pulling exposure down recovers the bright block from retained float headroom.
        try await commitCameraRaw(session, whiteBalance: .asShot) { $0.exposure = -1 }
        let darker = try pixels(try #require(session.activeLayer?.asset?.linearPlane))
        let brightest = darker.map { max($0.x, $0.y, $0.z) }.max() ?? 0
        #expect(brightest > 0.75 && brightest < 1.25, "\(brightest)")
        let provenance = try LWCatalogCodec.decode(LWMediaFullRenderProvenance.self, from: node.provenance)
        #expect(provenance.notes.contains { $0.contains("camera profile matrix") })
        let file = root.appendingPathComponent("Provenance.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: file)
        let reopened = try await ProjectStore.shared.load(from: file)
        let restored = try #require(reopened.manifest.layers.first?.liveSource)
        #expect(restored.provenance == node.provenance && restored.metadata == node.metadata)
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    // AC2: embedded camera-profile calibration and the transparency mask are retained for each checked-in DNG.
    @Test(arguments: checkedInDNGs)
    func checkedInDNGRetainsProfileCalibrationAndAlpha(_ name: String) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = try checkedIn(name, into: root)
        let hash = try sha256(original)
        let session = try await importedSession(original)
        let layer = try #require(session.activeLayer)
        let node = try #require(layer.liveSource)
        let provenance = try LWCatalogCodec.decode(LWMediaFullRenderProvenance.self, from: node.provenance)
        if name != "generated-linear-mask.dng" { #expect(provenance.calibration != nil, "the embedded profile calibration is recorded") }
        let samples = try pixels(try #require(layer.asset?.linearPlane))
        let alphas = Set(samples.map { ($0.w * 255).rounded() })
        #expect(alphas.isSuperset(of: [0, 128, 255]), "zero, partial and opaque mask samples are kept as straight alpha")
        #expect(samples.contains { $0.w > 0 && ($0.x < 0 || $0.y < 0 || $0.z < 0 || max($0.x, $0.y, $0.z) > 1) },
                "out-of-sRGB and over-one colors survive in float")
        #expect(try sha256(original) == hash)
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    // AC2: the displayed layer image is color managed from extended linear sRGB, so a wide-gamut display shows
    // colors outside sRGB instead of a clipped copy.
    @Test func liveRawLayerImageIsColorManagedForWideGamutDisplay() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try await importedSession(try checkedIn("generated-linear-mask.dng", into: root))
        let asset = try #require(session.activeLayer?.asset)
        let image = asset.image
        #expect(image.colorSpace?.name == CGColorSpace.extendedLinearSRGB)
        #expect(image.bitmapInfo.contains(.floatComponents))
        let samples = try pixels(try #require(asset.linearPlane))
        let index = try #require(samples.firstIndex { $0.w == 1 && min($0.x, $0.y, $0.z) < -0.01 })
        let p3 = try #require(CGColorSpace(name: CGColorSpace.extendedLinearDisplayP3))
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 32,
            bytesPerRow: image.width * 16, space: p3,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.interpolationQuality = .none
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data).assumingMemoryBound(to: Float.self)
        let x = index % image.width, y = index / image.width
        let shown = (0..<3).map { Double(data[(y * image.width + x) * 4 + $0]) }
        let source = samples[index]
        let linear = try #require(CGColorSpace(name: CGColorSpace.extendedLinearSRGB))
        let converted = try #require(CGColor(colorSpace: linear, components: [CGFloat(source.x), CGFloat(source.y), CGFloat(source.z), 1])?
            .converted(to: p3, intent: .relativeColorimetric, options: nil)?.components)
        for channel in 0..<3 { #expect(abs(shown[channel] - Double(converted[channel])) < 2e-3, "\(shown) \(converted)") }
        #expect(source.y < 0 || source.x < 0 || source.z < 0)
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    // AC2: a recipe change and a source change both invalidate renders of the affected source.
    @Test func recipeAndSourceChangesInvalidateRenders() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("invalidate.dng")
        try ProceduralDNG.write(to: original, width: 64, height: 48)
        let session = try await importedSession(original)
        let before = try #require(session.activeLayer?.asset)
        let cachedBefore = DownsampleCache.shared.image(before.image, level: 1).image
        try await commitCameraRaw(session, whiteBalance: .asShot) { $0.exposure = 1 }
        let after = try #require(session.activeLayer?.asset)
        #expect(after.image !== before.image, "a recipe change publishes a new layer image, the canvas caches' identity key")
        #expect(DownsampleCache.shared.image(after.image, level: 1).image !== cachedBefore)
        #expect(try pixels(try #require(after.linearPlane)) != pixels(try #require(before.linearPlane)))
        // The original changed on disk: development refuses instead of serving the old render.
        let node = try #require(session.activeLayer?.liveSource)
        _ = try await LWSourceDeveloper.shared.evaluatePlane(node)
        var bytes = try Data(contentsOf: original); bytes[bytes.count - 1] ^= 0xff
        try bytes.write(to: original)
        await #expect(throws: (any Error).self) { _ = try await LWSourceDeveloper.shared.evaluatePlane(node) }
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    // AC3: preview and full resolution share one development, agreeing within the declared tolerance; the export
    // develops the original at full size rather than reusing a browse preview.
    @Test func previewAndFullResolutionAgreeAndExportIsNotTheBrowsePreview() async throws {
        let tolerance = try JSONDecoder().decode(Tolerance.self, from: Data(contentsOf: Self.repository.appendingPathComponent("RAW_PREVIEW_TOLERANCE.json")))
        #expect(tolerance.schema == 1 && tolerance.per_channel_max_abs > 0)
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var fixtures = try Self.checkedInDNGs.map { try checkedIn($0, into: root) }
        let large = root.appendingPathComponent("procedural-large.dng")
        try ProceduralDNG.write(to: large, width: 2200, height: 1240)
        let rotated = root.appendingPathComponent("procedural-rotated.dng")
        try ProceduralDNG.write(to: rotated, width: 2100, height: 1180, orientation: 6)
        fixtures += [large, rotated]
        for url in fixtures {
            print("AC3 import", url.lastPathComponent)
            let session = try await importedSession(url)
            print("AC3 commit", url.lastPathComponent)
            try await commitCameraRaw(session, whiteBalance: .temperatureTint(kelvin: 5200, tint: 6)) {
                $0.exposure = 0.4; $0.contrast = 15; $0.highlights = -20; $0.shadows = 10; $0.vibrance = 10
            }
            let layer = try #require(session.activeLayer)
            let node = try #require(layer.liveSource)
            let shown = try #require(layer.asset)
            // Preview: the developed layer as the Camera Raw panel shows it, reduced to the preview limit.
            let preview = try FilterEdit.prepared(kind: .cameraRaw, from: shown.image, placed: layer.transform).previewSource
            // Full resolution: the export path develops the original again at full size.
            print("AC3 export", url.lastPathComponent)
            let full = try await ImageExporter.shared.renderPlane(try #require(session.projectSnapshot()))
            print("AC3 compare", url.lastPathComponent)
            #expect(full.width == node.originalWidth && full.height == node.originalHeight,
                    "export is the full-resolution development: \(url.lastPathComponent)")
            let reduced = try FilterEdit.prepared(kind: .cameraRaw, from: LWFloatPlaneImage(plane: full).image(), placed: layer.transform).previewSource
            #expect(reduced.width == preview.width && reduced.height == preview.height)
            if max(full.width, full.height) > Int(FilterEdit.previewLimit) { #expect(max(preview.width, preview.height) == Int(FilterEdit.previewLimit)) }
            let a = try LWLinearSurface.read(preview, maximumBytes: LWSourceDeveloper.maximumResultBytes)
            let b = try LWLinearSurface.read(reduced, maximumBytes: LWSourceDeveloper.maximumResultBytes)
            var worst: Float = 0
            for (p, q) in zip(a.pixels, b.pixels) { worst = max(worst, abs(p.x - q.x), abs(p.y - q.y), abs(p.z - q.z), abs(p.w - q.w)) }
            #expect(Double(worst) <= tolerance.per_channel_max_abs, "\(url.lastPathComponent): \(worst)")
            // The exported plane keeps float headroom a quantized browse preview cannot carry.
            if url == large { #expect(try pixels(full).contains { max($0.x, $0.y, $0.z) > 1 }) }
        }
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }
}
