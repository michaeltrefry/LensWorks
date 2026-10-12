import Foundation
import Testing
import CryptoKit
import CoreGraphics
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
        try FileManager.default.createDirectory(at: generated, withIntermediateDirectories: true)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["python3", repository.appendingPathComponent("scripts/generate_s47_procedural_photos.py").path, "--output", generated.path, "--seed", String(seed)]
        try process.run(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw LensWorksCatalogError.message("S47 generator exited \(process.terminationStatus)") }
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
        let (_, plane) = try await LWSourceDeveloper.shared.createPlane(original: try LWCatalogNativePath(fileURL: url), rawHint: RawImporter.matches(url))
        return try LWHDRFrame(width: plane.width, height: plane.height, pixels: Array(try plane.read(plane.globalExtent).surface.pixels))
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
        let result = try LWHDRMerger.merge(frames)
        #expect(result.referenceIndex == 1)
        #expect(result.offsets.allSatisfy { $0 == LWHDROffset(x: 0, y: 0) }, "\(result.offsets)")
        #expect(result.exposures[0] < 1 && result.exposures[2] > 1, "\(result.exposures)")
        #expect(result.maskedPixels[1] == 0 && result.maskedPixels[0] > 0 && result.maskedPixels[2] > 0)

        // The reference subject's red channel is clipped in the +1 EV frame yet recovered in the merge.
        let width = result.width, bounds = fixture.frames[1].subject_bounds
        let center = (bounds[1] + bounds[3]) / 2 * width + (bounds[0] + bounds[2]) / 2
        let brightClip = LWHDRMerger.clipLevel(frames[2])
        #expect(max(frames[2].pixels[center].x, frames[2].pixels[center].y, frames[2].pixels[center].z) >= brightClip)
        #expect(abs(result.radiance[center].x - frames[1].pixels[center].x) / frames[1].pixels[center].x < 0.02)
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
        let provenance = LWHDRMergeProvenance(documentID: UUID().uuidString, catalogPath: nil, deghost: true, referenceIndex: result.referenceIndex,
            baselineExposure: Double(-log2(scale)), sources: fixture.files.indices.map { i in
                .init(catalogImageID: "image-\(i)", assetID: "asset-\(i)", variantID: "master", filePath: fixture.files[i].path,
                      sha256: fixture.frames[i].sha256, relativeExposureEV: log2(result.exposures[i]), offset: result.offsets[i], profile: nil) })
        let dng = fixture.root.appendingPathComponent("merged.dng")
        try LWHDRDNGWriter.encode(result, provenance: provenance, reference: ["tiff:Make": "S47 & <Co>"]).write(to: dng)
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

/// AC1 and AC3 through the real catalog: one new linked catalog item, unchanged sources,
/// and an editor document with live RAW development that accepts layers.
@Suite(.serialized)
@MainActor
struct HDRMergeCatalogTests {
    @Test func mergeCreatesOneLinkedFloatDNGCatalogItemThatOpensWithRawControlsAndLayers() async throws {
        let fixture = try HDRBracketFixture.make(); defer { try? FileManager.default.removeItem(at: fixture.root) }
        let photos = fixture.root.appendingPathComponent("Photos")
        let worker = try #require(ProcessInfo.processInfo.environment["LW_CATALOG_TEST_WORKER"], "Explicit retained fixture helper is required.")
        let decode = ProcessInfo.processInfo.environment["LW_CATALOG_TEST_DECODE_WORKER"] ?? worker
        let config = LWManagedSessionConfig(worker_executable: try LWCatalogNativePath(fileURL: URL(fileURLWithPath: worker)), decode_worker_executable: try LWCatalogNativePath(fileURL: URL(fileURLWithPath: decode)),
            cache_root: try LWCatalogNativePath(fileURL: fixture.root.appendingPathComponent("Cache")), original_roots: [try LWCatalogNativePath(fileURL: photos)],
            limits: LWApplicationLimits(queued: 128, request_bytes: 1048576, reply_bytes: 1048576, page_rows: 100, scan_rows: 512, page_bytes: 131072, tickets: 128, ttl_seconds: 60, binary_bytes: 16777216), preview_policy: nil, preview_limits: nil)
        let defaults = try #require(UserDefaults(suiteName: "LWHDR-\(UUID())"))
        let model = LensWorksCatalog(configuration: config, index: LensWorksCatalogIndex(url: fixture.root.appendingPathComponent("Index.sqlite3")), defaults: defaults, migrateLegacy: false)
        await model.connect(fixture.root.appendingPathComponent("Catalog").path, create: true)
        do {
            if let error = model.error { throw LensWorksCatalogError.message(error) }
            let before = try fixture.hashes()
            try await model.startImport(photos.path); try await model.waitImport(terminal: true)
            #expect(model.assets.count == 3)
            let sources = model.assets
            await model.select(sources[0])
            #expect(model.hdrMergeAvailability() == "Select two or more bracketed photos.")
            for row in sources.dropFirst() { await model.select(row, extending: true) }
            #expect(model.selectionCount == 3 && model.hdrMergeAvailability() == nil)

            let outcome = try await model.mergeSelectionToHDR(deghost: true)
            #expect(model.error == nil, "\(model.error ?? "")")
            #expect(try fixture.hashes() == before)
            try await model.browse(text: nil)
            #expect(model.assets.count == 4)
            let merged = try #require(model.assets.first { $0.filename == outcome.dng.lastPathComponent })
            #expect(!sources.contains { $0.id == merged.id })
            #expect(model.selectedAsset?.id == merged.id)

            // The catalog item's own original is a linear float DNG carrying the link to all three sources.
            let original = try await model.service.originalLocation(try #require(merged.key)).localFileURL()
            let inspection = try LWDNGInspection(Data(contentsOf: original))
            #expect(inspection.tags[262] == [34892] && inspection.tags[339] == [3, 3, 3] && inspection.tags[258] == [32, 32, 32])
            let link = try inspection.provenance()
            #expect(Set(link.sources.map(\.catalogImageID)) == Set(sources.map(\.id)))
            #expect(Set(link.sources.map(\.assetID)) == Set(sources.compactMap { $0.key?.asset_id }))
            for source in link.sources {
                let row = try #require(sources.first { $0.id == source.catalogImageID })
                let file = try await model.service.originalLocation(try #require(row.key)).localFileURL()
                let hash = try LensWorksCatalog.sha256(file)
                #expect(source.filePath == file.path && source.sha256 == hash)
            }
            #expect(link.deghost && link == outcome.provenance)

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
            try await model.close()
        } catch {
            try? await model.close()
            throw error
        }
    }
}
