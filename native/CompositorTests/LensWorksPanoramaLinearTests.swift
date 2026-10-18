import Foundation
import Testing
@testable import Compositor

@Suite(.serialized)
struct LensWorksPanoramaLinearTests {
    enum MatchingRegime: String, CaseIterable, Sendable { case superWhite, signed, lowContrast }
    private func frame(start: Int, width: Int = 160, height: Int = 120, regime: MatchingRegime? = nil, noiseSeed: UInt32? = nil, hotPixel: Bool = false) throws -> LWFloatPlane {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            let tile = try LWLinearSurface.admitted(width: range.width, height: range.height,
                maximumBytes: range.width * range.height * 16, workingSet: workspace.workingSet) { index in
                let x = start + range.x + index % range.width, y = range.y + index / range.width
                // Real working latitude, not values that fit in an 8-bit display surface.
                let value = SIMD4<Float>(Float((x * 17 + y * 13 + x * y % 71) & 255) / 80,
                             Float((x * 29 + y * 7 + (x * 3 + y * 11) % 89) & 255) / 255,
                             Float((x * 5 + y * 31 + (x + y * 19) % 97) & 255) / 255 - 0.25, 1)
                var result = value
                if let regime {
                    switch regime {
                    case .superWhite: result = SIMD4(2 + value.x / 8, 2 + value.y / 8, 2 + value.z / 8, 1)
                    case .signed: result = SIMD4(-2 + value.x / 8, -2 + value.y / 8, -2 + value.z / 8, 1)
                    case .lowContrast: result = SIMD4(0.5 + value.x * 0.000001, 0.5 + value.y * 0.000001, 0.5 + value.z * 0.000001, 1)
                    }
                }
                if let noiseSeed {
                    for channel in 0..<3 {
                        var hash = UInt32(x) &* 0x9e3779b1 ^ UInt32(y) &* 0x85ebca6b ^ noiseSeed ^ UInt32(channel) &* 0xc2b2ae35
                        hash ^= hash >> 16; hash &*= 0x7feb352d; hash ^= hash >> 15
                        result[channel] += (Float(hash & 1023) / 1023 - 0.5) * 0.00001
                    }
                }
                if hotPixel, x - start == width - 1, y == height - 4 { result = SIMD4(65536, 65536, 65536, 1) }
                return result
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

    @Test(arguments: MatchingRegime.allCases, LensWorksPanoramaProjection.allCases)
    func translatedExtendedAndLowContrastSourcesMatchBeforeEveryProjection(_ regime: MatchingRegime, _ projection: LensWorksPanoramaProjection) throws {
        let planes = try [frame(start: 0, regime: regime), frame(start: 112, regime: regime), frame(start: 224, regime: regime)]
        let matchingRange = try LensWorksPanoramaStitcher.Raster.MatchingRange.measure(Array(planes.prefix(2)))
        let descriptor = try LensWorksPanoramaStitcher.Raster(plane: planes[0], matchingRange: matchingRange)
        for channel in 0..<3 {
            #expect(Set(stride(from: channel, to: descriptor.rgba.count, by: 4).map { descriptor.rgba[$0] }).count > 1,
                "Matching retains texture that a clipped display descriptor erased")
        }
        let aligned = try LensWorksPanoramaLinear.align(planes)
        #expect(aligned.alignments.allSatisfy { $0.horizontalOffset == 112 && $0.verticalOffset == 0 && $0.meanSeamError == 0 })
        let result = try LensWorksPanoramaLinear.render(planes, projection: projection, boundary: .autoCrop)
        #expect(result.width == 384 && result.height > 90)
        let pixels = try result.read(result.globalExtent).surface.pixels
        #expect(pixels.allSatisfy { $0.w == 1 })
        if projection == .perspective {
            let expected = try frame(start: 0, width: 384, regime: regime)
            #expect(Array(pixels) == Array(try expected.read(expected.globalExtent).surface.pixels))
        }
    }

    @Test(arguments: [0, 2], LensWorksPanoramaProjection.allCases)
    func noisyTextureIsNotErasedByAnExtremeOutlierInThisOrAnotherPair(_ outlierSource: Int, _ projection: LensWorksPanoramaProjection) throws {
        let planes = try (0..<3).map { index in
            try frame(start: index * 112, regime: .superWhite, noiseSeed: UInt32(index + 1), hotPixel: index == outlierSource)
        }
        let result = try LensWorksPanoramaLinear.align(planes)
        #expect(result.alignments.count == 2)
        #expect(result.alignments.allSatisfy { $0.horizontalOffset == 112 && $0.verticalOffset == 0 && $0.meanSeamError <= LensWorksPanoramaStitcher.declaredSeamErrorTolerance })
        #expect(result.work.featurePixels <= 2 * 160 * 120 && result.work.peakFeatureVotes <= 8192)
        let rendered = try LensWorksPanoramaLinear.render(planes, projection: projection, boundary: .autoCrop)
        #expect(rendered.width == 384 && rendered.height > 90)
    }

    @Test func ambiguousPartialConstantChannelsCannotSuppressRealFloatDifferences() throws {
        let range = LensWorksPanoramaStitcher.Raster.MatchingRange(low: SIMD3(0, 0, 0), high: SIMD3(0, 1, 0))
        #expect(range.difference(0, 2, channel: 0) > 0)
        func source(_ start: Int) throws -> LWFloatPlane {
            let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
            let builder = try workspace.makeBuilder(width: 160, height: 120)
            while let tileRange = builder.nextRange {
                let tile = try LWLinearSurface.admitted(width: tileRange.width, height: tileRange.height,
                    maximumBytes: tileRange.width * tileRange.height * 16, workingSet: workspace.workingSet) { index in
                    let x = start + tileRange.x + index % tileRange.width, y = tileRange.y + index / tileRange.width
                    // Horizontal detail lies outside both fixed matching grids and below the
                    // percentile population. The remaining vertical gradient cannot prove dx.
                    let marker: Float = y == 3 && [130, 139, 148].contains(x) ? Float(x) : 0
                    return SIMD4(marker, Float(y) / 119, 0, 1)
                }
                try builder.append(tile, at: tileRange)
            }
            return try builder.finish()
        }
        let planes = try [source(0), source(112)]
        #expect(throws: (any Error).self) { _ = try LensWorksPanoramaLinear.align(planes) }
    }

    @Test func genuinelyConstantFloatSourcesCannotClaimAnAlignment() throws {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let builder = try workspace.makeBuilder(width: 160, height: 120)
        while let range = builder.nextRange {
            let tile = try LWLinearSurface.admitted(width: range.width, height: range.height,
                maximumBytes: range.width * range.height * 16, workingSet: workspace.workingSet) { _ in SIMD4(2, 2, 2, 1) }
            try builder.append(tile, at: range)
        }
        let plane = try builder.finish()
        #expect(throws: (any Error).self) { _ = try LensWorksPanoramaLinear.align([plane, plane]) }
    }

    @Test func reducedDescriptorsRefineTranslatedAllSuperWhiteSources() throws {
        let planes = try [frame(start: 0, width: 1601, regime: .superWhite), frame(start: 1121, width: 1601, regime: .superWhite)]
        let result = try LensWorksPanoramaLinear.align(planes)
        #expect(result.alignments.count == 1 && result.alignments[0].horizontalOffset == 1121 && result.alignments[0].verticalOffset == 0)
        #expect(result.alignments[0].meanSeamError == 0)
    }

    @_optimize(speed) private func noisyExtendedFrame(start: Int, top: Int, exposure: Float, seed: UInt32) throws -> LWFloatPlane {
        let width = 6000, height = 4000
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            let tile = try LWLinearSurface.admitted(width: range.width, height: range.height,
                maximumBytes: range.width * range.height * 16, workingSet: workspace.workingSet) { index in
                let x = start + range.x + index % range.width, y = top + range.y + index / range.width
                let values = (((x / 31 * 17 + y / 29 * 13 + x * y / 70123) & 255),
                              ((x / 23 * 11 + y / 37 * 19 + x * y / 45123) & 255),
                              ((x / 43 * 29 + y / 19 * 7 + x * y / 97123) & 255))
                var pixel = SIMD4<Float>(repeating: 1)
                for channel in 0..<3 {
                    var hash = UInt32(x) &* 0x9e3779b1 ^ UInt32(y) &* 0x85ebca6b ^ seed ^ UInt32(channel) &* 0xc2b2ae35
                    hash ^= hash >> 16; hash &*= 0x7feb352d; hash ^= hash >> 15
                    let noise = (Float(hash & 1023) / 1023 - 0.5) * 0.0005
                    let value = channel == 0 ? values.0 : channel == 1 ? values.1 : values.2
                    pixel[channel] = (2 + Float(value) / 128) * exposure + noise
                }
                return pixel
            }
            try builder.append(tile, at: range)
        }
        return try builder.finish()
    }

    @Test func cameraSizedNoisyHDRAndExposureMatchingUsesOnlyBoundedProductionWork() throws {
        let left = try noisyExtendedFrame(start: 0, top: 0, exposure: 1, seed: 17)
        let right = try noisyExtendedFrame(start: 4201, top: 17, exposure: 1.002, seed: 91)
        // Calls the matching phase render actually uses, on tiled Float planes, not the RGBA8 fixture path.
        let result = try LensWorksPanoramaLinear.align([left, right])
        #expect(result.alignments.count == 1)
        #expect(result.alignments[0].horizontalOffset == 4201 && result.alignments[0].verticalOffset == 17)
        #expect(result.alignments[0].meanSeamError > 0 && result.alignments[0].meanSeamError <= LensWorksPanoramaStitcher.declaredSeamErrorTolerance)
        #expect(result.work.coarseComparisons < 30_000_000)
        #expect(result.work.refinementSamples < 2_000_000)
        #expect(result.work.featurePixels == 6000 * 4000, "The noisy, exposure-varying match really exercised the single linear fallback scan")
        #expect(result.work.peakFeatureVotes <= 8192)
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
        try LWLinearDNGWriter.writeDNG(plane, to: url)
        let original = try Data(contentsOf: url)
        // The DNG's strip payload is scene-linear RGB float32, not RGBA8 with a RAW extension.
        let payloadBytes = plane.width * plane.height * 12, begin = original.count - payloadBytes
        let reference = try plane.read(plane.globalExtent).surface.pixels
        original.withUnsafeBytes { bytes in
            for (index, value) in reference.enumerated() { for channel in 0..<3 {
                #expect(bytes.loadUnaligned(fromByteOffset: begin + index * 12 + channel * 4, as: UInt32.self).littleEndian == value[channel].bitPattern)
            } }
        }
        #expect(throws: (any Error).self) { try LWLinearDNGWriter.writeDNG(plane, to: url) }
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
        #expect(throws: (any Error).self) { _ = try LWLinearMediaDestination(output: root, subdirectory: "Panoramas") }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        try FileManager.default.removeItem(at: media)
        let admitted = try LWLinearMediaDestination(output: root, subdirectory: "Panoramas")
        try FileManager.default.moveItem(at: media, to: root.appendingPathComponent("AdmittedOriginal"))
        try FileManager.default.createSymbolicLink(at: media, withDestinationURL: outside)
        let plane = try frame(start: 0)
        #expect(throws: (any Error).self) { try LWLinearDNGWriter.writeDNG(plane, to: admitted.directory.appendingPathComponent("refused.dng"), destination: admitted) }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("AdmittedOriginal").path).isEmpty)
    }

    @Test func cancellationCleanupDeletesOnlyItsUnchangedPublishedFile() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try LWLinearMediaDestination(output: root, subdirectory: "Panoramas")
        let plane = try frame(start: 0)
        let unchanged = destination.directory.appendingPathComponent("unchanged.dng")
        try LWLinearDNGWriter.writeDNG(plane, to: unchanged, destination: destination)
        try destination.removeUnimportedPublication(named: unchanged.lastPathComponent)
        #expect(!FileManager.default.fileExists(atPath: unchanged.path))
        let published = destination.directory.appendingPathComponent("published.dng")
        try LWLinearDNGWriter.writeDNG(plane, to: published, destination: destination)
        let original = try Data(contentsOf: published), moved = destination.directory.appendingPathComponent("retained.dng")
        try FileManager.default.moveItem(at: published, to: moved)
        let replacement = Data("Another file now owns this pathname".utf8)
        try replacement.write(to: published, options: .withoutOverwriting)
        #expect(throws: LWLinearMediaRecoveryError.self) { try destination.removeUnimportedPublication(named: published.lastPathComponent) }
        #expect(try Data(contentsOf: published) == replacement)
        #expect(try Data(contentsOf: moved) == original)
        let edited = destination.directory.appendingPathComponent("edited.dng")
        try LWLinearDNGWriter.writeDNG(plane, to: edited, destination: destination)
        let handle = try FileHandle(forWritingTo: edited)
        try handle.truncate(atOffset: 0); try handle.write(contentsOf: replacement); try handle.close()
        #expect(throws: LWLinearMediaRecoveryError.self) { try destination.removeUnimportedPublication(named: edited.lastPathComponent) }
        #expect(try Data(contentsOf: edited) == replacement, "In-place edits are no longer the operation's unchanged publication")
    }

    @Test func publicationRefusesAnAncestorChangedToALinkEvenToTheSameHeldDirectory() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let ancestor = root.appendingPathComponent("ancestor"), output = ancestor.appendingPathComponent("output")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try LWLinearMediaDestination(output: output, subdirectory: "Panoramas")
        let plane = try frame(start: 0)
        let publication = destination.directory.appendingPathComponent("held.dng")
        try LWLinearDNGWriter.writeDNG(plane, to: publication, destination: destination)
        let original = try Data(contentsOf: publication)
        let held = root.appendingPathComponent("original-ancestor")
        try FileManager.default.moveItem(at: ancestor, to: held)
        try FileManager.default.createSymbolicLink(at: ancestor, withDestinationURL: held)
        #expect(throws: (any Error).self) { try destination.validate() }
        do {
            try destination.validatePublication(named: publication.lastPathComponent)
            Issue.record("A changed ancestor retained publication authority")
        } catch let recovery as LWLinearMediaRecoveryError {
            #expect(recovery.recoveryPaths.contains { $0.path.contains("/original-ancestor/") && $0.lastPathComponent == "held.dng" })
        }
        #expect(throws: (any Error).self) {
            try LWLinearDNGWriter.writeDNG(plane, to: destination.directory.appendingPathComponent("refused.dng"), destination: destination)
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: held.appendingPathComponent("output/Panoramas").path) == ["held.dng"])
        #expect(try Data(contentsOf: held.appendingPathComponent("output/Panoramas/held.dng")) == original)
        #expect(throws: (any Error).self) { _ = try LWLinearMediaDestination(output: output, subdirectory: "Panoramas") }
    }

    @Test func exactPublicationValidationReportsHeldOriginalAndReplacementPaths() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        defer { try? FileManager.default.removeItem(at: root) }
        let destination = try LWLinearMediaDestination(output: root, subdirectory: "Panoramas")
        let published = destination.directory.appendingPathComponent("published.dng"), original = root.appendingPathComponent("held-original.dng")
        try LWLinearDNGWriter.writeDNG(frame(start: 0), to: published, destination: destination)
        try destination.validatePublication(named: published.lastPathComponent)
        try FileManager.default.moveItem(at: published, to: original)
        let replacement = Data("A replacement must not become the generated panorama".utf8)
        try replacement.write(to: published, options: .withoutOverwriting)
        do {
            try destination.validatePublication(named: published.lastPathComponent)
            Issue.record("A replacement acquired publication authority")
        } catch let recovery as LWLinearMediaRecoveryError {
            #expect(recovery.recoveryPaths.contains { $0.lastPathComponent == "held-original.dng" })
            #expect(recovery.recoveryPaths.contains { $0.lastPathComponent == "published.dng" })
        }
        #expect(try Data(contentsOf: published) == replacement)
    }

    @Test func cancelledDNGPublicationLeavesNoPartialOriginal() async throws {
        let plane = try frame(start: 0)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".dng")
        defer { try? FileManager.default.removeItem(at: url) }
        let task = Task.detached {
            while !Task.isCancelled { await Task.yield() }
            try LWLinearDNGWriter.writeDNG(plane, to: url)
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
        try LWLinearDNGWriter.writeDNG(plane, to: url)
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
