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
    private struct Declared: Decodable { let seam_error_max_stops: Double, projection_error_max_stops: Double }
    private static func declared() throws -> Declared {
        try JSONDecoder().decode(Declared.self, from: Data(contentsOf: S47Generator.repository.appendingPathComponent("PANORAMA_SEAM_TOLERANCE.json")))
    }
    static func tolerance() throws -> Double { try declared().seam_error_max_stops }
    static func projectionTolerance() throws -> Double { try declared().projection_error_max_stops }
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
    /// A pinhole view. `gain` is the frame's exposure per channel, `noise` the standard deviation of
    /// seeded sensor noise as a share of the signal, and `clip` the level the sensor saturates at.
    /// `radiance` replaces the scene (it is given the world direction of each pixel's ray).
    static func view(seed: UInt32 = PanoramaFixture.seed, rotation: simd_double3x3, width: Int = 320, height: Int = 240, focal: Double = 300,
                     gain: SIMD3<Double> = SIMD3(repeating: 1), noise: Double = 0, noiseSeed: UInt64 = 1, clip: Double? = nil,
                     radiance custom: ((SIMD3<Double>) -> SIMD3<Double>)? = nil) throws -> LWMergeFrame {
        var samples = [Float16](repeating: 0, count: width * height * 3)
        var state = (noiseSeed &* 0x9E3779B97F4A7C15) | 1
        func uniform() -> Double { state ^= state << 13; state ^= state >> 7; state ^= state << 17; return Double(state >> 11) / Double(1 << 53) }
        func normal() -> Double { (-2 * log(max(uniform(), 1e-12))).squareRoot() * cos(2 * .pi * uniform()) }
        for y in 0..<height {
            for x in 0..<width {
                let d = rotation * SIMD3((Double(x) - Double(width - 1) / 2) / focal, (Double(y) - Double(height - 1) / 2) / focal, 1)
                var value = (custom?(d) ?? radiance(seed, d)) * gain
                if noise > 0 { value *= SIMD3(1 + noise * normal(), 1 + noise * normal(), 1 + noise * normal()) }
                if let clip { value = simd_min(value, SIMD3(repeating: clip)) }
                let o = (y * width + x) * 3
                samples[o] = Float16(value.x); samples[o + 1] = Float16(value.y); samples[o + 2] = Float16(value.z)
            }
        }
        return try LWMergeFrame(width: width, height: height, samples: samples)
    }
    static func views(_ rotations: [simd_double3x3]) throws -> [LWMergeFrame] { try rotations.map { try view(rotation: $0) } }
    static func latitude(_ d: SIMD3<Double>) -> Double { atan2(d.y, (d.x * d.x + d.z * d.z).squareRoot()) * 180 / .pi }
    static func longitude(_ d: SIMD3<Double>) -> Double { atan2(d.x, d.z) * 180 / .pi }
    /// The scene as a camera at `position` sees it along `d`, with `near` standing on the unit
    /// sphere round the origin in front of the scene, which is infinitely far: a camera that
    /// moves sees the near subjects shift against the scene.
    static func parallax(from position: SIMD3<Double>, _ d: SIMD3<Double>, near: (_ longitude: Double, _ latitude: Double, _ behind: SIMD3<Double>) -> SIMD3<Double>) -> SIMD3<Double> {
        let b = simd_dot(position, d) / simd_length_squared(d), c = (simd_length_squared(position) - 1) / simd_length_squared(d)
        let point = position + d * (-b + (b * b - c).squareRoot())
        return near(longitude(point), latitude(point), radiance(PanoramaFixture.seed, d))
    }
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

/// Where a stitched picture's pixels look, by the projection formulas written out here and the
/// cameras' true rotations: nothing of the stitcher's own geometry code is used.
nonisolated enum PanoramaTruth {
    /// The true world direction of a picture pixel. `truth` are the frames' true rotations.
    static func direction(_ result: LWPanoramaResult, _ x: Int, _ y: Int, toTruth: simd_double3x3) -> SIMD3<Double> {
        let geometry = result.geometry
        let u = Double(x + result.offsetX + geometry.originX) / geometry.scale, v = Double(y + result.offsetY + geometry.originY) / geometry.scale
        switch geometry.projection {
        case .spherical: return toTruth * SIMD3(sin(u) * cos(v), sin(v), cos(u) * cos(v))
        case .cylindrical: return toTruth * SIMD3(sin(u), v, cos(u))
        case .perspective: return toTruth * SIMD3(u, v, 1)
        }
    }
    /// Takes the picture's world to the true one, through the reference frame.
    static func toTruth(_ result: LWPanoramaResult, _ truth: [simd_double3x3]) -> simd_double3x3 {
        truth[result.alignment.reference] * result.alignment.rotations[result.alignment.reference].transpose
    }
    /// Mean |log2(picture / scene)| over every covered pixel and channel, in stops.
    static func error(_ result: LWPanoramaResult, truth: [simd_double3x3], radiance: (SIMD3<Double>) -> SIMD3<Double> = { PanoramaSyntheticScene.radiance(PanoramaFixture.seed, $0) }) -> Double {
        let turn = toTruth(result, truth)
        var sum = 0.0, count = 0
        for y in 0..<result.height {
            for x in 0..<result.width where result.labels[y * result.width + x] != 255 {
                let scene = radiance(direction(result, x, y, toTruth: turn)), picture = result.rgb(y * result.width + x)
                for channel in 0..<3 { sum += abs(log2(Double(max(picture[channel], 1e-4)) / scene[channel])) }
                count += 3
            }
        }
        return sum / Double(max(1, count))
    }
    /// Each row's runs of one frame's pixels, in order; in a full circle (`cyclic`) a run that
    /// crosses the cut is one run.
    static func runs(_ result: LWPanoramaResult, row: Int, cyclic: Bool) -> [(frame: UInt8, length: Int)] {
        var runs: [(frame: UInt8, length: Int)] = []
        for x in 0..<result.width {
            let label = result.labels[row * result.width + x]
            if let last = runs.last, last.frame == label { runs[runs.count - 1].length += 1 } else { runs.append((label, 1)) }
        }
        if cyclic, runs.count > 1, runs[0].frame == runs[runs.count - 1].frame { runs[0].length += runs.removeLast().length }
        return runs
    }
    /// Mean step, in stops of luminance, between a full circle's last column and its first beyond the scene's own step there.
    static func stepAcrossTheCut(_ result: LWPanoramaResult, truth: [simd_double3x3]) -> Double {
        let turn = toTruth(result, truth), last = result.width - 1
        func stops(_ v: SIMD3<Double>) -> Double { log2(0.2126 * v.x + 0.7152 * v.y + 0.0722 * v.z + 1e-4) }
        var sum = 0.0
        for y in 0..<result.height {
            let picture = abs(stops(SIMD3<Double>(result.rgb(y * result.width))) - stops(SIMD3<Double>(result.rgb(y * result.width + last))))
            let scene = abs(stops(PanoramaSyntheticScene.radiance(PanoramaFixture.seed, direction(result, 0, y, toTruth: turn))) - stops(PanoramaSyntheticScene.radiance(PanoramaFixture.seed, direction(result, last, y, toTruth: turn))))
            sum += max(0, picture - scene)
        }
        return sum / Double(result.height)
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

    /// Two frames, five in a row, a two-row grid and portrait frames; the five with sensor noise
    /// and in shuffled order: the global alignment is not tied to three frames, to one row, to
    /// the order the photos are given in, to landscape frames or to clean ones.
    @Test func twoFramesFiveFramesAGridPortraitShuffledAndNoisyFramesStitch() throws {
        let tolerance = try PanoramaFixture.tolerance()
        let five = (0..<5).map { Scene.rotation(yaw: Double($0) * 25 - 50, pitch: Double($0 % 2), roll: Double($0) * 0.4 - 0.8) }
        let shuffled = [3, 0, 4, 1, 2].map { five[$0] }
        let portrait = (0..<4).map { Scene.rotation(yaw: Double($0) * 19 - 28, pitch: Double($0 % 2) - 0.5, roll: 0.5 - Double($0) * 0.3) }
        // Noise with a standard deviation of 1 % of the signal, different in every frame.
        func noisy(_ rotations: [simd_double3x3]) throws -> [LWMergeFrame] { try rotations.enumerated().map { try Scene.view(rotation: $1, noise: 0.01, noiseSeed: UInt64($0 + 1)) } }
        let layouts: [(String, [simd_double3x3], Int, [LWMergeFrame])] = [
            ("two", [Scene.rotation(yaw: -12), Scene.rotation(yaw: 13, pitch: 1)], 1, []),
            ("five", five, 4, []),
            ("grid", [Scene.rotation(yaw: -13, pitch: -10), Scene.rotation(yaw: 13, pitch: -11), Scene.rotation(yaw: -12, pitch: 11), Scene.rotation(yaw: 14, pitch: 10)], 4, []),
            ("five with noise", five, 4, try noisy(five)),
            ("five shuffled", shuffled, 4, []),
            ("five shuffled with noise", shuffled, 4, try noisy(shuffled)),
            ("portrait", portrait, 3, try portrait.map { try Scene.view(rotation: $0, width: 240, height: 320) }),
        ]
        for (name, rotations, pairs, given) in layouts {
            let frames = try given.isEmpty ? Scene.views(rotations) : given
            let result = try LWPanoramaStitcher.stitch(frames)
            let alignment = result.alignment
            #expect(abs(alignment.focal - 300) / 300 < 0.02, "\(name) focal \(alignment.focal)")
            #expect(alignment.pairs.count >= pairs, "\(name): \(alignment.pairs)")
            var worst = 0.0
            for index in rotations.indices.dropFirst() {
                let solved = alignment.rotations[0].transpose * alignment.rotations[index], expected = rotations[0].transpose * rotations[index]
                worst = max(worst, Scene.angle(solved, expected))
                #expect(Scene.angle(solved, expected) < 0.5, "\(name) frame \(index): \(Scene.angle(solved, expected))°")
            }
            let seam = LWPanoramaSeamMetric.measure(result, frames: frames)
            print("S44 \(name): \(result.width) × \(result.height), focal \(alignment.focal), rms \(alignment.rms) px, worst rotation error \(worst)°, seam error \(seam.value)")
            #expect(seam.value < tolerance, "\(name): \(seam.value)")
            #expect(result.uncoveredPixels == 0 && Set(result.labels).count == rotations.count)
            // A grid is taller than one frame: both rows are in the picture.
            if name == "grid" { #expect(result.height > 280 && result.width > 380, "\(result.width) × \(result.height)") }
            if name == "portrait" { #expect(result.height > 240 && frames.allSatisfy { $0.width == 240 && $0.height == 320 }, "\(result.width) × \(result.height)") }
        }
    }

    /// AC1 against ground truth. The seam metric resamples the frames through the stitcher's own
    /// geometry, so it cannot tell a wrong projection from a right one. Here every covered pixel
    /// is compared with the scene in the direction the projection's formula gives for it
    /// (`PanoramaTruth.direction`, written out in this file) under the cameras' true rotations.
    @Test func everyProjectionShowsTheSceneWhereItsFormulaPutsIt() throws {
        let bound = try PanoramaFixture.projectionTolerance()
        #expect(bound == 0.09)
        let truth = [Scene.rotation(yaw: -13, pitch: -10), Scene.rotation(yaw: 13, pitch: -11), Scene.rotation(yaw: -12, pitch: 11), Scene.rotation(yaw: 14, pitch: 10)]
        let frames = try Scene.views(truth)
        let (alignment, works) = try LWPanoramaStitcher.align(frames)
        for projection in LWPanoramaProjection.allCases {
            let result = try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: projection))
            let error = PanoramaTruth.error(result, truth: truth)
            print("S44 ground-truth projection error, \(projection.rawValue): \(error) stops over \(result.width) × \(result.height); bound \(bound)")
            #expect(error < bound, "\(projection): \(error)")
            #expect(result.geometry.projection == projection && result.height > 280 && result.uncoveredPixels == 0)
        }
    }

    /// A white-balance difference between frames is a different gain in each channel. Each
    /// channel's gain is recovered, and each channel agrees at the seams, not only luminance.
    @Test func aWhiteBalanceDifferenceBetweenFramesIsRemovedInEveryChannel() throws {
        let tolerance = try PanoramaFixture.tolerance()
        let rotations = [Scene.rotation(yaw: -27, pitch: 1, roll: -0.5), Scene.rotation(yaw: 0), Scene.rotation(yaw: 28, pitch: -1, roll: 0.6)]
        let gains = [SIMD3(1.25, 1.0, 0.8), SIMD3(1.0, 1.0, 1.0), SIMD3(0.75, 0.9, 1.2)]
        let frames = try zip(rotations, gains).map { try Scene.view(rotation: $0, gain: $1) }
        let result = try LWPanoramaStitcher.stitch(frames)
        for channel in 0..<3 {
            for frame in [0, 2] {
                let solved = Double(log2(result.alignment.gains[frame][channel] / result.alignment.gains[1][channel])), expected = log2(gains[frame][channel] / gains[1][channel])
                #expect(abs(solved - expected) < 0.06, "channel \(channel), frame \(frame): \(solved) stops for \(expected)")
            }
        }
        var worst = 0.0
        for (name, weights) in [("R", SIMD3<Float>(1, 0, 0)), ("G", SIMD3<Float>(0, 1, 0)), ("B", SIMD3<Float>(0, 0, 1))] {
            let seam = LWPanoramaSeamMetric.measure(result, frames: frames, weights: weights)
            print("S44 white balance, channel \(name): seam error \(seam.value) (A \(seam.agreement), D \(seam.step))")
            #expect(seam.bandPixels > 2000 && seam.seamPairs > 200)
            worst = max(worst, seam.value)
        }
        #expect(worst < tolerance, "\(worst)")
        // The picture is the scene's colour, to within the set's mean gain in each channel.
        let turn = PanoramaTruth.toTruth(result, rotations)
        for channel in 0..<3 {
            let mean = pow(gains[0][channel] * gains[1][channel] * gains[2][channel], 1.0 / 3)
            var sum = 0.0, count = 0
            for y in stride(from: 0, to: result.height, by: 3) {
                for x in stride(from: 0, to: result.width, by: 3) {
                    let scene = Scene.radiance(PanoramaFixture.seed, PanoramaTruth.direction(result, x, y, toTruth: turn))[channel] * mean
                    sum += log2(Double(max(result.rgb(y * result.width + x)[channel], 1e-4)) / scene); count += 1
                }
            }
            #expect(abs(sum / Double(count)) < 0.06, "channel \(channel) is \(sum / Double(count)) stops from the scene")
        }
    }

    /// A solve that asks for an absurd exposure is held: a frame's exposure within 4 stops of the
    /// set's mean, each channel within 1 stop of the frame's exposure.
    @Test func anAbsurdExposureSolveIsHeldWithinLimits() {
        func stops(_ gain: SIMD3<Float>) -> [Double] { [Double(log2(gain.x)), Double(log2(gain.y)), Double(log2(gain.z))] }
        func close(_ a: [Double], _ b: [Double]) -> Bool { zip(a, b).allSatisfy { abs($0 - $1) < 1e-5 } }
        #expect(LWPanoramaStitcher.exposureLimitStops == 4 && LWPanoramaStitcher.channelLimitStops == 1)
        // Ordinary values pass through.
        #expect(close(stops(LWPanoramaStitcher.gain(luminanceStops: 0.5, channelStops: SIMD3(0.7, 0.5, 0.2))), [0.7, 0.5, 0.2]))
        #expect(close(stops(LWPanoramaStitcher.gain(luminanceStops: -3.9, channelStops: SIMD3(-4.8, -3.9, -3))), [-4.8, -3.9, -3]))
        // An exposure of ±30 stops is ±4; channels 10 stops either side of it are 1 stop either side.
        #expect(close(stops(LWPanoramaStitcher.gain(luminanceStops: 30, channelStops: SIMD3(40, 20, 30))), [5, 3, 4]))
        #expect(close(stops(LWPanoramaStitcher.gain(luminanceStops: -30, channelStops: SIMD3(-40, -20, -30))), [-5, -3, -4]))
        #expect(close(stops(LWPanoramaStitcher.gain(luminanceStops: 0, channelStops: SIMD3(8, -8, 0.4))), [1, -1, 0.4]))
        // Nothing that is not a number gets through.
        #expect(close(stops(LWPanoramaStitcher.gain(luminanceStops: .nan, channelStops: SIMD3(.nan, .infinity, -.infinity))), [0, 1, -1]))
    }

    /// A sky blown in two frames of different exposure and white balance records no level and no
    /// colour in either. In the picture it is one neutral level, the same from both frames.
    @Test func aRegionBlownInTwoFramesIsNeutralAndLevelAcrossTheSeam() throws {
        let tolerance = try PanoramaFixture.tolerance()
        let rotations = [Scene.rotation(yaw: -13, pitch: 0.5), Scene.rotation(yaw: 13, pitch: -0.5)]
        // Exposures 0.7 stop apart, and a different white balance.
        let gains = [SIMD3(0.8, 0.8, 0.8), SIMD3(1.15, 1.0, 0.9) * 1.3]
        // Above 6° of elevation the scene is a sky five times brighter than anything else in it.
        func scene(_ d: SIMD3<Double>) -> SIMD3<Double> { Scene.latitude(d) < -6 ? SIMD3(3.0, 2.8, 2.5) : Scene.radiance(PanoramaFixture.seed, d) }
        let frames = try zip(rotations, gains).map { try Scene.view(rotation: $0, gain: $1, clip: 1, radiance: scene) }
        // The sky is at the sensor's limit in every channel of both frames.
        for frame in frames { #expect(frame.rgb(10 * 320 + 160) == SIMD3(1, 1, 1) && frame.clipLevel == SIMD3(repeating: 0.98)) }
        let result = try LWPanoramaStitcher.stitch(frames)
        // The exposures are still solved, from what is not blown.
        for channel in 0..<3 {
            let solved = Double(log2(result.alignment.gains[1][channel] / result.alignment.gains[0][channel]))
            #expect(abs(solved - log2(gains[1][channel] / gains[0][channel])) < 0.06, "channel \(channel): \(solved)")
        }
        let turn = PanoramaTruth.toTruth(result, rotations)
        var lowest = Float.infinity, highest: Float = 0, tint: Float = 0, pixels = 0, seamPairs = 0, step: Float = 0
        for y in 0..<result.height {
            for x in 0..<result.width {
                // Sky, clear of its edge, that both frames see clear of their own edges.
                let d = PanoramaTruth.direction(result, x, y, toTruth: turn)
                guard Scene.latitude(d) < -9, rotations.allSatisfy({ rotation in
                    let c = rotation.transpose * d
                    guard c.z > 0 else { return false }
                    let px = 300 * c.x / c.z + 159.5, py = 300 * c.y / c.z + 119.5
                    return px >= 4 && py >= 4 && px <= 315 && py <= 235
                }) else { continue }
                let p = y * result.width + x, value = result.rgb(p)
                lowest = min(lowest, value.min()); highest = max(highest, value.max()); tint = max(tint, (value.max() - value.min()) / value.max()); pixels += 1
                if x + 1 < result.width, result.labels[p] != result.labels[p + 1] {
                    seamPairs += 1
                    step = max(step, abs(log2(LWPanoramaSeamMetric.luminance(value) / LWPanoramaSeamMetric.luminance(result.rgb(p + 1)))))
                }
            }
        }
        print("S44 blown sky: \(pixels) pixels blown in both frames, levels \(lowest) to \(highest), worst tint \(tint), \(seamPairs) seam pairs with a worst step of \(step) stops")
        #expect(pixels > 3000 && seamPairs > 20, "\(pixels) pixels, \(seamPairs) seam pairs")
        #expect(tint < 0.02, "R, G and B differ by \(tint) of the level")
        #expect(step < Float(tolerance) && log2(highest / lowest) < Float(tolerance), "step \(step), levels \(lowest) to \(highest)")
        // It is the level of the frame with the least headroom, and nothing in the picture is brighter.
        let ceiling = LWPanoramaStitcher.ceiling(result.alignment, clips: frames.map(\.clipLevel))
        #expect(abs(highest - ceiling) < 0.002 && result.peak <= ceiling + 0.002 && ceiling == (0.98 / result.alignment.gains[1]).min(), "\(highest) \(ceiling) \(result.peak)")
        #expect(LWPanoramaSeamMetric.measure(result, frames: frames).value < tolerance)
    }

    /// Twelve frames around the horizon: the canvas is the whole circle, and the frame that
    /// straddles the ±180° cut lands on both ends of it. With the frames turned 15° the cut falls
    /// in the overlap of two frames instead.
    @Test func aFullCircleStitchesAcrossTheCut() throws {
        let tolerance = try PanoramaFixture.tolerance(), projectionBound = try PanoramaFixture.projectionTolerance()
        for (offset, projections) in [(0.0, [LWPanoramaProjection.spherical, .cylindrical]), (15.0, [.spherical])] {
            let truth = (0..<12).map { Scene.rotation(yaw: Double($0) * 30 + offset, pitch: Double($0 % 3) - 1) }
            let frames = try Scene.views(truth)
            let (alignment, works) = try LWPanoramaStitcher.align(frames)
            #expect(alignment.pairs.count >= 12 && abs(alignment.focal - 300) / 300 < 0.02, "\(alignment.pairs.count) pairs, focal \(alignment.focal)")
            for projection in projections {
                let result = try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: projection, boundary: .autoCrop))
                #expect(result.geometry.fullCircle && result.width == result.geometry.width)
                // The circle is a whole number of pixels at every pyramid level, at the nearest scale to the focal length.
                #expect(result.width % 32 == 0 && abs(Double(result.width) - 2 * .pi * alignment.focal) <= 16 && abs(result.geometry.scale * 2 * .pi - Double(result.width)) < 1e-6, "\(result.width)")
                #expect(result.uncoveredPixels == 0 && Set(result.labels).count == 12)
                if offset == 0 {
                    // One frame owns pixels in both the first and the last column.
                    let first = Set((0..<result.height).map { result.labels[$0 * result.width] }), last = Set((0..<result.height).map { result.labels[$0 * result.width + result.width - 1] })
                    #expect(!first.intersection(last).isEmpty, "\(first) \(last)")
                }
                // Round every row there is one seam between each frame and the next: no more than
                // twelve changes of frame, and no sliver of one frame inside another's pixels.
                var changes = 0, sliver = Int.max
                for row in 0..<result.height {
                    let runs = PanoramaTruth.runs(result, row: row, cyclic: true)
                    // Round a circle a row of n runs changes frame n times.
                    changes = max(changes, runs.count > 1 ? runs.count : 0)
                    // A run between two runs of the same frame is a sliver of one frame inside another's pixels.
                    for index in runs.indices where runs.count >= 3 && runs[(index + runs.count - 1) % runs.count].frame == runs[(index + 1) % runs.count].frame {
                        sliver = min(sliver, runs[index].length)
                    }
                }
                #expect(changes <= 12 && changes >= 10, "\(projection) at \(offset)°: \(changes) changes of frame in one row")
                #expect(sliver >= 4, "\(projection) at \(offset)°: a run of \(sliver) pixels")
                // The seam metric counts the last column and the first as neighbours.
                let seam = LWPanoramaSeamMetric.measure(result, frames: frames)
                #expect(seam.value < tolerance, "\(projection): \(seam.value)")
                // The two ends meet: across the cut the picture steps by no more than the scene does, and it is the scene.
                let cut = PanoramaTruth.stepAcrossTheCut(result, truth: truth), error = PanoramaTruth.error(result, truth: truth)
                print("S44 full circle at \(offset)°, \(projection.rawValue): \(result.width) × \(result.height), seam error \(seam.value), step across the cut \(cut), \(changes) changes of frame per row, ground-truth error \(error)")
                #expect(cut < tolerance, "\(projection) at \(offset)°: \(cut) stops across the cut")
                #expect(error < projectionBound, "\(error)")
                // Fill Edges runs round the circle too.
                if projection == .spherical {
                    let filled = try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: projection, boundary: .fill))
                    #expect(filled.uncoveredPixels > 0 && filled.width == result.width)
                    var worst: Float = 0
                    for y in 0..<filled.height where filled.labels[y * filled.width] == 255 && filled.labels[y * filled.width + filled.width - 1] == 255 {
                        worst = max(worst, simd_reduce_max(abs(filled.rgb(y * filled.width) - filled.rgb(y * filled.width + filled.width - 1))))
                    }
                    #expect(worst < 0.02, "the fill steps by \(worst) across the cut")
                }
            }
            if offset == 0 {
                #expect(throws: LWPanoramaError.self) { try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: .perspective)) }
            }
        }
    }

    /// A wide sweep that is not a full circle, with its photos unevenly spaced: the canvas is cut
    /// in the stretch the photos leave out, not through the photos.
    @Test func anUnevenPartialSweepIsCutInItsGapAndKeepsEveryFrame() throws {
        let tolerance = try PanoramaFixture.tolerance()
        // 0° to 270°: nine photos 15° apart, then five 30° apart. Their mean direction is far from the middle of what they cover.
        let yaws: [Double] = [0, 15, 30, 45, 60, 75, 90, 105, 120, 150, 180, 210, 240, 270]
        let truth = yaws.map { Scene.rotation(yaw: $0, pitch: Double(Int($0) % 2)) }
        let frames = try Scene.views(truth)
        let (alignment, works) = try LWPanoramaStitcher.align(frames)
        // As aligned, the last frame points past ±180° from the mean direction.
        let spans = LWPanoramaStitcher.spans(alignment)
        #expect(spans.map(\.centre).max()! - spans.map(\.centre).min()! > 300 * .pi / 180, "\(spans.map { $0.centre * 180 / .pi })")
        let gap = try #require(LWPanoramaStitcher.widestGap(spans, least: 2 / alignment.focal))
        #expect(abs(gap.width * 180 / .pi - (360 - 270 - 2 * atan(159.5 / 300) * 180 / .pi)) < 2, "\(gap.width * 180 / .pi)°")
        for projection in [LWPanoramaProjection.spherical, .cylindrical] {
            let result = try LWPanoramaStitcher.compose(frames, alignment: alignment, works: works, options: LWPanoramaOptions(projection: projection))
            #expect(!result.geometry.fullCircle)
            #expect(Set(result.labels) == Set(0..<14), "\(Set(result.labels).sorted())")
            // The canvas is as wide as what the photos cover: 270° and one field of view.
            let covered = (270 * .pi / 180 + 2 * atan(159.5 / 300)) * alignment.focal
            // The crop trades a little width for height where the frames' pitch alternates; a
            // frame dropped from an end would cost at least its 30° (157 pixels) of its own.
            #expect(abs(Double(result.geometry.width) - covered) < 12 && result.width > Int(covered) - 120, "\(result.geometry.width) for \(covered), crop \(result.width)")
            #expect(result.uncoveredPixels == 0)
            let seam = LWPanoramaSeamMetric.measure(result, frames: frames)
            print("S44 uneven 326° sweep, \(projection.rawValue): \(result.width) × \(result.height) of a \(result.geometry.width)-wide canvas, seam error \(seam.value)")
            #expect(seam.value < tolerance, "\(seam.value)")
        }
        // The widest stretch no frame sees, on frames whose stretches pass 0° and overlap.
        func span(_ from: Double, _ to: Double) -> LWPanoramaStitcher.Span { LWPanoramaStitcher.Span(centre: (from + to) / 2 * .pi / 180, low: (from - to) / 2 * .pi / 180, high: (to - from) / 2 * .pi / 180) }
        let found = try #require(LWPanoramaStitcher.widestGap([span(300, 400), span(10, 20), span(60, 70), span(-170, -150)], least: 0.01))
        #expect(abs(found.middle * 180 / .pi - 130) < 1e-6 && abs(found.width * 180 / .pi - 120) < 1e-6, "\(found)")
        #expect(LWPanoramaStitcher.widestGap([span(0, 130), span(120, 250), span(240, 361)], least: 0.01) == nil)
        var pole = span(0, 10); pole.whole = true
        #expect(LWPanoramaStitcher.widestGap([pole], least: 0.01) == nil)
    }

    /// Handheld sets. Each either stitches within the tolerance or is refused with a reason that
    /// says what to do: none is written as a picture that is quietly wrong.
    @Test func handheldSetsStitchWithinTheToleranceOrAreRefusedWithTheReason() throws {
        let tolerance = try PanoramaFixture.tolerance()
        let rotations = [-25.0, 0, 25].map { Scene.rotation(yaw: $0, pitch: 0.5) }
        func worstRotationError(_ result: LWPanoramaResult, _ truth: [simd_double3x3]) -> Double {
            truth.indices.map { Scene.angle(result.alignment.rotations[0].transpose * result.alignment.rotations[$0], truth[0].transpose * truth[$0]) }.max()!
        }
        // Slight parallax: the camera turns about a point behind its lens, so near posts (at
        // distance 1) shift against the far scene by `arm` × 0.43 radians from one frame to the next.
        func posts(_ longitude: Double, _ latitude: Double, _ behind: SIMD3<Double>) -> SIMD3<Double> {
            let (post, noise) = Scene.shape(777, longitude, latitude, cell: 9)
            let a = Double(noise & 0xFF) / 255, b = Double((noise >> 8) & 0xFF) / 255
            return behind + (SIMD3(0.1 + 0.4 * a, 0.1 + 0.4 * b, 0.5 - 0.4 * a) - behind) * post
        }
        // A near wall over the lower half of every frame.
        func wall(_ longitude: Double, _ latitude: Double, _ behind: SIMD3<Double>) -> SIMD3<Double> {
            guard latitude > 2 else { return behind }
            let lon = longitude * .pi / 180, lat = latitude * .pi / 180
            return Scene.radiance(9191, SIMD3(sin(lon) * cos(lat), sin(lat), cos(lon) * cos(lat)))
        }
        func handheld(arm: Double, near: @escaping (Double, Double, SIMD3<Double>) -> SIMD3<Double>) throws -> [LWMergeFrame] {
            try rotations.map { rotation in try Scene.view(rotation: rotation, radiance: { Scene.parallax(from: rotation[2] * arm, $0, near: near) }) }
        }
        // 1 pixel of parallax on the posts: stitched, within the tolerance, to the true rotations.
        let slight = try handheld(arm: 0.008, near: posts)
        let stitched = try LWPanoramaStitcher.stitch(slight)
        let seam = LWPanoramaSeamMetric.measure(stitched, frames: slight)
        print("S44 slight parallax (1.0 px on near posts): seam error \(seam.value) (A \(seam.agreement), D \(seam.step)), worst rotation error \(worstRotationError(stitched, rotations))°")
        #expect(seam.value < tolerance && worstRotationError(stitched, rotations) < 0.5, "\(seam.value)")
        // 8 pixels of parallax on a near wall that fills half of every frame: two alignments fit, one for the wall and one for the scene.
        #expect(throws: LWPanoramaError.ambiguous(frame: 0, other: 1)) { try LWPanoramaStitcher.stitch(try handheld(arm: 0.06, near: wall)) }

        // A scene that repeats every 8° of longitude: any whole number of repeats joins two photos equally well.
        func repeating(_ unrepeated: Double) -> (SIMD3<Double>) -> SIMD3<Double> {
            { d in
                let longitude = Scene.longitude(d), latitude = Scene.latitude(d) * .pi / 180
                let folded = (longitude - (longitude / 8).rounded(.down) * 8 - 4) * .pi / 180
                let pattern = Scene.radiance(PanoramaFixture.seed, SIMD3(sin(folded) * cos(latitude), sin(latitude), cos(folded) * cos(latitude)))
                return pattern + (Scene.radiance(4242, d) - pattern) * unrepeated
            }
        }
        let sweep = [Scene.rotation(yaw: -13, pitch: 0.5), Scene.rotation(yaw: 13, pitch: -0.5), Scene.rotation(yaw: 37, pitch: 0.3)]
        #expect(throws: LWPanoramaError.ambiguous(frame: 0, other: 1)) { try LWPanoramaStitcher.stitch(try sweep.map { try Scene.view(rotation: $0, radiance: repeating(0)) }) }
        // With detail that does not repeat mixed in, the same sweep is joined the one right way.
        let mixed = try sweep.map { try Scene.view(rotation: $0, radiance: repeating(0.4)) }
        let joined = try LWPanoramaStitcher.stitch(mixed)
        let projectionBound = try PanoramaFixture.projectionTolerance()
        let mixedSeam = LWPanoramaSeamMetric.measure(joined, frames: mixed), mixedTruth = PanoramaTruth.error(joined, truth: sweep, radiance: repeating(0.4))
        print("S44 repeating pattern with 40 % unrepeated detail: seam error \(mixedSeam.value), worst rotation error \(worstRotationError(joined, sweep))°, ground-truth error \(mixedTruth)")
        #expect(mixedSeam.value < tolerance && worstRotationError(joined, sweep) < 0.5 && mixedTruth < projectionBound, "\(mixedSeam.value) \(mixedTruth)")
        #expect(joined.alignment.pairs.allSatisfy { $0.rival < 12 }, "\(joined.alignment.pairs)")

        // A flat subject photographed from two positions: the two photos match point for point (a
        // homography joins them), but no turn of one camera does.
        let flat = try Scene.view(rotation: Scene.rotation(yaw: 0))
        let homography = simd_double3x3(rows: [SIMD3(1.12, 0.05, 60), SIMD3(0.03, 0.92, 5), SIMD3(2e-4, -1e-4, 1)]).inverse
        var samples = [Float16](repeating: 0, count: 320 * 240 * 3)
        for y in 0..<240 {
            for x in 0..<320 {
                let p = homography * SIMD3(Double(x) - 159.5, Double(y) - 119.5, 1)
                let value = Scene.radiance(PanoramaFixture.seed, SIMD3(p.x / p.z / 300, p.y / p.z / 300, 1)), o = (y * 320 + x) * 3
                samples[o] = Float16(value.x); samples[o + 1] = Float16(value.y); samples[o + 2] = Float16(value.z)
            }
        }
        do { _ = try LWPanoramaStitcher.stitch([flat, try LWMergeFrame(width: 320, height: 240, samples: samples)]); Issue.record("Photos from two positions were stitched.") }
        catch let error as LWPanoramaError {
            guard case .notOnePanorama(let rms) = error else { Issue.record("\(error)"); return }
            #expect(rms > 4.5 && rms < 30, "\(rms)")
            #expect(error.message() == String(format: "These photos match each other but do not fit together as one panorama (they disagree by %.0f pixels). They may have been taken from different positions.", rms))
        }
        let names = ["left.dng", "right.dng"]
        #expect(LWPanoramaError.ambiguous(frame: 0, other: 1).message(names: names) == "“left.dng” and “right.dng” can be joined in two different ways. Either the scene repeats (a fence, bricks, rows of windows), or near and far subjects line up differently because the camera changed position. Reshoot turning the camera about its lens, with something that does not repeat in the overlap, or leave one of the two out.")
        // No figure when no alignment was found at all.
        #expect(LWPanoramaError.notOnePanorama(rmsPixels: .infinity).message() == "These photos match each other but do not fit together as one panorama. They may have been taken from different positions.")
        #expect(LWPanoramaError.notOnePanorama(rmsPixels: .nan).message() == LWPanoramaError.notOnePanorama(rmsPixels: .infinity).message())
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
        // The brightest sample is found when the picture is composed; the DNG's normalization reads it.
        #expect(result.peak == Float(result.samples.max()!) && result.peak > 0.3)
        let scale = LWPanoramaDNGWriter.normalization(result)
        #expect(scale == 1 / result.peak)
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
