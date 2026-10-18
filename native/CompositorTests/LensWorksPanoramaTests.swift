import Foundation
import Testing
@testable import Compositor

@Suite struct LensWorksPanoramaTests {
    private let width = 160, height = 120, overlap = 48

    private func frame(start: Int, verticalStart: Int = 0) -> LensWorksPanoramaStitcher.Raster {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let world = start + x, worldY = verticalStart + y, offset = (y * width + x) * 4
            // Non-periodic detail makes a false overlap observably worse than the declared shared world crop.
            rgba[offset] = UInt8((world * 17 + worldY * 13 + (world * worldY) % 71) & 255)
            rgba[offset + 1] = UInt8((world * 29 + worldY * 7 + (world * 3 + worldY * 11) % 89) & 255)
            rgba[offset + 2] = UInt8((world * 5 + worldY * 31 + (world + worldY * 19) % 97) & 255)
        } }
        return .init(width: width, height: height, rgba: rgba)
    }

    @Test(arguments: LensWorksPanoramaProjection.allCases)
    func stitchesGeneratedStyleThreeFrameSet(projection: LensWorksPanoramaProjection) throws {
        let step = width - overlap
        let result = try LensWorksPanoramaStitcher.stitch([frame(start: 0), frame(start: step), frame(start: step * 2)], projection: projection, boundary: .autoCrop)
        #expect(result.alignments.count == 2)
        #expect(result.alignments.allSatisfy { $0.horizontalOffset == step && $0.verticalOffset == 0 })
        #expect(result.alignments.allSatisfy { $0.meanSeamError <= LensWorksPanoramaStitcher.declaredSeamErrorTolerance })
        #expect(result.rgba.count == result.width * result.height * 4)
        #expect(stride(from: 3, to: result.rgba.count, by: 4).allSatisfy { result.rgba[$0] == 255 })
    }

    @Test(arguments: LensWorksPanoramaProjection.allCases)
    func alignsFramesCapturedRightToLeft(projection: LensWorksPanoramaProjection) throws {
        let step = width - overlap
        let result = try LensWorksPanoramaStitcher.stitch([frame(start: step * 2), frame(start: step), frame(start: 0)], projection: projection, boundary: .autoCrop)
        #expect(result.alignments.allSatisfy { $0.horizontalOffset == -step && $0.verticalOffset == 0 })
        #expect(result.alignments.allSatisfy { $0.meanSeamError <= LensWorksPanoramaStitcher.declaredSeamErrorTolerance })
    }

    @Test(arguments: LensWorksPanoramaBoundary.allCases)
    func boundaryHandlingLeavesAnOpaqueRectangle(boundary: LensWorksPanoramaBoundary) throws {
        let step = width - overlap
        let result = try LensWorksPanoramaStitcher.stitch([frame(start: 0), frame(start: step), frame(start: step * 2)], projection: .cylindrical, boundary: boundary)
        #expect(result.width > 0 && result.height > 0)
        // Auto-crop returns a fully covered rectangle; fill keeps its full projection bounds and repairs edges.
        #expect(stride(from: 3, to: result.rgba.count, by: 4).allSatisfy { result.rgba[$0] == 255 })
    }

    @Test func autoCropRemovesPartialBoundaryRowsInsteadOfFillingThem() throws {
        let step = width - overlap, verticalOffset = 8
        let frames = [frame(start: 0), frame(start: step, verticalStart: verticalOffset), frame(start: step * 2, verticalStart: verticalOffset)]
        let cropped = try LensWorksPanoramaStitcher.stitch(frames, projection: .perspective, boundary: .autoCrop)
        let filled = try LensWorksPanoramaStitcher.stitch(frames, projection: .perspective, boundary: .fillEdges)
        #expect(cropped.height < filled.height)
        #expect(cropped.height == height - verticalOffset)
        #expect(filled.height == height + verticalOffset)
        #expect(stride(from: 3, to: cropped.rgba.count, by: 4).allSatisfy { cropped.rgba[$0] == 255 })
        #expect(stride(from: 3, to: filled.rgba.count, by: 4).allSatisfy { filled.rgba[$0] == 255 })
    }

    @Test(arguments: LensWorksPanoramaProjection.allCases)
    func projectionKeepsMeaningfulDimensions(projection: LensWorksPanoramaProjection) throws {
        let step = width - overlap, world = step * 2 + width
        let result = try LensWorksPanoramaStitcher.stitch([frame(start: 0), frame(start: step), frame(start: step * 2)], projection: projection, boundary: .autoCrop)
        #expect(result.width >= world - 4 && result.height <= height && result.height > height * 3 / 4)
        var distinct = Set<UInt32>()
        for offset in stride(from: 0, to: result.rgba.count, by: 4) {
            let red = UInt32(result.rgba[offset]), green = UInt32(result.rgba[offset + 1]), blue = UInt32(result.rgba[offset + 2])
            distinct.insert(red << 16 | green << 8 | blue)
        }
        #expect(distinct.count > 1000)
    }

    @Test func perspectiveIsBitExactOutsideAndInsideOverlaps() throws {
        let step = width - overlap, worldWidth = step * 2 + width
        let result = try LensWorksPanoramaStitcher.stitch([frame(start: 0), frame(start: step), frame(start: step * 2)], projection: .perspective, boundary: .autoCrop)
        #expect(result.width == worldWidth && result.height == height)
        for y in 0..<height { for x in 0..<worldWidth {
            let world = x, offset = (y * worldWidth + x) * 4
            #expect(result.rgba[offset] == UInt8((world * 17 + y * 13 + (world * y) % 71) & 255))
            #expect(result.rgba[offset + 1] == UInt8((world * 29 + y * 7 + (world * 3 + y * 11) % 89) & 255))
            #expect(result.rgba[offset + 2] == UInt8((world * 5 + y * 31 + (world + y * 19) % 97) & 255))
        } }
    }

    @Test func curvedProjectionsWarpBothAxesAndCropActualUncoveredPixels() throws {
        let frames = [frame(start: 0), frame(start: 112), frame(start: 224)]
        let perspective = try LensWorksPanoramaStitcher.stitch(frames, projection: .perspective, boundary: .autoCrop)
        for projection in [LensWorksPanoramaProjection.cylindrical, .spherical] {
            let cropped = try LensWorksPanoramaStitcher.stitch(frames, projection: projection, boundary: .autoCrop)
            let filled = try LensWorksPanoramaStitcher.stitch(frames, projection: projection, boundary: .fillEdges)
            #expect(cropped.height < perspective.height && filled.height > cropped.height)
            #expect(stride(from: 3, to: cropped.rgba.count, by: 4).allSatisfy { cropped.rgba[$0] == 255 })
            #expect(stride(from: 3, to: filled.rgba.count, by: 4).allSatisfy { filled.rgba[$0] == 255 })
        }
    }

    @Test func cameraSizedMatchingHasABoundedComparisonBudgetAndRefinesToExactPixels() throws {
        let w = 6000, h = 4000, dx = 4201, dy = 17
        func large(_ start: Int, _ top: Int) -> LensWorksPanoramaStitcher.Raster {
            var bytes = [UInt8](repeating: 255, count: w * h * 4)
            for y in 0..<h { for x in 0..<w {
                let wx = x + start, wy = y + top, offset = (y * w + x) * 4
                // Smooth photographic-scale structure with distinct detail; the optimum is not
                // aligned to any pyramid grid and must be refined at the original resolution.
                bytes[offset] = UInt8((wx / 31 * 17 + wy / 29 * 13 + wx * wy / 70123) & 255)
                bytes[offset + 1] = UInt8((wx / 23 * 11 + wy / 37 * 19 + wx * wy / 45123) & 255)
                bytes[offset + 2] = UInt8((wx / 43 * 29 + wy / 19 * 7 + wx * wy / 97123) & 255)
            } }
            return .init(width: w, height: h, rgba: bytes)
        }
        let result = try LensWorksPanoramaStitcher.match(large(0, 0), large(dx, dy))
        #expect(result.dx == dx && result.dy == dy && result.error == 0)
        // Counts actual sampled RGB comparisons, not a machine-dependent timing benchmark.
        #expect(result.comparisons < 30_000_000)
    }

    @Test func narrowTallFramesDoNotReadOutsideReducedDescriptors() throws {
        let w = 17, h = 4096
        var bytes = [UInt8](repeating: 255, count: w * h * 4)
        for y in 0..<h { for x in 0..<w {
            let index = (y * w + x) * 4
            bytes[index] = UInt8((x * 19 + y * 17) & 255)
            bytes[index + 1] = UInt8((x * 11 + y * 37) & 255)
        } }
        let raster = LensWorksPanoramaStitcher.Raster(width: w, height: h, rgba: bytes)
        let match = try LensWorksPanoramaStitcher.match(raster, raster)
        #expect(match.dx == 0 && match.dy == 0 && match.error == 0)
    }

    @Test func cancellationInterruptsMatchingBeforePublication() async throws {
        let frames = [frame(start: 0), frame(start: 112)]
        let task = Task.detached {
            // Cancellation is already set when work enters the production matcher.
            while !Task.isCancelled { await Task.yield() }
            return try LensWorksPanoramaStitcher.stitch(frames, projection: .perspective, boundary: .autoCrop)
        }
        task.cancel()
        do { _ = try await task.value; Issue.record("Cancelled panorama completed") }
        catch is CancellationError { }
    }

    @Test func sourceLinksRoundTripWithEditableWorkingVersion() throws {
        let assets = (1...3).map { LensWorksCatalogAsset(sequence: Int64($0), id: "a\($0)", originalPath: "/Photos/\($0).png", state: "ready", previewPath: nil) }
        let sources = assets.map(LensWorksPanoramaSource.init)
        #expect(sources.map(\.photoID) == ["a1", "a2", "a3"])
        let version = LensWorksWorkingVersion(id: UUID(), photoID: "result", catalogPath: "/Catalog", originalPath: "/Photos/result.png", projectPath: "/Edits/result.comp", name: "Result", sourceLinks: sources)
        let decoded = try JSONDecoder().decode(LensWorksWorkingVersion.self, from: version.encoded())
        #expect((decoded.sourceLinks ?? []) == sources)
        #expect(decoded.photoID == "result")
    }
}
