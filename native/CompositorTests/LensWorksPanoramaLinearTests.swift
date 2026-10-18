import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
struct LensWorksPanoramaLinearTests {
    private func frame(start: Int, width: Int = 160, height: Int = 120) throws -> LWFloatPlane {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            let tile = try LWLinearSurface.admitted(width: range.width, height: range.height,
                maximumBytes: range.width * range.height * 16, workingSet: workspace.workingSet) { index in
                let x = start + range.x + index % range.width, y = range.y + index / range.width
                // Real working latitude, not values that fit in an 8-bit display surface.
                return SIMD4(Float((x * 17 + y * 13 + x * y % 71) & 255) / 80,
                             Float((x * 29 + y * 7 + (x * 3 + y * 11) % 89) & 255) / 255,
                             Float((x * 5 + y * 31 + (x + y * 19) % 97) & 255) / 255 - 0.25, 1)
            }
            try builder.append(tile, at: range)
        }
        return try builder.finish()
    }

    @Test func linearIdentityPreservesEverySampleIncludingHighlights() throws {
        let first = try frame(start: 0), second = try frame(start: 112), third = try frame(start: 224)
        let result = try LensWorksPanoramaLinear.render([first, second, third], projection: .perspective, boundary: .autoCrop)
        let expected = try frame(start: 0, width: 384)
        #expect(result.width == 384 && result.height == 120)
        let pixels = try result.read(result.globalExtent).surface.pixels
        let reference = try expected.read(expected.globalExtent).surface.pixels
        #expect(Array(pixels) == Array(reference))
        #expect(pixels.contains { $0.x > 3 })
        #expect(pixels.contains { $0.z < 0 })
    }

    @Test(arguments: LensWorksPanoramaProjection.allCases)
    func everyProductionProjectionKeepsOpaqueFloatLatitude(_ projection: LensWorksPanoramaProjection) throws {
        let planes = try [frame(start: 0), frame(start: 112), frame(start: 224)]
        for boundary in LensWorksPanoramaBoundary.allCases {
            let result = try LensWorksPanoramaLinear.render(planes, projection: projection, boundary: boundary)
            let pixels = try result.read(result.globalExtent).surface.pixels
            #expect(result.width == 384 && result.height > 90)
            #expect(pixels.allSatisfy { $0.w == 1 })
            #expect(pixels.contains { $0.x > 3 })
        }
    }

    @Test func boundedDescriptorsAndOriginalPixelRefinementRetainAliasedFineDetail() throws {
        let first = try frame(start: 0, width: 1601), second = try frame(start: 1121, width: 1601)
        let descriptor = try LensWorksPanoramaStitcher.Raster(plane: first)
        #expect(descriptor.width == 801 && descriptor.height == 60 && descriptor.sourceScale == 2)
        let result = try LensWorksPanoramaLinear.render([first, second], projection: .perspective, boundary: .autoCrop)
        let expected = try frame(start: 0, width: 2722)
        #expect(result.width == 2722 && result.height == 120)
        #expect(Array(try result.read(result.globalExtent).surface.pixels) == Array(try expected.read(expected.globalExtent).surface.pixels))
    }

    @Test func productionDescriptorsHandleNarrowTallSources() throws {
        let source = try frame(start: 0, width: 17, height: 4096)
        let descriptor = try LensWorksPanoramaStitcher.Raster(plane: source)
        #expect(descriptor.width == 5 && descriptor.height == 1024 && descriptor.sourceScale == 4)
        let result = try LensWorksPanoramaLinear.render([source, source], projection: .perspective, boundary: .autoCrop)
        #expect(result.width == source.width && result.height == source.height)
        #expect(Array(try result.read(result.globalExtent).surface.pixels) == Array(try source.read(source.globalExtent).surface.pixels))
    }

    @Test func floatDNGContainsOriginalBitsAcrossStripsAndNeverReplacesAnOriginal() throws {
        let plane = try frame(start: 0, width: 160, height: 260)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("panorama.dng")
        try LensWorksPanoramaLinear.writeDNG(plane, to: url)
        let original = try Data(contentsOf: url)
        // The DNG's strip payload is scene-linear RGB float32, not RGBA8 with a RAW extension.
        let payloadBytes = plane.width * plane.height * 12, begin = original.count - payloadBytes
        let reference = try plane.read(plane.globalExtent).surface.pixels
        original.withUnsafeBytes { bytes in
            for (index, value) in reference.enumerated() { for channel in 0..<3 {
                #expect(bytes.loadUnaligned(fromByteOffset: begin + index * 12 + channel * 4, as: UInt32.self).littleEndian == value[channel].bitPattern)
            } }
        }
        #expect(throws: (any Error).self) { try LensWorksPanoramaLinear.writeDNG(plane, to: url) }
        #expect(try Data(contentsOf: url) == original)
    }

    @Test func publicationRefusesLinkedAndReplacedMediaDirectories() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root); try? FileManager.default.removeItem(at: outside) }
        let media = root.appendingPathComponent("Panoramas")
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: outside)
        #expect(throws: (any Error).self) { _ = try LensWorksPanoramaDestination(output: root) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: media)
        let admitted = try LensWorksPanoramaDestination(output: root)
        try FileManager.default.moveItem(at: media, to: root.appendingPathComponent("AdmittedOriginal"))
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: outside)
        let plane = try frame(start: 0)
        #expect(throws: (any Error).self) { try LensWorksPanoramaLinear.writeDNG(plane, to: admitted.directory.appendingPathComponent("refused.dng"), destination: admitted) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("AdmittedOriginal").path).isEmpty)
    }

    @Test func cancelledDNGPublicationLeavesNoPartialOriginal() async throws {
        let plane = try frame(start: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            try LensWorksPanoramaLinear.writeDNG(plane, to: url)
        }
        task.cancel()
        do { try await task.value; Issue.record("Cancelled DNG writer completed") }
        catch is CancellationError { }
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }

    @Test @MainActor func publishedDNGActuallyOpensAndRedevelopsAsLiveRAW() async throws {
        let plane = try frame(start: 0, height: 260)
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("linear-panorama.dng")
        try LensWorksPanoramaLinear.writeDNG(plane, to: url)
        let session = EditorSession()
        await session.importImages([url])
        #expect(session.importError == nil)
        let layer = try #require(session.activeLayer)
        let source = try #require(layer.liveSource)
        let original = try #require(layer.asset?.linearPlane)
        #expect(source.rawHint && original.width == plane.width && original.height == plane.height)
        let before = try original.read(original.globalExtent).surface.pixels
        #expect(before.contains { $0.x > 1 }, "DNG development retained super-white scene latitude")
        #expect(before.contains { $0.z < 0 }, "DNG development retained signed wide-gamut working samples")
        let reference = try plane.read(plane.globalExtent).surface.pixels
        #expect(zip(before, reference).allSatisfy { a, b in
            abs(a.x - b.x) < 0.0005 && abs(a.y - b.y) < 0.0005 && abs(a.z - b.z) < 0.0005 && a.w == b.w
        }, "The declared linear-sRGB DNG color contract round-trips through the real native decoder")
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        #expect(edit.liveSource != nil)
        var settings = edit.settings; settings.cameraRaw.exposure = 0.5
        session.updateFilter(settings, preview: false)
        await session.commitFilter()
        #expect(session.brushError == nil && session.filterEdit == nil)
        #expect(session.activeLayer?.liveSource?.settings.exposure == 0.5)
        let developed = try #require(session.activeLayer?.asset?.linearPlane)
        let after = try developed.read(developed.globalExtent).surface.pixels
        #expect(Array(before) != Array(after))
        #expect(session.activeLayer?.liveSource?.id == source.id)
    }
}
