import Foundation
import Testing
import CoreGraphics
import ImageIO
import SQLite3
import simd
@testable import Compositor

/// The S47 generator's rotated-camera panorama set (`--rotation-panorama`): one procedural scene
/// seen by a pinhole camera that only rotates, in a plain series and a series whose frames
/// differ in exposure and carry lens falloff. Every frame's rotation is ground truth.
nonisolated struct PanoramaFixture {
    struct Frame: Decodable, Sendable {
        let path: String, series: String, sha256: String
        let camera_to_world: [Double]
        let exposure_stops: Double, vignetting: Double
        var rotation: simd_double3x3 {
            simd_double3x3(rows: [SIMD3(camera_to_world[0], camera_to_world[1], camera_to_world[2]), SIMD3(camera_to_world[3], camera_to_world[4], camera_to_world[5]), SIMD3(camera_to_world[6], camera_to_world[7], camera_to_world[8])])
        }
    }
    static let seed: UInt32 = 25322
    let root: URL
    let focal: Double
    let frames: [Frame]

    /// Generates the set into a fresh private folder: `Photos` holds the six frames.
    static func make() throws -> PanoramaFixture {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("LWPano-\(UUID())")
        let generated = root.appendingPathComponent("generated")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try S47Generator.run(output: generated, seed: seed, arguments: ["--rotation-panorama"])
        struct Manifest: Decodable {
            struct Section: Decodable { struct Parameters: Decodable { let focal_pixels: Double }; let parameters: Parameters; let photos: [Frame] }
            let rotation_panorama: Section
        }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: generated.appendingPathComponent("fixture-manifest.json")))
        let photos = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: false)
        for frame in manifest.rotation_panorama.photos {
            try FileManager.default.copyItem(at: generated.appendingPathComponent(frame.path), to: photos.appendingPathComponent(URL(fileURLWithPath: frame.path).lastPathComponent))
        }
        try FileManager.default.removeItem(at: generated)
        return PanoramaFixture(root: root, focal: manifest.rotation_panorama.parameters.focal_pixels, frames: manifest.rotation_panorama.photos)
    }
    func frames(_ series: String) -> [Frame] { frames.filter { $0.series == series } }
    func file(_ frame: Frame) -> URL { root.appendingPathComponent("Photos").appendingPathComponent(URL(fileURLWithPath: frame.path).lastPathComponent) }
    func files(_ series: String) -> [URL] { frames(series).map(file) }
    func hashes() throws -> [String] { try frames.map { try LensWorksCatalog.sha256(file($0)) } }
    /// Keeps only one series in `Photos`, for a catalog that should hold just those three.
    func keepOnly(_ series: String) throws { for frame in frames where frame.series != series { try FileManager.default.removeItem(at: file(frame)) } }
    func developed(_ series: String) async throws -> [LWMergeFrame] {
        var result: [LWMergeFrame] = []
        for url in files(series) { result.append(try await LensWorksCatalog.developPanoramaFrame(original: try LWCatalogNativePath(fileURL: url), url: url, frames: 3)) }
        return result
    }
    static func tolerance() throws -> Double {
        struct Declared: Decodable { let seam_error_max_stops: Double }
        return try JSONDecoder().decode(Declared.self, from: Data(contentsOf: S47Generator.repository.appendingPathComponent("PANORAMA_SEAM_TOLERANCE.json"))).seam_error_max_stops
    }
}

/// A procedural scene on the sphere of directions and pinhole views of it with known rotation:
/// the same construction as the generator's rotated-camera set, for layouts it does not ship
/// (two frames, five, a grid, a full circle, frames that do not belong).
nonisolated enum PanoramaSyntheticScene {
    static func mix(_ seed: UInt32, _ x: Int, _ y: Int) -> UInt32 {
        var v = seed ^ (UInt32(truncatingIfNeeded: x) &* 0x9E3779B1) ^ (UInt32(truncatingIfNeeded: y) &* 0x85EBCA77)
        v ^= v >> 16; v = v &* 0x7FEB352D; v ^= v >> 15; v = v &* 0x846CA68B
        return v ^ (v >> 16)
    }
    @inline(__always) static func smooth(_ low: Double, _ high: Double, _ value: Double) -> Double {
        let t = min(1, max(0, (value - low) / (high - low)))
        return t * t * (3 - 2 * t)
    }
    static func shape(_ seed: UInt32, _ longitude: Double, _ latitude: Double, cell: Double) -> (Double, UInt32) {
        let column = Int((longitude / cell).rounded(.down)), row = Int((latitude / cell).rounded(.down))
        let noise = mix(seed, column, row)
        let cx = (Double(column) + 0.32 + 0.36 * Double(noise & 0xFF) / 255) * cell, cy = (Double(row) + 0.32 + 0.36 * Double((noise >> 8) & 0xFF) / 255) * cell
        let radius = cell * (0.14 + 0.14 * Double((noise >> 16) & 0xFF) / 255)
        let dx = longitude - cx, dy = latitude - cy
        var distance = (dx * dx + dy * dy).squareRoot()
        if noise & 0x1000000 != 0 {
            let angle = Double((noise >> 25) & 0x3F) / 63 * .pi / 2
            distance = max(abs(cos(angle) * dx + sin(angle) * dy), abs(cos(angle) * dy - sin(angle) * dx))
        }
        return (1 - smooth(radius - 0.3, radius + 0.3, distance), noise)
    }
    /// Linear radiance in [0.06, 0.6] along a world direction (x right, y down, z forward).
    static func radiance(_ seed: UInt32, _ d: SIMD3<Double>) -> SIMD3<Double> {
        let longitude = atan2(d.x, d.z) * 180 / .pi, latitude = atan2(d.y, (d.x * d.x + d.z * d.z).squareRoot()) * 180 / .pi
        let ground = smooth(-6, 6, latitude + 3 * sin(longitude * 3 * .pi / 180)), wave = 0.5 + 0.5 * sin((longitude * 2.3 + latitude * 1.1) * .pi / 180)
        var colour = SIMD3(0.16 + 0.10 * ground + 0.05 * wave, 0.22 + 0.04 * ground + 0.04 * (1 - wave), 0.34 - 0.20 * ground + 0.04 * wave)
        let (large, a) = shape(seed, longitude, latitude, cell: 4)
        if large > 0 {
            let tint = SIMD3(0.08 + 0.5 * Double((a >> 3) & 0x1F) / 31, 0.08 + 0.5 * Double((a >> 11) & 0x1F) / 31, 0.08 + 0.5 * Double((a >> 19) & 0x1F) / 31)
            colour += (tint - colour) * large
        }
        let (small, b) = shape(seed ^ 0x5A17C3D1, longitude, latitude, cell: 2.2)
        if small > 0 { colour += (SIMD3(repeating: b & 0x20000000 != 0 ? 0.07 : 0.58) - colour) * small * 0.8 }
        return simd_clamp(colour, SIMD3(repeating: 0.06), SIMD3(repeating: 0.6))
    }
    /// Camera-to-world rotation: yaw about y, then pitch about x, then roll about z, in degrees.
    static func rotation(yaw: Double, pitch: Double = 0, roll: Double = 0) -> simd_double3x3 {
        func turn(_ degrees: Double, _ axis: SIMD3<Double>) -> simd_double3x3 { simd_double3x3(simd_quatd(angle: degrees * .pi / 180, axis: axis)) }
        return turn(yaw, SIMD3(0, 1, 0)) * turn(pitch, SIMD3(1, 0, 0)) * turn(roll, SIMD3(0, 0, 1))
    }
    static func view(seed: UInt32 = PanoramaFixture.seed, rotation: simd_double3x3, width: Int = 320, height: Int = 240, focal: Double = 300, gain: Double = 1) throws -> LWMergeFrame {
        var samples = [Float16](repeating: 0, count: width * height * 3)
        for y in 0..<height {
            for x in 0..<width {
                let d = rotation * SIMD3((Double(x) - Double(width - 1) / 2) / focal, (Double(y) - Double(height - 1) / 2) / focal, 1)
                let value = radiance(seed, d) * gain, o = (y * width + x) * 3
                samples[o] = Float16(value.x); samples[o + 1] = Float16(value.y); samples[o + 2] = Float16(value.z)
            }
        }
        return try LWMergeFrame(width: width, height: height, samples: samples)
    }
    static func views(_ rotations: [simd_double3x3]) throws -> [LWMergeFrame] { try rotations.map { try view(rotation: $0) } }
    /// The angle, in degrees, between two rotations.
    static func angle(_ a: simd_double3x3, _ b: simd_double3x3) -> Double {
        let r = a.transpose * b
        return acos(max(-1, min(1, (r[0][0] + r[1][1] + r[2][2] - 1) / 2))) * 180 / .pi
    }
    /// Writes a frame as an sRGB PNG, for a catalog to import.
    static func write(_ frame: LWMergeFrame, to url: URL) throws {
        var bytes = [UInt8](repeating: 255, count: frame.width * frame.height * 4)
        func encode(_ v: Float) -> UInt8 { let c = min(1, max(0, v)); return UInt8((c <= 0.0031308 ? c * 12.92 : 1.055 * pow(c, 1 / 2.4) - 0.055) * 255 + 0.5) }
        for p in 0..<(frame.width * frame.height) { let v = frame.rgb(p); bytes[p * 4] = encode(v.x); bytes[p * 4 + 1] = encode(v.y); bytes[p * 4 + 2] = encode(v.z) }
        let space = try #require(CGColorSpace(name: CGColorSpace.sRGB)), provider = try #require(CGDataProvider(data: Data(bytes) as CFData))
        let image = try #require(CGImage(width: frame.width, height: frame.height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: frame.width * 4, space: space,
            bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
        let destination = try #require(CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil))
        CGImageDestinationAddImage(destination, image, nil)
        #expect(CGImageDestinationFinalize(destination))
    }
}

@Suite(.serialized)
@MainActor
struct PanoramaMergeTests {
    typealias Scene = PanoramaSyntheticScene

    /// AC1. The tolerance is declared in PANORAMA_SEAM_TOLERANCE.json; the metric lives with
    /// LWPanoramaSeamMetric and docs/PANORAMA_MERGE.md.
    @Test func generatedSetStitchesUnderEveryProjectionWithinTheSeamTolerance() async throws {
        let fixture = try PanoramaFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tolerance = try PanoramaFixture.tolerance()
        #expect(tolerance == 0.04)
        let before = try fixture.hashes()
        #expect(before == fixture.frames.map(\.sha256) && fixture.frames.count == 6)
        for series in ["plain", "exposure"] {
            let truth = fixture.frames(series), frames = try await fixture.developed(series)
            #expect(frames.count == 3 && frames.allSatisfy { $0.width == 320 && $0.height == 240 })
            let (alignment, works) = try LWPanoramaStitcher.align(frames)
            // Ground truth: the camera's focal length and each frame's rotation relative to the centre frame.
            #expect(abs(alignment.focal - fixture.focal) / fixture.focal < 0.02, "\(series) focal \(alignment.focal)")
            #expect(alignment.pairs.map { [$0.first, $0.second] } == [[0, 1], [1, 2]], "\(alignment.pairs)")
            for index in [0, 2] {
                let solved = alignment.rotations[1].transpose * alignment.rotations[index], expected = truth[1].rotation.transpose * truth[index].rotation
                #expect(Scene.angle(solved, expected) < 0.5, "\(series) frame \(index): \(Scene.angle(solved, expected))° from the truth")
            }
            if series == "exposure" {
                // The frames' exposure differences and the lens falloff are recovered.
                let stops = alignment.gains.map { Double(log2($0.y)) }
                #expect(abs((stops[0] - stops[1]) - (truth[0].exposure_stops - truth[1].exposure_stops)) < 0.06 && abs((stops[2] - stops[1]) - (truth[2].exposure_stops - truth[1].exposure_stops)) < 0.06, "\(stops)")
                #expect(abs(alignment.vignetting.x + alignment.vignetting.y - log2(1 - truth[0].vignetting)) < 0.06, "\(alignment.vignetting)")
            } else {
                #expect(alignment.gains.allSatisfy { abs(log2($0.y)) < 0.03 } && alignment.vignetting == .zero, "\(alignment.gains) \(alignment.vignetting)")
            }
            for projection in LWPanoramaProjection.allCases {
                for boundary in LWPanoramaBoundary.allCases {
                    let result = try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: projection, boundary: boundary))
                    let seam = LWPanoramaSeamMetric.measure(result, frames: frames)
                    print("S44 seam error, \(series) series, \(projection.rawValue), \(boundary.rawValue): E \(seam.value) (A \(seam.agreement), D \(seam.step)) over \(seam.bandPixels) band pixels and \(seam.seamPairs) seam pairs; tolerance \(tolerance)")
                    #expect(seam.value < tolerance, "\(series) \(projection) \(boundary): \(seam.value)")
                    #expect(seam.bandPixels > 2000 && seam.seamPairs > 200)
                    #expect(Set(result.labels).subtracting([255]) == [0, 1, 2], "every frame supplies part of the picture")
                    #expect(result.width > 500 && result.bands >= 3)
                }
            }
        }
        #expect(try fixture.hashes() == before)
    }

    /// How the seam metric was checked: it must fail when registration, exposure compensation or
    /// blending is broken, by the component that sees each.
    @Test func theSeamMetricFailsWhenRegistrationCompensationOrBlendingIsBroken() async throws {
        let fixture = try PanoramaFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let tolerance = try PanoramaFixture.tolerance()
        let frames = try await fixture.developed("exposure")
        let (alignment, works) = try LWPanoramaStitcher.align(frames)
        func measure(_ alignment: LWPanoramaAlignment, _ options: LWPanoramaOptions = .init()) throws -> LWPanoramaSeamMetric.Measurement {
            LWPanoramaSeamMetric.measure(try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: options), frames: frames)
        }
        let sound = try measure(alignment)
        #expect(sound.value < tolerance)
        // Registration: one frame turned a quarter of a degree (1.3 pixels), then half a degree.
        for (degrees, factor) in [(0.25, 1.4), (0.5, 2.5)] {
            var turned = alignment
            turned.rotations[2] = alignment.rotations[2] * LWPanoramaStitcher.rotation(vector: SIMD3(0, degrees * .pi / 180, 0))
            let broken = try measure(turned)
            print("S44 seam error with frame 3 turned \(degrees)°: \(broken.value) (A \(broken.agreement), D \(broken.step))")
            #expect(broken.agreement > factor * tolerance, "\(degrees)°: \(broken.agreement)")
        }
        // Exposure compensation: one frame's gain a fifth off, and no compensation at all.
        var misexposed = alignment
        misexposed.gains[2] *= 1.2
        #expect(try measure(misexposed).agreement > 2 * tolerance)
        let uncompensated = try measure(alignment, LWPanoramaOptions(compensateExposure: false))
        #expect(uncompensated.agreement > 5 * tolerance)
        // Blending: with the exposure difference left in, a cut without blending steps across the
        // seam; multi-band blending takes the step out (the frames still disagree, so A fails).
        let cut = try measure(alignment, LWPanoramaOptions(compensateExposure: false, blend: .none))
        print("S44 seam error uncompensated: cut \(cut.value) (A \(cut.agreement), D \(cut.step)); blended \(uncompensated.value) (A \(uncompensated.agreement), D \(uncompensated.step))")
        #expect(cut.step > 5 * tolerance && cut.value > 5 * tolerance)
        #expect(uncompensated.step < tolerance && uncompensated.step < cut.step / 5)
        // A cut of compensated, registered frames has no seam to see, and the metric agrees.
        #expect(try measure(alignment, LWPanoramaOptions(blend: .none)).value < tolerance)
    }

    /// AC2.
    @Test func autoCropLeavesNoUncoveredPixelAndFillYieldsTheFullCanvas() async throws {
        let fixture = try PanoramaFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frames = try await fixture.developed("plain")
        let (alignment, works) = try LWPanoramaStitcher.align(frames)
        for projection in LWPanoramaProjection.allCases {
            let cropped = try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: projection, boundary: .autoCrop))
            let filled = try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: projection, boundary: .fill))
            let canvas = filled.geometry
            // Fill: the whole canvas, a full rectangle of finite samples, some of it not covered by any frame.
            #expect(filled.width == canvas.width && filled.height == canvas.height && filled.offsetX == 0 && filled.offsetY == 0)
            #expect(filled.samples.count == filled.width * filled.height * 3 && filled.labels.count == filled.width * filled.height)
            #expect(filled.uncoveredPixels > 1000 && filled.uncoveredPixels == filled.labels.filter { $0 == 255 }.count)
            #expect(filled.samples.allSatisfy { $0.isFinite && $0 >= 0 })
            // The fill continues the picture: every uncovered pixel is within the scene's range and close to its neighbours.
            var worstStep: Float = 0
            for y in 0..<filled.height {
                for x in 0..<filled.width where filled.labels[y * filled.width + x] == 255 {
                    let value = filled.rgb(y * filled.width + x)
                    #expect(value.min() > 0.03 && value.max() < 0.7, "\(projection) fill at \(x),\(y): \(value)")
                    if value.min() <= 0.03 || value.max() >= 0.7 { return }
                    if x + 1 < filled.width, filled.labels[y * filled.width + x + 1] == 255 { worstStep = max(worstStep, simd_reduce_max(abs(filled.rgb(y * filled.width + x + 1) - value))) }
                }
            }
            #expect(worstStep < 0.1, "\(projection) fill steps by \(worstStep)")
            // Auto-crop: no uncovered pixel, inside the canvas, and the same picture as the canvas there.
            #expect(cropped.uncoveredPixels == 0 && !cropped.labels.contains(255))
            #expect(cropped.width > 0 && cropped.height > 0 && cropped.offsetX >= 0 && cropped.offsetY >= 0)
            #expect(cropped.offsetX + cropped.width <= canvas.width && cropped.offsetY + cropped.height <= canvas.height)
            #expect(cropped.samples.count == cropped.width * cropped.height * 3)
            var same = true
            for y in 0..<cropped.height {
                for x in 0..<cropped.width {
                    let p = (y + cropped.offsetY) * filled.width + x + cropped.offsetX
                    if cropped.rgb(y * cropped.width + x) != filled.rgb(p) || cropped.labels[y * cropped.width + x] != filled.labels[p] { same = false }
                }
            }
            #expect(same)
            // It is a largest rectangle: it cannot grow by a row or a column on any side.
            func covered(_ x0: Int, _ y0: Int, _ x1: Int, _ y1: Int) -> Bool {
                guard x0 >= 0, y0 >= 0, x1 <= filled.width, y1 <= filled.height else { return false }
                for y in y0..<y1 { for x in x0..<x1 where filled.labels[y * filled.width + x] == 255 { return false } }
                return true
            }
            let x0 = cropped.offsetX, y0 = cropped.offsetY, x1 = x0 + cropped.width, y1 = y0 + cropped.height
            #expect(covered(x0, y0, x1, y1))
            #expect(!covered(x0 - 1, y0, x1, y1) && !covered(x0, y0 - 1, x1, y1) && !covered(x0, y0, x1 + 1, y1) && !covered(x0, y0, x1, y1 + 1))
            #expect(cropped.width * cropped.height > filled.width * filled.height / 2)
            print("S44 \(projection.rawValue): canvas \(canvas.width) × \(canvas.height), \(filled.uncoveredPixels) uncovered; auto-crop \(cropped.width) × \(cropped.height) at \(cropped.offsetX), \(cropped.offsetY)")
        }
    }

    @Test func theLargestCoveredRectangleIsFoundInAnIrregularCoverage() throws {
        // A plus-shaped coverage: the largest rectangle is the 9 × 3 horizontal bar, not the 3 × 7 vertical one.
        let width = 9, height = 7
        var labels = [UInt8](repeating: 255, count: width * height)
        for y in 0..<height { for x in 0..<width where (2...4).contains(y) || (3...5).contains(x) { labels[y * width + x] = 0 } }
        #expect(try LWPanoramaStitcher.largestCoveredRectangle(labels, width: width, height: height) == LWPanoramaStitcher.Region(x0: 0, y0: 2, x1: 9, y1: 5))
        #expect(try LWPanoramaStitcher.largestCoveredRectangle([UInt8](repeating: 255, count: 12), width: 4, height: 3).width == 0)
        #expect(try LWPanoramaStitcher.largestCoveredRectangle([UInt8](repeating: 1, count: 12), width: 4, height: 3) == LWPanoramaStitcher.Region(x0: 0, y0: 0, x1: 4, y1: 3))
    }

    /// Two frames, five in a row and a two-row grid: the global alignment is not tied to three frames or to one row.
    @Test func twoFramesFiveFramesAndATwoRowGridStitch() throws {
        let tolerance = try PanoramaFixture.tolerance()
        let layouts: [(String, [simd_double3x3], Int)] = [
            ("two", [Scene.rotation(yaw: -12), Scene.rotation(yaw: 13, pitch: 1)], 1),
            ("five", (0..<5).map { Scene.rotation(yaw: Double($0) * 25 - 50, pitch: Double($0 % 2), roll: Double($0) * 0.4 - 0.8) }, 4),
            ("grid", [Scene.rotation(yaw: -13, pitch: -10), Scene.rotation(yaw: 13, pitch: -11), Scene.rotation(yaw: -12, pitch: 11), Scene.rotation(yaw: 14, pitch: 10)], 4),
        ]
        for (name, rotations, pairs) in layouts {
            let frames = try Scene.views(rotations)
            let result = try LWPanoramaStitcher.stitch(frames)
            let alignment = result.alignment
            #expect(abs(alignment.focal - 300) / 300 < 0.02, "\(name) focal \(alignment.focal)")
            #expect(alignment.pairs.count >= pairs, "\(name): \(alignment.pairs)")
            for index in rotations.indices.dropFirst() {
                let solved = alignment.rotations[0].transpose * alignment.rotations[index], expected = rotations[0].transpose * rotations[index]
                #expect(Scene.angle(solved, expected) < 0.5, "\(name) frame \(index): \(Scene.angle(solved, expected))°")
            }
            let seam = LWPanoramaSeamMetric.measure(result, frames: frames)
            print("S44 \(name): \(result.width) × \(result.height), focal \(alignment.focal), rms \(alignment.rms) px, seam error \(seam.value)")
            #expect(seam.value < tolerance, "\(name): \(seam.value)")
            #expect(result.uncoveredPixels == 0 && Set(result.labels).count == rotations.count)
            // A grid is taller than one frame: both rows are in the picture.
            if name == "grid" { #expect(result.height > 280 && result.width > 380, "\(result.width) × \(result.height)") }
        }
    }

    /// Twelve frames around the horizon: the canvas is the whole circle, and the frame that
    /// straddles the ±180° cut lands on both ends of it.
    @Test func aFullCircleStitchesAcrossTheCut() throws {
        let tolerance = try PanoramaFixture.tolerance()
        let frames = try Scene.views((0..<12).map { Scene.rotation(yaw: Double($0) * 30, pitch: Double($0 % 3) - 1) })
        let (alignment, works) = try LWPanoramaStitcher.align(frames)
        #expect(alignment.pairs.count >= 12 && abs(alignment.focal - 300) / 300 < 0.02, "\(alignment.pairs.count) pairs, focal \(alignment.focal)")
        for projection in [LWPanoramaProjection.spherical, .cylindrical] {
            let result = try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: projection, boundary: .autoCrop))
            #expect(result.geometry.fullCircle && result.width == result.geometry.width)
            #expect(abs(Double(result.width) - 2 * .pi * alignment.focal) < 2, "\(result.width)")
            #expect(result.uncoveredPixels == 0 && Set(result.labels).count == 12)
            // One frame owns pixels in both the first and the last column.
            let first = Set((0..<result.height).map { result.labels[$0 * result.width] }), last = Set((0..<result.height).map { result.labels[$0 * result.width + result.width - 1] })
            #expect(!first.intersection(last).isEmpty, "\(first) \(last)")
            let seam = LWPanoramaSeamMetric.measure(result, frames: frames)
            #expect(seam.value < tolerance, "\(projection): \(seam.value)")
        }
        #expect(throws: LWPanoramaError.self) { try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: .perspective)) }
    }

    /// The reasons a person can act on, with the photos named.
    @Test func framesThatCannotBeJoinedAreRefusedWithTheReason() throws {
        let centre = try Scene.view(rotation: Scene.rotation(yaw: 0))
        // Too little overlap: the frames share a strip of about 30 pixels of their 320.
        let thin = [try Scene.view(rotation: Scene.rotation(yaw: -25)), try Scene.view(rotation: Scene.rotation(yaw: 25, pitch: 1))]
        #expect(throws: LWPanoramaError.insufficientOverlap(frame: 0, other: 1)) { try LWPanoramaStitcher.align(thin) }
        // No overlap at all, and a photo of another scene among two that match.
        #expect(throws: LWPanoramaError.unmatched(frame: 1)) { try LWPanoramaStitcher.align([try Scene.view(rotation: Scene.rotation(yaw: -40)), try Scene.view(rotation: Scene.rotation(yaw: 40))]) }
        let stranger = [try Scene.view(rotation: Scene.rotation(yaw: -13)), try Scene.view(rotation: Scene.rotation(yaw: 13)), try Scene.view(seed: 99, rotation: Scene.rotation(yaw: 30))]
        #expect(throws: LWPanoramaError.unmatched(frame: 2)) { try LWPanoramaStitcher.align(stranger) }
        // A photo with nothing in it.
        let blank = try LWMergeFrame(width: 320, height: 240, samples: [Float16](repeating: 0.25, count: 320 * 240 * 3))
        #expect(throws: LWPanoramaError.featureless(frame: 1)) { try LWPanoramaStitcher.align([centre, blank]) }
        // Count and size.
        #expect(throws: LWPanoramaError.tooFewFrames) { try LWPanoramaStitcher.stitch([centre]) }
        #expect(throws: LWPanoramaError.tooManyFrames) { try LWPanoramaStitcher.align([LWMergeFrame](repeating: centre, count: LWPanoramaStitcher.maximumFrames + 1)) }
        let small = try Scene.view(rotation: Scene.rotation(yaw: 10), width: 300, height: 240)
        #expect(throws: LWPanoramaError.sizeMismatch(frame: 1)) { try LWPanoramaStitcher.align([centre, small]) }
        // A sweep too wide for a flat picture.
        let wide = try Scene.views((0..<7).map { Scene.rotation(yaw: Double($0) * 25 - 75) })
        do { _ = try LWPanoramaStitcher.stitch(wide, options: LWPanoramaOptions(projection: .perspective)); Issue.record("A 206° sweep was laid out flat.") }
        catch let error as LWPanoramaError {
            guard case .tooWideForPerspective(let degrees) = error else { Issue.record("\(error)"); return }
            #expect(degrees > 140)
            #expect(error.message().contains("too wide for the Perspective projection. Choose Cylindrical or Spherical."))
        }
        #expect(try LWPanoramaStitcher.stitch(wide).width > 1000)
        let names = ["left.dng", "right.dng", "other.dng"]
        #expect(LWPanoramaError.unmatched(frame: 2).message(names: names) == "“other.dng” does not match any of the other photos. Remove it from the selection, or add a photo that overlaps it.")
        #expect(LWPanoramaError.insufficientOverlap(frame: 0, other: 1).message(names: names) == "“left.dng” and “right.dng” overlap too little to be joined. Add a photo taken between them, or reshoot with about a third of each photo overlapping the next.")
        #expect(LWPanoramaError.featureless(frame: 1).message(names: names).hasPrefix("“right.dng” has too little detail"))
        #expect(LWPanoramaError.sizeMismatch(frame: 1).localizedDescription.hasPrefix("Photo 2 has different pixel dimensions from the first photo."))
        #expect(LWPanoramaError.notOnePanorama(rmsPixels: 31.4).message().contains("disagree by 31 pixels"))
    }

    /// The budget's unit is bytes: 6 per frame pixel plus 48 MiB per frame, 10 per canvas pixel
    /// and 14 per pixel of the largest warped frame (docs/PANORAMA_MERGE.md, "Memory").
    @Test func theMemoryBudgetAdmitsOrdinarySetsAndRefusesOversizedOnesWithTheNumbers() async throws {
        let budget = LWMergeBudget.minimumBytes
        #expect(budget == 6 * 1024 * 1024 * 1024 && LWMergeBudget.bytes >= budget && LWHDRMerger.budgetBytes == LWMergeBudget.bytes)
        let megabytes = 48 * 1024 * 1024
        #expect(LWPanoramaStitcher.workingBytes(frames: 6, width: 8192, height: 5464, canvasPixels: 166_000_000, warpPixels: 50_000_000) == 6 * (8192 * 5464 * 6 + megabytes) + 166_000_000 * 10 + 50_000_000 * 14)
        #expect(LWPanoramaStitcher.expectedCanvasPixels(frames: 3, width: 1000, height: 1000) == 2_400_000)
        // On the 16 GB Mac's budget: 8 × 45 MP, 12 and 16 × 24 MP, 4 × 61 MP and 2 × 102 MP are admitted before any frame is loaded.
        try LWPanoramaStitcher.admit(frames: 8, width: 8192, height: 5464, budget: budget)
        try LWPanoramaStitcher.admit(frames: 12, width: 6000, height: 4000, budget: budget)
        try LWPanoramaStitcher.admit(frames: 4, width: 9504, height: 6336, budget: budget)
        try LWPanoramaStitcher.admit(frames: 16, width: 6000, height: 4000, budget: budget)
        try LWPanoramaStitcher.admit(frames: 2, width: 11648, height: 8736, budget: budget)
        try LWPanoramaStitcher.admit(frames: 24, width: 4500, height: 3000, budget: budget)
        let needed = LWPanoramaStitcher.workingBytes(frames: 12, width: 8192, height: 5464, canvasPixels: LWPanoramaStitcher.expectedCanvasPixels(frames: 12, width: 8192, height: 5464), warpPixels: 8192 * 5464)
        #expect(throws: LWPanoramaError.tooLarge(frames: 12, width: 8192, height: 5464, outputWidth: 0, outputHeight: 0, neededBytes: needed, budgetBytes: budget)) {
            try LWPanoramaStitcher.admit(frames: 12, width: 8192, height: 5464, budget: budget)
        }
        let early = LWPanoramaError.tooLarge(frames: 12, width: 8192, height: 5464, outputWidth: 0, outputHeight: 0, neededBytes: needed, budgetBytes: budget).message()
        #expect(early == "Merging 12 photos of 8192 × 5464 (45 MP) into a panorama needs about 8.3 GB of memory; this Mac allows 6.4 GB for a merge. Select fewer photos.", "\(early)")
        let late = LWPanoramaError.tooLarge(frames: 6, width: 8192, height: 5464, outputWidth: 30000, outputHeight: 10000, neededBytes: 7_000_000_000, budgetBytes: budget).message()
        #expect(late.contains("into a 30000 × 10000 (300 MP) panorama needs about 7.0 GB"), "\(late)")
        #expect(LWPanoramaStitcher.workingBytes(frames: 2, width: .max / 2, height: 4, canvasPixels: 1, warpPixels: 1) == .max)
        #expect(LWPanoramaError.outputTooLarge(width: 40000, height: 10000).message().contains("400 MP") && LWPanoramaStitcher.maximumOutputPixels * 12 < Int(UInt32.max))

        // The composition checks the same model against the canvas it has actually laid out, before allocating it.
        let frames = try Scene.views([Scene.rotation(yaw: -12), Scene.rotation(yaw: 13)])
        let (alignment, works) = try LWPanoramaStitcher.align(frames)
        let result = try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works)
        #expect(result.workingBytes > 2 * (320 * 240 * 6 + megabytes) + result.geometry.width * result.geometry.height * 10)
        #expect(try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, budget: result.workingBytes).samples == result.samples)
        #expect(throws: LWPanoramaError.tooLarge(frames: 2, width: 320, height: 240, outputWidth: result.geometry.width, outputHeight: result.geometry.height, neededBytes: result.workingBytes, budgetBytes: result.workingBytes - 1)) {
            try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, budget: result.workingBytes - 1)
        }
        // The production loader refuses before loading, with the numbers.
        let fixture = try PanoramaFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let first = fixture.files("plain")[0]
        do { _ = try await LensWorksCatalog.developPanoramaFrame(original: try LWCatalogNativePath(fileURL: first), url: first, frames: 3, budget: 1_000_000); Issue.record("An over-budget frame was loaded.") }
        catch let error as LWPanoramaError {
            guard case .tooLarge(3, 320, 240, 0, 0, _, 1_000_000) = error else { Issue.record("\(error)"); return }
        }
    }

    @Test func panoramaDNGIsLinearFloatWithProvenanceAndDevelopsThroughTheLiveSource() async throws {
        let fixture = try PanoramaFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frames = try await fixture.developed("exposure"), truth = fixture.frames("exposure")
        let result = try LWPanoramaStitcher.stitch(frames, options: LWPanoramaOptions(projection: .cylindrical))
        let scale = LWPanoramaDNGWriter.normalization(result)
        let provenance = LWPanoramaProvenance(documentID: UUID().uuidString, projection: .cylindrical, boundary: .autoCrop, focalPixels: result.alignment.focal,
            baselineExposure: Double(-log2(scale)), sources: truth.indices.map { i in
                .init(record: LWDerivedSourceRecord(catalogImageID: "image-\(i)", assetID: "asset-\(i)", variantID: "master", fileName: i == 0 ? "a & <b>.png" : fixture.file(truth[i]).lastPathComponent, sha256: truth[i].sha256),
                      rotation: simd_quatd(result.alignment.rotations[i]).vector, relativeExposureEV: Double(log2(result.alignment.gains[i].y)), profile: i == 1 ? "sRGB IEC61966-2.1" : nil) })
        let dng = fixture.root.appendingPathComponent("panorama.dng"), streamed = fixture.root.appendingPathComponent("streamed.dng")
        try LWPanoramaDNGWriter.encode(result, provenance: provenance, reference: ["tiff:Make": "S47 & <Co>"]).write(to: dng)
        // The streamed write Merge to Panorama… uses is the same file, and never replaces one.
        try LWPanoramaDNGWriter.write(result, provenance: provenance, reference: ["tiff:Make": "S47 & <Co>"], to: streamed)
        #expect(try Data(contentsOf: streamed) == Data(contentsOf: dng))
        try Data("existing".utf8).write(to: streamed)
        #expect(throws: POSIXError.self) { try LWPanoramaDNGWriter.write(result, provenance: provenance, to: streamed) }
        #expect(try Data(contentsOf: streamed) == Data("existing".utf8))
        let inspection = try LWDNGInspection(Data(contentsOf: dng))
        #expect(inspection.tags[262] == [34892] && inspection.tags[339] == [3, 3, 3] && inspection.tags[258] == [32, 32, 32])
        #expect(inspection.tags[50706] == [1, 4, 0, 0] && inspection.width == result.width && inspection.height == result.height)
        #expect(try inspection.panoramaProvenance() == provenance)
        // Whichever merge wrote a file, its record says which, and an HDR reader does not mistake it.
        #expect(try LWDNGInspection.mergeRecord(at: dng) == LWDerivedMergeRecord(kind: .panorama, sources: provenance.sources.map(\.record)))
        #expect(throws: LWLinearDNGError.self) { try inspection.provenance() }
        #expect(throws: LWLinearDNGError.self) { try LWDNGInspection.mergeRecord(at: fixture.files("plain")[0]) }
        let packet = String(decoding: try #require(inspection.xmp), as: UTF8.self)
        #expect(!packet.contains(fixture.root.path) && !packet.contains(NSHomeDirectory()) && packet.contains("lwpano:projection=\"cylindrical\""))
        let samples = try #require(inspection.floatSamples)
        let baseline = Float(try #require(inspection.tags[50730]?.first))
        #expect(samples.max()! == 1 && samples.count == result.samples.count)
        var worstStored: Float = 0
        for index in samples.indices { worstStored = max(worstStored, abs(samples[index] * exp2(baseline) - Float(result.samples[index]))) }
        #expect(worstStored <= 1e-4, "worst stored delta \(worstStored)")
        // The editor's managed DNG development reads the samples with identity linear-sRGB color.
        let developed = try await LensWorksCatalog.developPanoramaFrame(original: try LWCatalogNativePath(fileURL: dng), url: dng)
        #expect(developed.width == result.width && developed.height == result.height)
        var worst: Float = 0
        for index in 0..<(result.width * result.height) {
            worst = max(worst, simd_reduce_max(abs(developed.rgb(index) - SIMD3(samples[index * 3], samples[index * 3 + 1], samples[index * 3 + 2]))))
        }
        #expect(worst < 0.01, "worst developed delta \(worst)")
    }

    @Test func aStitchIsCancelledWithItsCaller() async throws {
        let frames = try Scene.views((0..<6).map { Scene.rotation(yaw: Double($0) * 25 - 62) })
        let started = ContinuousClock.now
        let task = Task { try await LensWorksCatalog.detached { try (0..<50).map { _ in try LWPanoramaStitcher.stitch(frames).width } } }
        try await Task.sleep(for: .milliseconds(150))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(10))
    }
}

/// AC3 through the real catalog: one new linked catalog item, unchanged sources, and an editor
/// document with live RAW development that accepts layers.
@Suite(.serialized)
@MainActor
struct PanoramaMergeCatalogTests {
    /// A catalog over the generated plain series' three photos.
    private func withPanoramaCatalog(series: String = "plain", _ body: (LensWorksCatalog, PanoramaFixture, [LensWorksCatalogAsset], UserDefaults) async throws -> Void) async throws {
        let fixture = try PanoramaFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.keepOnly(series)
        try await MergeCatalogHarness.withCatalog(root: fixture.root, photos: 3) { model, sources, defaults in try await body(model, fixture, sources, defaults) }
    }
    /// Files in the photos folder that the fixture did not put there.
    private func leftovers(_ fixture: PanoramaFixture, series: String = "plain") throws -> [String] {
        let known = Set(fixture.files(series).map(\.lastPathComponent))
        return try FileManager.default.contentsOfDirectory(atPath: fixture.root.appendingPathComponent("Photos").path).filter { !known.contains($0) }.sorted()
    }

    @Test func mergeCreatesOneLinkedPanoramaCatalogItemThatOpensWithRawControlsAndLayers() async throws {
        try await withPanoramaCatalog { model, fixture, sources, defaults in
            let photos = fixture.root.appendingPathComponent("Photos"), files = fixture.files("plain")
            let before = try files.map { try LensWorksCatalog.sha256($0) }
            // A photo the catalog has not imported, beside the sources: a merge does not add it.
            try FileManager.default.copyItem(at: files[0], to: photos.appendingPathComponent("uncataloged-beside.png"))
            let checkpointKey = "LensWorks.importSource." + (try #require(model.catalogPath))
            let checkpoint = try #require(defaults.data(forKey: checkpointKey))
            await model.select(sources[0])
            #expect(model.panoramaMergeAvailability() == "Select two or more overlapping photos.")
            for row in sources.dropFirst() { await model.select(row, extending: true) }
            #expect(model.selectionCount == 3 && model.panoramaMergeAvailability() == nil && model.hdrMergeAvailability() == nil)

            let outcome = try await model.mergeSelectionToPanorama(projection: .cylindrical, boundary: .autoCrop)
            #expect(model.error == nil, "\(model.error ?? "")")
            #expect(try files.map { try LensWorksCatalog.sha256($0) } == before)
            #expect(model.assets.count == 4 && model.searchText.isEmpty && model.activeFolder == nil, "\(model.assets.map(\.filename))")
            #expect(defaults.data(forKey: checkpointKey) == checkpoint, "the folder-import resume source is not replaced")
            #expect(outcome.dng.lastPathComponent.hasSuffix("-Pano.dng"))
            #expect(try leftovers(fixture) == [outcome.dng.lastPathComponent, "uncataloged-beside.png"].sorted())
            let merged = try #require(model.assets.first { $0.filename == outcome.dng.lastPathComponent })
            #expect(!sources.contains { $0.id == merged.id })
            #expect(model.selectedAsset?.id == merged.id && outcome.asset.id == merged.id)
            #expect(!model.isMergingPanorama && !model.isMerging && model.panoramaMergeCancelReason == "No merge to panorama is running.")
            #expect(model.status == "Merged 3 photos to a panorama: \(outcome.dng.lastPathComponent)")
            #expect(outcome.result.uncoveredPixels == 0 && outcome.result.width > 500 && outcome.result.options.projection == .cylindrical)

            // The catalog item's own original is a linear float DNG whose XMP names all three sources.
            let original = try await model.service.originalLocation(try #require(merged.key)).localFileURL()
            #expect(original.resolvingSymlinksInPath().path == outcome.dng.resolvingSymlinksInPath().path)
            let inspection = try LWDNGInspection(Data(contentsOf: original))
            #expect(inspection.tags[262] == [34892] && inspection.tags[339] == [3, 3, 3] && inspection.tags[258] == [32, 32, 32])
            #expect(inspection.width == outcome.result.width && inspection.height == outcome.result.height)
            let record = try inspection.panoramaProvenance()
            #expect(record == outcome.provenance && record.projection == .cylindrical && record.boundary == .autoCrop)
            #expect(Set(record.sources.map(\.record.catalogImageID)) == Set(sources.map(\.id)))
            for source in record.sources {
                let row = try #require(sources.first { $0.id == source.record.catalogImageID })
                let file = try await model.service.originalLocation(try #require(row.key)).localFileURL()
                let hash = try LensWorksCatalog.sha256(file)
                #expect(source.record.fileName == file.lastPathComponent && source.record.sha256 == hash && source.record.assetID == row.key?.asset_id)
            }
            // The file is meant to be shared: its XMP holds no local path.
            let packet = String(decoding: try #require(inspection.xmp), as: UTF8.self)
            #expect(!packet.contains(fixture.root.path) && !packet.contains(NSHomeDirectory()) && !packet.contains("catalogPath"))

            // The link on the catalog side, and its kind.
            let link = try #require(try await model.derivedLink(of: merged))
            #expect(link.kind == .panorama && link.sources.count == 3 && Set(link.sources.map(\.imageID)) == Set(sources.map(\.id)))
            for source in link.sources {
                let row = try #require(sources.first { $0.id == source.imageID })
                #expect(source.assetID == row.key?.asset_id && source.variantID == row.key?.variant_id && source.filename == row.filename && !source.missing)
            }
            #expect(try await model.panoramaSources(of: merged) == link.sources)
            #expect(try await model.hdrMergeSources(of: merged).isEmpty, "a panorama is not an HDR merge")
            #expect(try await model.derivedLink(of: sources[0]) == nil)
            // It is durable catalog-side state: a second index connection reads it.
            let reopened = LensWorksCatalogIndex(url: fixture.root.appendingPathComponent("Index.sqlite3"))
            #expect(try await reopened.link(catalog: try #require(model.catalogPath), image: merged.id) == link)
            // Following the link selects the three sources; the HDR command's route refuses a panorama.
            await #expect(throws: LensWorksCatalogError.self) { try await model.selectHDRMergeSources(of: merged) }
            try await model.selectDerivedSources(of: merged, kind: .panorama)
            #expect(model.selectionCount == 3 && model.selection == Set(sources.map(\.id)))
            await model.select(merged)
            #expect(model.selectedAsset?.id == merged.id && model.selectionCount == 1)

            // AC3: it opens in the editor as a live RAW source with RAW controls and accepts a layer.
            let output = fixture.root.appendingPathComponent("Versions")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            await model.setOutput(output.path)
            let workspace = ProjectWorkspace()
            await model.createWorkingVersion(workspace: workspace)
            #expect(model.error == nil, "\(model.error ?? "")")
            let session = workspace.current.session
            #expect(workspace.current.controller.workingVersion?.photoID == merged.photoID)
            let rawLayer = try #require(session.activeLayer)
            #expect(rawLayer.liveSource != nil && rawLayer.asset?.linearPlane != nil)
            #expect(session.document?.size == CGSize(width: outcome.result.width, height: outcome.result.height))
            session.beginFilter(.cameraRaw)
            let edit = try #require(session.filterEdit)
            #expect(edit.liveSource != nil)
            session.cancelFilter()
            session.addBlankLayer()
            #expect(session.document?.layers.count == 2)
            #expect(session.document?.layers.contains { $0.liveSource != nil } == true)
            #expect(try files.map { try LensWorksCatalog.sha256($0) } == before)
        }
    }

    @Test func aCancelledOrFailedPanoramaLeavesNoFileAndNoCatalogItem() async throws {
        try await withPanoramaCatalog(series: "exposure") { model, fixture, sources, _ in
            let files = fixture.files("exposure"), before = try files.map { try LensWorksCatalog.sha256($0) }
            await MergeCatalogHarness.selectAll(model, sources)
            // The selection changes between the command and the merge reading it.
            try await model.index.setSelection(owner: model.selectionOwnerForCommands, rows: [LensWorksSelectedRow(imageID: sources[0].id, key: try #require(sources[0].key))], replace: true)
            do { _ = try await model.mergeSelectionToPanorama(); Issue.record("A changed selection merged.") }
            catch { #expect(error.localizedDescription == "The selection changed while Merge to Panorama was starting. Try again.") }
            #expect(!model.isMerging && !model.isBusy)
            await MergeCatalogHarness.selectAll(model, sources)

            // The Cancel command while the merge is working; meanwhile no other merge can start.
            let running = Task { try await model.mergeSelectionToPanorama() }
            while !model.isMergingPanorama { await Task.yield() }
            #expect(model.panoramaMergeCancelReason == nil && model.hdrMergeCancelReason == "No merge to HDR is running.")
            #expect(model.panoramaMergeAvailability() == "A merge to panorama is already running." && model.hdrMergeAvailability() == "A merge to panorama is already running.")
            model.cancelHDRMerge()  // Not its merge: nothing happens.
            #expect(model.isMergingPanorama)
            model.cancelPanoramaMerge()
            await #expect(throws: CancellationError.self) { _ = try await running.value }
            #expect(!model.isMerging && !model.isBusy && model.error == nil)
            #expect(model.status == "Merge to Panorama canceled. Nothing was added to the catalog.")
            #expect(try leftovers(fixture, series: "exposure").isEmpty)

            // A failure after the DNG is in place and before the catalog has it.
            var written: [URL] = []
            model.mergeWrittenFixture = { url in
                written.append(url)
                #expect(FileManager.default.fileExists(atPath: url.path))
                throw LensWorksCatalogError.message("fixture failure after the write")
            }
            do { _ = try await model.mergeSelectionToPanorama(); Issue.record("The fixture failure was swallowed.") }
            catch { #expect(error.localizedDescription == "fixture failure after the write") }
            #expect(written.count == 1)
            #expect(try leftovers(fixture, series: "exposure").isEmpty)
            // The Cancel command at that same point.
            model.mergeWrittenFixture = { url in written.append(url); model.cancelPanoramaMerge() }
            await #expect(throws: CancellationError.self) { _ = try await model.mergeSelectionToPanorama() }
            #expect(written.count == 2)
            #expect(try leftovers(fixture, series: "exposure").isEmpty)
            #expect(model.assets.count == 3 && !model.isImporting)
            #expect(try files.map { try LensWorksCatalog.sha256($0) } == before)

            // Nothing is left that stops the next merge; a second one takes the next free name.
            model.mergeWrittenFixture = nil
            let outcome = try await model.mergeSelectionToPanorama(boundary: .fill)
            #expect(model.assets.count == 4 && outcome.result.uncoveredPixels > 0 && outcome.provenance.boundary == .fill)
            #expect(try leftovers(fixture, series: "exposure") == [outcome.dng.lastPathComponent])
            await MergeCatalogHarness.selectAll(model, sources)
            let second = try await model.mergeSelectionToPanorama(projection: .perspective)
            #expect(second.dng.lastPathComponent == outcome.dng.deletingPathExtension().lastPathComponent + "-2.dng" && model.assets.count == 5)
            #expect(try files.map { try LensWorksCatalog.sha256($0) } == before)
        }
    }

    /// A photo that does not belong is named, by file name, in the reason; nothing is written.
    @Test func aPhotoThatDoesNotMatchIsNamedAndNothingIsWritten() async throws {
        let fixture = try PanoramaFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        try fixture.keepOnly("plain")
        let photos = fixture.root.appendingPathComponent("Photos")
        try FileManager.default.removeItem(at: fixture.files("plain")[2])
        try PanoramaSyntheticScene.write(try PanoramaSyntheticScene.view(seed: 99, rotation: PanoramaSyntheticScene.rotation(yaw: 30)), to: photos.appendingPathComponent("stranger.png"))
        try PanoramaSyntheticScene.write(try PanoramaSyntheticScene.view(rotation: PanoramaSyntheticScene.rotation(yaw: 10), width: 300, height: 240), to: photos.appendingPathComponent("smaller.png"))
        try await MergeCatalogHarness.withCatalog(root: fixture.root, photos: 4) { model, assets, _ in
            let known = Set(try FileManager.default.contentsOfDirectory(atPath: photos.path))
            func merge(_ names: [String]) async -> String? {
                await MergeCatalogHarness.selectAll(model, names.map { name in assets.first { $0.filename == name }! })
                do { _ = try await model.mergeSelectionToPanorama(); return nil } catch { return error.localizedDescription }
            }
            #expect(await merge(["plain-left.png", "plain-center.png", "stranger.png"]) == "“stranger.png” does not match any of the other photos. Remove it from the selection, or add a photo that overlaps it.")
            // Whichever of the two the selection lists second is the one named.
            let mismatch = await merge(["plain-left.png", "smaller.png"]) ?? ""
            #expect(mismatch.hasPrefix("“smaller.png” has different pixel dimensions from the first photo.") || mismatch.hasPrefix("“plain-left.png” has different pixel dimensions from the first photo."), "\(mismatch)")
            #expect(!model.isMerging && !model.isBusy && model.assets.count == 4)
            #expect(Set(try FileManager.default.contentsOfDirectory(atPath: photos.path)) == known)
            // The two that do belong still merge.
            #expect(await merge(["plain-left.png", "plain-center.png"]) == nil)
            #expect(model.assets.count == 5)
        }
    }

    /// The catalog index is rebuildable: without it, a panorama's link comes back from the record
    /// in its own DNG, as a panorama's.
    @Test func thePanoramaLinkIsRebuiltFromTheFileWhenTheCatalogIndexIsDeleted() async throws {
        try await withPanoramaCatalog { model, fixture, sources, defaults in
            await MergeCatalogHarness.selectAll(model, sources)
            let outcome = try await model.mergeSelectionToPanorama()
            let recorded = try #require(try await model.derivedLink(of: outcome.asset))
            #expect(recorded.kind == .panorama && recorded.sources.count == 3 && recorded.sources.allSatisfy { !$0.missing })
            let catalog = try #require(model.catalogPath), indexFile = fixture.root.appendingPathComponent("Index.sqlite3")
            try await model.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: indexFile.path + suffix) }
            // One source's bytes change while the index is gone.
            try Data("not the photo any more".utf8).write(to: fixture.files("plain")[2])

            let (reopened, _) = try MergeCatalogHarness.model(root: fixture.root, defaults: defaults)
            await reopened.connect(catalog)
            do {
                if let error = reopened.error { throw LensWorksCatalogError.message(error) }
                let merged = try #require(reopened.assets.first { $0.filename == outcome.dng.lastPathComponent })
                let fresh = LensWorksCatalogIndex(url: indexFile)
                #expect(try await fresh.link(catalog: catalog, image: merged.id) == nil, "the new index starts without the link")
                let rebuilt = try #require(try await reopened.derivedLink(of: merged))
                #expect(rebuilt.kind == .panorama && rebuilt.sources.map(\.imageID) == recorded.sources.map(\.imageID))
                #expect(rebuilt.sources.map(\.missing) == recorded.sources.map { $0.filename == "plain-right.png" }, "\(rebuilt.sources)")
                #expect(try await fresh.link(catalog: catalog, image: merged.id) == rebuilt, "it is stored again, so the file is read once")
                #expect(try await reopened.hdrMergeSources(of: merged).isEmpty)
                try await reopened.selectDerivedSources(of: merged, kind: .panorama)
                #expect(reopened.selectionCount == 2)
                #expect(reopened.status == "Selected 2 of the 3 source photos of \(outcome.dng.lastPathComponent); the others are no longer in this catalog.")
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
        }
    }

    /// An index written before panoramas has no kind column: it gains it, and its links stay HDR merges.
    @Test func anIndexWithoutTheKindColumnGainsItAndItsLinksStayHDRMerges() async throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
        let folder = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("LWPano-index-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Index.sqlite3")
        var database: OpaquePointer?
        #expect(sqlite3_open(file.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA application_id=1280792146; CREATE TABLE derived_sources(catalog TEXT NOT NULL,image TEXT NOT NULL,position INTEGER NOT NULL,source_image TEXT NOT NULL,source_asset TEXT NOT NULL,source_variant TEXT NOT NULL,source_name TEXT NOT NULL,missing INTEGER NOT NULL DEFAULT 0,PRIMARY KEY(catalog,image,position)); INSERT INTO derived_sources VALUES('/catalog','merged',0,'image-a','asset-a','master','a.png',0);", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let index = LensWorksCatalogIndex(url: file)
        let kept = LensWorksDerivedSource(imageID: "image-a", assetID: "asset-a", variantID: "master", filename: "a.png")
        #expect(try await index.link(catalog: "/catalog", image: "merged") == LensWorksDerivedLink(kind: .hdr, sources: [kept]))
        let other = LensWorksDerivedSource(imageID: "image-b", assetID: "asset-b", variantID: "master", filename: "b.png")
        try await index.recordSources(catalog: "/catalog", image: "wide", kind: .panorama, sources: [kept, other])
        #expect(try await index.link(catalog: "/catalog", image: "wide") == LensWorksDerivedLink(kind: .panorama, sources: [kept, other]))
        #expect(try await index.link(catalog: "/catalog", image: "merged")?.kind == .hdr)
        #expect(try await index.sources(catalog: "/catalog", image: "wide") == [kept, other])
        #expect(try await index.link(catalog: "/catalog", image: "absent") == nil)
    }
}
