import Testing
import AppKit
import SwiftUI
import Foundation
import CoreGraphics
@testable import Compositor

/// S10 (sc-24665) bullets 2 and 3: merging, whole-layer copy and paste, and copying layers into another document
/// keep blend mode, opacity, masks, clipping and folder structure, each as one undo step; and a layer graph saved
/// and reopened is the same graph with the same pixels. Each flow runs on an 8-bit document (the retained Core
/// Graphics compositor) and on a document with HDR float layers (the float compositor).
@MainActor struct LayerGraphOperationTests {
    typealias F = LayerGraphFixture
    static let width = 48, height = 40

    /// A document with its layer ids by name. The float variant mixes HDR float layers with 8-bit ones.
    struct Fixture {
        let session: EditorSession
        let ids: [String: UUID]
        let float: Bool
        /// Keeps the fixture planes' scratch storage alive.
        let workspace: LWFloatWorkspace?
        func id(_ name: String) throws -> UUID { try #require(ids[name]) }
        func layer(_ name: String) throws -> ImageLayer { let id = try id(name); return try #require(session.document?.layers.first { $0.id == id }) }
    }

    /// Bottom to top: Backdrop; Outer (90%, masked) holding Base (Hard Light, 80%, soft-edged), Clipped (Multiply,
    /// clipped to Base), Inner (70%) holding Deep (Screen, masked); Top (60%, soft-edged).
    static func fixture(float: Bool, into session: EditorSession = EditorSession()) throws -> Fixture {
        let w = width, h = height
        let workspace = float ? try LWFloatWorkspace(workingSet: .sourceGraphs) : nil
        session.createDocument(width: w, height: h)
        var layers: [ImageLayer] = [], ids: [String: UUID] = [:]
        func transform(_ origin: CGPoint, _ size: CGSize) -> LayerTransform { var t = LayerTransform(origin: origin, size: size); t.sampling = .nearest; return t }
        func add(_ name: String, seed: Int, _ iw: Int, _ ih: Int, at origin: CGPoint, hdr: Bool = false, alpha: Int? = nil, parent: String? = nil,
                 mode: LayerBlendMode = .normal, opacity: Double = 1, clip: String? = nil, mask: Int? = nil) throws {
            let image = F.pattern(iw, ih, seed: seed, alpha: alpha)
            let asset = hdr && float ? try F.floatAsset(image, gain: 2.5, workspace: try #require(workspace), name: name) : F.asset(image, name)
            let id = UUID(); ids[name] = id
            layers.append(ImageLayer(id: id, asset: asset, name: name, isVisible: true, transform: transform(origin, CGSize(width: iw, height: ih)),
                parentID: parent.flatMap { ids[$0] }, opacity: opacity, blendMode: mode,
                mask: try mask.map { LayerMask(asset: try F.ramp(iw, ih, seed: $0)) }, maskSourceID: clip.flatMap { ids[$0] }))
        }
        func folder(_ name: String, parent: String? = nil, opacity: Double, mask: Int? = nil) throws {
            let id = UUID(); ids[name] = id
            layers.append(ImageLayer(id: id, asset: nil, name: name, isVisible: true, transform: transform(.zero, CGSize(width: w, height: h)),
                parentID: parent.flatMap { ids[$0] }, isGroup: true, opacity: opacity, mask: try mask.map { LayerMask(asset: try F.ramp(w, h, seed: $0)) }))
        }
        try add("Backdrop", seed: 1, w, h, at: .zero, hdr: true, alpha: 255)
        try folder("Outer", opacity: 0.9, mask: 1)
        try add("Base", seed: 2, 36, 28, at: CGPoint(x: 4, y: 4), hdr: true, parent: "Outer", mode: .hardLight, opacity: 0.8)
        try add("Clipped", seed: 3, 40, 30, at: CGPoint(x: 2, y: 2), alpha: 255, parent: "Outer", mode: .multiply, clip: "Base")
        try folder("Inner", parent: "Outer", opacity: 0.7)
        try add("Deep", seed: 4, 30, 24, at: CGPoint(x: 14, y: 12), hdr: true, alpha: 255, parent: "Inner", mode: .screen, mask: 2)
        try add("Top", seed: 5, 26, 22, at: CGPoint(x: 20, y: 16), opacity: 0.6)
        session.document?.layers = layers
        session.selectLayer(ids["Top"])
        session.history.reset()
        return Fixture(session: session, ids: ids, float: float, workspace: workspace)
    }

    // MARK: Rendering and comparison

    /// The document's composite: straight float samples (float documents) or premultiplied 8-bit levels.
    enum Pixels {
        case float([SIMD4<Float>]), levels([SIMD4<Double>])
        func matches(_ other: Pixels) -> Double {
            switch (self, other) {
            case (.float(let a), .float(let b)): a.count == b.count ? F.worstRelative(a, b) : .infinity
            case (.levels(let a), .levels(let b)): a.count == b.count ? F.worst(a, b).error : .infinity
            default: .infinity
            }
        }
        /// The same picture moved by whole pixels on a `width` × `height` canvas, transparent where nothing lands.
        func shifted(_ dx: Int, _ dy: Int, width: Int, height: Int) -> Pixels {
            func move<T>(_ p: [T], _ zero: T) -> [T] {
                (0..<width * height).map { i in
                    let x = i % width - dx, y = i / width - dy
                    return x >= 0 && y >= 0 && x < width && y < height ? p[y * width + x] : zero
                }
            }
            switch self { case .float(let p): return .float(move(p, .zero)); case .levels(let p): return .levels(move(p, .zero)) }
        }
        /// Float: relative, exact to float rounding. Levels: the retained compositor's 8-bit rounding.
        var tolerance: Double { if case .float = self { 1e-5 } else { 1 } }
        var isHDR: Bool { if case .float(let p) = self { p.contains { $0.x > 1.5 || $0.y > 1.5 || $0.z > 1.5 } } else { false } }
    }
    static func render(_ snapshot: ProjectSnapshot, float: Bool) async throws -> Pixels {
        float ? .float(try F.float(snapshot, workingSet: .sourceGraphs)) : .levels(try F.levels(try await ImageExporter.shared.render(snapshot).image))
    }
    static func render(_ session: EditorSession, float: Bool) async throws -> Pixels {
        try await render(try #require(session.projectSnapshot()), float: float)
    }
    /// The composite of only `ids` (and what their folders hold), cut loose from everything else, as Merge takes it.
    static func renderOnly(_ ids: Set<UUID>, of session: EditorSession, float: Bool) async throws -> Pixels {
        let snapshot = try #require(session.projectSnapshot())
        var manifest = snapshot.manifest
        manifest.layers = manifest.layers.filter { ids.contains($0.id) }.map { record in
            var record = record
            if let parent = record.parentID, !ids.contains(parent) { record.parentID = nil }
            if let source = record.maskSourceID, !ids.contains(source) { record.maskSourceID = nil }
            return record
        }
        return try await render(ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks), float: float)
    }
    /// A layer's own samples: straight float for a float layer, premultiplied 8-bit levels otherwise.
    static func samples(_ asset: ImportedImage) throws -> Pixels {
        if let plane = asset.linearPlane { return .float(try F.pixels(plane)) }
        return .levels(try F.levels(asset.image))
    }
    /// A mask's stored bytes, row by row.
    static func maskBytes(_ mask: LayerMask) throws -> [UInt8] {
        let image = mask.asset.image
        let context = try BrushRaster.context(width: image.width, height: image.height, mask: true)
        BrushRaster.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height), mask: true, context: context)
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self), row = context.bytesPerRow
        return (0..<image.width * image.height).map { bytes[($0 / image.width) * row + $0 % image.width] }
    }
    /// What shapes the graph, per layer, in order: everything but pixel storage.
    static func shape(_ layers: [ImageLayer], renaming: [UUID: UUID] = [:]) -> [String] {
        func name(_ id: UUID?) -> String { id.map { (renaming[$0] ?? $0).uuidString } ?? "-" }
        return layers.map { l in
            let mask = l.mask.map { "mask(\($0.isEnabled),\($0.isLinked),\(String(describing: $0.placement)),\($0.asset.image.width)x\($0.asset.image.height))" } ?? "-"
            return "\(name(l.id))|\(l.name)|\(l.isVisible)|\(l.transform)|\(name(l.parentID))|\(l.isGroup)|\(l.opacity)|\(l.blendMode.rawValue)|\(name(l.maskSourceID))|\(mask)|\(l.asset != nil)"
        }
    }

    // MARK: Every layer operation

    /// Each layer, folder, blend, mask and clipping operation of the retained Layers panel and Layer menu, run on
    /// its own against the fixture: it changes the graph, the changed document composites to the same pixels in
    /// the float compositor as in the retained one, and one undo puts the graph and the pixels back exactly.
    static let operations: [(name: String, run: @MainActor (Fixture) throws -> Void)] = [
        ("New Blank Layer", { $0.session.addBlankLayer() }),
        ("New Folder", { $0.session.addGroup() }),
        ("Group Layers", { f in f.session.selectLayers([try f.id("Base"), try f.id("Clipped")], primary: try f.id("Clipped")); f.session.groupSelectedLayers() }),
        ("Ungroup Layers", { f in f.session.selectLayer(try f.id("Inner")); f.session.ungroupLayers() }),
        ("Move into folder", { f in _ = f.session.placeLayer(try f.id("Top"), in: try f.id("Inner")) }),
        ("Move Out of Folder", { f in f.session.selectLayer(try f.id("Deep")); f.session.moveActiveLayerOutOfGroup() }),
        ("Move Layer Down", { f in f.session.selectLayer(try f.id("Top")); f.session.moveActiveLayer(by: -1) }),
        ("Reorder", { f in f.session.reorderLayers(from: IndexSet(integer: 0), to: (f.session.document?.layers.count ?? 0)) }),
        ("Delete Layer", { f in f.session.deleteLayer(try f.id("Top")) }),
        ("Delete Folder", { f in f.session.deleteLayer(try f.id("Inner")) }),
        ("Rename Layer", { f in f.session.renameLayer(try f.id("Deep"), to: "Renamed") }),
        ("Hide Layer", { f in f.session.toggleLayerVisibility(try f.id("Outer")) }),
        ("Blend Mode", { f in f.session.selectLayer(try f.id("Deep")); f.session.setLayerBlendMode(.linearLight) }),
        ("Next Blend Mode", { f in f.session.selectLayer(try f.id("Top")); f.session.cycleBlendMode(forward: true) }),
        ("Layer Opacity", { f in f.session.selectLayer(try f.id("Base")); f.session.setLayerOpacity(0.35) }),
        ("Folder Opacity", { f in f.session.selectLayer(try f.id("Outer")); f.session.setLayerOpacity(0.5) }),
        ("Selected Layers Opacity", { f in f.session.selectLayers([try f.id("Base"), try f.id("Top")], primary: try f.id("Top")); f.session.setSelectedLayersOpacity(0.25) }),
        ("Flip Layer Horizontal", { f in f.session.selectLayer(try f.id("Deep")); f.session.flipLayers(horizontally: true) }),
        ("Flip Folder Vertical", { f in f.session.selectLayer(try f.id("Outer")); f.session.flipLayers(horizontally: false) }),
        ("Flip Canvas Horizontal", { $0.session.flipCanvas(horizontally: true) }),
        ("Add Layer Mask", { f in f.session.selectLayer(try f.id("Top")); f.session.addLayerMask(revealing: false) }),
        ("Add Folder Mask", { f in f.session.selectLayer(try f.id("Inner")); f.session.addLayerMask(revealing: false) }),
        ("Disable Mask", { f in f.session.selectLayer(try f.id("Deep")); f.session.toggleLayerMask() }),
        ("Disable Folder Mask", { f in f.session.selectLayer(try f.id("Outer")); f.session.toggleLayerMask() }),
        ("Delete Mask", { f in f.session.selectLayer(try f.id("Deep")); f.session.deleteLayerMask() }),
        ("Unlink Mask", { f in f.session.toggleMaskLink(try f.id("Deep")) }),
        ("Copy Mask", { f in f.session.copyMask(from: try f.id("Deep"), to: try f.id("Top")) }),
        ("Release Clipping Mask", { f in f.session.toggleClippingMask(try f.id("Clipped")) }),
        ("Create Clipping Mask", { f in
            let top = try f.id("Top")
            guard f.session.canToggleClippingMask(top) else { throw ProjectError.invalid }
            f.session.toggleClippingMask(top)
        }),
        ("Live mask link", { f in guard f.session.linkMask(source: try f.id("Top"), target: try f.id("Deep")) else { throw ProjectError.invalid } }),
        ("Duplicate Layer", { f in f.session.selectLayer(try f.id("Base")); f.session.duplicateActiveLayer() }),
        ("Duplicate Folder", { f in f.session.selectLayer(try f.id("Outer")); f.session.duplicateActiveLayer() }),
        ("Move Layer Up", { f in f.session.selectLayer(try f.id("Backdrop")); f.session.moveActiveLayer(by: 1) }),
        ("Flip Layer Vertical", { f in f.session.selectLayer(try f.id("Top")); f.session.flipLayers(horizontally: false) }),
        ("Eye swipe", { f in
            guard f.session.beginVisibilitySwipe(try f.id("Top")) == false else { throw ProjectError.invalid }
            f.session.setVisibilityInSwipe(try f.id("Deep"), visible: false); f.session.setVisibilityInSwipe(try f.id("Outer"), visible: false)
            f.session.endVisibilitySwipe()
            guard try !f.layer("Top").isVisible, try !f.layer("Deep").isVisible, try !f.layer("Outer").isVisible else { throw ProjectError.invalid }
        }),
        ("Join a clipping group", { f in
            // Dropped between a base and the layer clipped to it, a layer is clipped to that base too.
            guard f.session.placeLayer(try f.id("Top"), in: try f.id("Outer"), above: try f.id("Base")),
                  try f.layer("Top").maskSourceID == (try f.id("Base")), try f.layer("Clipped").maskSourceID == (try f.id("Base")) else { throw ProjectError.invalid }
        }),
        ("Leave a clipping group", { f in
            guard f.session.placeLayer(try f.id("Clipped"), in: nil), try f.layer("Clipped").maskSourceID == nil else { throw ProjectError.invalid }
        }),
        ("Reveal Selection", { f in
            f.session.selectLayer(try f.id("Top")); f.session.addMask(revealing: true)
            guard try f.layer("Top").mask != nil, f.session.document?.selection == nil else { throw ProjectError.invalid }
        }),
        ("Load Layer Selection", { f in
            f.session.loadLayerSelection(layerID: try f.id("Deep"))
            guard f.session.document?.selection != nil else { throw ProjectError.invalid }
        }),
        ("Load Mask Selection", { f in
            f.session.loadMaskSelection(layerID: try f.id("Deep"))
            guard f.session.document?.selection != nil else { throw ProjectError.invalid }
        }),
        ("Delete (active layer)", { f in f.session.selectLayer(try f.id("Deep")); f.session.deleteActiveLayer() }),
        ("Import as a layer", { f in
            f.session.selectLayer(try f.id("Deep"))
            f.session.insert(LayerGraphFixture.asset(LayerGraphFixture.pattern(10, 8, seed: 40), "Imported"))
            // Above the selected layer's folder contents, inside the same folder, selected.
            guard f.session.activeLayer?.name == "Imported", f.session.activeLayer?.parentID == (try f.id("Inner")) else { throw ProjectError.invalid }
        }),
        ("Move a mask apart", { f in
            // Unlinked, the mask transforms on its own: it takes a placement and the layer stays put.
            let deep = try f.layer("Deep")
            f.session.selectLayerTarget(deep.id, mask: true)
            f.session.beginTransform()
            guard f.session.transformTargetsMask, var moved = f.session.transformEdit?.draft else { throw ProjectError.invalid }
            moved.origin.x += 6
            f.session.previewTransform(moved); f.session.commitTransform()
            guard try f.layer("Deep").mask?.placement == moved, try f.layer("Deep").transform == deep.transform else { throw ProjectError.invalid }
        }),
        ("Duplicate into folder", { f in guard f.session.duplicateLayer(try f.id("Top"), in: try f.id("Inner")) else { throw ProjectError.invalid } }),
    ]

    @Test(arguments: [false, true])
    func everyLayerOperationChangesTheGraphCompositesAndUndoes(_ float: Bool) async throws {
        for operation in Self.operations {
            let fixture = try Self.fixture(float: float), s = fixture.session
            if operation.name == "Create Clipping Mask" {
                // A plain layer directly under Top, beside it, to clip to.
                s.selectLayer(try fixture.id("Backdrop")); s.duplicateActiveLayer()
                _ = s.placeLayer(try #require(s.activeLayerID), in: nil, above: try fixture.id("Outer"))
                s.history.reset()
            }
            if operation.name == "Move a mask apart" { s.toggleMaskLink(try fixture.id("Deep")); s.history.reset() }
            if operation.name == "Reveal Selection" {
                s.setSelection(DocumentSelection(path: CGPath(rect: CGRect(x: 22, y: 18, width: 12, height: 10), transform: nil)), name: "Select")
                s.history.reset()
            }
            let before = try #require(s.document)
            let pixelsBefore = try await Self.render(s, float: float)
            try operation.run(fixture)
            #expect(s.commandRefusal == nil, "\(operation.name): \(s.commandRefusal ?? "")")
            let after = try #require(s.document)
            #expect(after != before, "\(operation.name) changed nothing")
            #expect(s.history.undoCount == 1, "\(operation.name) is one undo step, not \(s.history.undoCount)")
            try LayerHierarchy.validate(after.layers.map(\.hierarchyRecord)); try LiveMaskGraph.validate(after.layers.map(\.hierarchyRecord))
            let pixelsAfter = try await Self.render(s, float: float)
            if !float {
                // The same 8-bit document through the float compositor: the operation means the same pixels there, within
                // `LayerGraphPixelTests.levelTolerance` or, at a pixel beyond it, within what one 8-bit level explains.
                let snapshot = try #require(s.projectSnapshot())
                let graph = LayerGraphPixelTests.Graph(width: Self.width, height: Self.height, layers: snapshot.manifest.layers,
                    images: snapshot.images.mapValues(\.image), masks: snapshot.masks)
                let found = try await LayerGraphPixelTests.unexplained(graph)
                #expect(found.refused == 0, "\(operation.name): float and retained differ at \(found.refused) of \(found.outliers) pixels beyond tolerance; \(found.first)")
            }
            s.undo()
            #expect(s.document == before, "\(operation.name): undo did not restore the graph")
            let pixelsUndone = try await Self.render(s, float: float)
            #expect(pixelsUndone.matches(pixelsBefore) == 0, "\(operation.name): the pixels after undo differ by \(pixelsUndone.matches(pixelsBefore))")
            s.redo()
            #expect(s.document == after, "\(operation.name): redo did not reapply")
            let pixelsRedone = try await Self.render(s, float: float)
            #expect(pixelsRedone.matches(pixelsAfter) == 0, "\(operation.name): the pixels after redo differ by \(pixelsRedone.matches(pixelsAfter))")
        }
    }

    /// Panel state that is not part of the document: selection, folder expansion, viewing a mask alone, the blend
    /// preview and the drop rules. None of it adds an undo step or changes the graph.
    @Test(arguments: [false, true])
    func panelStateLeavesTheGraphAlone(_ float: Bool) throws {
        let fixture = try Self.fixture(float: float), s = fixture.session
        let before = try #require(s.document)
        let top = try fixture.id("Top"), deep = try fixture.id("Deep"), inner = try fixture.id("Inner"), outer = try fixture.id("Outer"), base = try fixture.id("Base")
        s.selectLayer(top)
        s.extendSelection(with: deep)
        #expect(s.selectedLayerIDs == [top, deep] && s.activeLayerID == deep)
        s.extendSelection(with: deep)
        #expect(s.selectedLayerIDs == [top])
        // Collapsing a folder hides its rows and moves the selection out of it.
        s.selectLayer(deep)
        s.toggleGroupExpansion(inner)
        #expect(s.collapsedGroupIDs == [inner] && s.activeLayerID == inner && !s.layerRows.contains { $0.layer.id == deep })
        s.toggleGroupExpansion(inner)
        #expect(s.collapsedGroupIDs.isEmpty && s.layerRows.count == before.layers.count)
        #expect(s.layerRows.first?.layer.id == top && s.layerRows.first { $0.layer.id == deep }?.depth == 2)
        s.toggleMaskAlone(deep)
        #expect(s.maskAloneLayer?.id == deep && s.isMaskSelected)
        s.toggleMaskAlone(deep)
        #expect(s.maskAloneLayer == nil)
        s.selectLayer(deep)
        s.previewBlendMode(.difference, for: deep)
        let previewed = s.displayedBlendMode(for: try fixture.layer("Deep"))
        #expect(previewed == .difference)
        s.previewBlendMode(nil, for: deep)
        let settled = s.displayedBlendMode(for: try fixture.layer("Deep"))
        #expect(settled == .screen)
        // A folder cannot go inside itself or what it holds; a mask copies to layers, not folders; a layer cannot
        // take its alpha from itself, a folder, or a layer that takes its own from it.
        #expect(s.canPlaceLayer(top, in: inner) && !s.canPlaceLayer(outer, in: inner) && !s.canPlaceLayer(outer, in: outer) && !s.canPlaceLayer(top, in: base))
        #expect(s.canCopyMask(from: deep, to: top) && !s.canCopyMask(from: deep, to: inner) && !s.canCopyMask(from: top, to: deep))
        #expect(s.canLinkMask(source: top, target: deep) && !s.canLinkMask(source: top, target: top) && !s.canLinkMask(source: outer, target: top))
        let clipped = try fixture.id("Clipped")
        #expect(!s.canLinkMask(source: clipped, target: base), "a cycle is refused")
        #expect(s.canToggleClippingMask(clipped) && !s.canToggleClippingMask(base) && !s.canToggleClippingMask(outer))
        #expect(s.canUngroupLayers == false)
        s.selectLayer(inner)
        #expect(s.canUngroupLayers && s.canEditOpacity && !s.canEditAppearance, "a folder takes opacity, not a blend mode")
        #expect(s.document == before && s.history.undoCount == 0)
    }

    /// A mask's value operations: new pixels keep its state and placement, and its white and black areas trace to
    /// complementary outlines.
    @Test func maskReplacementKeepsItsStateAndItsAreasTrace() throws {
        var placement = LayerTransform(origin: CGPoint(x: 3, y: 5), size: CGSize(width: 20, height: 10)); placement.sampling = .nearest
        let mask = LayerMask(asset: try F.mask(20, 10) { x, _ in x < 8 ? 255 : 0 }, isEnabled: false, placement: placement, isLinked: false)
        let replaced = mask.replacing(try F.mask(20, 10) { x, _ in x < 8 ? 0 : 255 })
        #expect(!replaced.isEnabled && !replaced.isLinked && replaced.placement == placement && replaced != mask)
        #expect(replaced.asset.image !== mask.asset.image && replaced.enabledImage == nil)
        let white = try #require(MaskTracing.whitePixels(in: mask.asset.image)), dark = try #require(MaskTracing.darkPixels(in: mask.asset.image))
        #expect(white.boundingBoxOfPath == CGRect(x: 0, y: 0, width: 8, height: 10))
        #expect(dark.boundingBoxOfPath == CGRect(x: 8, y: 0, width: 12, height: 10))
        #expect(LayerMask.solid(revealing: true).map { LayerMask.background(of: $0.asset.thumbnail) } == 1)
        #expect(LayerMask.solid(revealing: false).map { LayerMask.background(of: $0.asset.thumbnail) } == 0)
    }

    /// Deleting a layer that lends its alpha asks what becomes of the layers that take it: "Bake and Delete" keeps
    /// the dependent layer's look in its own pixels, at its own precision; "Remove Links and Delete" reveals it;
    /// Cancel deletes nothing. Either deletion is one undo step. The question is answered here in place of the alert.
    @Test(arguments: [false, true])
    func deletingALiveMaskSourceBakesOrRemovesTheLink(_ float: Bool) async throws {
        let fixture = try Self.fixture(float: float), s = fixture.session
        let top = try fixture.id("Top"), deep = try fixture.id("Deep")
        #expect(s.linkMask(source: top, target: deep))
        s.history.reset()
        let before = try #require(s.document)
        let look = try await Self.renderOnly([deep, top], of: hiding(top, in: s), float: float)
        // A layer nothing depends on is not this function's to delete: it asks nothing and does nothing.
        var asked: [Int] = []
        #expect(!s.deleteWithLiveMaskChoice([deep]) { asked.append($0); return .bake })
        #expect(asked.isEmpty && s.document == before)
        // Cancel.
        #expect(s.deleteWithLiveMaskChoice([top]) { asked.append($0); return .cancel })
        #expect(asked == [1] && s.document == before && s.history.undoCount == 0 && !s.isProjectBusy)
        // Bake and Delete.
        #expect(s.deleteWithLiveMaskChoice([top]) { _ in .bake })
        try await Self.idle(s)
        #expect(s.brushError == nil, "\(s.brushError ?? "")")
        #expect(s.history.undoCount == 1 && s.document?.layers.contains { $0.id == top } == false)
        let kept = try fixture.layer("Deep")
        #expect(kept.maskSourceID == nil && kept.mask == before.layers.first { $0.id == deep }?.mask)
        #expect((kept.asset?.linearPlane != nil) == float && kept.asset?.image !== before.layers.first { $0.id == deep }?.asset?.image)
        let after = try await Self.renderOnly([deep], of: s, float: float)
        #expect(after.matches(look) <= (float ? 1e-5 : 2), "baked look differs by \(after.matches(look))")
        if float { #expect(after.isHDR) }
        s.undo()
        #expect(s.document == before)
        // Remove Links and Delete.
        #expect(s.deleteWithLiveMaskChoice([top]) { _ in .removeLinks })
        #expect(s.history.undoCount == 1 && s.document?.layers.contains { $0.id == top } == false && !s.isProjectBusy)
        let revealed = try fixture.layer("Deep")
        #expect(revealed.maskSourceID == nil && revealed.asset?.image === before.layers.first { $0.id == deep }?.asset?.image)
        s.undo()
        #expect(s.document == before)
    }
    /// Waits for a session's background operation (a bake, a development) to finish.
    static func idle(_ session: EditorSession) async throws {
        for _ in 0..<4000 where session.isProjectBusy { try await Task.sleep(for: .milliseconds(5)) }
        #expect(!session.isProjectBusy)
    }

    /// A layer larger than the canvas, or hanging off it, keeps its baked coverage where it is off the canvas:
    /// the coverage belongs to the layer's own grid, not to the part of it the canvas shows. `origin` puts Deep
    /// (taking Top's soft alpha) off the top-left, then off the bottom-right. Bake and Delete and a copy into a
    /// larger project are each checked for the 8-bit and the float layer against the same expected alpha.
    @Test(arguments: [CGPoint(x: -12, y: -10), CGPoint(x: 30, y: 26)])
    func bakedCoverageReachesThePartOfALayerOffTheCanvas(_ origin: CGPoint) async throws {
        let offset = (x: 6, y: 5)
        // Deep is opaque; Top's soft alpha, at Top's 60%, is what it takes. In Deep's own 30 × 24 grid:
        let lender = try F.levels(F.pattern(26, 22, seed: 5)).map(\.w)
        let expected: [Double] = (0..<30 * 24).map { i in
            let x = i % 30 - offset.x, y = i / 30 - offset.y
            return x >= 0 && y >= 0 && x < 26 && y < 22 ? lender[y * 26 + x] * 0.6 : 0
        }
        let offCanvas = (0..<30 * 24).filter { i in
            let x = Int(origin.x) + i % 30, y = Int(origin.y) + i / 30
            return x < 0 || y < 0 || x >= Self.width || y >= Self.height
        }
        #expect(offCanvas.contains { expected[$0] > 60 }, "the fixture lends coverage off the canvas")
        func arranged(float: Bool, into session: EditorSession = EditorSession()) throws -> Fixture {
            let fixture = try Self.fixture(float: float, into: session)
            let deep = try #require(session.document?.layers.firstIndex { $0.name == "Deep" }), top = try #require(session.document?.layers.firstIndex { $0.name == "Top" })
            session.document?.layers[deep].transform.origin = origin
            session.document?.layers[deep].maskSourceID = try fixture.id("Top")
            session.document?.layers[top].transform.origin = CGPoint(x: origin.x + CGFloat(offset.x), y: origin.y + CGFloat(offset.y))
            session.history.reset()
            return fixture
        }
        func check(_ asset: ImportedImage?, float: Bool, _ flow: String) throws {
            let asset = try #require(asset)
            #expect((asset.linearPlane != nil) == float, "\(flow): the layer keeps its sample format")
            let alpha = try float ? F.pixels(try #require(asset.linearPlane)).map { Double($0.w) * 255 } : F.levels(asset.image).map(\.w)
            #expect(alpha.count == expected.count)
            let worst = zip(alpha, expected).map { abs($0 - $1) }.max() ?? .infinity
            #expect(worst <= 1.5, "\(flow), \(float ? "float" : "8-bit"): baked alpha differs from the lent coverage by \(worst) levels")
            #expect(offCanvas.contains { alpha[$0] > 60 }, "\(flow), \(float ? "float" : "8-bit"): the part off the canvas keeps its coverage")
        }
        for float in [false, true] {
            // Bake and Delete.
            let deleting = try arranged(float: float)
            #expect(deleting.session.deleteWithLiveMaskChoice([try deleting.id("Top")]) { _ in .bake })
            try await Self.idle(deleting.session)
            try check(try deleting.layer("Deep").asset, float: float, "Bake and Delete")
            // A copy into a larger project, without its lender.
            let workspace = ProjectWorkspace()
            let copying = try arranged(float: float, into: workspace.current.session)
            let second = workspace.addTab(reuseEmpty: false)
            second.session.createDocument(width: Self.width * 3, height: Self.height * 3)
            await workspace.copyLayers([try copying.id("Deep")], into: second.id)
            let copy = try #require(second.session.document?.layers.first)
            #expect(copy.maskSourceID == nil && second.session.importError == nil)
            try check(copy.asset, float: float, "Copy into another project")
        }
    }

    /// A copy of the session's document with one layer hidden, for rendering what its dependents show.
    private func hiding(_ id: UUID, in session: EditorSession) throws -> EditorSession {
        let copy = EditorSession()
        copy.createDocument(width: Self.width, height: Self.height)
        copy.document = session.document
        let index = try #require(copy.document?.layers.firstIndex { $0.id == id })
        copy.document?.layers[index].isVisible = false
        return copy
    }

    // MARK: Layers panel and blend menu

    private func layerTable(_ session: EditorSession) -> (LayerTableView, NativeLayerList.Coordinator, NSWindow) {
        let coordinator = NativeLayerList.Coordinator(session: session), table = LayerTableView()
        table.session = session; table.rowHeight = 52; table.allowsMultipleSelection = true; table.allowsEmptySelection = true
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("layer")); column.width = 252
        table.addTableColumn(column)
        table.delegate = coordinator; table.dataSource = coordinator
        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 252, height: 400))
        scroll.documentView = table
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 252, height: 400), styleMask: [.titled], backing: .buffered, defer: false)
        window.contentView = scroll
        coordinator.update(table)
        return (table, coordinator, window)
    }

    /// The Layers panel's context menu, item by item, on the layer it applies to: the item is enabled, choosing it
    /// goes through the command dispatcher under its registered command, changes the graph in one undo step, and
    /// undo restores it.
    @Test(arguments: [false, true])
    func layersPanelContextMenuRunsEveryLayerCommand(_ float: Bool) throws {
        typealias C = NativeLayerList.Coordinator
        let cases: [(selector: Selector, command: LensWorksCommandID, argument: String?, select: [String], undoable: Bool)] = [
            (#selector(C.duplicateLayerAction), .duplicateLayer, nil, ["Outer"], true),
            (#selector(C.deleteLayerAction), .deleteLayer, nil, ["Inner"], true),
            (#selector(C.toggleClippingMaskAction), .clippingMask, nil, ["Clipped"], true),
            (#selector(C.groupSelectedLayersAction), .groupLayers, nil, ["Base", "Clipped"], true),
            (#selector(C.ungroupLayersAction), .ungroupLayers, nil, ["Inner"], true),
            (#selector(C.moveOutOfFolderAction), .moveOutOfFolder, nil, ["Deep"], true),
            (#selector(C.mergeLayersAction), .mergeLayers, nil, ["Outer"], true),
            (#selector(C.addWhiteMaskAction), .addMask, "white", ["Top"], true),
            (#selector(C.addBlackMaskAction), .addMask, "black", ["Inner"], true),
            (#selector(C.toggleMaskAction), .toggleMask, nil, ["Outer"], true),
            (#selector(C.deleteMaskAction), .deleteMask, nil, ["Deep"], true),
            (#selector(C.toggleMaskLinkAction), .linkMask, nil, ["Deep"], true),
            (#selector(C.toggleVisibilityAction), .visibility, nil, ["Outer"], true),
            (#selector(C.renameLayerAction), .beginRename, nil, ["Deep"], false),
        ]
        for item in cases {
            let fixture = try Self.fixture(float: float), s = fixture.session
            let (table, coordinator, window) = layerTable(s)
            defer { withExtendedLifetime(window) {} }
            let ids = try item.select.map(fixture.id)
            s.selectLayers(Set(ids), primary: ids.last)
            coordinator.update(table)
            #expect(table.numberOfRows == s.layerRows.count)
            let row = try #require(s.layerRows.firstIndex { $0.layer.id == ids.last })
            let menu = try #require(coordinator.contextMenu(for: row))
            let entries = menu.items + menu.items.flatMap { $0.submenu?.items ?? [] }
            let entry = try #require(entries.first { $0.action == item.selector }, "\(item.command) is in the menu")
            #expect(entry.isEnabled, "\(item.command) is available for \(item.select)")
            #expect(entry.identifier?.rawValue == LensWorksCommandInvocation(item.command, item.argument).identifier)
            let before = try #require(s.document)
            #expect(NSApp.sendAction(item.selector, to: entry.target, from: entry))
            #expect(LensWorksCommandDispatcher.lastInvocation == LensWorksCommandInvocation(item.command, item.argument))
            if item.undoable {
                #expect(s.document != before && s.history.undoCount == 1, "\(item.command) is one undo step")
                s.undo()
                #expect(s.document == before, "\(item.command) undoes")
            } else {
                #expect(s.renamingLayerID == ids.last && s.document == before)
            }
        }
        // What cannot apply is disabled rather than silently doing nothing.
        let fixture = try Self.fixture(float: float), s = fixture.session
        let (table, coordinator, window) = layerTable(s)
        defer { withExtendedLifetime(window) {} }
        s.selectLayer(try fixture.id("Backdrop"))
        coordinator.update(table)
        let menu = try #require(coordinator.contextMenu(for: s.layerRows.count - 1))
        for selector in [#selector(C.toggleClippingMaskAction), #selector(C.moveOutOfFolderAction), #selector(C.mergeLayersAction),
                         #selector(C.toggleMaskAction), #selector(C.deleteMaskAction), #selector(C.toggleMaskLinkAction)] {
            #expect(menu.items.first { $0.action == selector }?.isEnabled == false, "\(selector) has nothing to act on for the bottom layer")
        }
        #expect(!menu.items.contains { $0.action == #selector(C.ungroupLayersAction) })
    }

    /// The panel's table itself: every row has a view, selecting rows selects layers, a row can be dragged (its
    /// pasteboard item names the layer), and a move to a row reorders within or across folders as one undo step.
    @Test(arguments: [false, true])
    func layersPanelRowsSelectAndReorder(_ float: Bool) throws {
        let fixture = try Self.fixture(float: float), s = fixture.session
        let (table, coordinator, window) = layerTable(s)
        defer { withExtendedLifetime(window) {} }
        let rows = s.layerRows.map(\.layer.id)
        #expect(rows == (try ["Top", "Outer", "Inner", "Deep", "Clipped", "Base", "Backdrop"].map(fixture.id)), "top first, folders before their contents")
        for row in rows.indices {
            #expect(coordinator.tableView(table, viewFor: table.tableColumns.first, row: row) != nil)
            #expect(coordinator.tableView(table, heightOfRow: row) >= 52)
            let item = try #require(coordinator.tableView(table, pasteboardWriterForRow: row) as? NSPasteboardItem)
            #expect(item.string(forType: NativeLayerList.Coordinator.layerType) == rows[row].uuidString)
        }
        table.selectRowIndexes(IndexSet([3, 5]), byExtendingSelection: false)
        #expect(s.selectedLayerIDs == [rows[3], rows[5]])
        table.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        #expect(s.selectedLayerIDs == [rows[0]] && s.activeLayerID == rows[0] && s.history.undoCount == 0)
        let before = try #require(s.document)
        // Top dropped above Deep lands inside Inner, directly above Deep.
        #expect(coordinator.moveLayer(rows[0], to: 3))
        let top = try fixture.layer("Top"), inner = try fixture.id("Inner")
        #expect(top.parentID == inner && s.history.undoCount == 1 && s.selectedLayerIDs == [rows[0]])
        coordinator.update(table)
        #expect(s.layerRows.map(\.layer.id) == [rows[1], rows[2], rows[0], rows[3], rows[4], rows[5], rows[6]])
        s.undo()
        #expect(s.document == before)
        // A clipped layer dragged to the bottom leaves its clipping group.
        coordinator.update(table)
        #expect(coordinator.moveLayer(rows[4], to: rows.count))
        let clipped = try fixture.layer("Clipped")
        #expect(clipped.parentID == nil && clipped.maskSourceID == nil && s.document?.layers.first?.id == rows[4])
        s.undo()
        #expect(s.document == before)
        // A folder cannot be dropped into itself, and a row that is not a drop target is refused.
        coordinator.update(table)
        #expect(!coordinator.moveLayer(rows[1], to: 3) && !coordinator.moveLayer(rows[0], to: -1) && s.document == before)
    }

    /// The blend menu lists every mode once, in its groups; highlighting one previews it on the canvas without an
    /// undo step, and choosing it commits it as one.
    @Test func blendMenuPreviewsAndCommitsEveryMode() throws {
        #expect(LayerBlendMode.groups.flatMap { $0 }.count == LayerBlendMode.allCases.count)
        #expect(Set(LayerBlendMode.groups.flatMap { $0 }) == Set(LayerBlendMode.allCases))
        let fixture = try Self.fixture(float: true), s = fixture.session
        let top = try fixture.id("Top")
        s.selectLayer(top)
        let coordinator = BlendModePicker.Coordinator(session: s)
        let button = NSPopUpButton(frame: .zero, pullsDown: false)
        for group in LayerBlendMode.groups { for mode in group { button.addItem(withTitle: mode.rawValue) } }
        let menu = try #require(button.menu)
        for mode in LayerBlendMode.allCases where mode != .normal {
            let entry = try #require(menu.item(withTitle: mode.rawValue))
            coordinator.menuWillOpen(menu)
            coordinator.menu(menu, willHighlight: entry)
            let shown = s.displayedBlendMode(for: try fixture.layer("Top"))
            #expect(shown == mode && s.history.undoCount == 0)
            let committed = try fixture.layer("Top").blendMode
            #expect(committed == .normal, "a preview is not a change")
            button.select(entry)
            coordinator.choose(button)
            let chosen = try fixture.layer("Top").blendMode
            #expect(chosen == mode && s.history.undoCount == 1)
            s.undo()
            let restored = try fixture.layer("Top").blendMode
            #expect(restored == .normal)
            s.history.reset()
        }
        // A folder has no blend mode of its own.
        s.selectLayer(try fixture.id("Outer"))
        #expect(!s.canEditAppearance)
        s.setLayerBlendMode(.multiply)
        let folderMode = try fixture.layer("Outer").blendMode
        #expect(folderMode == .normal && s.history.undoCount == 0)
    }

    // MARK: Merge

    private func checkMerge(float: Bool, select names: [String], action: String, mergedName: String, parent: String?, removed: [String]) async throws {
        let fixture = try Self.fixture(float: float), s = fixture.session
        let selected = Set(try names.map(fixture.id)), removedIDs = Set(try removed.map(fixture.id))
        s.selectLayers(selected, primary: try fixture.id(names.last!))
        #expect(s.canMergeLayers && s.mergeTitle == action)
        let before = try #require(s.document), undoCount = s.history.undoCount, activeBefore = try #require(s.activeLayerID)
        let expected = try await Self.renderOnly(removedIDs, of: s, float: float)
        s.mergeLayers()
        let merged = try #require(s.activeLayer)
        #expect(s.selectedLayerIDs == [merged.id], "the merged layer is the selection")
        #expect(s.history.undoCount == undoCount + 1, "\(action) is one undo step")
        #expect(merged.name == mergedName && !merged.isGroup && merged.blendMode == .normal && merged.opacity == 1 && merged.mask == nil)
        let expectedParent = try parent.map(fixture.id)
        #expect(merged.parentID == expectedParent)
        #expect(s.document?.layers.contains { removedIDs.contains($0.id) } == false)
        #expect(s.document?.layers.count == before.layers.count - removedIDs.count + 1)
        // The merged layer alone is the merged layers' composite, blend modes, opacity, masks and clipping baked in.
        let alone = try await Self.renderOnly([merged.id], of: s, float: float)
        #expect(alone.matches(expected) <= expected.tolerance, "\(action): merged pixels differ by \(alone.matches(expected))")
        // A float merge stays float: HDR is not clamped into an 8-bit layer.
        #expect((merged.asset?.linearPlane != nil) == float)
        if float { #expect(alone.isHDR) }
        // Trimmed to what is there, on whole pixels.
        #expect(merged.transform.origin.x == merged.transform.origin.x.rounded() && merged.transform.size.width <= CGFloat(Self.width))
        let after = try #require(s.document)
        s.undo()
        #expect(s.document == before, "undo restores the graph")
        #expect(Self.shape(try #require(s.document).layers) == Self.shape(before.layers))
        // History keeps the active layer: undo puts it back (a selection of several comes back as that layer).
        #expect(s.activeLayerID == activeBefore && s.selectedLayerIDs == [activeBefore], "undo restores the active layer")
        s.redo()
        #expect(s.document == after)
        #expect(s.activeLayerID == merged.id && s.selectedLayerIDs == [merged.id], "redo selects the merged layer again")
    }

    @Test(arguments: [false, true])
    func mergeGroupBakesTheFolderIntoOneLayerAndUndoes(_ float: Bool) async throws {
        try await checkMerge(float: float, select: ["Outer"], action: "Merge Group", mergedName: "Outer", parent: nil,
                             removed: ["Outer", "Base", "Clipped", "Inner", "Deep"])
    }

    @Test(arguments: [false, true])
    func mergeSelectedLayersAcrossFoldersAndUndoes(_ float: Bool) async throws {
        // Base comes out of its folder (and loses the folder's mask and opacity, as the merge is of the layers picked);
        // the nested folder comes whole.
        try await checkMerge(float: float, select: ["Base", "Inner", "Top"], action: "Merge Layers", mergedName: "Top", parent: nil,
                             removed: ["Base", "Inner", "Deep", "Top"])
    }

    @Test(arguments: [false, true])
    func mergeDownKeepsTheAppearanceRepointsClippingAndUndoes(_ float: Bool) async throws {
        let fixture = try Self.fixture(float: float), s = fixture.session
        // Deep onto a new layer below it in the same folder.
        let below = F.pattern(20, 20, seed: 9)
        var lower = ImageLayer(id: UUID(), asset: float ? try F.floatAsset(below, gain: 2, workspace: try #require(fixture.workspace)) : F.asset(below),
            name: "Lower", isVisible: true, transform: LayerTransform(origin: CGPoint(x: 10, y: 10), size: CGSize(width: 20, height: 20)), parentID: try fixture.id("Inner"))
        lower.transform.sampling = .nearest
        let deepIndex = try #require(s.document?.layers.firstIndex { $0.name == "Deep" })
        s.document?.layers.insert(lower, at: deepIndex)
        // Something outside the merge that takes Deep's alpha.
        let topIndex = try #require(s.document?.layers.firstIndex { $0.name == "Top" })
        s.document?.layers[topIndex].maskSourceID = try fixture.id("Deep")
        s.history.reset()
        s.selectLayer(try fixture.id("Deep"))
        #expect(s.mergeTitle == "Merge Down" && s.canMergeLayers)
        let before = try #require(s.document)
        let expected = try await Self.renderOnly([lower.id, try fixture.id("Deep")], of: s, float: float)
        s.mergeLayers()
        let merged = try #require(s.activeLayer)
        let inner = try fixture.id("Inner")
        #expect(merged.name == "Lower" && merged.parentID == inner)
        let topSource = try fixture.layer("Top").maskSourceID
        #expect(topSource == merged.id, "layers clipped to a merged layer clip to the result")
        #expect((merged.asset?.linearPlane != nil) == float)
        let alone = try await Self.renderOnly([merged.id], of: s, float: float)
        #expect(alone.matches(expected) <= expected.tolerance, "merged pixels differ by \(alone.matches(expected))")
        #expect(s.history.undoCount == 1 && s.selectedLayerIDs == [merged.id])
        let after = try #require(s.document), deepID = try fixture.id("Deep")
        s.undo()
        #expect(s.document == before)
        #expect(s.activeLayerID == deepID && s.selectedLayerIDs == [deepID], "undo restores the active layer")
        s.redo()
        #expect(s.document == after && s.activeLayerID == merged.id && s.selectedLayerIDs == [merged.id], "redo selects the merged layer again")
        s.undo()
        // A folder below, or nothing below, is not something to merge down into.
        s.selectLayer(try fixture.id("Top"))
        #expect(!s.canMergeLayers)
        s.mergeLayers()
        #expect(s.document == before)
    }

    /// Merging every layer of a document whose layers are all Normal leaves the picture exactly as it was.
    @Test(arguments: [false, true])
    func mergingNormalLayersLeavesTheCompositeUnchanged(_ float: Bool) async throws {
        let fixture = try Self.fixture(float: float), s = fixture.session
        for i in try #require(s.document?.layers.indices) { s.document?.layers[i].blendMode = .normal }
        let before = try await Self.render(s, float: float)
        s.selectLayers(Set(try ["Backdrop", "Outer", "Top"].map(fixture.id)), primary: try fixture.id("Top"))
        s.mergeLayers()
        #expect(s.document?.layers.count == 1)
        let after = try await Self.render(s, float: float)
        #expect(after.matches(before) <= before.tolerance, "composite changed by \(after.matches(before))")
    }

    // MARK: Whole-layer copy and paste

    @Test(arguments: [false, true])
    func copyAndPasteOfAFolderKeepsTheGraphAndIsOneUndoStep(_ float: Bool) async throws {
        let workspace = ProjectWorkspace(), tab = workspace.current
        let fixture = try Self.fixture(float: float, into: tab.session), s = fixture.session
        s.selectLayer(try fixture.id("Outer"))
        #expect(s.canCopyLayer)
        s.copySelection()
        let before = try #require(s.document)
        #expect(workspace.pasteCopiedLayer())
        let after = try #require(s.document)
        #expect(s.history.undoCount == 1, "Paste is one undo step")
        #expect(after.layers.count == before.layers.count + 5)
        let copy = try #require(s.activeLayer)
        let outerID = try fixture.id("Outer")
        #expect(copy.isGroup && copy.name == "Outer copy" && copy.id != outerID)
        // The copy sits directly above the original, with the same structure under new identities.
        let originals = try ["Outer", "Base", "Clipped", "Inner", "Deep"].map(fixture.layer)
        let known = Set(before.layers.map(\.id))
        let copies = after.layers.filter { !known.contains($0.id) }
        #expect(copies.first?.id == copy.id)
        let outerIndex = try #require(after.layers.firstIndex { $0.id == originals[0].id })
        let copyIndex = try #require(after.layers.firstIndex { $0.id == copy.id })
        #expect(copyIndex > outerIndex && after.layers[copyIndex].parentID == originals[0].parentID, "the copy is above its original, beside it")
        let renaming = Dictionary(uniqueKeysWithValues: zip(copies.map(\.id), originals.map(\.id)))
        var expectedShape = Self.shape(originals)
        expectedShape[0] = expectedShape[0].replacingOccurrences(of: "|Outer|", with: "|Outer copy|")
        #expect(Self.shape(copies, renaming: renaming) == expectedShape)
        // Clipping points at the copy's own base, masks and pixels are the originals', float stays float.
        #expect(copies[2].maskSourceID == copies[1].id && copies[4].parentID == copies[3].id && copies[3].parentID == copy.id)
        for (made, original) in zip(copies, originals) {
            #expect(made.mask == original.mask && made.asset?.image === original.asset?.image)
            #expect((made.asset?.linearPlane != nil) == (original.asset?.linearPlane != nil))
        }
        let original = try await Self.renderOnly(Set(originals.map(\.id)), of: s, float: float)
        let pasted = try await Self.renderOnly(Set(copies.map(\.id)), of: s, float: float)
        #expect(pasted.matches(original) == 0)
        #expect(s.selectedLayerIDs == [copy.id], "the pasted folder is the selection")
        s.undo()
        #expect(s.document == before)
        #expect(s.activeLayerID == outerID && s.selectedLayerIDs == [outerID], "undo restores the active layer")
        s.redo()
        #expect(s.document == after)
        #expect(s.activeLayerID == copy.id && s.selectedLayerIDs == [copy.id], "redo selects the pasted folder again")
    }

    // MARK: Copy into another document

    @Test(arguments: [false, true])
    func crossDocumentCopyKeepsTheGraphAndUndoesInTheTargetOnly(_ float: Bool) async throws {
        let workspace = ProjectWorkspace(), first = workspace.current
        let fixture = try Self.fixture(float: float, into: first.session), source = fixture.session
        let second = workspace.addTab(reuseEmpty: false)
        second.session.createDocument(width: Self.width, height: Self.height)
        second.session.history.reset()
        let sourceBefore = try #require(source.document)
        await workspace.copyLayers([try fixture.id("Outer")], into: second.id)
        let target = second.session
        let copies = try #require(target.document?.layers)
        let originals = try ["Outer", "Base", "Clipped", "Inner", "Deep"].map(fixture.layer)
        #expect(copies.count == 5 && target.history.undoCount == 1)
        #expect(Set(copies.map(\.id)).isDisjoint(with: sourceBefore.layers.map(\.id)), "copies take new identities")
        let renaming = Dictionary(uniqueKeysWithValues: zip(copies.map(\.id), originals.map(\.id)))
        #expect(Self.shape(copies, renaming: renaming) == Self.shape(originals))
        #expect(copies[2].maskSourceID == copies[1].id && copies[4].parentID == copies[3].id)
        for (made, original) in zip(copies, originals) { #expect((made.asset?.linearPlane != nil) == (original.asset?.linearPlane != nil)) }
        let expected = try await Self.renderOnly(Set(originals.map(\.id)), of: source, float: float)
        let made = try await Self.render(target, float: float)
        #expect(made.matches(expected) == 0, "copied pixels differ by \(made.matches(expected))")
        if float { #expect(made.isHDR) }
        #expect(source.document == sourceBefore && source.history.undoCount == 0, "the source document is untouched")
        let after = try #require(target.document), sourceActive = source.activeLayerID, sourceSelected = source.selectedLayerIDs
        #expect(target.activeLayerID == copies[0].id && target.selectedLayerIDs == [copies[0].id], "the copied folder is the selection in the target")
        target.undo()
        #expect(target.document?.layers.isEmpty == true && source.document == sourceBefore)
        #expect(target.activeLayerID == nil && target.selectedLayerIDs.isEmpty, "undo leaves the empty target with nothing selected")
        target.redo()
        #expect(target.document == after)
        #expect(target.activeLayerID == copies[0].id && target.selectedLayerIDs == [copies[0].id], "redo selects the copied folder again")
        #expect(source.activeLayerID == sourceActive && source.selectedLayerIDs == sourceSelected, "the source's selection is untouched")
    }

    /// A clipped layer copied without its base keeps what it looked like: the base's coverage is baked into its
    /// alpha, at the precision of its own pixels.
    @Test(arguments: [false, true])
    func crossDocumentCopyOfAClippedLayerBakesItsCoverage(_ float: Bool) async throws {
        let workspace = ProjectWorkspace(), first = workspace.current
        let fixture = try Self.fixture(float: float, into: first.session), source = fixture.session
        // Deep (a float layer in the float document) takes Top's soft alpha, from outside its folder.
        let deepIndex = try #require(source.document?.layers.firstIndex { $0.name == "Deep" })
        source.document?.layers[deepIndex].maskSourceID = try fixture.id("Top")
        source.document?.layers[deepIndex].blendMode = .normal
        let second = workspace.addTab(reuseEmpty: false)
        second.session.createDocument(width: Self.width, height: Self.height)
        // What Deep shows on its own: its pixels through its mask and Top's coverage, with no folder around it.
        let snapshot = try #require(source.projectSnapshot())
        var manifest = snapshot.manifest
        manifest.layers = manifest.layers.filter { ["Deep", "Top"].contains($0.name) }.map { var r = $0; r.parentID = nil; if r.name == "Top" { r.isVisible = false }; return r }
        let expected = try await Self.render(ProjectSnapshot(manifest: manifest, images: snapshot.images, masks: snapshot.masks), float: float)
        await workspace.copyLayers([try fixture.id("Deep")], into: second.id)
        let copy = try #require(second.session.document?.layers.first)
        #expect(second.session.document?.layers.count == 1 && copy.maskSourceID == nil && copy.mask != nil)
        #expect((copy.asset?.linearPlane != nil) == float, "a float layer stays float when its coverage is baked")
        // One layer copied alone is centred on the target canvas; its pixels moved with it.
        let deepTransform = try fixture.layer("Deep").transform
        let dx = Int(copy.transform.origin.x - deepTransform.origin.x), dy = Int(copy.transform.origin.y - deepTransform.origin.y)
        #expect(copy.transform.center == CGPoint(x: Self.width / 2, y: Self.height / 2) && copy.transform.size == deepTransform.size)
        let made = try await Self.render(second.session, float: float)
        let moved = expected.shifted(dx, dy, width: Self.width, height: Self.height)
        #expect(made.matches(moved) <= (float ? 1e-5 : 2), "baked pixels differ by \(made.matches(moved))")
        if float { #expect(made.isHDR) }
    }

    // MARK: Save and reopen

    /// Every blend mode, nested folders, folder and layer masks (enabled, disabled, moved, unlinked), clipping, a
    /// live mask link, opacity and visibility: saved, loaded and installed in a new session, the graph and the
    /// rendered pixels are unchanged, and a second save of the reopened document changes nothing either.
    @Test(arguments: [false, true])
    func layerGraphRoundTripsThroughSaveAndReopen(_ float: Bool) async throws {
        let fixture = try Self.fixture(float: float), s = fixture.session
        var layers = try #require(s.document?.layers)
        // One small layer per blend mode, alternately inside the nested folder, with assorted opacity and visibility.
        for (i, mode) in LayerBlendMode.allCases.enumerated() {
            let image = F.pattern(8, 6, seed: 20 + i)
            var layer = ImageLayer(id: UUID(), asset: float && i % 3 == 0 ? try F.floatAsset(image, gain: 3, workspace: try #require(fixture.workspace)) : F.asset(image),
                name: mode.rawValue, isVisible: i % 7 != 3, transform: LayerTransform(origin: CGPoint(x: (i % 6) * 8, y: (i / 6) * 9 + 2), size: CGSize(width: 8, height: 6)),
                parentID: i % 2 == 0 ? try fixture.id("Inner") : nil, opacity: 1 - Double(i) * 0.03, blendMode: mode)
            layer.transform.sampling = .nearest
            layers.append(layer)
        }
        func index(_ name: String) throws -> Int { try #require(layers.firstIndex { $0.name == name }) }
        // A disabled folder mask, a moved and unlinked layer mask, a hidden folder, and a live link to a hidden layer.
        layers[try index("Inner")].mask = LayerMask(asset: try F.ramp(Self.width, Self.height, seed: 6), isEnabled: false)
        var moved = LayerTransform(origin: CGPoint(x: 18, y: 14), size: CGSize(width: 30, height: 24)); moved.sampling = .nearest
        layers[try index("Deep")].mask?.placement = moved
        layers[try index("Deep")].mask?.isLinked = false
        layers[try index("Top")].maskSourceID = try fixture.id("Base")
        var hidden = ImageLayer(name: "Hidden folder", blankSize: CGSize(width: Self.width, height: Self.height))
        hidden.isGroup = true; hidden.isVisible = false; hidden.opacity = 0.4; hidden.parentID = try fixture.id("Outer")
        layers.insert(hidden, at: try index("Inner"))
        layers[try index(LayerBlendMode.overlay.rawValue)].parentID = hidden.id
        s.document?.layers = layers
        s.selectLayer(try fixture.id("Deep"))
        try LayerHierarchy.validate(layers.map(\.hierarchyRecord))

        let snapshot = try #require(s.projectSnapshot())
        let before = try await Self.render(snapshot, float: float)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("LayerGraph-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: url) }
        try await ProjectStore.shared.save(snapshot, to: url)
        let loaded = try await ProjectStore.shared.load(from: url)
        #expect(loaded.manifest.layers.count == layers.count)
        for mode in LayerBlendMode.allCases {
            #expect(loaded.manifest.layers.first { $0.name == mode.rawValue }?.blendMode == mode, "\(mode) is saved by name")
        }
        let reopened = EditorSession()
        reopened.installProject(loaded, from: url)
        let restored = try #require(reopened.document)
        #expect(restored.id == s.document?.id && restored.width == Self.width && restored.height == Self.height)
        #expect(Self.shape(restored.layers) == Self.shape(layers), "identity, order, folders, visibility, opacity, blend, clipping and masks")
        let deepID = try fixture.id("Deep")
        #expect(reopened.activeLayerID == deepID)
        for (made, original) in zip(restored.layers, layers) {
            #expect((made.asset?.linearPlane != nil) == (original.asset?.linearPlane != nil), "\(original.name) keeps its sample format")
        }
        // Every layer's own pixels and every mask's bytes, hidden layers and disabled masks included: the composite
        // shows neither.
        for (made, original) in zip(restored.layers, layers) {
            #expect((made.asset == nil) == (original.asset == nil), "\(original.name) keeps having pixels or none")
            if let madeAsset = made.asset, let originalAsset = original.asset {
                let same = try Self.samples(madeAsset).matches(Self.samples(originalAsset))
                #expect(same == 0, "\(original.name): reopened layer samples differ by \(same)")
            }
            #expect((made.mask == nil) == (original.mask == nil), "\(original.name) keeps having a mask or none")
            if let madeMask = made.mask, let originalMask = original.mask {
                #expect(try Self.maskBytes(madeMask) == Self.maskBytes(originalMask), "\(original.name): reopened mask bytes differ")
            }
        }
        #expect(restored.layers.contains { !$0.isVisible && $0.asset != nil } && restored.layers.contains { $0.mask?.isEnabled == false },
            "the fixture has hidden pixels and a disabled mask to compare")
        let after = try await Self.render(reopened, float: float)
        #expect(after.matches(before) == 0, "reopened pixels differ by \(after.matches(before))")
        if float { #expect(after.isHDR) }
        // Saved again from the reopened session: still the same graph and pixels.
        let again = FileManager.default.temporaryDirectory.appendingPathComponent("LayerGraph-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: again) }
        try await ProjectStore.shared.save(try #require(reopened.projectSnapshot()), to: again)
        let second = EditorSession()
        second.installProject(try await ProjectStore.shared.load(from: again), from: again)
        #expect(Self.shape(try #require(second.document).layers) == Self.shape(layers))
        let secondPixels = try await Self.render(second, float: float)
        #expect(secondPixels.matches(before) == 0)
    }

    // MARK: Live source layers

    /// A private physical directory with a procedural RAW in it, imported the way the product imports one: a live
    /// source layer developed in float.
    private func liveRawSession(_ session: EditorSession = EditorSession()) async throws -> (session: EditorSession, root: URL) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("LayerGraphLive-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        let root = try #require(folder.physicalFileURL)
        let original = root.appendingPathComponent("layer.dng")
        try ProceduralDNG.write(to: original, width: 64, height: 48)
        await session.importImages([original])
        #expect(session.importError == nil, "\(session.importError ?? "")")
        let layer = try #require(session.activeLayer)
        #expect(layer.liveSource != nil && layer.asset?.linearPlane != nil)
        return (session, root)
    }
    /// A recipe change on the active live source layer, committed through Camera Raw as the product commits it.
    private func develop(_ session: EditorSession, _ change: (inout CameraRawSettings) -> Void) async throws {
        session.beginFilter(.cameraRaw)
        let edit = try #require(session.filterEdit)
        #expect(edit.liveSource != nil)
        var settings = edit.settings
        change(&settings.cameraRaw)
        session.updateFilter(settings, preview: false)
        await session.commitFilter()
        #expect(session.filterEdit == nil && session.brushError == nil, "\(session.brushError ?? "")")
    }
    private func exported(_ session: EditorSession) async throws -> [SIMD4<Float>] {
        try F.pixels(try await ImageExporter.shared.renderPlane(try #require(session.projectSnapshot())))
    }

    /// "Bake and Delete" on a live source layer: its pixels are developed afresh from the original on every export
    /// and every recipe change, so the coverage is kept in the layer's mask, not in pixels a development replaces.
    /// The export shows the look from before the deletion, a recipe change keeps the coverage, and undo restores.
    @Test func bakingALiveSourceLayerKeepsItsCoverageThroughExportAndRedevelopment() async throws {
        let (s, root) = try await liveRawSession(); defer { try? FileManager.default.removeItem(at: root) }
        let live = try #require(s.activeLayer)
        // A soft-edged layer, hidden so that only its coverage shows, lends the live layer its alpha.
        var soft = ImageLayer(id: UUID(), asset: F.asset(F.pattern(40, 30, seed: 5), "Soft"), name: "Soft", isVisible: false,
            transform: LayerTransform(origin: CGPoint(x: 10, y: 8), size: CGSize(width: 40, height: 30)), opacity: 0.8)
        soft.transform.sampling = .nearest
        s.document?.layers.append(soft)
        let liveIndex = try #require(s.document?.layers.firstIndex { $0.id == live.id })
        s.document?.layers[liveIndex].maskSourceID = soft.id
        // The live layer has a mask of its own already: the baked coverage is multiplied into it.
        let grid = try #require(live.asset?.image)
        let ownMask = LayerMask(asset: try F.mask(grid.width, grid.height) { x, _ in 90 + x * 2 })
        s.document?.layers[liveIndex].mask = ownMask
        s.selectLayer(live.id)
        s.history.reset()
        let before = try #require(s.document)
        let look = try await exported(s)
        #expect(look.contains { $0.w > 0.05 && $0.w < 0.75 } && look.contains { $0.w == 0 }, "the lent coverage is soft and partial")
        var unmasked = try #require(s.projectSnapshot()); unmasked.masks = [:]
        var bare = unmasked.manifest; for i in bare.layers.indices { bare.layers[i].maskFile = nil }
        let withoutOwnMask = try F.pixels(try await ImageExporter.shared.renderPlane(ProjectSnapshot(manifest: bare, images: unmasked.images)))
        #expect(zip(look, withoutOwnMask).contains { $1.w - $0.w > 0.05 }, "the layer's own mask shows in the look")
        #expect(s.deleteWithLiveMaskChoice([soft.id]) { _ in .bake })
        try await Self.idle(s)
        #expect(s.brushError == nil, "\(s.brushError ?? "")")
        let kept = try #require(s.document?.layers.first { $0.id == live.id })
        #expect(s.document?.layers.count == 1 && s.history.undoCount == 1 && kept.maskSourceID == nil)
        #expect(kept.liveSource == live.liveSource && kept.asset?.image === live.asset?.image, "the source and its developed pixels are untouched")
        #expect(kept.mask?.isEnabled == true && kept.mask?.placement == nil && kept.mask != ownMask, "the coverage is in the layer's mask, in the layer's grid")
        #expect(kept.mask?.asset.image.width == grid.width && kept.mask?.asset.image.height == grid.height)
        let baked = try await exported(s)
        #expect(F.worstRelative(baked, look) <= 1e-4, "the export after the bake differs from the look before it by \(F.worstRelative(baked, look))")
        // A recipe change develops the layer again from its original: the coverage is still there.
        try await develop(s) { $0.exposure = 1 }
        let developed = try #require(s.document?.layers.first { $0.id == live.id })
        #expect(developed.liveSource?.revision != live.liveSource?.revision && developed.asset?.image !== live.asset?.image)
        let after = try await exported(s)
        let alphaError = zip(after, look).map { abs($0.w - $1.w) }.max() ?? 1
        #expect(alphaError <= 1e-4, "the coverage after a recipe change differs by \(alphaError)")
        #expect(zip(after, baked).contains { $0.w > 0.05 && abs($0.x - $1.x) > 0.01 }, "the recipe change shows in the export")
        s.undo(); s.undo()
        #expect(s.document == before && s.history.undoCount == 0)
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    /// Duplicate Layer and Paste of a live source layer: the copy is a live source layer too, with a source node of
    /// its own (same original, development and revision), so a recipe change develops the copy and leaves the
    /// original alone; one undo removes the copy.
    @Test func duplicateAndPasteOfALiveSourceLayerKeepTheCopyDevelopable() async throws {
        let workspace = ProjectWorkspace()
        let (s, root) = try await liveRawSession(workspace.current.session); defer { try? FileManager.default.removeItem(at: root) }
        let live = try #require(s.activeLayer), node = try #require(live.liveSource)
        s.history.reset()
        let before = try #require(s.document)
        for paste in [false, true] {
            let how = paste ? "Paste" : "Duplicate Layer"
            s.selectLayer(live.id)
            if paste { s.copySelection(); #expect(workspace.pasteCopiedLayer()) } else { s.duplicateActiveLayer() }
            #expect(s.brushError == nil, "\(how): \(s.brushError ?? "")")
            let copy = try #require(s.activeLayer), fork = try #require(copy.liveSource, "\(how): the copy keeps a live source")
            #expect(copy.id != live.id && s.document?.layers.count == 2 && s.history.undoCount == 1, "\(how) is one undo step")
            #expect(fork.id != node.id, "\(how): the copy's source has its own identity")
            #expect(fork.revision == node.revision && fork.sourceLineage == node.sourceLineage && fork.original == node.original
                && fork.settings == node.settings && fork.whiteBalance == node.whiteBalance, "\(how): same original and development")
            try fork.validate()
            #expect(copy.asset?.image === live.asset?.image)
            let afterCopy = try #require(s.document)
            // A recipe change on the copy develops the copy, and only the copy.
            try await develop(s) { $0.exposure = 1 }
            let developed = try #require(s.document?.layers.first { $0.id == copy.id }), untouched = try #require(s.document?.layers.first { $0.id == live.id })
            #expect(developed.liveSource?.id == fork.id && developed.liveSource?.revision != fork.revision && developed.liveSource?.settings.exposure == 1, "\(how): the copy took the recipe")
            #expect(developed.asset?.image !== copy.asset?.image, "\(how): the copy was developed again")
            #expect(untouched == live, "\(how): the original layer, its source and its pixels are untouched")
            let copyPixels = try F.pixels(try #require(developed.asset?.linearPlane)), originalPixels = try F.pixels(try #require(untouched.asset?.linearPlane))
            #expect(copyPixels != originalPixels)
            s.undo()
            #expect(s.document == afterCopy)
            s.undo()
            #expect(s.document == before, "\(how): one undo removes the copy")
        }
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    /// A copy's source node carries the layer's retained operations with it, bound to the copy's own identity: a
    /// retouched layer, or one whose retouch sampled the layers around it, copies like any other and stays valid.
    @Test func aForkedSourceNodeRebindsItsRetainedOperations() throws {
        let fixture = FloatRetouchFixture()
        let (retouched, stroke) = try fixture.nodeAndStroke(kind: .paint, width: 8, height: 8, points: [CGPoint(x: 3, y: 3)])
        let fork = try retouched.forked()
        #expect(fork.id != retouched.id && fork.revision == retouched.revision && fork.sourceLineage == retouched.sourceLineage)
        #expect(fork.retouch.count == 1 && fork.retouch.first?.sourceID == fork.id, "the stroke belongs to the copy")
        #expect(fork.retouch.first?.points == stroke.points && fork.retouch.first?.kind == stroke.kind && fork.retouch.first?.upstreamRevision == stroke.upstreamRevision)
        try fork.validate()
        #expect(retouched.retouch.first?.sourceID == retouched.id, "the original keeps its own")
        try retouched.validate()
        // A captured sample-all composite goes with the copy too.
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let sampled = try fixture.sampleAllNode(width: 8, height: 8, overlay: nil, workspace: workspace)
        let sampledFork = try sampled.node.forked()
        #expect(sampledFork.sampleComposites.count == 1 && sampledFork.sampleComposites.first?.sourceID == sampledFork.id)
        #expect(sampledFork.sampleComposites.first?.revision == sampled.revision && sampledFork.sampleComposites.first?.payload == sampled.node.sampleComposites.first?.payload)
        #expect(sampledFork.planeAssets.keys == sampled.node.planeAssets.keys)
        try sampledFork.validate()
        #expect(sampled.node.sampleComposites.first?.sourceID == sampled.node.id)
    }

    /// A live source layer copied into another project stays a live source layer there, with a source node of its
    /// own: the target develops it from the same original, the source project is untouched, and undo removes it.
    @Test func crossDocumentCopyOfALiveSourceLayerStaysDevelopableInTheTarget() async throws {
        let workspace = ProjectWorkspace(), first = workspace.current
        let (source, root) = try await liveRawSession(first.session); defer { try? FileManager.default.removeItem(at: root) }
        let live = try #require(source.activeLayer), node = try #require(live.liveSource)
        source.history.reset()
        let sourceBefore = try #require(source.document)
        let second = workspace.addTab(reuseEmpty: false), target = second.session
        target.createDocument(width: 96, height: 80)
        target.history.reset()
        await workspace.copyLayers([live.id], into: second.id)
        #expect(target.importError == nil && target.brushError == nil, "\(target.importError ?? "") \(target.brushError ?? "")")
        let copy = try #require(target.document?.layers.first), fork = try #require(copy.liveSource, "the copy keeps a live source in the target")
        #expect(target.document?.layers.count == 1 && target.history.undoCount == 1 && copy.id != live.id)
        #expect(fork.id != node.id && fork.revision == node.revision && fork.sourceLineage == node.sourceLineage && fork.original == node.original && fork.settings == node.settings)
        try fork.validate()
        #expect(source.document == sourceBefore && source.history.undoCount == 0, "the source project is untouched")
        // The target exports by developing the copy from its original, and a recipe change there develops it again.
        let exportedBefore = try await exported(target)
        #expect(exportedBefore.contains { $0.w > 0 })
        target.selectLayer(copy.id)
        try await develop(target) { $0.exposure = 1 }
        let developed = try #require(target.document?.layers.first)
        #expect(developed.liveSource?.id == fork.id && developed.liveSource?.revision != fork.revision && developed.asset?.image !== copy.asset?.image)
        let exportedAfter = try await exported(target)
        #expect(exportedAfter != exportedBefore)
        #expect(source.document == sourceBefore, "the recipe change stays in the target")
        target.undo(); target.undo()
        #expect(target.document?.layers.isEmpty == true && target.history.undoCount == 0)
        try await LWSourceDeveloper.shared.drainRetainedSessions()
    }

    // MARK: Layers panel drags, pointer and hosted controls

    private func descendants(_ view: NSView) -> [NSView] { view.subviews + view.subviews.flatMap { descendants($0) } }
    /// Lets SwiftUI and the main queue catch up until `done`, for at most two seconds.
    private func settle(_ view: NSView? = nil, until done: () -> Bool) async {
        let end = Date().addingTimeInterval(2)
        repeat {
            RunLoop.current.run(until: Date().addingTimeInterval(0.02)); view?.layoutSubtreeIfNeeded()
            try? await Task.sleep(for: .milliseconds(5))
        } while !done() && Date() < end
    }
    private func mouse(_ type: NSEvent.EventType, at point: NSPoint, flags: NSEvent.ModifierFlags = [], clicks: Int = 1, in window: NSWindow) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: point, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: clicks, pressure: type == .mouseMoved ? 0 : 1))
    }
    /// Makes `flags` the modifiers of the application's current event, which the panel's hit-testing reads.
    private func setCurrentEventModifiers(_ flags: NSEvent.ModifierFlags) throws {
        let event = try #require(NSEvent.otherEvent(with: .applicationDefined, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0, context: nil, subtype: 0, data1: 0, data2: 0))
        NSApp.postEvent(event, atStart: true)
        let received = NSApp.nextEvent(matching: .applicationDefined, until: Date().addingTimeInterval(2), inMode: .default, dequeue: true)
        #expect(received != nil && NSApp.currentEvent?.modifierFlags.intersection(.deviceIndependentFlagsMask) == flags)
    }
    /// The Layers panel as the product builds it, in a window of its own: its list, with its rows' views.
    private func hostedPanel(_ session: EditorSession) async throws -> (table: LayerTableView, coordinator: NativeLayerList.Coordinator, window: NSWindow, host: NSView) {
        let host = NSHostingView(rootView: LayersPanel(session: session))
        host.frame = CGRect(x: 0, y: 0, width: 252, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        await settle(host) { self.descendants(host).contains { ($0 as? LayerTableView)?.numberOfRows == session.layerRows.count } }
        let table = try #require(descendants(host).compactMap { $0 as? LayerTableView }.first)
        let coordinator = try #require(table.delegate as? NativeLayerList.Coordinator)
        layOut(table, in: window)
        return (table, coordinator, window, host)
    }
    /// Lets the hosted panel follow the session, and gives the list its rows' views again.
    private func layOut(_ table: NSTableView, in window: NSWindow) {
        RunLoop.current.run(until: Date().addingTimeInterval(0.03))
        window.contentView?.layoutSubtreeIfNeeded()
        for row in 0..<table.numberOfRows { _ = table.view(atColumn: 0, row: row, makeIfNecessary: true) }
        table.layoutSubtreeIfNeeded()
    }
    /// A window point over a row's name (away from its thumbnails), or in the strip along its bottom edge.
    private func point(row: Int, strip: Bool = false, in table: NSTableView) -> NSPoint {
        let rect = table.rect(ofRow: row)
        return table.convert(NSPoint(x: rect.maxX - 30, y: strip ? rect.maxY - 3 : rect.minY + 6), to: nil)
    }

    /// Drops on the Layers panel, through the table's own drop validation and acceptance: a layer dropped on a
    /// folder goes into it, an Option-drag copies instead of moving, a mask dragged onto another layer is copied
    /// to it, and what cannot be dropped is refused. Each accepted drop is one undo step.
    @Test(arguments: [false, true])
    func layersPanelDropsMoveCopyAndCarryMasks(_ float: Bool) throws {
        typealias C = NativeLayerList.Coordinator
        let fixture = try Self.fixture(float: float), s = fixture.session
        let (table, coordinator, window) = layerTable(s)
        defer { withExtendedLifetime(window) {} }
        let top = try fixture.id("Top"), outer = try fixture.id("Outer"), inner = try fixture.id("Inner"), deep = try fixture.id("Deep"), backdrop = try fixture.id("Backdrop")
        func row(_ id: UUID) throws -> Int { try #require(s.layerRows.firstIndex { $0.layer.id == id }) }
        func drag(layers: [UUID] = [], mask: UUID? = nil, source: Any?, operations: NSDragOperation = [.move, .copy], over target: Int = 0) -> DragStub {
            let pasteboard = NSPasteboard.withUniqueName()
            if let mask {
                pasteboard.declareTypes([C.maskType], owner: nil); pasteboard.setString(mask.uuidString, forType: C.maskType)
            } else {
                pasteboard.writeObjects(layers.map { id in let item = NSPasteboardItem(); item.setString(id.uuidString, forType: C.layerType); return item })
            }
            return DragStub(pasteboard: pasteboard, source: source, operations: operations, location: point(row: target, in: table), window: window)
        }
        let before = try #require(s.document)
        // A layer dropped on a folder goes into it, on top of what it holds.
        var info = drag(layers: [top], source: table)
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: try row(inner), proposedDropOperation: .on) == .move)
        #expect(coordinator.tableView(table, acceptDrop: info, row: try row(inner), dropOperation: .on))
        coordinator.update(table)
        #expect(try fixture.layer("Top").parentID == inner && s.history.undoCount == 1 && s.selectedLayerIDs == [top])
        #expect(s.layerRows.map(\.layer.id).prefix(4) == [outer, inner, top, deep], "Top is the first row inside Inner")
        s.undo(); coordinator.update(table)
        #expect(s.document == before)
        // With Option held the drag offers only Copy: the layer is copied to where it is dropped.
        info = drag(layers: [top], source: table, operations: .copy)
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: try row(backdrop), proposedDropOperation: .above) == .copy)
        #expect(coordinator.tableView(table, acceptDrop: info, row: try row(backdrop), dropOperation: .above))
        coordinator.update(table)
        let layers = try #require(s.document?.layers)
        #expect(layers.count == before.layers.count + 1 && s.history.undoCount == 1, "an Option-drop is one undo step")
        #expect(layers.last?.id == top && layers.last == before.layers.last, "the original stays where it was")
        #expect(layers[0].id == backdrop && layers[1].name == "Top copy" && layers[1].parentID == nil && layers[1].asset?.image === before.layers.last?.asset?.image,
            "the copy sits where it was dropped, directly above Backdrop")
        s.undo(); coordinator.update(table)
        #expect(s.document == before)
        // A folder cannot be dropped into what it holds, and a drag from another list is not this list's.
        info = drag(layers: [outer], source: table)
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: try row(inner), proposedDropOperation: .on) == [])
        info = drag(layers: [top], source: NSTableView())
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: try row(inner), proposedDropOperation: .on) == [])
        #expect(!coordinator.tableView(table, acceptDrop: info, row: try row(inner), dropOperation: .on) && s.document == before && s.history.undoCount == 0)
        // A mask dragged from its thumbnail lands on the row under the pointer, as a copy.
        info = drag(mask: deep, source: NSObject(), over: try row(top))
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: try row(backdrop), proposedDropOperation: .above) == .copy)
        #expect(coordinator.tableView(table, acceptDrop: info, row: try row(top), dropOperation: .on))
        let masked = try fixture.layer("Top"), lender = try fixture.layer("Deep")
        #expect(masked.mask?.asset.image === lender.mask?.asset.image && masked.mask?.placement == lender.transform && lender.mask == before.layers.first { $0.id == deep }?.mask)
        #expect(s.history.undoCount == 1 && s.isMaskSelected && s.activeLayerID == top)
        s.undo(); coordinator.update(table)
        #expect(s.document == before)
        // A folder takes no copied mask, and neither does the layer the mask came from.
        info = drag(mask: deep, source: NSObject(), over: try row(inner))
        #expect(coordinator.tableView(table, validateDrop: info, proposedRow: try row(inner), proposedDropOperation: .on) == [])
        #expect(!coordinator.tableView(table, acceptDrop: info, row: try row(inner), dropOperation: .on) && s.document == before)
    }

    /// The pointer over the Layers panel. Option over the strip along a row's bottom edge shows the clipping cursor
    /// (create or release, drawn with an outline), and an Option-click there clips or releases the layer; with
    /// Option held the strip's clicks go to the list itself, not to the row's controls. The list tracks the mouse
    /// in one tracking area and watches modifier changes only while it is in a window.
    @Test(arguments: [false, true])
    func layersPanelOptionClickClipsAndTheCursorSaysSo(_ float: Bool) async throws {
        let fixture = try Self.fixture(float: float), s = fixture.session
        // The clipped layer has a stroke: its row lists the effect along the bottom, where the clipping strip is.
        let stroked = try #require(s.document?.layers.firstIndex { $0.name == "Clipped" })
        s.document?.layers[stroked].effects = LayerEffects(stroke: StrokeEffect())
        s.history.reset()
        let (table, _, window, _) = try await hostedPanel(s)
        defer { withExtendedLifetime(window) {} }
        let base = try fixture.id("Base")
        func row(_ name: String) throws -> Int { let id = try fixture.id(name); return try #require(s.layerRows.firstIndex { $0.layer.id == id }) }
        func flag(_ name: String) -> Any? { Mirror(reflecting: table).children.first { $0.label == name }?.value }
        func cursorActive() -> Bool { flag("clippingCursorActive") as? Bool ?? false }
        // An optional reflects as one child when it holds a value and none when it is nil.
        func monitoring() -> Bool { flag("clippingMonitor").map { Mirror(reflecting: $0).children.count == 1 } ?? false }
        #expect(table.session === s)
        // One tracking area, replaced rather than added to.
        table.updateTrackingAreas(); table.updateTrackingAreas()
        let areas = table.trackingAreas.filter { ($0.owner as AnyObject?) === table }
        #expect(areas.count == 1 && areas.first?.options.isSuperset(of: [.inVisibleRect, .mouseEnteredAndExited, .mouseMoved, .cursorUpdate]) == true)
        #expect(table.window === window && monitoring(), "in a window the list watches modifier changes")

        // Option over the strip of a clipped layer offers to release it; the cursor is a drawn, outlined picture.
        let strip = point(row: try row("Clipped"), strip: true, in: table)
        NSCursor.arrow.set()
        table.refreshClippingCursor(.option, at: strip)
        let release = NSCursor.current
        #expect(release !== NSCursor.arrow && release !== CanvasView.duplicateCursor && cursorActive(), "a cursor of its own")
        #expect(release.image.size == NSSize(width: 30, height: 28) && release.hotSpot == NSPoint(x: 3, y: 3))
        func picture(_ cursor: NSCursor) throws -> [SIMD4<Double>] { try F.levels(try #require(cursor.image.cgImage(forProposedRect: nil, context: nil, hints: nil))) }
        let drawn = try picture(release)
        #expect(drawn.contains { $0.w > 200 && $0.x < 40 } && drawn.contains { $0.w > 200 && $0.x > 215 }, "black symbols on a white outline")
        // Leaving the list gives the cursor back.
        table.mouseExited(with: try mouse(.mouseMoved, at: NSPoint(x: -500, y: -500), in: window))
        #expect(NSCursor.current === NSCursor.arrow && !cursorActive())
        // The mouse events feed the same decision.
        for send in [table.mouseEntered(with:), table.mouseMoved(with:), table.cursorUpdate(with:)] {
            NSCursor.arrow.set()
            send(try mouse(.mouseMoved, at: strip, flags: .option, in: window))
            #expect(NSCursor.current === release)
        }
        // A folder is never clipped: over its strip Option offers to duplicate it, like the rest of the row.
        table.refreshClippingCursor(.option, at: point(row: try row("Inner"), strip: true, in: table))
        #expect(NSCursor.current === CanvasView.duplicateCursor)
        // A layer with nothing below it to clip to gets the plain arrow there.
        table.refreshClippingCursor(.option, at: point(row: try row("Backdrop"), strip: true, in: table))
        #expect(NSCursor.current === NSCursor.arrow)

        // The strip runs over the row of the layer's effect. Without Option a click there is the effect's; with
        // Option it is the list's, which clips; above the strip the effect keeps Option for dragging a copy of itself.
        let stripRect = table.rect(ofRow: try row("Clipped"))
        let inStrip = table.superview!.convert(NSPoint(x: stripRect.midX, y: stripRect.maxY - 3), from: table)
        let aboveStrip = table.superview!.convert(NSPoint(x: stripRect.midX, y: stripRect.maxY - 14), from: table)
        #expect(stripRect.height > 60, "the row is taller for its effect")
        try setCurrentEventModifiers([])
        let plain = table.hitTest(inStrip)
        #expect(plain != nil && plain !== table, "without Option the effect's row takes the click")
        try setCurrentEventModifiers(.option)
        #expect(table.hitTest(inStrip) === table, "with Option the strip's click is the list's")
        let above = table.hitTest(aboveStrip)
        #expect(above != nil && above !== table, "above the strip the effect keeps its Option-drag")
        try setCurrentEventModifiers([.option, .command])
        #expect(table.hitTest(inStrip) !== table, "Command-Option is not the clipping gesture")
        try setCurrentEventModifiers([])

        // An Option-click in the strip releases the clipping mask, and again creates it: one undo step each.
        let before = try #require(s.document)
        table.mouseDown(with: try mouse(.leftMouseDown, at: strip, flags: .option, in: window))
        #expect(try fixture.layer("Clipped").maskSourceID == nil && s.history.undoCount == 1)
        table.refreshClippingCursor(.option, at: strip)
        let create = NSCursor.current
        #expect(create !== release && create !== NSCursor.arrow && create !== CanvasView.duplicateCursor && create.image.size == release.image.size,
            "the cursor follows the click: it now offers to create the clipping mask")
        #expect(try picture(create) != drawn, "the two clipping cursors are different pictures")
        layOut(table, in: window)
        table.mouseDown(with: try mouse(.leftMouseDown, at: point(row: try row("Clipped"), strip: true, in: table), flags: .option, in: window))
        #expect(try fixture.layer("Clipped").maskSourceID == base && s.history.undoCount == 2)
        s.undo(); s.undo()
        #expect(s.document == before)
        // Nothing to clip to: the click changes nothing.
        layOut(table, in: window)
        table.mouseDown(with: try mouse(.leftMouseDown, at: point(row: try row("Backdrop"), strip: true, in: table), flags: .option, in: window))
        #expect(s.document == before && s.history.undoCount == 0)

        // Out of its window the list stops watching modifiers.
        table.removeFromSuperview()
        #expect(table.window == nil && !monitoring())
    }

    /// Clicks on the Layers panel: a right-click selects the row under it and opens that row's menu, Select All
    /// selects the canvas (never every layer), a click on a row's name targets the layer when its mask was the
    /// target, a double-click on the name renames it, and a layer's thumbnail can be dragged within the app only.
    @Test(arguments: [false, true])
    func layersPanelClicksSelectRenameAndOpenTheRowMenu(_ float: Bool) async throws {
        typealias C = NativeLayerList.Coordinator
        let fixture = try Self.fixture(float: float), s = fixture.session
        let (table, _, window, _) = try await hostedPanel(s)
        defer { withExtendedLifetime(window) {} }
        let deep = try fixture.id("Deep"), base = try fixture.id("Base"), clipped = try fixture.id("Clipped")
        func row(_ id: UUID) throws -> Int { try #require(s.layerRows.firstIndex { $0.layer.id == id }) }
        let before = try #require(s.document)

        // A right-click on a row that is not selected selects it and opens its menu.
        let menu = try #require(table.menu(for: try mouse(.rightMouseDown, at: point(row: try row(deep), in: table), in: window)))
        #expect(menu.items.contains { $0.action == #selector(C.duplicateLayerAction) } && menu.items.contains { $0.action == #selector(C.deleteMaskAction) && $0.isEnabled })
        let deepRow = try row(deep)
        #expect(s.selectedLayerIDs == [deep] && s.activeLayerID == deep && table.selectedRowIndexes == IndexSet(integer: deepRow))
        // On a row inside a selection of several the selection stays, and that row becomes the active one.
        s.selectLayers([base, clipped], primary: clipped); layOut(table, in: window)
        #expect(table.menu(for: try mouse(.rightMouseDown, at: point(row: try row(base), in: table), in: window)) != nil)
        #expect(s.selectedLayerIDs == [base, clipped] && s.activeLayerID == base)
        // Below the last row there is no menu.
        let below = table.convert(NSPoint(x: 100, y: table.rect(ofRow: table.numberOfRows - 1).maxY + 40), to: nil)
        #expect(table.menu(for: try mouse(.rightMouseDown, at: below, in: window)) == nil)

        // Select All is the canvas's, even with the panel focused.
        s.selectLayer(deep); layOut(table, in: window)
        table.selectAll(nil)
        #expect(s.document?.selection?.path.boundingBoxOfPath == CGRect(x: 0, y: 0, width: Self.width, height: Self.height))
        #expect(s.selectedLayerIDs == [deep] && table.selectedRowIndexes.count == 1, "never every layer")
        s.undo()
        #expect(s.document == before)
        s.history.reset()

        // Real clicks, through the application's event queue, so the table knows which row was clicked. AppKit
        // delivers mouse events only to a window that is on screen.
        window.orderFrontRegardless()
        defer { window.orderOut(nil) }
        func click(_ point: NSPoint, clicks: Int = 1) throws {
            for count in 1...clicks {
                NSApp.postEvent(try mouse(.leftMouseDown, at: point, clicks: count, in: window), atStart: false)
                NSApp.postEvent(try mouse(.leftMouseUp, at: point, clicks: count, in: window), atStart: false)
            }
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date().addingTimeInterval(0.3), inMode: .default, dequeue: true) {
                NSApp.sendEvent(event)
            }
        }
        // With the layer's mask as the target, a click on the row's name targets the layer itself again.
        s.selectLayerTarget(deep, mask: true); layOut(table, in: window)
        #expect(s.isMaskSelected && table.selectedRowIndexes == IndexSet(integer: deepRow))
        try click(point(row: try row(deep), in: table))
        #expect(!s.isMaskSelected && s.activeLayerID == deep && s.document == before)
        // A double-click on the name renames the layer.
        #expect(s.renamingLayerID == nil)
        try click(point(row: try row(base), in: table), clicks: 2)
        #expect(s.renamingLayerID == base && s.activeLayerID == base && s.document == before)
        s.renamingLayerID = nil

        // A layer's thumbnail is a drag source inside the application (onto another row, or another project's tab).
        let thumbnails = descendants(table).filter { String(describing: type(of: $0)) == "LayerThumbnailButton" }.compactMap { $0 as? NSDraggingSource }
        let thumbnail = try #require(thumbnails.first)
        #expect(thumbnail.draggingSession(NSDraggingSession(), sourceOperationMaskFor: .withinApplication) == .copy)
        #expect(thumbnail.draggingSession(NSDraggingSession(), sourceOperationMaskFor: .outsideApplication) == [])
    }

    /// The Layers panel as the product builds it, hosted in a window: the list, the blend menu, the opacity
    /// controls, the mask button and the footer are all bound to the session and follow it.
    @Test func hostedLayersPanelBindsEveryControlToTheSession() async throws {
        let fixture = try Self.fixture(float: false), s = fixture.session
        let deep = try fixture.id("Deep"), base = try fixture.id("Base"), outer = try fixture.id("Outer"), top = try fixture.id("Top")
        s.selectLayer(deep)
        #expect(LayersPanel(session: s).width == 252 && LayersPanel.widths == 202...352)
        let host = NSHostingView(rootView: LayersPanel(session: s, width: 300))
        host.frame = CGRect(x: 0, y: 0, width: 300, height: 700)
        let window = NSWindow(contentRect: host.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = host
        defer { withExtendedLifetime(window) {} }
        await settle(host) { self.descendants(host).contains { $0 is LayerTableView } }
        #expect(host.fittingSize.width == 300, "the panel is as wide as it is told to be")

        // The list.
        let table = try #require(descendants(host).compactMap { $0 as? LayerTableView }.first)
        let coordinator = try #require(table.delegate as? NativeLayerList.Coordinator)
        #expect(table.session === s && coordinator.session === s && table.dataSource === coordinator && table.target === coordinator)
        #expect(table.numberOfRows == s.layerRows.count && table.accessibilityIdentifier() == "layersList" && table.allowsMultipleSelection)
        #expect(table.action == #selector(NativeLayerList.Coordinator.clickedLayer(_:)) && table.doubleAction == #selector(NativeLayerList.Coordinator.renameClickedLayer(_:)))
        #expect(Set(table.registeredDraggedTypes).isSuperset(of: [NativeLayerList.Coordinator.layerType, NativeLayerList.Coordinator.maskType]))
        #expect(table.selectedRowIndexes == IndexSet(integer: try #require(s.layerRows.firstIndex { $0.layer.id == deep })))
        s.addBlankLayer()
        await settle(host) { table.numberOfRows == s.layerRows.count }
        #expect(table.numberOfRows == 8, "the list follows the document")
        s.undo()
        await settle(host) { table.numberOfRows == 7 }

        // The blend menu: every mode in its groups, showing the active layer's, disabled for a folder. The controls
        // are rebuilt for each active layer, so the menu is looked up again after the selection changes.
        func blendMenu() -> NSPopUpButton? { descendants(host).compactMap { $0 as? NSPopUpButton }.first { $0.accessibilityLabel() == "Blend mode" && $0.window != nil } }
        var popup = try #require(blendMenu())
        var picker = try #require(popup.menu?.delegate as? BlendModePicker.Coordinator)
        #expect(picker.session === s && popup.target === picker && popup.action == #selector(BlendModePicker.Coordinator.choose(_:)))
        #expect(BlendModePicker(session: s).makeCoordinator().session === s)
        #expect(popup.itemTitles.filter { !$0.isEmpty } == LayerBlendMode.groups.flatMap { $0 }.map(\.rawValue))
        #expect(popup.menu?.items.filter(\.isSeparatorItem).count == LayerBlendMode.groups.count - 1)
        #expect(popup.titleOfSelectedItem == LayerBlendMode.screen.rawValue && popup.isEnabled)
        s.selectLayer(base)
        await settle(host) { blendMenu()?.titleOfSelectedItem == LayerBlendMode.hardLight.rawValue }
        #expect(blendMenu()?.titleOfSelectedItem == LayerBlendMode.hardLight.rawValue && blendMenu()?.isEnabled == true)
        s.selectLayer(outer)
        await settle(host) { blendMenu()?.isEnabled == false }
        #expect(blendMenu()?.isEnabled == false, "a folder has no blend mode")
        // Highlighting previews; closing the menu without choosing ends the preview.
        s.selectLayer(deep)
        await settle(host) { blendMenu()?.isEnabled == true && blendMenu()?.titleOfSelectedItem == LayerBlendMode.screen.rawValue }
        popup = try #require(blendMenu()); picker = try #require(popup.menu?.delegate as? BlendModePicker.Coordinator)
        let menu = try #require(popup.menu)
        picker.menuWillOpen(menu)
        picker.menu(menu, willHighlight: menu.item(withTitle: LayerBlendMode.difference.rawValue))
        let previewed = s.displayedBlendMode(for: try fixture.layer("Deep"))
        #expect(previewed == .difference && picker.tracking)
        picker.menuDidClose(menu)
        #expect(!picker.tracking)
        await settle { s.displayedBlendMode(for: s.document!.layers.first { $0.id == deep }!) == .screen }
        let restored = s.displayedBlendMode(for: try fixture.layer("Deep"))
        #expect(restored == .screen && s.history.undoCount == 0, "a cancelled menu leaves the layer's own mode")
        // Taking the menu away while it is open ends the preview too.
        picker.menuWillOpen(menu)
        picker.menu(menu, willHighlight: menu.item(withTitle: LayerBlendMode.multiply.rawValue))
        BlendModePicker.dismantleNSView(popup, coordinator: picker)
        let dismantled = s.displayedBlendMode(for: try fixture.layer("Deep"))
        #expect(dismantled == .screen && popup.menu?.delegate == nil)
        popup.menu?.delegate = picker; picker.menuDidClose(menu)
        await settle { !picker.tracking }

        // Opacity: the percent field shows the active layer's, and the slider sets it as one undo step.
        func percentField() -> NSTextField? { descendants(host).compactMap { $0 as? NSTextField }.first { $0.placeholderString == "Opacity percent" } }
        s.selectLayer(base)
        await settle(host) { percentField()?.stringValue == "80" }
        #expect(percentField()?.stringValue == "80" && percentField()?.isEnabled == true)
        let slider = try #require(descendants(host).compactMap { $0 as? NSSlider }.first)
        slider.doubleValue = slider.minValue + (slider.maxValue - slider.minValue) * 0.35
        #expect(slider.sendAction(slider.action, to: slider.target))
        await settle(host) { percentField()?.stringValue == "35" }
        #expect(abs((try fixture.layer("Base").opacity) - 0.35) < 1e-9 && s.history.undoCount == 1 && percentField()?.stringValue == "35")
        s.undo()
        await settle(host) { percentField()?.stringValue == "80" }
        #expect(try fixture.layer("Base").opacity == 0.8 && percentField()?.stringValue == "80")
        s.history.reset()

        // The mask button, on its own so that its middle is where a click lands: a click adds a white mask, an
        // Option-click a black one, and a layer that has a mask cannot be given another.
        let button = NSHostingView(rootView: LayerMaskMenu(session: s))
        button.frame = CGRect(origin: .zero, size: button.fittingSize)
        let buttonWindow = NSWindow(contentRect: button.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        buttonWindow.contentView = button
        defer { withExtendedLifetime(buttonWindow) {} }
        buttonWindow.orderFrontRegardless()
        defer { buttonWindow.orderOut(nil) }
        func press(_ flags: NSEvent.ModifierFlags = []) async throws {
            let middle = NSPoint(x: button.bounds.midX, y: button.bounds.midY)
            NSApp.postEvent(try mouse(.leftMouseDown, at: middle, flags: flags, in: buttonWindow), atStart: false)
            NSApp.postEvent(try mouse(.leftMouseUp, at: middle, flags: flags, in: buttonWindow), atStart: false)
            while let event = NSApp.nextEvent(matching: [.leftMouseDown, .leftMouseUp], until: Date().addingTimeInterval(0.3), inMode: .default, dequeue: true) { NSApp.sendEvent(event) }
            RunLoop.current.run(until: Date().addingTimeInterval(0.05)); try await Task.sleep(for: .milliseconds(30))
        }
        s.selectLayer(top)
        await settle(button) { button.fittingSize.width > 20 }
        try await press()
        let white = try #require(try fixture.layer("Top").mask, "a click on the mask button adds a mask")
        #expect(LayerMask.background(of: white.asset.thumbnail) == 1 && s.history.undoCount == 1, "a white mask, one undo step")
        try await press()
        #expect(try fixture.layer("Top").mask == white && s.history.undoCount == 1, "a layer has one mask: the button is disabled")
        s.undo()
        try await press(.option)
        let black = try #require(try fixture.layer("Top").mask, "an Option-click adds a mask too")
        #expect(LayerMask.background(of: black.asset.thumbnail) == 0 && s.history.undoCount == 1, "a black mask with Option")
        try setCurrentEventModifiers([])
        // The footer's icons take an 8 pt by 12 pt margin as their hit area.
        let icon = NSHostingView(rootView: Color.clear.frame(width: 10, height: 10).footerHitArea())
        #expect(icon.fittingSize == CGSize(width: 26, height: 34))

        // Showing a mask alone puts up a badge naming the layer; its button goes back to the image.
        s.toggleMaskAlone(top)
        let alone = try #require(s.maskAloneLayer)
        let badgeHost = NSHostingView(rootView: MaskAloneBadge(session: s, layer: alone).fixedSize())
        badgeHost.frame = CGRect(x: 0, y: 0, width: 400, height: 60)
        let badgeWindow = NSWindow(contentRect: badgeHost.frame, styleMask: [.borderless], backing: .buffered, defer: false)
        badgeWindow.contentView = badgeHost
        defer { withExtendedLifetime(badgeWindow) {} }
        await settle(badgeHost) { self.descendants(badgeHost).contains { $0 is MaskAloneBadgeView } }
        let badge = try #require(descendants(badgeHost).compactMap { $0 as? MaskAloneBadgeView }.first)
        await settle(badgeHost) { badge.layerName == "Top" }
        #expect(badge.layerName == "Top" && descendants(badge).contains { ($0 as? NSTextField)?.stringValue == "Top" })
        #expect(badge.acceptsFirstMouse(for: nil), "its button works on the first click, as the canvas under it does")
        #expect(s.viewsMaskAlone)
        try #require(descendants(badge).compactMap { $0 as? NSButton }.first).performClick(nil)
        #expect(!s.viewsMaskAlone && s.maskAloneLayer == nil)
    }
}

/// A drag in progress, as the Layers panel's table sees one: a pasteboard, where it came from, the operations its
/// source allows and where the pointer is.
private final class DragStub: NSObject, NSDraggingInfo {
    let draggingPasteboard: NSPasteboard
    let draggingSource: Any?
    let draggingSourceOperationMask: NSDragOperation
    let draggingLocation: NSPoint
    let draggingDestinationWindow: NSWindow?
    init(pasteboard: NSPasteboard, source: Any?, operations: NSDragOperation, location: NSPoint, window: NSWindow) {
        draggingPasteboard = pasteboard; draggingSource = source; draggingSourceOperationMask = operations
        draggingLocation = location; draggingDestinationWindow = window
    }
    deinit { draggingPasteboard.releaseGlobally() }
    var draggedImageLocation: NSPoint { draggingLocation }
    var draggedImage: NSImage? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 0
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options: NSDraggingItemEnumerationOptions = [], for view: NSView?, classes: [AnyClass],
                                searchOptions: [NSPasteboard.ReadingOptionKey: Any] = [:], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}
