import AppKit
import Foundation
import Testing
@testable import Compositor

/// A pixel edit replaces a layer's pixels and nothing else about it: the layer's effects (a stroke, a drop shadow)
/// stay on it, and one Undo puts the pixels back. Each edit here rebuilds the layer from its parts, so each is
/// held to keeping them.
@MainActor
struct PixelEditKeepsLayerTests {
    private static let effects = LayerEffects(stroke: StrokeEffect(size: 3, red: 1, green: 1, blue: 1), shadow: ShadowEffect())

    /// A 60×40 document whose one layer is half red, half blue, with a stroke and a drop shadow.
    private func session() throws -> EditorSession {
        let context = try PixelAdjust.bitmap(width: 60, height: 40, mask: false)
        context.setFillColor(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 30, height: 40))
        context.setFillColor(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)); context.fill(CGRect(x: 30, y: 0, width: 30, height: 40))
        let image = try #require(context.makeImage())
        let session = EditorSession()
        session.insert(ImportedImage(image: image, thumbnail: image, name: "Paint"))
        session.document?.layers[0].effects = Self.effects
        session.history.reset()
        return session
    }
    private func pixel(_ session: EditorSession, x: Int, y: Int) throws -> [UInt8] {
        let image = try #require(session.document?.layers.first?.asset?.image)
        let context = try PixelAdjust.bitmap(width: image.width, height: image.height, mask: false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let data = try #require(context.data), at = y * context.bytesPerRow + x * 4
        return (0..<4).map { data.load(fromByteOffset: at + $0, as: UInt8.self) }
    }
    /// The layer still has its effects and everything else it had, with other pixels; one Undo restores it whole.
    private func expectKept(_ session: EditorSession, before: CanvasDocument?, name: String, was: [UInt8], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let layer = try #require(session.document?.layers.first, sourceLocation: sourceLocation), old = try #require(before?.layers.first, sourceLocation: sourceLocation)
        #expect(layer.effects == Self.effects, "\(name) kept the layer’s stroke and drop shadow", sourceLocation: sourceLocation)
        #expect(layer.id == old.id && layer.name == old.name && layer.opacity == old.opacity && layer.blendMode == old.blendMode && layer.mask == old.mask, sourceLocation: sourceLocation)
        #expect(session.history.undoCount == 1 && session.history.undoName == name, sourceLocation: sourceLocation)
        #expect(try pixel(session, x: 5, y: 5) != was, "\(name) changed the pixels", sourceLocation: sourceLocation)
        session.undo()
        #expect(session.document == before && session.history.undoCount == 0, sourceLocation: sourceLocation)
        #expect(try pixel(session, x: 5, y: 5) == was, sourceLocation: sourceLocation)
    }

    @Test func invertKeepsTheLayersEffectsAndOneUndoRestoresThePixels() async throws {
        let session = try session(), before = session.document, was = try pixel(session, x: 5, y: 5)
        #expect(was[3] == 255 && was[0] > 200)
        await session.invertPixels()
        let now = try pixel(session, x: 5, y: 5)
        #expect(now == [255 - was[0], 255 - was[1], 255 - was[2], 255] && session.brushError == nil)
        try expectKept(session, before: before, name: "Invert", was: was)
    }

    @Test func levelsKeepsTheLayersEffects() async throws {
        let session = try session(), before = session.document, was = try pixel(session, x: 5, y: 5)
        session.beginLevels()
        var settings = LevelsSettings(); settings.ranges[0].outputWhite = 128
        session.updateLevels(settings, preview: false)
        await session.commitLevels()
        #expect(session.levels == nil && session.brushError == nil)
        try expectKept(session, before: before, name: "Levels", was: was)
    }

    @Test func hueSaturationKeepsTheLayersEffects() async throws {
        let session = try session(), before = session.document, was = try pixel(session, x: 5, y: 5)
        session.beginHueSaturation()
        var settings = try #require(session.hueSaturation).settings
        settings.hue = 120
        session.updateHueSaturation(settings, preview: false)
        await session.commitHueSaturation()
        #expect(session.hueSaturation == nil && session.brushError == nil)
        try expectKept(session, before: before, name: "Hue/Saturation", was: was)
    }

    @Test func transformingSelectedPixelsKeepsTheLayersEffects() async throws {
        let session = try session(), was = try pixel(session, x: 5, y: 5)
        session.applySelection(CGPath(rect: CGRect(x: 0, y: 0, width: 10, height: 10), transform: nil), mode: .replace, name: "Marquee")
        session.history.reset()
        let selected = session.document
        await session.beginSelectionTransform()
        var draft = try #require(session.transformEdit?.draft)
        draft.origin = CGPoint(x: 40, y: 20)
        session.previewTransform(draft)
        session.commitTransform()
        #expect(session.document?.layers.count == 1 && session.brushError == nil)
        #expect(try pixel(session, x: 5, y: 5)[3] == 0 && pixel(session, x: 45, y: 25) == was, "the selected pixels moved")
        try expectKept(session, before: selected, name: "Transform Selection", was: was)
    }
}
