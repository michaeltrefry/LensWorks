import Testing
import AppKit
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
    /// its own against the fixture: it changes the graph, the document still composites, and one undo puts the
    /// graph back exactly.
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
            try operation.run(fixture)
            #expect(s.commandRefusal == nil, "\(operation.name): \(s.commandRefusal ?? "")")
            let after = try #require(s.document)
            #expect(after != before, "\(operation.name) changed nothing")
            #expect(s.history.undoCount == 1, "\(operation.name) is one undo step, not \(s.history.undoCount)")
            try LayerHierarchy.validate(after.layers.map(\.hierarchyRecord)); try LiveMaskGraph.validate(after.layers.map(\.hierarchyRecord))
            _ = try await Self.render(s, float: float)
            s.undo()
            #expect(s.document == before, "\(operation.name): undo did not restore the graph")
            s.redo()
            #expect(s.document == after, "\(operation.name): redo did not reapply")
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

    /// Deleting a layer that lends its alpha: "Bake and Delete" keeps the dependent layer's look in its own pixels,
    /// at its own precision; "Remove Links and Delete" reveals it. Either is one undo step.
    @Test(arguments: [false, true])
    func deletingALiveMaskSourceBakesOrRemovesTheLink(_ float: Bool) async throws {
        let fixture = try Self.fixture(float: float), s = fixture.session
        let top = try fixture.id("Top"), deep = try fixture.id("Deep")
        #expect(s.linkMask(source: top, target: deep))
        s.history.reset()
        let before = try #require(s.document)
        let look = try await Self.renderOnly([deep, top], of: hiding(top, in: s), float: float)
        let snapshot = try #require(s.projectSnapshot())
        let baked = try #require(try LiveMaskBaker.bake(snapshot, target: deep))
        #expect((baked.linearPlane != nil) == float)
        s.finishDeletingLayers([top], baked: [deep: baked])
        #expect(s.history.undoCount == 1 && s.document?.layers.contains { $0.id == top } == false)
        let kept = try fixture.layer("Deep")
        #expect(kept.maskSourceID == nil && kept.mask == before.layers.first { $0.id == deep }?.mask)
        let after = try await Self.renderOnly([deep], of: s, float: float)
        #expect(after.matches(look) <= (float ? 1e-5 : 2), "baked look differs by \(after.matches(look))")
        if float { #expect(after.isHDR) }
        s.undo()
        #expect(s.document == before)
        // Remove Links and Delete.
        s.finishDeletingLayers([top], baked: [:])
        let revealed = try fixture.layer("Deep")
        #expect(revealed.maskSourceID == nil && revealed.asset?.image === before.layers.first { $0.id == deep }?.asset?.image)
        s.undo()
        #expect(s.document == before)
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
        let before = try #require(s.document), undoCount = s.history.undoCount
        let expected = try await Self.renderOnly(removedIDs, of: s, float: float)
        s.mergeLayers()
        let merged = try #require(s.activeLayer)
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
        s.redo()
        #expect(s.document == after)
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
        #expect(s.history.undoCount == 1)
        s.undo()
        #expect(s.document == before)
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
        s.undo()
        #expect(s.document == before)
        s.redo()
        #expect(s.document == after)
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
        let after = try #require(target.document)
        target.undo()
        #expect(target.document?.layers.isEmpty == true && source.document == sourceBefore)
        target.redo()
        #expect(target.document == after)
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
}
