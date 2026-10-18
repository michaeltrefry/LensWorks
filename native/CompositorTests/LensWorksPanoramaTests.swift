import Foundation
import Testing
@testable import Compositor

@Suite struct LensWorksPanoramaTests {
    private let width = 160, height = 120, overlap = 48

    private func frame(start: Int) -> LensWorksPanoramaStitcher.Raster {
        var rgba = [UInt8](repeating: 255, count: width * height * 4)
        for y in 0..<height { for x in 0..<width {
            let world = start + x, offset = (y * width + x) * 4
            // Non-periodic detail makes a false overlap observably worse than the declared shared world crop.
            rgba[offset] = UInt8((world * 17 + y * 13 + (world * y) % 71) & 255)
            rgba[offset + 1] = UInt8((world * 29 + y * 7 + (world * 3 + y * 11) % 89) & 255)
            rgba[offset + 2] = UInt8((world * 5 + y * 31 + (world + y * 19) % 97) & 255)
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

    @Test(arguments: LensWorksPanoramaBoundary.allCases)
    func boundaryHandlingLeavesAnOpaqueRectangle(boundary: LensWorksPanoramaBoundary) throws {
        let step = width - overlap
        let result = try LensWorksPanoramaStitcher.stitch([frame(start: 0), frame(start: step), frame(start: step * 2)], projection: .cylindrical, boundary: boundary)
        #expect(result.width > 0 && result.height > 0)
        // Auto-crop removes transparent boundary columns before the final edge repair; fill keeps its full projection bounds.
        #expect(stride(from: 3, to: result.rgba.count, by: 4).allSatisfy { result.rgba[$0] == 255 })
    }

    @Test func fillEdgesRetainsProjectionBoundsThatAutoCropRemoves() throws {
        let step = width - overlap, frames = [frame(start: 0), frame(start: step), frame(start: step * 2)]
        let cropped = try LensWorksPanoramaStitcher.stitch(frames, projection: .spherical, boundary: .autoCrop)
        let filled = try LensWorksPanoramaStitcher.stitch(frames, projection: .spherical, boundary: .fillEdges)
        #expect(filled.width > cropped.width)
        #expect(stride(from: 3, to: cropped.rgba.count, by: 4).allSatisfy { cropped.rgba[$0] == 255 })
        #expect(stride(from: 3, to: filled.rgba.count, by: 4).allSatisfy { filled.rgba[$0] == 255 })
    }

    @Test func sourceLinksRoundTripWithEditableWorkingVersion() throws {
        let source = LensWorksPanoramaSource(photoID: "one", variantID: "master", originalPath: "/Photos/one.png", nativeOriginal: nil)
        let version = LensWorksWorkingVersion(id: UUID(), photoID: "result", catalogPath: "/Catalog", originalPath: "/Photos/result.png", projectPath: "/Edits/result.comp", name: "Result", sourceLinks: [source])
        let decoded = try JSONDecoder().decode(LensWorksWorkingVersion.self, from: version.encoded())
        #expect((decoded.sourceLinks ?? []) == [source])
        #expect(decoded.photoID == "result")
    }
}
