import Foundation
import Testing
import CryptoKit
import CoreGraphics
import ImageIO
import SQLite3
import simd
@testable import Compositor

/// The S47 generated moving-subject bracket (scripts/generate_s47_procedural_photos.py),
/// developed through the editor's own source development.
nonisolated struct HDRBracketFixture {
    struct Frame: Decodable { let path: String; let exposure_stops: Int; let subject_bounds: [Int]; let sha256: String }
    let root: URL
    let files: [URL]
    let frames: [Frame]
    static let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()

    /// Generates the bracket with the checked-in generator into a fresh private folder and
    /// keeps only the three bracket photos in `photos`.
    static func make(seed: UInt32 = 25316) throws -> HDRBracketFixture {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("LWHDR-\(UUID())")
        let generated = root.appendingPathComponent("generated")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)  // the generator creates `generated` itself
        let process = Process()
        // The generator needs Python 3.10+ (the provisioned CI interpreter); macOS's /usr/bin/python3 is older.
        let python = ProcessInfo.processInfo.environment["LW_PYTHON"]
            ?? ["/opt/homebrew/opt/python@3.12/bin/python3.12", "/usr/local/bin/python3", "/usr/bin/python3"].first { FileManager.default.isExecutableFile(atPath: $0) }!
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [repository.appendingPathComponent("scripts/generate_s47_procedural_photos.py").path, "--output", generated.path, "--seed", String(seed)]
        let errors = Pipe(); process.standardError = errors
        try process.run()
        let diagnostics = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LensWorksCatalogError.message("S47 generator exited \(process.terminationStatus): \(diagnostics)") }
        struct Manifest: Decodable { let photos: [Record] }
        struct Record: Decodable { let kind: String; let path: String; let exposure_stops: Int?; let subject_bounds: [Int]?; let sha256: String }
        let manifest = try JSONDecoder().decode(Manifest.self, from: Data(contentsOf: generated.appendingPathComponent("fixture-manifest.json")))
        let bracket = manifest.photos.filter { $0.kind == "exposure-bracket" }
        let photos = root.appendingPathComponent("Photos")
        try FileManager.default.createDirectory(at: photos, withIntermediateDirectories: false)
        var files: [URL] = []
        for record in bracket {
            let target = photos.appendingPathComponent(URL(fileURLWithPath: record.path).lastPathComponent)
            try FileManager.default.copyItem(at: generated.appendingPathComponent(record.path), to: target)
            files.append(target)
        }
        try FileManager.default.removeItem(at: generated)
        return HDRBracketFixture(root: root, files: files, frames: bracket.map {
            Frame(path: $0.path, exposure_stops: $0.exposure_stops ?? 0, subject_bounds: $0.subject_bounds ?? [], sha256: $0.sha256)
        })
    }
    var subjectRegion: [LWHDRRegion] { frames.map { LWHDRRegion(minX: $0.subject_bounds[0], minY: $0.subject_bounds[1], maxX: $0.subject_bounds[2], maxY: $0.subject_bounds[3]) } }
    func hashes() throws -> [String] { try files.map { try LensWorksCatalog.sha256($0) } }
    static func develop(_ url: URL) async throws -> LWHDRFrame {
        try await LensWorksCatalog.developHDRFrame(original: try LWCatalogNativePath(fileURL: url), url: url)
    }
    func developed() async throws -> [LWHDRFrame] {
        var frames: [LWHDRFrame] = []
        for file in files { frames.append(try await Self.develop(file)) }
        return frames
    }
}

@Suite(.serialized)
@MainActor
struct HDRMergeTests {
    @Test func generatedBracketHasAMovingSubjectAndMergesWithRecoveredHighlights() async throws {
        let fixture = try HDRBracketFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        #expect(fixture.frames.map(\.exposure_stops) == [-1, 0, 1])
        #expect(Set(fixture.frames.map { $0.subject_bounds[0] }).count == 3, "Step 0: the subject moves across the bracket")
        let before = try fixture.hashes()
        #expect(before == fixture.frames.map(\.sha256))
        let frames = try await fixture.developed()
        // The production loader refuses a bracket one byte over the memory budget, with the numbers.
        let needed = frames[0].width * frames[0].height * (3 * 6 + 32), first = fixture.files[0]
        await #expect(throws: LWHDRMergeError.tooLarge(frames: 3, width: frames[0].width, height: frames[0].height, neededBytes: needed, budgetBytes: needed - 1)) {
            _ = try await LensWorksCatalog.developHDRFrame(original: try LWCatalogNativePath(fileURL: first), url: first, frames: 3, budget: needed - 1)
        }
        #expect(try await LensWorksCatalog.developHDRFrame(original: try LWCatalogNativePath(fileURL: first), url: first, frames: 3, budget: needed).samples == frames[0].samples)
        let result = try LWHDRMerger.merge(frames)
        #expect(result.referenceIndex == 1)
        #expect(result.offsets.allSatisfy { $0 == LWHDROffset(x: 0, y: 0) }, "\(result.offsets)")
        #expect(result.exposures[0] < 1 && result.exposures[2] > 1, "\(result.exposures)")
        #expect(result.maskedPixels[1] == 0 && result.maskedPixels[0] > 0 && result.maskedPixels[2] > 0)

        // The subject's red channel clips in the +1 EV frame; the merge keeps the reference subject unclipped.
        let width = result.width
        func center(_ frame: Int) -> Int { let b = fixture.frames[frame].subject_bounds; return (b[1] + b[3]) / 2 * width + (b[0] + b[2]) / 2 }
        let brightClip = LWHDRMerger.clipLevel(frames[2]).max()
        #expect(frames[2].pixels[center(2)].x >= brightClip)
        #expect(abs(result.radiance[center(1)].x - frames[1].pixels[center(1)].x) / frames[1].pixels[center(1)].x < 0.02)
        // Expected dynamic range: the merge holds the full reference range, records values above
        // what the brightest frame can (its clip, in its own exposure units), and is not 8-bit quantized.
        func span(_ values: [Float]) -> Float { log2(values.max()! / values.filter { $0 > 1e-6 }.min()!) }
        let merged = result.radiance.map { max($0.x, $0.y, $0.z) }
        let brightValid = frames[2].pixels.map { max($0.x, $0.y, $0.z) }.filter { $0 < brightClip }
        #expect(span(merged) >= span(frames[1].pixels.map { max($0.x, $0.y, $0.z) }) - 0.05)
        #expect(span(merged) > span(brightValid))
        #expect(merged.max()! * Float(result.exposures[2]) > brightClip)
        #expect(Set(result.radiance.map(\.y)).count > 256)
        #expect(try fixture.hashes() == before)
    }

    /// AC2. The metric definition lives with LWHDRGhostingMetric and docs/HDR_MERGE.md.
    @Test func deghostingLowersTheGhostingMetricOnTheMovingSubject() async throws {
        let fixture = try HDRBracketFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frames = try await fixture.developed()
        let on = try LWHDRMerger.merge(frames, options: LWHDRMergeOptions(deghost: true))
        let off = try LWHDRMerger.merge(frames, options: LWHDRMergeOptions(deghost: false))
        let moving = fixture.subjectRegion
        let gOn = LWHDRGhostingMetric.measure(on, reference: frames[on.referenceIndex], region: moving)
        let gOff = LWHDRGhostingMetric.measure(off, reference: frames[off.referenceIndex], region: moving)
        print("S43 ghosting metric on moving-subject region: deghost on \(gOn.value), off \(gOff.value) over \(gOn.pixels) pixels")
        #expect(gOn.pixels == gOff.pixels && gOn.pixels > 1000)
        #expect(gOn.value < gOff.value)
        #expect(gOn.value < 0.5 * gOff.value)
        // Outside the moving region both merges agree with the reference equally closely.
        let top = LWHDRRegion(minX: 0, minY: 0, maxX: on.width - 1, maxY: 30)
        let sOn = LWHDRGhostingMetric.measure(on, reference: frames[on.referenceIndex], region: [top])
        let sOff = LWHDRGhostingMetric.measure(off, reference: frames[off.referenceIndex], region: [top])
        #expect(abs(sOn.value - sOff.value) < 0.01 && sOn.value < 0.2, "static: \(sOn.value) \(sOff.value)")
    }

    @Test func alignmentRecoversAKnownTranslation() async throws {
        let fixture = try HDRBracketFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        var frames = try await fixture.developed()
        let w = frames[2].width, h = frames[2].height, source = frames[2].pixels
        // shifted(x, y) = source(x - 3, y + 2), so aligned(x, y) = shifted(x + 3, y - 2).
        var shifted = [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: source.count)
        for y in 0..<h { for x in 0..<w where x - 3 >= 0 && y + 2 < h { shifted[y * w + x] = source[(y + 2) * w + x - 3] } }
        frames[2] = try LWHDRFrame(width: w, height: h, pixels: shifted)
        let result = try LWHDRMerger.merge(frames)
        #expect(result.offsets[2] == LWHDROffset(x: 3, y: -2))
        #expect(result.offsets[0] == LWHDROffset(x: 0, y: 0))
    }

    @Test func mergedDNGIsLinearFloatWithProvenanceAndDevelopsThroughTheLiveSource() async throws {
        let fixture = try HDRBracketFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let frames = try await fixture.developed()
        let result = try LWHDRMerger.merge(frames)
        let scale = LWHDRDNGWriter.normalization(result)
        let provenance = LWHDRMergeProvenance(documentID: UUID().uuidString, deghost: true, referenceIndex: result.referenceIndex,
            baselineExposure: Double(-log2(scale)), sources: fixture.files.indices.map { i in
                .init(catalogImageID: "image-\(i)", assetID: "asset-\(i)", variantID: "master", fileName: fixture.files[i].lastPathComponent,
                      sha256: fixture.frames[i].sha256, relativeExposureEV: log2(result.exposures[i]), offset: result.offsets[i], profile: nil) })
        let dng = fixture.root.appendingPathComponent("merged.dng")
        try LWHDRDNGWriter.encode(result, provenance: provenance, reference: ["tiff:Make": "S47 & <Co>"]).write(to: dng)
        // The streamed write Merge to HDR… uses is the same file, and never replaces one.
        let streamed = fixture.root.appendingPathComponent("streamed.dng")
        try LWHDRDNGWriter.write(result, provenance: provenance, reference: ["tiff:Make": "S47 & <Co>"], to: streamed)
        #expect(try Data(contentsOf: streamed) == Data(contentsOf: dng))
        try Data("existing".utf8).write(to: streamed)
        #expect(throws: POSIXError.self) { try LWHDRDNGWriter.write(result, provenance: provenance, to: streamed) }
        #expect(try Data(contentsOf: streamed) == Data("existing".utf8))
        let inspection = try LWDNGInspection(Data(contentsOf: dng))
        #expect(inspection.tags[262] == [34892] && inspection.tags[339] == [3, 3, 3] && inspection.tags[258] == [32, 32, 32])
        #expect(inspection.tags[50706] == [1, 4, 0, 0] && inspection.width == result.width && inspection.height == result.height)
        #expect(try inspection.provenance() == provenance)
        let samples = try #require(inspection.floatSamples)
        let baseline = Float(try #require(inspection.tags[50730]?.first))
        #expect(samples.max()! == 1)
        for (index, value) in result.radiance.enumerated() {
            let restored = SIMD3(samples[index * 3], samples[index * 3 + 1], samples[index * 3 + 2]) * exp2(baseline)
            #expect(simd_reduce_max(abs(restored - value)) <= 1e-4 * max(1, simd_reduce_max(value)))
            if simd_reduce_max(abs(restored - value)) > 1e-4 * max(1, simd_reduce_max(value)) { break }
        }
        // The editor's managed DNG development reads the samples with identity linear-sRGB color.
        let developed = try await HDRBracketFixture.develop(dng)
        var worst: Float = 0
        for (index, pixel) in developed.pixels.enumerated() {
            let stored = SIMD3(samples[index * 3], samples[index * 3 + 1], samples[index * 3 + 2])
            worst = max(worst, simd_reduce_max(abs(SIMD3(pixel.x, pixel.y, pixel.z) - stored)))
        }
        #expect(worst < 0.01, "worst developed delta \(worst)")
    }
}

/// Synthetic brackets for the pure merge: a static scene whose radiance rises along x on a
/// log scale, exposed at `stops` and clipped at each channel's `saturation`.
nonisolated enum HDRSyntheticBracket {
    static func radiance(_ x: Int, width: Int, low: Float, high: Float) -> Float { low * pow(high / low, Float(x) / Float(width - 1)) }
    static func frame(width: Int = 64, height: Int = 64, stops: Float, low: Float = 0.002, high: Float = 0.9,
                      saturation: SIMD3<Float> = SIMD3(repeating: 1)) throws -> LWHDRFrame {
        var pixels: [SIMD4<Float>] = []
        for _ in 0..<height {
            for x in 0..<width {
                let value = radiance(x, width: width, low: low, high: high) * exp2(stops)
                pixels.append(SIMD4(min(value, saturation.x), min(value, saturation.y), min(value, saturation.z), 1))
            }
        }
        return try LWHDRFrame(width: width, height: height, pixels: pixels)
    }
}

extension HDRMergeTests {
    private func expectScene(_ result: LWHDRMergeResult, stops: [Float]) {
        let reference = stops[result.referenceIndex]
        for (index, stop) in stops.enumerated() {
            #expect(abs(Float(log2(result.exposures[index])) - (stop - reference)) < 0.02, "exposure \(index): \(result.exposures)")
        }
        var worst: Float = 0
        for x in 0..<result.width {
            let expected = HDRSyntheticBracket.radiance(x, width: result.width, low: 0.002, high: 0.9) * exp2(reference)
            let merged = result.radiance[(result.height / 2) * result.width + x]
            worst = max(worst, abs(merged.x - expected) / expected, abs(merged.y - expected) / expected, abs(merged.z - expected) / expected)
        }
        #expect(worst < 0.01, "worst relative radiance error \(worst)")
    }
    @Test func aTwoFrameBracketMerges() throws {
        let stops: [Float] = [0, 2]
        let result = try LWHDRMerger.merge(try stops.map { try HDRSyntheticBracket.frame(stops: $0) })
        #expect(result.exposures.count == 2 && result.radiance.count == 64 * 64)
        expectScene(result, stops: stops)
    }
    @Test func aNineFrameBracketMerges() throws {
        let stops: [Float] = [-4, -3, -2, -1, 0, 1, 2, 3, 4]
        #expect(stops.count == LWHDRMerger.maximumFrames)
        let result = try LWHDRMerger.merge(try stops.map { try HDRSyntheticBracket.frame(stops: $0) })
        #expect(result.referenceIndex == 4 && result.exposures.count == 9)
        expectScene(result, stops: stops)
    }
    @Test func oneFrameIsTooFew() throws {
        let frame = try HDRSyntheticBracket.frame(stops: 0)
        #expect(throws: LWHDRMergeError.tooFewFrames) { try LWHDRMerger.merge([frame]) }
    }
    @Test func tenFramesAreTooMany() throws {
        let frames = try (0..<10).map { try HDRSyntheticBracket.frame(stops: Float($0) / 2 - 2) }
        #expect(throws: LWHDRMergeError.tooManyFrames) { try LWHDRMerger.merge(frames) }
    }
    @Test func framesOfDifferentSizesAreRefused() throws {
        let frames = [try HDRSyntheticBracket.frame(width: 64, height: 64, stops: 0), try HDRSyntheticBracket.frame(width: 64, height: 60, stops: 1)]
        #expect(throws: LWHDRMergeError.sizeMismatch) { try LWHDRMerger.merge(frames) }
    }
    @Test func framesWithoutSharedWellExposedPixelsAreRefused() throws {
        let black = try LWHDRFrame(width: 64, height: 64, pixels: [SIMD4<Float>](repeating: SIMD4(0, 0, 0, 1), count: 64 * 64))
        #expect(throws: LWHDRMergeError.insufficientOverlap) { try LWHDRMerger.merge([try HDRSyntheticBracket.frame(stops: 0), black]) }
    }

    /// The exposure estimate reads every pixel of a small frame and a regular grid of a large one.
    @Test func largeFramesEstimateExposureFromASampledGrid() {
        #expect(LWHDRMerger.exposureGrid(width: 64, height: 64) == (1, 64 * 64))
        #expect(LWHDRMerger.exposureGrid(width: 2000, height: 2000) == (1, 4_000_000))
        for (width, height, step) in [(6000, 4000, 2), (8192, 5464, 3), (11648, 8736, 5)] {
            let grid = LWHDRMerger.exposureGrid(width: width, height: height)
            #expect(grid.step == step)
            // Exactly the pixels a stride over x and y visits, and a few million of them.
            #expect(grid.samples == stride(from: 0, to: width, by: step).underestimatedCount * stride(from: 0, to: height, by: step).underestimatedCount)
            #expect(grid.samples >= 4_000_000 && grid.samples <= 8_000_000)
        }
    }

    /// White-balanced RAW development leaves each channel saturating at its own level. Where only
    /// the brighter frame's green is saturated (below that frame's red maximum), the merge must
    /// not blend that frame in.
    @Test func aChannelSaturatedBelowTheFrameMaximumGetsNoWeight() throws {
        let saturation = SIMD3<Float>(2.0, 1.0, 1.5)
        let dark = try HDRSyntheticBracket.frame(stops: 0, low: 0.01, high: 0.9, saturation: saturation)
        let bright = try HDRSyntheticBracket.frame(stops: 2, low: 0.01, high: 0.9, saturation: saturation)
        #expect(LWHDRMerger.clipLevel(bright) == 0.98 * saturation)
        let result = try LWHDRMerger.merge([dark, bright], options: LWHDRMergeOptions(deghost: true, align: false))
        #expect(result.referenceIndex == 0 && abs(result.exposures[1] - 4) < 0.05)
        var checked = 0
        for x in 0..<64 {
            let scene = HDRSyntheticBracket.radiance(x, width: 64, low: 0.01, high: 0.9)
            // Only green is saturated in the bright frame: 4 × scene is past 1.0 but below 1.5 and 2.0.
            guard scene * 4 > 1.05, scene * 4 < 1.4 else { continue }
            let merged = result.radiance[32 * 64 + x]
            #expect(abs(merged.y - scene) / scene < 0.01, "x \(x): green \(merged.y) for scene \(scene)")
            #expect(abs(merged.x - scene) / scene < 0.01 && abs(merged.z - scene) / scene < 0.01)
            checked += 1
        }
        #expect(checked >= 3)
    }

    /// A RAW frame's clip level is the decoder's, wherever the sensor's white lands: here a
    /// neutral subject saturates at 0.7, where the raster estimate (never below 1.0) sees nothing.
    @Test func aSourceWhiteLevelBelowOneIsDetectedAsClipping() throws {
        let white = SIMD3<Float>(repeating: 0.7)
        func frame(stops: Float) throws -> LWHDRFrame {
            var pixels: [SIMD4<Float>] = []
            for _ in 0..<64 { for x in 0..<64 {
                let value = min(HDRSyntheticBracket.radiance(x, width: 64, low: 0.01, high: 0.6) * exp2(stops), 0.7)
                pixels.append(SIMD4(value, value, value, 1))
            } }
            return try LWHDRFrame(width: 64, height: 64, pixels: pixels, whiteLevel: white)
        }
        let dark = try frame(stops: 0), bright = try frame(stops: 2)
        #expect(LWHDRMerger.clipLevel(bright) == 0.98 * white)
        let result = try LWHDRMerger.merge([dark, bright], options: LWHDRMergeOptions(deghost: true, align: false))
        #expect(result.referenceIndex == 0 && abs(result.exposures[1] - 4) < 0.05)
        var checked = 0
        for x in 0..<64 {
            let scene = HDRSyntheticBracket.radiance(x, width: 64, low: 0.01, high: 0.6)
            guard scene * 4 > 0.72 else { continue }  // Saturated at 0.7 in the bright frame.
            let merged = result.radiance[32 * 64 + x]
            #expect(abs(merged.x - scene) / scene < 0.01 && abs(merged.y - scene) / scene < 0.01 && abs(merged.z - scene) / scene < 0.01, "x \(x): \(merged) for scene \(scene)")
            checked += 1
        }
        #expect(checked >= 10)
    }

    /// A saturated red subject reads 2.0 in red while a neutral highlight's red is clipped at 1.0.
    /// The frame's own red maximum would hide the clipped neutrals; the decoder's level does not.
    @Test func aSaturatedColouredSubjectDoesNotHideClippedNeutralHighlights() throws {
        let white = SIMD3<Float>(repeating: 1)
        func frame(stops: Float) throws -> LWHDRFrame {
            var pixels: [SIMD4<Float>] = []
            for y in 0..<64 { for x in 0..<64 {
                let gain = exp2(stops)
                if y < 8 {  // The red subject: its red saturates at 2.0 in the bright frame.
                    pixels.append(SIMD4(min(0.6 * gain, 2.0), 0.02 * gain, 0.02 * gain, 1))
                } else {    // Neutral: red is the first channel to saturate, at 1.0; the others reach 1.5.
                    let value = HDRSyntheticBracket.radiance(x, width: 64, low: 0.01, high: 0.9) * gain
                    pixels.append(SIMD4(min(value, 1.0), min(value, 1.5), min(value, 1.5), 1))
                }
            } }
            return try LWHDRFrame(width: 64, height: 64, pixels: pixels, whiteLevel: white)
        }
        let dark = try frame(stops: 0), bright = try frame(stops: 2)
        #expect(bright.pixels[0].x == 2.0 && LWHDRMerger.clipLevel(bright) == SIMD3(repeating: 0.98))
        let result = try LWHDRMerger.merge([dark, bright], options: LWHDRMergeOptions(deghost: true, align: false))
        #expect(result.referenceIndex == 0 && abs(result.exposures[1] - 4) < 0.05)
        var checked = 0
        for x in 0..<64 {
            let scene = HDRSyntheticBracket.radiance(x, width: 64, low: 0.01, high: 0.9)
            guard scene * 4 > 1.05, scene * 4 < 1.4 else { continue }  // Only red is clipped in the bright frame.
            let merged = result.radiance[32 * 64 + x]
            #expect(abs(merged.x - scene) / scene < 0.01, "x \(x): red \(merged.x) for scene \(scene)")
            #expect(abs(merged.y - scene) / scene < 0.01 && abs(merged.z - scene) / scene < 0.01)
            checked += 1
        }
        #expect(checked >= 3)
        // The red subject itself comes from the frame that holds it unclipped.
        let subject = result.radiance[4 * 64 + 32]
        #expect(abs(subject.x - 0.6) < 0.006 && abs(subject.y - 0.02) < 0.001 && abs(subject.z - 0.02) < 0.001, "\(subject)")
    }

    /// The level reaches the merge from the decode worker: a camera DNG's frame carries where a
    /// neutral subject first clips, though its white-level block develops to twice that in red;
    /// a raster frame carries none and falls back to the estimate.
    @Test func aCameraRawFrameCarriesTheDecodersNeutralClipLevelAndARasterFrameNone() async throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("LWHDR-white-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let raw = root.appendingPathComponent("procedural.dng")
        try ProceduralDNG.write(to: raw, width: 96, height: 64)
        let frame = try await LensWorksCatalog.developHDRFrame(original: try LWCatalogNativePath(fileURL: raw), url: raw)
        let white = try #require(frame.whiteLevel)
        #expect(abs(white.x - 1) < 0.01 && abs(white.y - 1) < 0.01 && abs(white.z - 1) < 0.01, "\(white)")
        #expect(LWHDRMerger.clipLevel(frame) == 0.98 * white)
        // The saturated block (as-shot neutral 0.5, 1, 0.75) develops far above that level in red
        // and blue and below it in green. A level estimated from the frame would be this block's
        // own red and blue, and 1.0 in green, and would call the block's surroundings well exposed.
        let block = frame.pixels[4 * 96 + 4]
        #expect(block.x > 1.9 && block.y < 0.98 && block.z > 1.2, "\(block)")
        #expect(LWHDRMerger.clipped(SIMD3(block.x, block.y, block.z), LWHDRMerger.clipLevel(frame)))
        let fixture = try HDRBracketFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let raster = try await HDRBracketFixture.develop(fixture.files[0])
        #expect(raster.whiteLevel == nil && LWHDRMerger.clipLevel(raster) == SIMD3(repeating: 0.98))
    }

    /// The budget's unit is bytes per pixel: 6 per frame plus 32 shared (docs/HDR_MERGE.md, "Memory").
    @Test func theMemoryBudgetAdmitsOrdinaryBracketsAndRefusesOversizedOnesWithTheNumbers() throws {
        let budget = LWHDRMerger.minimumBudgetBytes
        #expect(budget == 6 * 1024 * 1024 * 1024 && LWHDRMerger.budgetBytes >= budget)
        #expect(LWHDRMerger.workingBytes(frames: 5, width: 8192, height: 5464) == 8192 * 5464 * (5 * 6 + 32))
        // 45 MP and 61 MP camera files, 3 through 9 frames, on the 16 GB Mac's budget.
        for frames in [3, 5, 9] {
            try LWHDRMerger.admit(frames: frames, width: 8192, height: 5464, budget: budget)
            try LWHDRMerger.admit(frames: frames, width: 9504, height: 6336, budget: budget)
        }
        try LWHDRMerger.admit(frames: 5, width: 11648, height: 8736, budget: budget)  // 102 MP × 5
        #expect(throws: LWHDRMergeError.tooLarge(frames: 9, width: 11648, height: 8736, neededBytes: 11648 * 8736 * 86, budgetBytes: budget)) {
            try LWHDRMerger.admit(frames: 9, width: 11648, height: 8736, budget: budget)
        }
        let message = LWHDRMergeError.tooLarge(frames: 9, width: 11648, height: 8736, neededBytes: 11648 * 8736 * 86, budgetBytes: budget).localizedDescription
        #expect(message.contains("9 photos") && message.contains("102 MP") && message.contains("8.8 GB") && message.contains("6.4 GB"), "\(message)")
        #expect(LWHDRMerger.workingBytes(frames: 2, width: .max / 2, height: 4) == .max)
    }

    /// The blocker: a frame above ~16 MP could not be read through the 512 MiB float working set
    /// in one piece. The production loader reads bounded row strips (349 rows at this width).
    @Test func aTwentyFourMegapixelFrameLoadsThroughTheMergeLoader() async throws {
        let width = 6000, height = 4000
        func level(_ x: Int, _ y: Int) -> UInt8 { UInt8((y * 7 + x / 64) & 255) }
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
        let root = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("LWHDR-large-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("large.png")
        do {
            var bytes = Data(count: width * height * 4)
            bytes.withUnsafeMutableBytes { raw in
                for y in 0..<height { for block in 0..<((width + 63) / 64) {
                    let x = block * 64
                    memset(raw.baseAddress! + (y * width + x) * 4, Int32(level(x, y)), min(64, width - x) * 4)
                } }
            }
            let space = try #require(CGColorSpace(name: CGColorSpace.sRGB)), provider = try #require(CGDataProvider(data: bytes as CFData))
            let image = try #require(CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                space: space, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent))
            let destination = try #require(CGImageDestinationCreateWithURL(file as CFURL, "public.png" as CFString, 1, nil))
            CGImageDestinationAddImage(destination, image, nil)
            #expect(CGImageDestinationFinalize(destination))
        }
        #expect(width * height * 32 > LWFloatWorkingSet.maximumBytes, "a whole-extent read of this frame cannot be admitted")
        let frame = try await LensWorksCatalog.developHDRFrame(original: try LWCatalogNativePath(fileURL: file), url: file)
        #expect(frame.width == width && frame.height == height && frame.samples.count == width * height * 3)
        func linear(_ value: UInt8) -> Float { let v = Float(value) / 255; return v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        // Rows on both sides of the strip seams (349 rows per strip), and the frame's corners.
        var worst: Float = 0
        for y in [0, 1, 348, 349, 350, 697, 698, 2000, 3489, 3490, 3999] {
            for x in [0, 63, 64, 3000, 5999] {
                let pixel = frame.pixels[y * width + x], expected = linear(level(x, y))
                worst = max(worst, abs(pixel.x - expected), abs(pixel.y - expected), abs(pixel.z - expected))
            }
        }
        #expect(worst < 2e-3, "worst sample error \(worst)")
    }

    @Test func detachedWorkIsCancelledWithItsCaller() async throws {
        let started = ContinuousClock.now
        let task = Task { try await LensWorksCatalog.detached { () -> Bool in
            // Bounded: without cancellation this returns, it never hangs the suite.
            for _ in 0..<500 { try Task.checkCancellation(); usleep(10_000) }
            return true
        } }
        try await Task.sleep(for: .milliseconds(100))
        task.cancel()
        await #expect(throws: CancellationError.self) { _ = try await task.value }
        #expect(ContinuousClock.now - started < .seconds(3))
    }

    @Test func aMergedFileNeverReplacesAnExistingOne() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LWHDR-move-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: folder) }
        try Data("existing".utf8).write(to: folder.appendingPathComponent("shot-HDR.dng"))
        let first = folder.appendingPathComponent(".partial-1"), second = folder.appendingPathComponent(".partial-2")
        try Data("first".utf8).write(to: first); try Data("second".utf8).write(to: second)
        #expect(try LensWorksCatalog.moveWithoutReplacing(first, into: folder, stem: "shot-HDR").lastPathComponent == "shot-HDR-2.dng")
        #expect(try LensWorksCatalog.moveWithoutReplacing(second, into: folder, stem: "shot-HDR").lastPathComponent == "shot-HDR-3.dng")
        #expect(try Data(contentsOf: folder.appendingPathComponent("shot-HDR.dng")) == Data("existing".utf8))
        #expect(try Data(contentsOf: folder.appendingPathComponent("shot-HDR-2.dng")) == Data("first".utf8))
        #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == ["shot-HDR-2.dng", "shot-HDR-3.dng", "shot-HDR.dng"])
    }
}

/// AC1 and AC3 through the real catalog: one new linked catalog item, unchanged sources,
/// and an editor document with live RAW development that accepts layers.
@Suite(.serialized)
@MainActor
struct HDRMergeCatalogTests {
    private func catalogModel(_ fixture: HDRBracketFixture, defaults: UserDefaults? = nil) throws -> (model: LensWorksCatalog, defaults: UserDefaults) {
        let photos = fixture.root.appendingPathComponent("Photos")
        let worker = try #require(ProcessInfo.processInfo.environment["LW_CATALOG_TEST_WORKER"], "Explicit retained fixture helper is required.")
        let decode = ProcessInfo.processInfo.environment["LW_CATALOG_TEST_DECODE_WORKER"] ?? worker
        let config = LWManagedSessionConfig(worker_executable: try LWCatalogNativePath(fileURL: URL(fileURLWithPath: worker)), decode_worker_executable: try LWCatalogNativePath(fileURL: URL(fileURLWithPath: decode)),
            cache_root: try LWCatalogNativePath(fileURL: fixture.root.appendingPathComponent("Cache")), original_roots: [try LWCatalogNativePath(fileURL: photos)],
            limits: LWApplicationLimits(queued: 128, request_bytes: 1048576, reply_bytes: 1048576, page_rows: 100, scan_rows: 512, page_bytes: 131072, tickets: 128, ttl_seconds: 60, binary_bytes: 16777216), preview_policy: nil, preview_limits: nil)
        // In-memory preferences of this fixture's own: nothing reaches a preferences file.
        let defaults = defaults ?? LensWorksUserState.defaults(testing: true)
        return (LensWorksCatalog(configuration: config, index: LensWorksCatalogIndex(url: fixture.root.appendingPathComponent("Index.sqlite3")), defaults: defaults, migrateLegacy: false), defaults)
    }
    /// A catalog over the generated bracket's folder with its three photos imported.
    private func withBracketCatalog(_ body: (LensWorksCatalog, HDRBracketFixture, [LensWorksCatalogAsset], UserDefaults) async throws -> Void) async throws {
        let fixture = try HDRBracketFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photos = fixture.root.appendingPathComponent("Photos")
        let (model, defaults) = try catalogModel(fixture)
        await model.connect(fixture.root.appendingPathComponent("Catalog").path, create: true)
        do {
            if let error = model.error { throw LensWorksCatalogError.message(error) }
            try await model.startImport(photos.path); try await model.waitImport(terminal: true)
            #expect(model.assets.count == 3)
            try await body(model, fixture, model.assets, defaults)
            if model.catalogPath != nil { try await model.close() }
        } catch {
            if model.catalogPath != nil { try? await model.close() }
            throw error
        }
    }
    private func selectAll(_ model: LensWorksCatalog, _ sources: [LensWorksCatalogAsset]) async {
        await model.select(sources[0])
        for row in sources.dropFirst() { await model.select(row, extending: true) }
    }
    /// Files in the bracket's folder tree that the fixture did not put there.
    private func leftovers(_ fixture: HDRBracketFixture) throws -> [String] {
        let photos = fixture.root.appendingPathComponent("Photos"), known = Set(fixture.files.map(\.lastPathComponent))
        return try FileManager.default.contentsOfDirectory(atPath: photos.path).filter { !known.contains($0) }.sorted()
    }

    @Test func mergeCreatesOneLinkedFloatDNGCatalogItemThatOpensWithRawControlsAndLayers() async throws {
        try await withBracketCatalog { model, fixture, sources, defaults in
            let photos = fixture.root.appendingPathComponent("Photos")
            let before = try fixture.hashes()
            // Photos the catalog has not imported, beside the sources and in a subfolder: a merge adds neither.
            try FileManager.default.createDirectory(at: photos.appendingPathComponent("Sub"), withIntermediateDirectories: false)
            try FileManager.default.copyItem(at: fixture.files[0], to: photos.appendingPathComponent("uncataloged-beside.png"))
            try FileManager.default.copyItem(at: fixture.files[0], to: photos.appendingPathComponent("Sub/uncataloged-below.png"))
            let checkpointKey = "LensWorks.importSource." + (try #require(model.catalogPath))
            let checkpoint = try #require(defaults.data(forKey: checkpointKey))
            await model.select(sources[0])
            #expect(model.hdrMergeAvailability() == "Select two or more bracketed photos.")
            for row in sources.dropFirst() { await model.select(row, extending: true) }
            #expect(model.selectionCount == 3 && model.hdrMergeAvailability() == nil)

            let outcome = try await model.mergeSelectionToHDR(deghost: true)
            #expect(model.error == nil, "\(model.error ?? "")")
            #expect(try fixture.hashes() == before)
            #expect(model.assets.count == 4 && model.searchText.isEmpty && model.activeFolder == nil, "\(model.assets.map(\.filename))")
            #expect(defaults.data(forKey: checkpointKey) == checkpoint, "the folder-import resume source is not replaced")
            #expect(try leftovers(fixture) == ["Sub", outcome.dng.lastPathComponent, "uncataloged-beside.png"].sorted())
            let merged = try #require(model.assets.first { $0.filename == outcome.dng.lastPathComponent })
            #expect(!sources.contains { $0.id == merged.id })
            #expect(model.selectedAsset?.id == merged.id && outcome.asset.id == merged.id)
            #expect(!model.isMergingHDR && model.hdrMergeCancelReason != nil)

            // The catalog item's own original is a linear float DNG whose XMP names all three sources.
            let original = try await model.service.originalLocation(try #require(merged.key)).localFileURL()
            #expect(original.resolvingSymlinksInPath().path == outcome.dng.resolvingSymlinksInPath().path)
            let inspection = try LWDNGInspection(Data(contentsOf: original))
            #expect(inspection.tags[262] == [34892] && inspection.tags[339] == [3, 3, 3] && inspection.tags[258] == [32, 32, 32])
            let link = try inspection.provenance()
            #expect(Set(link.sources.map(\.catalogImageID)) == Set(sources.map(\.id)))
            #expect(Set(link.sources.map(\.assetID)) == Set(sources.compactMap { $0.key?.asset_id }))
            for source in link.sources {
                let row = try #require(sources.first { $0.id == source.catalogImageID })
                let file = try await model.service.originalLocation(try #require(row.key)).localFileURL()
                let hash = try LensWorksCatalog.sha256(file)
                #expect(source.fileName == file.lastPathComponent && source.sha256 == hash)
            }
            #expect(link.deghost && link == outcome.provenance)
            // The file is meant to be shared: its XMP holds no local path.
            let packet = String(decoding: try #require(inspection.xmp), as: UTF8.self)
            #expect(!packet.contains(fixture.root.path) && !packet.contains(NSHomeDirectory()) && !packet.contains("catalogPath"))

            // The link on the catalog side: the merged item's recorded sources, read back through the model.
            let linked = try await model.hdrMergeSources(of: merged)
            #expect(linked.count == 3 && Set(linked.map(\.imageID)) == Set(sources.map(\.id)))
            for source in linked {
                let row = try #require(sources.first { $0.id == source.imageID })
                #expect(source.assetID == row.key?.asset_id && source.variantID == row.key?.variant_id && source.filename == row.filename)
            }
            #expect(try await model.hdrMergeSources(of: sources[0]).isEmpty)
            // It is durable catalog-side state, not session state: a second index connection reads it.
            let reopened = LensWorksCatalogIndex(url: fixture.root.appendingPathComponent("Index.sqlite3"))
            #expect(try await reopened.sources(catalog: try #require(model.catalogPath), image: merged.id) == linked)
            // Following the link selects the three sources.
            try await model.selectHDRMergeSources(of: merged)
            #expect(model.selectionCount == 3 && model.selection == Set(sources.map(\.id)))
            #expect(sources.contains { $0.id == model.selectedPhotoID })
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
            #expect(try fixture.hashes() == before)
        }
    }

    /// An agent runs Merge to HDR… through the registry on the current selection. The originals it
    /// reads and the folder it writes into are held to the granted folders, its deghost argument
    /// reaches the merge, and Select HDR Source Photos follows the link it records.
    @Test func anAgentMergesTheSelectionOnlyInsideAGrantedFolderAndFollowsTheLink() async throws {
        let harness = try LensWorksAutomationTests.Harness(); defer { harness.cleanUp() }
        try await withBracketCatalog { model, fixture, sources, _ in
            harness.catalog = model
            let tools = harness.automation.tools
            func invoke(_ command: String, _ arguments: [String: Any] = [:]) async -> [String: Any] {
                await tools.call("invoke_command", arguments: ["command": command, "arguments": arguments])
            }
            func text(_ result: [String: Any]) -> String { ((result["content"] as? [[String: Any]])?.compactMap { $0["text"] as? String } ?? []).joined(separator: "\n") }
            let before = try fixture.hashes()
            let idle = await invoke("catalog.hdr.cancel")
            #expect(idle["isError"] as? Bool == true && text(idle) == "No merge to HDR is running.", "\(text(idle))")
            await model.select(sources[0])
            let single = await invoke("catalog.hdr.merge")
            #expect(single["isError"] as? Bool == true && text(single) == "Select two or more bracketed photos.", "\(text(single))")
            await selectAll(model, sources)
            // Nothing is granted: refused before any original is read, and nothing is written.
            let ungranted = await invoke("catalog.hdr.merge", ["deghost": false])
            #expect(ungranted["isError"] as? Bool == true && text(ungranted).hasPrefix("A source photo’s original: No folders are granted to automation"), "\(text(ungranted))")
            #expect(try leftovers(fixture).isEmpty && model.assets.count == 3 && !model.isMergingHDR)
            // A granted folder that does not hold the originals admits nothing either.
            let elsewhere = fixture.root.appendingPathComponent("Elsewhere")
            try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: false)
            try harness.automation.folders.grant(elsewhere)
            let outside = await invoke("catalog.hdr.merge", ["deghost": false])
            #expect(outside["isError"] as? Bool == true && text(outside).contains("outside every folder granted to automation"), "\(text(outside))")
            #expect(try leftovers(fixture).isEmpty && model.assets.count == 3)

            try harness.automation.folders.grant(fixture.root.appendingPathComponent("Photos"))
            let merged = await invoke("catalog.hdr.merge", ["deghost": false])
            #expect(merged["isError"] as? Bool == false, "\(text(merged))")
            #expect(LensWorksCommandDispatcher.lastInvocation?.id == .mergeHDR && LensWorksCommandDispatcher.lastOrigin == .agent)
            #expect(try fixture.hashes() == before && model.assets.count == 4 && !model.isMergingHDR)
            let written = try leftovers(fixture)
            #expect(written.count == 1 && written[0].hasSuffix("-HDR.dng"), "\(written)")
            let photo = try #require(model.selectedAsset)
            #expect(photo.filename == written.first && !sources.contains { $0.id == photo.id })
            let original = try await model.service.originalLocation(try #require(photo.key)).localFileURL()
            #expect(try !LWDNGInspection(Data(contentsOf: original)).provenance().deghost)

            // The agent follows the link: the three sources become the selection.
            let followed = await invoke("catalog.hdr.selectSources", ["photo": photo.id])
            #expect(followed["isError"] as? Bool == false && model.selection == Set(sources.map(\.id)), "\(text(followed))")
            #expect(LensWorksCommandDispatcher.lastInvocation?.id == .selectHDRSources && LensWorksCommandDispatcher.lastOrigin == .agent)
        }
    }

    /// The merged photo is identified by where its original is, not by its file name, and the
    /// user's browse scope is left as it was even when the merged photo is outside it.
    @Test func aSameNamedPhotoInAnotherCatalogedFolderIsNotMistakenForTheMerge() async throws {
        try await withBracketCatalog { model, fixture, sources, _ in
            // The name the merge will take already exists, cataloged, in another folder.
            let name = fixture.files[1].deletingPathExtension().lastPathComponent + "-HDR.dng"
            let other = fixture.root.appendingPathComponent("Other")
            try FileManager.default.createDirectory(at: other, withIntermediateDirectories: false)
            let small = try LWHDRMerger.merge([try HDRSyntheticBracket.frame(stops: 0), try HDRSyntheticBracket.frame(stops: 2)])
            let record = LWHDRMergeProvenance(documentID: UUID().uuidString, deghost: true, referenceIndex: small.referenceIndex, baselineExposure: 0, sources: [
                .init(catalogImageID: "elsewhere", assetID: "elsewhere", variantID: "master", fileName: "elsewhere.png", sha256: "", relativeExposureEV: 0, offset: LWHDROffset(x: 0, y: 0), profile: nil)])
            let decoyFile = other.appendingPathComponent(name)
            try LWHDRDNGWriter.encode(small, provenance: record).write(to: decoyFile)
            try await model.startImport(other.path); try await model.waitImport(terminal: true)
            #expect(model.assets.count == 4)
            let decoy = try #require(model.assets.first { $0.filename == name })
            await selectAll(model, sources)
            #expect(model.selectionCount == 3)
            // The user is looking at the other folder, where only the same-named photo shows.
            let folder = try await model.folder(at: other.path)
            try await model.browse(folder: folder, recursive: true)
            #expect(model.assets.map(\.id) == [decoy.id] && model.selectionCount == 3 && model.hdrMergeAvailability() == nil)

            let outcome = try await model.mergeSelectionToHDR()
            #expect(outcome.dng.lastPathComponent == name && outcome.dng.deletingLastPathComponent().lastPathComponent == "Photos")
            #expect(outcome.asset.id != decoy.id && !sources.contains { $0.id == outcome.asset.id })
            let admitted = try await model.service.originalLocation(try #require(outcome.asset.key)).localFileURL()
            #expect(admitted.resolvingSymlinksInPath().path == outcome.dng.resolvingSymlinksInPath().path)
            // The browse scope, search text and visible page are the user's own.
            #expect(model.activeFolder?.id.value == folder.id.value && model.searchText.isEmpty && model.browseOptions.text == nil)
            #expect(model.assets.map(\.id) == [decoy.id])
            // The merged photo is the selected photo all the same, and it is what opens.
            #expect(model.selectedAsset?.id == outcome.asset.id && model.selectionCount == 1)
            // Each same-named photo resolves by its own location.
            #expect(try await model.recentCatalogRow(original: decoyFile)?.image_id == decoy.id)
            #expect(try await model.recentCatalogRow(original: outcome.dng)?.image_id == outcome.asset.id)
            #expect(try await model.recentCatalogRow(original: other.appendingPathComponent("absent-HDR.dng")) == nil)
            #expect(try await model.hdrMergeSources(of: outcome.asset).count == 3)
            // The decoy keeps its own link, rebuilt from its own record: one source this catalog never had.
            #expect(try await model.hdrMergeSources(of: decoy) == [LensWorksDerivedSource(imageID: "elsewhere", assetID: "elsewhere", variantID: "master", filename: "elsewhere.png", missing: true)])
            let output = fixture.root.appendingPathComponent("Versions")
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: false)
            await model.setOutput(output.path)
            let workspace = ProjectWorkspace()
            await model.createWorkingVersion(workspace: workspace)
            #expect(model.error == nil, "\(model.error ?? "")")
            #expect(workspace.current.controller.workingVersion?.photoID == outcome.asset.photoID)
            #expect(workspace.current.session.document?.size == CGSize(width: outcome.result.width, height: outcome.result.height))
        }
    }

    @Test func aCancelledOrFailedMergeLeavesNoFileAndNoCatalogItem() async throws {
        try await withBracketCatalog { model, fixture, sources, _ in
            let before = try fixture.hashes()
            await selectAll(model, sources)
            // The selection changes between the command and the merge reading it.
            try await model.index.setSelection(owner: model.selectionOwnerForCommands, rows: [LensWorksSelectedRow(imageID: sources[0].id, key: try #require(sources[0].key))], replace: true)
            do { _ = try await model.mergeSelectionToHDR(); Issue.record("A changed selection merged.") }
            catch { #expect(error.localizedDescription == "The selection changed while Merge to HDR was starting. Try again.") }
            #expect(!model.isMergingHDR && !model.isBusy)
            await selectAll(model, sources)
            #expect(model.selectionCount == 3)

            // The Cancel command while the merge is working.
            let running = Task { try await model.mergeSelectionToHDR() }
            while !model.isMergingHDR { await Task.yield() }
            #expect(model.hdrMergeCancelReason == nil && model.hdrMergeAvailability() == "A merge to HDR is already running.")
            model.cancelHDRMerge()
            await #expect(throws: CancellationError.self) { _ = try await running.value }
            #expect(!model.isMergingHDR && !model.isBusy && model.error == nil)
            #expect(model.status == "Merge to HDR canceled. Nothing was added to the catalog.")
            #expect(try leftovers(fixture).isEmpty)

            // A failure after the DNG is in place and before the catalog has it.
            var written: [URL] = []
            model.hdrMergeWrittenFixture = { url in
                written.append(url)
                #expect(FileManager.default.fileExists(atPath: url.path))
                throw LensWorksCatalogError.message("fixture failure after the write")
            }
            do { _ = try await model.mergeSelectionToHDR(); Issue.record("The fixture failure was swallowed.") }
            catch { #expect(error.localizedDescription == "fixture failure after the write") }
            #expect(written.count == 1)
            #expect(try leftovers(fixture).isEmpty)

            // The Cancel command at that same point.
            model.hdrMergeWrittenFixture = { url in written.append(url); model.cancelHDRMerge() }
            await #expect(throws: CancellationError.self) { _ = try await model.mergeSelectionToHDR() }
            #expect(written.count == 2)
            #expect(try leftovers(fixture).isEmpty)
            #expect(model.assets.count == 3 && !model.isImporting)
            #expect(try fixture.hashes() == before)

            // Nothing is left that stops the next merge.
            model.hdrMergeWrittenFixture = nil
            let outcome = try await model.mergeSelectionToHDR()
            #expect(model.assets.count == 4)
            #expect(try leftovers(fixture) == [outcome.dng.lastPathComponent])
        }
    }

    /// The catalog index is rebuildable: without it, a merged photo's link comes back from the
    /// record in its own DNG, matched to the catalog by asset ID and the sources' bytes.
    @Test func theLinkIsRebuiltFromTheMergedFileWhenTheCatalogIndexIsDeleted() async throws {
        try await withBracketCatalog { model, fixture, sources, defaults in
            await selectAll(model, sources)
            let outcome = try await model.mergeSelectionToHDR()
            let recorded = try await model.hdrMergeSources(of: outcome.asset)
            #expect(recorded.count == 3 && recorded.allSatisfy { !$0.missing })
            let catalog = try #require(model.catalogPath), indexFile = fixture.root.appendingPathComponent("Index.sqlite3")
            try await model.close()
            for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: indexFile.path + suffix) }
            #expect(!FileManager.default.fileExists(atPath: indexFile.path))

            let (reopened, _) = try catalogModel(fixture, defaults: defaults)
            await reopened.connect(catalog)
            do {
                if let error = reopened.error { throw LensWorksCatalogError.message(error) }
                #expect(reopened.assets.count == 4)
                let merged = try #require(reopened.assets.first { $0.filename == outcome.dng.lastPathComponent })
                let fresh = LensWorksCatalogIndex(url: indexFile)
                #expect(try await fresh.sources(catalog: catalog, image: merged.id).isEmpty, "the new index starts without the link")
                let rebuilt = try await reopened.hdrMergeSources(of: merged)
                #expect(rebuilt == recorded)
                // It is stored again, so the file is read once.
                #expect(try await fresh.sources(catalog: catalog, image: merged.id) == recorded)
                // A photo that is not a LensWorks merge has no link, DNG or not.
                let plain = try #require(reopened.assets.first { $0.id == sources[0].id })
                #expect(try await reopened.hdrMergeSources(of: plain).isEmpty)
                try await reopened.selectHDRMergeSources(of: merged)
                #expect(reopened.selectionCount == 3 && reopened.selection == Set(sources.map(\.id)))
                try await reopened.close()
            } catch { try? await reopened.close(); throw error }
        }
    }

    /// A rebuilt link keeps every source the file names. One that is no longer in the catalog,
    /// or whose original no longer has the recorded bytes, is kept as missing under its file name.
    @Test func aRebuiltLinkKeepsSourcesThatAreNoLongerInTheCatalogAsMissing() async throws {
        try await withBracketCatalog { model, fixture, sources, _ in
            // A merged DNG whose record names: a source still in the catalog with its bytes; a
            // source in the catalog whose bytes have changed since; a source the catalog does not have.
            let photos = fixture.root.appendingPathComponent("Photos")
            func recorded(_ asset: LensWorksCatalogAsset, hash: String?) async throws -> LWHDRMergeProvenance.Source {
                let key = try #require(asset.key), file = try await model.service.originalLocation(key).localFileURL()
                return .init(catalogImageID: asset.id, assetID: key.asset_id, variantID: key.variant_id, fileName: file.lastPathComponent,
                    sha256: try hash ?? LensWorksCatalog.sha256(file), relativeExposureEV: 0, offset: LWHDROffset(x: 0, y: 0), profile: nil)
            }
            let record = LWHDRMergeProvenance(documentID: UUID().uuidString, deghost: true, referenceIndex: 0, baselineExposure: 0, sources: [
                try await recorded(sources[0], hash: nil),
                try await recorded(sources[1], hash: String(repeating: "0", count: 64)),
                .init(catalogImageID: "removed-image", assetID: "removed-asset", variantID: "master", fileName: "removed-from-catalog.png", sha256: String(repeating: "1", count: 64), relativeExposureEV: 1, offset: LWHDROffset(x: 0, y: 0), profile: nil)])
            let small = try LWHDRMerger.merge([try HDRSyntheticBracket.frame(stops: 0), try HDRSyntheticBracket.frame(stops: 2)])
            let file = photos.appendingPathComponent("merged-elsewhere-HDR.dng")
            try LWHDRDNGWriter.write(small, provenance: record, to: file)
            let asset = try await model.importOriginal(file)
            #expect(model.assets.count == 4)

            let link = try await model.hdrMergeSources(of: asset)
            let first = try #require(sources[0].key), second = try #require(sources[1].key)
            #expect(link == [
                LensWorksDerivedSource(imageID: sources[0].id, assetID: first.asset_id, variantID: first.variant_id, filename: sources[0].filename),
                LensWorksDerivedSource(imageID: sources[1].id, assetID: second.asset_id, variantID: second.variant_id, filename: sources[1].filename, missing: true),
                LensWorksDerivedSource(imageID: "removed-image", assetID: "removed-asset", variantID: "master", filename: "removed-from-catalog.png", missing: true)])
            // Stored with the missing marks, and read back the same.
            #expect(try await model.index.sources(catalog: try #require(model.catalogPath), image: asset.id) == link)
            #expect(try await model.hdrMergeSources(of: asset) == link)
            // Following the link selects only the source that is still there, and says so.
            try await model.selectHDRMergeSources(of: asset)
            #expect(model.selectionCount == 1 && model.selection == [sources[0].id])
            #expect(model.status == "Selected 1 of the 3 source photos of merged-elsewhere-HDR.dng; the others are no longer in this catalog.")
        }
    }

    /// An index written before sources could be recorded as missing is upgraded in place.
    @Test func anIndexWithoutTheMissingColumnGainsItAndKeepsItsLinks() async throws {
        let physical = try #require(realpath(FileManager.default.temporaryDirectory.path, nil)); defer { free(physical) }
        let folder = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("LWHDR-index-\(UUID())")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); defer { try? FileManager.default.removeItem(at: folder) }
        let file = folder.appendingPathComponent("Index.sqlite3")
        var database: OpaquePointer?
        #expect(sqlite3_open(file.path, &database) == SQLITE_OK)
        #expect(sqlite3_exec(database, "PRAGMA application_id=1280792146; CREATE TABLE derived_sources(catalog TEXT NOT NULL,image TEXT NOT NULL,position INTEGER NOT NULL,source_image TEXT NOT NULL,source_asset TEXT NOT NULL,source_variant TEXT NOT NULL,source_name TEXT NOT NULL,PRIMARY KEY(catalog,image,position)); INSERT INTO derived_sources VALUES('/catalog','merged',0,'image-a','asset-a','master','a.png');", nil, nil, nil) == SQLITE_OK)
        sqlite3_close(database)
        let index = LensWorksCatalogIndex(url: file)
        let kept = LensWorksDerivedSource(imageID: "image-a", assetID: "asset-a", variantID: "master", filename: "a.png")
        #expect(try await index.sources(catalog: "/catalog", image: "merged") == [kept])
        let gone = LensWorksDerivedSource(imageID: "image-b", assetID: "asset-b", variantID: "master", filename: "b.png", missing: true)
        try await index.recordSources(catalog: "/catalog", image: "merged", sources: [kept, gone])
        #expect(try await index.sources(catalog: "/catalog", image: "merged") == [kept, gone])
    }
}
