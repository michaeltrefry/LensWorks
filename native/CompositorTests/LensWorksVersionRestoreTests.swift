import AppKit
import Testing
@testable import Compositor

@MainActor
struct LensWorksVersionRestoreTests {
    private func image(_ color: CGColor) throws -> ImportedImage {
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Layer")
    }

    @Test func undoAndCheckpointRestoreChangeTheCanvasAndRetainAssets() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(try image(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        let controller = ProjectController(session: session)
        controller.initializeLensWorksDocument(photoID: "p1", named: "A")
        let version = try #require(controller.selectedLensWorksVersionID)
        let first = session.document?.layers.count ?? 0

        try controller.captureLensWorksComposition(in: version)
        try controller.addLensWorksCheckpoint(named: "one", to: version)
        let checkpoint = try #require(controller.lensWorksDocument?.versions.first?.checkpoints.first?.id)
        session.insert(try image(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)))
        #expect(session.document?.layers.count == first + 1)
        try controller.captureLensWorksComposition(in: version)

        try controller.undoLensWorksVersion(version)
        #expect(session.document?.layers.count == first)
        try controller.redoLensWorksVersion(version)
        #expect(session.document?.layers.count == first + 1)
        try controller.restoreLensWorksCheckpoint(checkpoint, in: version)
        #expect(session.document?.layers.count == first)

        let reachable = try #require(controller.lensWorksDocument).reachableAssets
        #expect(!reachable.isEmpty && reachable.allSatisfy { controller.lensWorksDocumentAssets[$0] != nil })
    }
}
