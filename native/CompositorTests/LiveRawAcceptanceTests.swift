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
    /// `blockRamp`: when nonzero the white block blends into the gradient over that many pixels
    /// (smoothstep) instead of a hard edge.
    static func write(to url: URL, width: Int, height: Int, orientation: UInt16 = 1, blockRamp: Int = 0) throws {
        var pixels = Data(capacity: width * height * 6)
        for y in 0..<height {
            for x in 0..<width {
                let fx = Double(x) / Double(max(1, width - 1)), fy = Double(y) / Double(max(1, height - 1))
                var rgb = [0.05 + 0.45 * fx, 0.05 + 0.6 * fy, 0.4 - 0.3 * fx * fy]
                if blockRamp > 0 {
                    let outside = Double(max(0, x - width / 6 + 1, y - height / 6 + 1)) / Double(blockRamp)
                    let t = outside >= 1 ? 0 : 1 - outside * outside * (3 - 2 * outside)
                    rgb = rgb.map { $0 + (1 - $0) * t }
                } else if x < width / 6, y < height / 6 { rgb = [1, 1, 1] }
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

    /// The RAW develop request an import waits on: the sheet goes up with the file's as-shot settings and the
    /// import resumes with what the person chose, or with nothing when they cancel; a caller that answers for
    /// itself is asked instead of the sheet.
    @Test func rawDevelopRequestWaitsForTheSheetAndResumesWithItsChoice() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("develop.dng")
        try ProceduralDNG.write(to: original, width: 32, height: 24)
        let session = EditorSession()
        func request() async throws -> Task<RawDevelopSettings?, Never> {
            let task = Task { await session.developRaw(original) }
            for _ in 0..<2000 where session.rawDevelop == nil { try await Task.sleep(for: .milliseconds(2)) }
            return task
        }
        // Import: the sheet shows the file and its as-shot settings; the request returns the edited settings.
        var pending = try await request()
        let shown = try #require(session.rawDevelop)
        #expect(shown.url == original && shown.settings.isAsShot && session.showsRawDevelop)
        var chosen = shown.settings; chosen.exposure = 0.5
        session.finishRawDevelop(chosen)
        #expect(await pending.value == chosen)
        #expect(session.rawDevelop == nil && !session.showsRawDevelop)
        // Cancel: nothing comes back and the sheet is gone.
        pending = try await request()
        session.finishRawDevelop(nil)
        #expect(await pending.value == nil)
        #expect(session.rawDevelop == nil && !session.showsRawDevelop)
        // A caller that confirms for itself is asked with the same as-shot settings, and no sheet goes up.
        var asked: [(URL, RawDevelopSettings)] = []
        session.confirmRawDevelop = { url, settings in asked.append((url, settings)); var edited = settings; edited.boost = 0; return edited }
        let confirmed = await session.developRaw(original)
        #expect(asked.count == 1 && asked.first?.0 == original && asked.first?.1 == shown.settings)
        #expect(confirmed?.boost == 0 && session.rawDevelop == nil && !session.showsRawDevelop)
    }

    // AC1: RAW controls stay editable under layers across save/reopen; the original is never written.
    @Test func rawControlsStayEditableUnderLayersAfterSaveAndReopen() async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let original = root.appendingPathComponent("procedural.dng")
        try ProceduralDNG.write(to: original, width: 96, height: 64)
        let originalHash = try sha256(original)
        let session = try await importedSession(original)
        let rawID = try #require(session.activeLayerID)
        // Every retained RAW/basic control group at a non-default value.
        var expected = CameraRawSettings()
        expected.exposure = 0.75; expected.contrast = 20; expected.highlights = -30; expected.shadows = 25; expected.whites = 10; expected.blacks = -5
        expected.temperature = 8; expected.tint = -4; expected.vibrance = 15; expected.saturation = -10
        expected.texture = 5; expected.clarity = 10; expected.dehaze = 5
        expected.curve.rgb = CameraRawCurveSettings.mediumContrast; expected.curve.shadows = 7; expected.curve.refineSaturation = -13
        expected.mixer.hue[1] = 31; expected.mixer.saturation[5] = -27; expected.mixer.luminance[6] = 18
        expected.grading.shadows.hue = 35; expected.grading.shadows.saturation = 12; expected.grading.global.luminance = 9
        expected.detail.sharpenAmount = 71; expected.detail.sharpenRadius = 74; expected.detail.sharpenDetail = 49; expected.detail.sharpenMasking = 38
        expected.detail.noiseLuminance = 77; expected.detail.noiseLuminanceDetail = 81; expected.detail.noiseColor = 72
        expected.optics.distortion = 28; expected.optics.removeChromaticAberration = true; expected.optics.purpleAmount = 23
        expected.geometry.horizontal = 21; expected.geometry.vertical = -16; expected.geometry.rotate = 4; expected.geometry.constrainCrop = true
        expected.calibration.process = .version2; expected.calibration.redHue = 28; expected.calibration.blueSaturation = -17; expected.calibration.shadowTint = 9
        expected.vignetteAmount = -43; expected.vignetteMidpoint = 36; expected.vignetteRoundness = 21
        expected.grainAmount = 67; expected.grainSize = 39; expected.grainRoughness = 82
        expected.glow = 65; expected.glowSpread = 63; expected.glowRange = 24; expected.glowWarmth = -31
        func expectEveryGroup(_ actual: CameraRawSettings, _ wanted: CameraRawSettings, _ stage: String) {
            #expect([actual.exposure, actual.contrast, actual.highlights, actual.shadows, actual.whites, actual.blacks,
                     actual.temperature, actual.tint, actual.vibrance, actual.saturation, actual.texture, actual.clarity, actual.dehaze]
                    == [wanted.exposure, wanted.contrast, wanted.highlights, wanted.shadows, wanted.whites, wanted.blacks,
                        wanted.temperature, wanted.tint, wanted.vibrance, wanted.saturation, wanted.texture, wanted.clarity, wanted.dehaze], "basic \(stage)")
            #expect(actual.curve == wanted.curve, "curve \(stage)"); #expect(actual.mixer == wanted.mixer, "mixer \(stage)")
            #expect(actual.grading == wanted.grading, "grading \(stage)"); #expect(actual.detail == wanted.detail, "detail \(stage)")
            #expect(actual.optics == wanted.optics, "optics \(stage)"); #expect(actual.geometry == wanted.geometry, "geometry \(stage)")
            #expect(actual.calibration == wanted.calibration, "calibration \(stage)")
            #expect([actual.vignetteAmount, actual.vignetteMidpoint, actual.vignetteRoundness] == [wanted.vignetteAmount, wanted.vignetteMidpoint, wanted.vignetteRoundness], "vignette \(stage)")
            #expect([actual.grainAmount, actual.grainSize, actual.grainRoughness] == [wanted.grainAmount, wanted.grainSize, wanted.grainRoughness], "grain \(stage)")
            #expect([actual.glow, actual.glowSpread, actual.glowRange, actual.glowWarmth] == [wanted.glow, wanted.glowSpread, wanted.glowRange, wanted.glowWarmth], "glow \(stage)")
            #expect(actual == wanted, "every retained control \(stage)")
        }
        let defaults = CameraRawSettings()
        #expect(expected.curve != defaults.curve && expected.mixer != defaults.mixer && expected.grading != defaults.grading
                && expected.detail != defaults.detail && expected.optics != defaults.optics && expected.geometry != defaults.geometry
                && expected.calibration != defaults.calibration, "every group is set away from its default")
        try await commitCameraRaw(session, whiteBalance: .temperatureTint(kelvin: 4800, tint: 12)) { $0 = expected }
        let developed = try #require(session.activeLayer?.liveSource)
        expectEveryGroup(developed.settings, expected, "after commit")
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
        expectEveryGroup(source.settings, expected, "after save and reopen")
        #expect(source == developed)
        #expect(source.whiteBalance == .temperatureTint(kelvin: 4800, tint: 12))

        // Still live after reopen: change exposure and white balance again beneath the overlay.
        restored.activeLayerID = rawID
        let before = try pixels(try #require(restored.activeLayer?.asset?.linearPlane))
        try await commitCameraRaw(restored, whiteBalance: .asShot) { $0.exposure = -0.5 }
        let edited = try #require(restored.activeLayer)
        #expect(edited.liveSource?.whiteBalance == .asShot)
        var reedited = expected; reedited.exposure = -0.5
        expectEveryGroup(try #require(edited.liveSource?.settings), reedited, "after editing exposure on the reopened layer")
        #expect(try pixels(try #require(edited.asset?.linearPlane)) != before)
        #expect(restored.document?.layers.map(\.id) == [rawID, overlay])
        restored.undo()
        #expect(restored.activeLayer?.liveSource == developed)
        #expect(try sha256(original) == originalHash)
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    // AC2: float working data keeps highlight latitude; orientation applies; profile provenance survives save/reopen.
    /// EXIF orientation: the displayed (u, v) of stored pixel (x, y) in a stored w x h image.
    private static func displayed(_ orientation: UInt16, x: Int, y: Int, w: Int, h: Int) -> (u: Int, v: Int) {
        switch orientation {
        case 2: return (w - 1 - x, y)          // mirrored horizontally
        case 3: return (w - 1 - x, h - 1 - y)  // rotated 180
        case 4: return (x, h - 1 - y)          // mirrored vertically
        case 5: return (y, x)                  // transposed
        case 6: return (h - 1 - y, x)          // rotated 90 clockwise
        case 7: return (h - 1 - y, w - 1 - x)  // transversed
        case 8: return (y, w - 1 - x)          // rotated 90 counter-clockwise
        default: return (x, y)
        }
    }

    @Test(arguments: [UInt16(1), 2, 3, 4, 5, 6, 7, 8])
    func floatWorkingDataKeepsLatitudeOrientationAndProfileProvenance(_ orientation: UInt16) async throws {
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        let (w, h) = (60, 36)
        // The same stored samples with orientation 1 give the unrotated reference development.
        let upright = root.appendingPathComponent("upright.dng")
        try ProceduralDNG.write(to: upright, width: w, height: h)
        let reference = try pixels(try #require(try await importedSession(upright).activeLayer?.asset?.linearPlane))
        let original = root.appendingPathComponent("oriented-\(orientation).dng")
        try ProceduralDNG.write(to: original, width: w, height: h, orientation: orientation)
        let session = try await importedSession(original)
        let layer = try #require(session.activeLayer)
        let node = try #require(layer.liveSource)
        let plane = try #require(layer.asset?.linearPlane)
        let transposed = orientation >= 5
        #expect(plane.width == (transposed ? h : w) && plane.height == (transposed ? w : h))
        // Pixel placement: every stored sample lands where EXIF orientation puts it, mirrored cases included.
        let oriented = try pixels(plane)
        var misplaced = 0
        for y in 0..<h { for x in 0..<w {
            let target = Self.displayed(orientation, x: x, y: y, w: w, h: h)
            let a = oriented[target.v * plane.width + target.u], e = reference[y * w + x]
            if (0..<4).contains(where: { abs(a[$0] - e[$0]) > 1e-5 }) { misplaced += 1 }
        } }
        #expect(misplaced == 0, "orientation \(orientation): \(misplaced) of \(w * h) samples misplaced")
        // The bright block sits at the stored top-left; it must appear at the oriented corner.
        let corner = Self.displayed(orientation, x: 0, y: 0, w: w, h: h)
        #expect(max(oriented[corner.v * plane.width + corner.u].x, 0) > 1, "orientation \(orientation) block corner")
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

    // AC3: the Camera Raw preview the user sees and the full-resolution export come from one development
    // code path. The preview is developed on a reduced grid; the export re-develops the original at full
    // size; after the export is reduced to the preview grid the two agree within the declared tolerance.
    @Test func previewAndFullResolutionAgreeAndExportIsNotTheBrowsePreview() async throws {
        let tolerance = try JSONDecoder().decode(Tolerance.self, from: Data(contentsOf: Self.repository.appendingPathComponent("RAW_PREVIEW_TOLERANCE.json")))
        #expect(tolerance.schema == 1 && tolerance.per_channel_max_abs > 0)
        let root = try folder(); defer { try? FileManager.default.removeItem(at: root) }
        var fixtures = try Self.checkedInDNGs.map { try checkedIn($0, into: root) }
        // Two fixtures larger than the preview limit exercise the reduced preview grid. Development is
        // nonlinear, so it does not commute with resampling across a discontinuity (a pixel straddling
        // a hard white edge differs by ~0.2 whichever path is used); their bright block therefore meets
        // the gradient over a 128 px ramp, and the comparison measures the shared code path.
        let large = root.appendingPathComponent("procedural-large.dng")
        try ProceduralDNG.write(to: large, width: 2200, height: 1240, blockRamp: 128)
        let rotated = root.appendingPathComponent("procedural-rotated.dng")
        try ProceduralDNG.write(to: rotated, width: 2100, height: 1180, orientation: 6, blockRamp: 128)
        fixtures += [large, rotated]
        for url in fixtures {
            let session = try await importedSession(url)
            try await commitCameraRaw(session, whiteBalance: .temperatureTint(kelvin: 5200, tint: 6)) {
                $0.exposure = 0.4; $0.contrast = 15; $0.highlights = -20; $0.shadows = 10; $0.vibrance = 10
            }
            let layer = try #require(session.activeLayer)
            let node = try #require(layer.liveSource)
            // Preview: open Camera Raw on the committed layer and let the live preview render; this is the
            // image the canvas shows (FilterEdit.preparedPreview), developed by the product preview task.
            session.beginFilter(.cameraRaw)
            let edit = try #require(session.filterEdit)
            session.updateFilter(edit.settings, preview: true)
            for _ in 0..<8 { guard let task = edit.previewTask else { break }; await task.value }
            #expect(edit.previewTask == nil && !edit.preparing)
            #expect(edit.previewError == nil, "\(edit.previewError ?? "")")
            let shown = try #require(edit.preparedPreview, "the preview task published a displayed image")
            let previewSurface = try #require(edit.livePreviewSurface)
            session.cancelFilter()
            let expectedGrid = LWSourceDeveloper.previewExtent(width: node.originalWidth, height: node.originalHeight,
                                                              maximumSide: Int(FilterEdit.previewLimit))
            #expect(shown.width == (expectedGrid?.width ?? node.originalWidth) && shown.height == (expectedGrid?.height ?? node.originalHeight),
                    "the preview is developed on the preview grid, not reduced from a full-size development: \(url.lastPathComponent)")
            #expect(previewSurface.width == shown.width && previewSurface.height == shown.height)
            // Full resolution: the export re-develops the original from source.
            let before = await LWSourceDeveloper.shared.fullResolutionDevelopments
            let full = try await ImageExporter.shared.renderPlane(try #require(session.projectSnapshot()))
            let after = await LWSourceDeveloper.shared.fullResolutionDevelopments
            #expect(after == before + 1, "export develops the original again instead of reusing layer pixels: \(url.lastPathComponent)")
            #expect(full.width == node.originalWidth && full.height == node.originalHeight,
                    "export is the full-resolution development: \(url.lastPathComponent)")
            // Reduce the export to the preview grid with the same exact area average the preview applies to its source.
            let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
            let reduced = shown.width == full.width && shown.height == full.height ? full
                : try LWFloatCompositor.downscale(full, width: shown.width, height: shown.height, workspace: workspace)
            let a = try LWLinearSurface.read(shown, maximumBytes: LWSourceDeveloper.maximumResultBytes)
            let b = try pixels(reduced)
            #expect(a.pixels.count == b.count)
            var worst: Float = 0
            for (p, q) in zip(a.pixels, b) where p.w > 0 || q.w > 0 {
                worst = max(worst, abs(p.x * p.w - q.x * q.w), abs(p.y * p.w - q.y * q.w), abs(p.z * p.w - q.z * q.w), abs(p.w - q.w))
            }
            print("AC3 \(url.lastPathComponent): preview \(shown.width)x\(shown.height), worst per-channel \(worst)")
            #expect(Double(worst) <= tolerance.per_channel_max_abs, "\(url.lastPathComponent): \(worst)")
            // The exported plane keeps float headroom a quantized browse preview cannot carry.
            if url == large { #expect(try pixels(full).contains { max($0.x, $0.y, $0.z) > 1 }) }
        }
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }
}
