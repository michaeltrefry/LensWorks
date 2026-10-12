import Foundation

/// Every action a menu item or keyboard shortcut can reach. A menu item, context-menu item, pull-down item or key
/// binding that is not one of these is a registry bypass, and the command audit (CommandAuditTests and
/// scripts/ci/command_registry_audit.py) fails naming it.
nonisolated enum LensWorksCommandID: String, Codable, CaseIterable, Sendable {
    // S38 typed layer and catalog-recipe commands.
    case visibility = "layer.visibility"
    case opacity = "layer.opacity"
    case rename = "layer.rename"
    case beginRename = "layer.rename.begin"
    case firstVariants = "catalog.variants.first"
    case moreVariants = "catalog.variants.more"
    case selectVariant = "catalog.variant.select"
    case copy = "catalog.recipe.copy"
    case exposure = "catalog.recipe.exposure"
    case undoRecipe = "catalog.recipe.undo"
    case redoRecipe = "catalog.recipe.redo"
    case rating = "catalog.rating"
    // App menu.
    case hideApp = "app.hide", hideOthers = "app.hideOthers", showAll = "app.showAll"
    // File.
    case openCatalog = "file.catalog.open", newCatalog = "file.catalog.new", addPhotos = "file.catalog.addPhotos"
    case newCanvas = "file.newCanvas", openProject = "file.openProject", openRecent = "file.openRecent"
    case clearRecent = "file.openRecent.clear", importImages = "file.importImages", save = "file.save"
    case saveAs = "file.saveAs", exportPNG = "file.exportPNG", exportJPEG = "file.exportJPEG", closeProject = "file.closeProject"
    // Edit.
    case undo = "edit.undo", redo = "edit.redo", cut = "edit.cut", copyPixels = "edit.copy"
    case copyMerged = "edit.copyMerged", paste = "edit.paste", keyboardShortcuts = "edit.keyboardShortcuts", aiModels = "edit.aiModels"
    case fillForeground = "edit.fillForeground", fillBackground = "edit.fillBackground"
    case clearSelectionPixels = "edit.clearSelectionPixels", contentAwareFill = "edit.contentAwareFill"
    // View.
    case fitCanvas = "view.fit", actualPixels = "view.actualPixels", zoomIn = "view.zoomIn", zoomOut = "view.zoomOut"
    case pixelGrid = "view.pixelGrid", smartSnap = "view.smartSnap", transformControls = "view.transformControls"
    case showGrid = "view.show.grid", showGuides = "view.show.guides", gridSettings = "view.gridSettings"
    case rulers = "view.rulers", snap = "view.snap", snapToGuides = "view.snapTo.guides", snapToGrid = "view.snapTo.grid"
    case snapToLayers = "view.snapTo.layers", snapToBounds = "view.snapTo.documentBounds"
    case lockGuides = "view.lockGuides", clearGuides = "view.clearGuides"
    // Select.
    case selectAll = "select.all", deselect = "select.deselect", inverseSelection = "select.inverse"
    case selectLayerPixels = "select.layerPixels", selectSubject = "select.subject", colorRange = "select.colorRange"
    case selectMaskBlack = "select.maskBlackAreas", expandSelection = "select.expand"
    case contractSelection = "select.contract", featherSelection = "select.feather"
    // Image and Filter.
    case curves = "image.curves", levels = "image.levels", hueSaturation = "image.hueSaturation"
    case imageAdjustment = "image.adjustment", invert = "image.invert", canvasSize = "image.canvasSize"
    case imageSize = "image.imageSize", trim = "image.trim", flipCanvasHorizontal = "image.flipCanvasHorizontal"
    case flipCanvasVertical = "image.flipCanvasVertical", filter = "filter.apply"
    // Layer.
    case newAdjustment = "layer.newAdjustment", editAdjustment = "layer.editAdjustment"
    case transform = "layer.transform", layerViaCopy = "layer.viaCopy", duplicateLayer = "layer.duplicate"
    case clippingMask = "layer.clippingMask", groupLayers = "layer.group", ungroupLayers = "layer.ungroup"
    case moveOutOfFolder = "layer.moveOutOfFolder", newBlankLayer = "layer.newBlank"
    case moveLayerUp = "layer.moveUp", moveLayerDown = "layer.moveDown", mergeLayers = "layer.merge"
    case flipLayerHorizontal = "layer.flipHorizontal", flipLayerVertical = "layer.flipVertical"
    case deleteLayer = "layer.delete", addMask = "layer.mask.add", toggleMask = "layer.mask.toggle"
    case deleteMask = "layer.mask.delete", linkMask = "layer.mask.link", addEffect = "layer.effect.add"
    case blendMode = "layer.blendMode", opacityDigit = "layer.opacityDigit"
    // Canvas and tools.
    case selectTool = "tool.select", moveTool = "tool.move", handTool = "tool.hand", zoomTool = "tool.zoom"
    case brushTool = "tool.brush", eraserTool = "tool.eraser", spotHealingTool = "tool.spotHealing"
    case cloneStampTool = "tool.cloneStamp", typeTool = "tool.type", gradientTool = "tool.gradient"
    case shapeTool = "tool.shape", eyedropperTool = "tool.eyedropper", marqueeTool = "tool.marquee"
    case magicTool = "tool.magic", lassoTool = "tool.lasso", blurTool = "tool.blur", cropTool = "tool.crop"
    case swapColors = "palette.swap", resetColors = "palette.reset", cycleToolMode = "tool.cycleMode"
    case temporaryHand = "tool.temporaryHand", cycleShapeKind = "tool.shape.cycleKind"
    case canvasDelete = "canvas.delete", apply = "canvas.apply", cancel = "canvas.cancel"
    case brushSize = "brush.size", brushHardness = "brush.hardness"
    case nudge = "canvas.nudge", movePixels = "canvas.movePixels", levelsPreview = "levels.togglePreview"
    case finishText = "text.finish", tracking = "text.tracking", leading = "text.leading"
    case stepField = "field.step", saveShortcuts = "shortcuts.save", cancelShortcuts = "shortcuts.cancel"
    case cameraRawScope = "cameraRaw.scope", selectProjectTab = "project.tab.select"
    case cancelField = "field.cancel", canvasPreset = "file.newCanvas.preset"
    // Catalog browser.
    case locateFolder = "catalog.folder.locate", addToVirtualFolder = "catalog.virtualFolder.addSelected"
    case removeFromVirtualFolder = "catalog.virtualFolder.removeSelected"
    case renameVirtualFolder = "catalog.virtualFolder.rename", moveVirtualFolder = "catalog.virtualFolder.move"
    case deleteVirtualFolder = "catalog.virtualFolder.delete", showNestedKeywords = "catalog.keyword.showNested"
    case addKeyword = "catalog.keyword.addToSelected", removeKeyword = "catalog.keyword.removeFromSelected"
    case renameKeyword = "catalog.keyword.rename", moveKeyword = "catalog.keyword.move"
    case addSynonym = "catalog.keyword.addSynonym", deleteKeyword = "catalog.keyword.delete"
    case openInEditor = "catalog.asset.openInEditor", sortBy = "catalog.sort", sortDirection = "catalog.sortDirection"
    case ratePhotos = "catalog.organize.rate", flagPhotos = "catalog.organize.flag", labelPhotos = "catalog.organize.label"
    case moveCatalogSelection = "catalog.selection.move", filterRating = "catalog.filter.rating"
    case filterFlag = "catalog.filter.flag", filterLabel = "catalog.filter.label"
    case filterAnyKeyword = "catalog.filter.anyKeyword", clearFilters = "catalog.filter.clear"
    // Settings › Automation and the agent confirmation sheet. Never invocable by an agent.
    case automationEnabled = "automation.enabled", automationShowSecret = "automation.secret.show"
    case automationCopySecret = "automation.secret.copy", automationRegenerateSecret = "automation.secret.regenerate"
    case automationRevokeSecret = "automation.secret.revoke", automationCopyConfiguration = "automation.configuration.copy"
    case automationAllow = "automation.confirmation.allow", automationDecline = "automation.confirmation.decline"
}
nonisolated enum LensWorksCommandHistoryOwner: String, Codable, Sendable {
    case document, nativeRecipe, nativeMetadata, none
}
nonisolated enum LensWorksCommandParameterType: String, Codable, Sendable {
    case uuid, uuidArray, optionalBoolean, unitInterval, layerName, cursor, variant, catalogCopyName, exposure, rating
    /// One value from the closed set the description names.
    case choice
    /// An identity the invoking surface owns (a recent file, project tab, folder or keyword).
    case reference
}
nonisolated struct LensWorksCommandParameter: Codable, Sendable {
    let name: String
    let type: LensWorksCommandParameterType
    let description: String
}
nonisolated struct LensWorksCommandShortcut: Codable, Equatable, Sendable {
    let key: String
    let modifiers: Int
    init(_ key: String, _ modifiers: Int) { self.key = key; self.modifiers = modifiers }
}
/// Where a binding is live. Bindings in one scope never shadow another scope's keys except Menus, which are
/// window-wide; Canvas & Layers and Text Editing share the editor's key space.
nonisolated enum LensWorksShortcutScope: String, Codable, CaseIterable, Sendable {
    case menu = "Menus", canvas = "Canvas & Layers", text = "Text Editing", catalog = "Catalog"
    /// Focused numeric fields and the shortcut editor itself; fixed, so not listed in the shortcut editor.
    case field = "Fields", dialog = "Shortcut Editor"
    func overlaps(_ other: Self) -> Bool {
        let editor: Set<Self> = [.menu, .canvas, .text]
        if self == other || self == .menu || other == .menu { return true }
        return editor.contains(self) && editor.contains(other)
    }
}
/// How a binding's modifiers compare with a key press: exactly; at least these (the press may add more); or any.
nonisolated enum LensWorksModifierMatch: String, Codable, Sendable { case exact, atLeast, any }
nonisolated struct LensWorksCommandBinding: Codable, Sendable {
    let title: String
    let scope: LensWorksShortcutScope
    let chord: LensWorksCommandShortcut
    var argument: String? = nil
    var modifierMatch: LensWorksModifierMatch = .exact
    var configurable: Bool { scope != .field && scope != .dialog }
}
nonisolated enum LensWorksTitleMatch: String, Codable, Sendable {
    /// One of `titles`, optionally followed by " — reason".
    case exact
    /// A title starting with one of `titles` and a space (Undo Brush Stroke).
    case prefix
    /// Any title: the item names a user's file or tab, and its menu path identifies the command.
    case any
}
nonisolated struct LensWorksCommandDescriptor: Codable, Identifiable, Sendable {
    let id: LensWorksCommandID
    let label: String
    /// The primary menu path ("File", "View/Show", "Layers Panel/Add Mask"); `menus` lists every path it appears in.
    let menu: String
    let menus: [String]
    let titles: [String]
    let titleMatch: LensWorksTitleMatch
    let bindings: [LensWorksCommandBinding]
    let parameters: [LensWorksCommandParameter]
    let undoable: Bool
    let historyOwner: LensWorksCommandHistoryOwner
    /// A permanent change nothing in the app can undo: when an agent asks for it, the person confirms it in the app
    /// before it runs.
    let requiresAgentConfirmation: Bool
    /// The first default chord, for single-binding commands.
    var shortcut: LensWorksCommandShortcut? { bindings.first?.chord }
    init(id: LensWorksCommandID, label: String, menu: String, menus: [String]? = nil, titles: [String]? = nil,
         titleMatch: LensWorksTitleMatch = .exact, bindings: [LensWorksCommandBinding] = [],
         parameters: [LensWorksCommandParameter] = [], undoable: Bool = false, historyOwner: LensWorksCommandHistoryOwner = .none,
         requiresAgentConfirmation: Bool = false) {
        self.id = id; self.label = label; self.menu = menu; self.menus = menus ?? [menu]
        self.titles = titles ?? [label]; self.titleMatch = titleMatch; self.bindings = bindings
        self.parameters = parameters; self.undoable = undoable; self.historyOwner = historyOwner
        self.requiresAgentConfirmation = requiresAgentConfirmation
    }
    /// Whether a rendered menu item titled `title` is this command (a disabled reason may follow " — ").
    func accepts(title: String) -> Bool {
        let base = title.components(separatedBy: " — ").first ?? title
        switch titleMatch {
        case .exact: return titles.contains(base)
        case .prefix: return titles.contains { base == $0 || base.hasPrefix($0 + " ") }
        case .any: return true
        }
    }
}

nonisolated private func bind(_ title: String, _ scope: LensWorksShortcutScope, _ key: String, _ modifiers: Int = 0,
                              argument: String? = nil, match: LensWorksModifierMatch = .exact) -> LensWorksCommandBinding {
    .init(title: title, scope: scope, chord: .init(key, modifiers), argument: argument, modifierMatch: match)
}
nonisolated private func menuKey(_ title: String, _ key: String, _ modifiers: Int) -> [LensWorksCommandBinding] {
    [bind(title, .menu, key, modifiers)]
}
nonisolated private func choice(_ name: String, _ values: [String]) -> [LensWorksCommandParameter] {
    [.init(name: name, type: .choice, description: "One of: " + values.joined(separator: ", ") + ".")]
}
nonisolated private func reference(_ name: String, _ description: String) -> [LensWorksCommandParameter] {
    [.init(name: name, type: .reference, description: description)]
}

nonisolated enum LensWorksCommandRegistry {
    static let catalogLabels = ["Red", "Yellow", "Green", "Blue", "Purple"]
    static let imageAdjustmentKinds: [FilterKind] = [.blackWhite, .colorBalance, .exposure, .gradientMap, .grain]
    static let filterMenuKinds = FilterKind.allCases.filter { $0 != .contentAwareFill && !$0.isImageAdjustment }
    static let directions: [(name: String, key: String)] = [("Left", "\u{f702}"), ("Right", "\u{f703}"), ("Up", "\u{f700}"), ("Down", "\u{f701}")]

    static let descriptors: [LensWorksCommandDescriptor] = {
        let groups: [[LensWorksCommandDescriptor]] = [layerAndRecipe, appMenu, fileMenu, editMenu, viewMenu, selectMenu, imageMenu, layerMenu, canvas, panels, catalogBrowser, automation]
        return groups.flatMap { $0 }
    }()

    private static let variantParameter = LensWorksCommandParameter(name: "expected", type: .variant, description: "Required current full VariantKey, revision and recipe digest captured before dispatch.")
    private static let layerAndRecipe: [LensWorksCommandDescriptor] = [
        .init(id: .visibility, label: "Hide/Show Layer", menu: "Layer", menus: ["Layer", "Layers Panel"], titles: ["Hide Layer", "Show Layer"], bindings: menuKey("Hide/Show Layer", "h", 9), parameters: [.init(name: "layers", type: .uuidArray, description: "Exact layer identities in the admitted document; visibility toggles or an explicit Bool."), .init(name: "visible", type: .optionalBoolean, description: "Nil toggles each admitted layer; Bool sets explicit visibility.")], undoable: true, historyOwner: .document),
        .init(id: .opacity, label: "Layer Opacity", menu: "Layer/Appearance", parameters: [.init(name: "layers", type: .uuidArray, description: "Exact layer UUIDs in the admitted document."), .init(name: "opacity", type: .unitInterval, description: "Finite value from 0 through 1 applied to the admitted layer identities.")], undoable: true, historyOwner: .document),
        .init(id: .rename, label: "Rename Layer", menu: "Layer", parameters: [.init(name: "layer", type: .uuid, description: "Exact admitted layer UUID."), .init(name: "name", type: .layerName, description: "Nonempty trimmed name, at most 16,384 UTF-8 bytes, for one exact layer UUID.")], undoable: true, historyOwner: .document),
        .init(id: .beginRename, label: "Rename Layer…", menu: "Layer", menus: ["Layer", "Layers Panel"], parameters: [.init(name: "layer", type: .uuid, description: "The exact layer to name in this admitted document.")]),
        .init(id: .firstVariants, label: "First Catalog Copies", menu: "Catalog/Recipe", parameters: [variantParameter]),
        .init(id: .moreVariants, label: "More Catalog Copies", menu: "Catalog/Recipe", parameters: [variantParameter, .init(name: "cursor", type: .cursor, description: "Exact continuing cursor from the admitted page.")]),
        .init(id: .selectVariant, label: "Select Catalog Version", menu: "Catalog/Recipe", parameters: [variantParameter, .init(name: "variant", type: .variant, description: "Full native VariantKey and revision from this admitted photo's variant page.")]),
        .init(id: .copy, label: "Create Named Catalog Copy", menu: "Catalog/Recipe", parameters: [variantParameter, .init(name: "label", type: .catalogCopyName, description: "Nonempty catalog version name, at most 1,024 UTF-8 bytes.")], historyOwner: .nativeRecipe),
        .init(id: .exposure, label: "Apply Catalog Exposure", menu: "Catalog/Recipe", parameters: [variantParameter, .init(name: "exposureEV", type: .exposure, description: "Finite native recipe exposure; full VariantKey, revision and recipe digest CAS are captured synchronously.")], undoable: true, historyOwner: .nativeRecipe),
        .init(id: .undoRecipe, label: "Undo Catalog Recipe", menu: "Catalog/Recipe", parameters: [variantParameter], historyOwner: .nativeRecipe),
        .init(id: .redoRecipe, label: "Redo Catalog Recipe", menu: "Catalog/Recipe", parameters: [variantParameter], historyOwner: .nativeRecipe),
        .init(id: .rating, label: "Catalog Rating", menu: "Catalog/Recipe", menus: ["Catalog/Recipe", "Catalog Recipe/Catalog Rating"], titles: ["Unrated", "1", "2", "3", "4", "5"], parameters: [variantParameter, .init(name: "rating", type: .rating, description: "0 (unrated) through 5; native metadata revision CAS owns publication.")], historyOwner: .nativeMetadata)
    ]
    private static let appMenu: [LensWorksCommandDescriptor] = [
        .init(id: .hideApp, label: "Hide LensWorks", menu: "App"),
        // The binding keeps its historical title so saved custom shortcuts still apply.
        .init(id: .hideOthers, label: "Hide Others", menu: "App", bindings: menuKey("Hide Compositor", "h", 3)),
        .init(id: .showAll, label: "Show All", menu: "App")
    ]
    private static let fileMenu: [LensWorksCommandDescriptor] = [
        .init(id: .openCatalog, label: "Open Catalog…", menu: "File"),
        .init(id: .newCatalog, label: "New Catalog…", menu: "File"),
        .init(id: .addPhotos, label: "Add Photos to Catalog…", menu: "File"),
        .init(id: .newCanvas, label: "New Canvas…", menu: "File", bindings: menuKey("New Canvas", "n", 1)),
        .init(id: .openProject, label: "Open Project…", menu: "File", bindings: menuKey("Open Project", "o", 1)),
        .init(id: .openRecent, label: "Open Recent Project", menu: "File/Open Recent", titleMatch: .any, parameters: reference("project", "A project file listed in Open Recent.")),
        .init(id: .clearRecent, label: "Clear Menu", menu: "File/Open Recent"),
        .init(id: .importImages, label: "Import Images…", menu: "File", undoable: true, historyOwner: .document),
        .init(id: .save, label: "Save", menu: "File", bindings: menuKey("Save", "s", 1)),
        .init(id: .saveAs, label: "Save As…", menu: "File", bindings: menuKey("Save As", "s", 9)),
        .init(id: .exportPNG, label: "Export PNG…", menu: "File", bindings: menuKey("Export PNG", "e", 9)),
        .init(id: .exportJPEG, label: "Export JPEG…", menu: "File", bindings: menuKey("Export JPEG", "s", 11)),
        .init(id: .closeProject, label: "Close Project", menu: "File", bindings: menuKey("Close Project", "w", 1))
    ]
    private static let editMenu: [LensWorksCommandDescriptor] = [
        .init(id: .undo, label: "Undo", menu: "Edit", titleMatch: .prefix, bindings: menuKey("Undo", "z", 1), historyOwner: .document),
        .init(id: .redo, label: "Redo", menu: "Edit", titleMatch: .prefix, bindings: menuKey("Redo", "z", 9), historyOwner: .document),
        .init(id: .cut, label: "Cut", menu: "Edit", bindings: menuKey("Cut", "x", 1), undoable: true, historyOwner: .document),
        .init(id: .copyPixels, label: "Copy", menu: "Edit", bindings: menuKey("Copy", "c", 1)),
        .init(id: .copyMerged, label: "Copy Merged", menu: "Edit", bindings: menuKey("Copy Merged", "c", 9)),
        .init(id: .paste, label: "Paste", menu: "Edit", bindings: menuKey("Paste", "v", 1), undoable: true, historyOwner: .document),
        .init(id: .keyboardShortcuts, label: "Keyboard Shortcuts…", menu: "Edit"),
        .init(id: .aiModels, label: "AI Models…", menu: "Edit"),
        .init(id: .fillForeground, label: "Fill with Foreground Color", menu: "Edit", bindings: menuKey("Fill with Foreground", "\u{7f}", 2), undoable: true, historyOwner: .document),
        .init(id: .fillBackground, label: "Fill with Background Color", menu: "Edit", bindings: menuKey("Fill with Background", "\u{7f}", 1), undoable: true, historyOwner: .document),
        .init(id: .clearSelectionPixels, label: "Clear Selection Pixels", menu: "Edit", undoable: true, historyOwner: .document),
        .init(id: .contentAwareFill, label: "Content-Aware Fill…", menu: "Edit", bindings: menuKey("Content-Aware Fill", "\u{7f}", 8), undoable: true, historyOwner: .document)
    ]
    private static let viewMenu: [LensWorksCommandDescriptor] = [
        .init(id: .fitCanvas, label: "Fit Canvas", menu: "View", bindings: menuKey("Fit Canvas", "0", 1)),
        .init(id: .actualPixels, label: "Actual Pixels", menu: "View", bindings: menuKey("Actual Pixels", "1", 1)),
        .init(id: .zoomIn, label: "Zoom In", menu: "View", bindings: menuKey("Zoom In", "=", 1)),
        .init(id: .zoomOut, label: "Zoom Out", menu: "View", bindings: menuKey("Zoom Out", "-", 1)),
        .init(id: .pixelGrid, label: "Pixel Grid (800% and above)", menu: "View"),
        .init(id: .smartSnap, label: "Snap", menu: "View"),
        .init(id: .transformControls, label: "Show Transform Controls", menu: "View", bindings: menuKey("Show Transform Controls", "h", 1)),
        .init(id: .showGrid, label: "Grid", menu: "View/Show", bindings: menuKey("Show Grid", "'", 1)),
        .init(id: .showGuides, label: "Guides", menu: "View/Show", bindings: menuKey("Show Guides", ";", 1)),
        .init(id: .gridSettings, label: "Grid Settings…", menu: "View", undoable: true, historyOwner: .document),
        .init(id: .rulers, label: "Rulers", menu: "View", bindings: menuKey("Show Rulers", "r", 1)),
        .init(id: .snap, label: "Snap", menu: "View", bindings: menuKey("Snap", ";", 9)),
        .init(id: .snapToGuides, label: "Guides", menu: "View/Snap To"),
        .init(id: .snapToGrid, label: "Grid", menu: "View/Snap To"),
        .init(id: .snapToLayers, label: "Layers", menu: "View/Snap To"),
        .init(id: .snapToBounds, label: "Document Bounds", menu: "View/Snap To"),
        .init(id: .lockGuides, label: "Lock Guides", menu: "View", bindings: menuKey("Lock Guides", ";", 3)),
        .init(id: .clearGuides, label: "Clear Guides", menu: "View", undoable: true, historyOwner: .document)
    ]
    private static let selectMenu: [LensWorksCommandDescriptor] = [
        .init(id: .selectAll, label: "All", menu: "Select", bindings: menuKey("Select All", "a", 1), undoable: true, historyOwner: .document),
        .init(id: .deselect, label: "Deselect", menu: "Select", bindings: menuKey("Deselect", "d", 1), undoable: true, historyOwner: .document),
        .init(id: .inverseSelection, label: "Inverse", menu: "Select", bindings: menuKey("Inverse Selection", "i", 9), undoable: true, historyOwner: .document),
        .init(id: .selectLayerPixels, label: "Layer's Pixels", menu: "Select", undoable: true, historyOwner: .document),
        .init(id: .selectSubject, label: "Subject", menu: "Select", bindings: menuKey("Select Subject", "a", 3), undoable: true, historyOwner: .document),
        .init(id: .colorRange, label: "Color Range…", menu: "Select", undoable: true, historyOwner: .document),
        .init(id: .selectMaskBlack, label: "Mask's Black Areas", menu: "Select", undoable: true, historyOwner: .document),
        .init(id: .expandSelection, label: "Expand…", menu: "Select", undoable: true, historyOwner: .document),
        .init(id: .contractSelection, label: "Contract…", menu: "Select", undoable: true, historyOwner: .document),
        .init(id: .featherSelection, label: "Feather…", menu: "Select", undoable: true, historyOwner: .document)
    ]
    private static let imageMenu: [LensWorksCommandDescriptor] = [
        .init(id: .curves, label: "Curves…", menu: "Image", bindings: menuKey("Curves", "m", 1), undoable: true, historyOwner: .document),
        .init(id: .levels, label: "Levels…", menu: "Image", bindings: menuKey("Levels", "l", 1), undoable: true, historyOwner: .document),
        .init(id: .hueSaturation, label: "Hue/Saturation…", menu: "Image", bindings: menuKey("Hue/Saturation", "u", 1), undoable: true, historyOwner: .document),
        .init(id: .imageAdjustment, label: "Image Adjustment…", menu: "Image", titles: imageAdjustmentKinds.map { $0.rawValue + "…" }, parameters: choice("kind", imageAdjustmentKinds.map(\.rawValue)), undoable: true, historyOwner: .document),
        .init(id: .invert, label: "Invert", menu: "Image", titles: ["Invert", "Invert Mask"], bindings: menuKey("Invert Pixels / Mask", "i", 1), undoable: true, historyOwner: .document),
        .init(id: .canvasSize, label: "Canvas Size…", menu: "Image", bindings: menuKey("Canvas Size", "c", 3), undoable: true, historyOwner: .document),
        .init(id: .imageSize, label: "Image Size…", menu: "Image", bindings: menuKey("Image Size", "i", 3), undoable: true, historyOwner: .document),
        .init(id: .trim, label: "Trim…", menu: "Image", undoable: true, historyOwner: .document),
        .init(id: .flipCanvasHorizontal, label: "Flip Canvas Horizontal", menu: "Image", undoable: true, historyOwner: .document),
        .init(id: .flipCanvasVertical, label: "Flip Canvas Vertical", menu: "Image", undoable: true, historyOwner: .document),
        .init(id: .filter, label: "Filter…", menu: "Filter", titles: filterMenuKinds.map { $0.rawValue + "…" }, parameters: choice("kind", filterMenuKinds.map(\.rawValue)), undoable: true, historyOwner: .document)
    ]
    private static let layerMenu: [LensWorksCommandDescriptor] = [
        .init(id: .newAdjustment, label: "New Adjustment Layer", menu: "Layer/New Adjustment Layer", menus: ["Layer/New Adjustment Layer", "Layers Panel Footer/Adjustment"],
              titles: AdjustmentKind.allCases.flatMap { [$0.rawValue, $0.rawValue + "…"] }, parameters: choice("kind", AdjustmentKind.allCases.map(\.rawValue)), undoable: true, historyOwner: .document),
        .init(id: .editAdjustment, label: "Edit Adjustment…", menu: "Layer", undoable: true, historyOwner: .document),
        .init(id: .transform, label: "Transform Layer", menu: "Layer", titles: ["Transform Selection", "Transform Layer"], bindings: menuKey("Transform Layer / Selection", "t", 1), undoable: true, historyOwner: .document),
        .init(id: .layerViaCopy, label: "Duplicate Layer", menu: "Layer", titles: ["Duplicate Layer", "Layer via Copy"], bindings: menuKey("Duplicate / Layer via Copy", "j", 1), undoable: true, historyOwner: .document),
        .init(id: .duplicateLayer, label: "Duplicate Layer", menu: "Layers Panel", undoable: true, historyOwner: .document),
        .init(id: .clippingMask, label: "Create Clipping Mask", menu: "Layer", menus: ["Layer", "Layers Panel"], titles: ["Create Clipping Mask", "Release Clipping Mask"], bindings: menuKey("Toggle Clipping Mask", "g", 3), undoable: true, historyOwner: .document),
        .init(id: .groupLayers, label: "Group Selected Layers", menu: "Layer", menus: ["Layer", "Layers Panel"], bindings: menuKey("Group Layers", "g", 1), undoable: true, historyOwner: .document),
        .init(id: .ungroupLayers, label: "Ungroup Layers", menu: "Layer", menus: ["Layer", "Layers Panel"], bindings: menuKey("Ungroup Layers", "g", 9), undoable: true, historyOwner: .document),
        .init(id: .moveOutOfFolder, label: "Move Out of Folder", menu: "Layer", menus: ["Layer", "Layers Panel"], undoable: true, historyOwner: .document),
        .init(id: .newBlankLayer, label: "New Blank Layer", menu: "Layer", bindings: menuKey("New Blank Layer", "n", 9), undoable: true, historyOwner: .document),
        .init(id: .moveLayerUp, label: "Move Layer Up", menu: "Layer", bindings: menuKey("Move Layer Up", "]", 1), undoable: true, historyOwner: .document),
        .init(id: .moveLayerDown, label: "Move Layer Down", menu: "Layer", bindings: menuKey("Move Layer Down", "[", 1), undoable: true, historyOwner: .document),
        .init(id: .mergeLayers, label: "Merge Down", menu: "Layer", menus: ["Layer", "Layers Panel"], titles: ["Merge Down", "Merge Layers", "Merge Group"], bindings: menuKey("Merge Layers", "e", 1), undoable: true, historyOwner: .document),
        .init(id: .flipLayerHorizontal, label: "Flip Layer Horizontal", menu: "Layer", undoable: true, historyOwner: .document),
        .init(id: .flipLayerVertical, label: "Flip Layer Vertical", menu: "Layer", undoable: true, historyOwner: .document),
        .init(id: .deleteLayer, label: "Delete Layer", menu: "Layer", menus: ["Layer", "Layers Panel"],
              titles: ["Delete Layer", "Delete Layers", "Delete Selected Layers", "Delete Layer Mask"] + LayerEffectKind.allCases.map { "Delete " + $0.rawValue }, undoable: true, historyOwner: .document),
        .init(id: .addMask, label: "Add Mask", menu: "Layers Panel/Add Mask", titles: ["Reveal All (White)", "Hide All (Black)"], parameters: choice("fill", ["white", "black"]), undoable: true, historyOwner: .document),
        .init(id: .toggleMask, label: "Disable Mask", menu: "Layers Panel", titles: ["Enable Mask", "Disable Mask"], undoable: true, historyOwner: .document),
        .init(id: .deleteMask, label: "Delete Mask", menu: "Layers Panel", undoable: true, historyOwner: .document),
        .init(id: .linkMask, label: "Unlink Mask", menu: "Layers Panel", titles: ["Link Mask", "Unlink Mask"], undoable: true, historyOwner: .document),
        .init(id: .addEffect, label: "Add Layer Effect", menu: "Layers Panel Footer/Effects", titles: LayerEffectKind.allCases.map { $0.rawValue + "…" }, parameters: choice("kind", LayerEffectKind.allCases.map(\.rawValue)), undoable: true, historyOwner: .document)
    ]
    private static let canvas: [LensWorksCommandDescriptor] = {
        func tool(_ id: LensWorksCommandID, _ label: String, _ title: String, _ key: String) -> LensWorksCommandDescriptor {
            .init(id: id, label: label, menu: "Canvas", bindings: [bind(title, .canvas, key)])
        }
        var rows: [LensWorksCommandDescriptor] = [
            tool(.selectTool, "Select Tool", "Select tool", "a"), tool(.moveTool, "Move Tool", "Move / Transform tool", "v"),
            tool(.handTool, "Hand Tool", "Hand tool", "h"), tool(.zoomTool, "Zoom Tool", "Zoom tool", "z"),
            tool(.brushTool, "Brush Tool", "Brush tool", "b"), tool(.eraserTool, "Eraser", "Eraser", "e"),
            tool(.spotHealingTool, "Spot Healing", "Spot Healing", "j"), tool(.cloneStampTool, "Clone Stamp", "Clone Stamp", "s"),
            tool(.typeTool, "Type Tool", "Type tool", "t"), tool(.gradientTool, "Gradient Tool", "Gradient tool", "g"),
            tool(.shapeTool, "Shape Tool", "Shape tool", "u"), tool(.eyedropperTool, "Eyedropper Tool", "Eyedropper tool", "i"),
            tool(.marqueeTool, "Marquee Tool", "Marquee / cycle shape", "m"), tool(.magicTool, "Magic Tool", "Magic", "w"),
            tool(.lassoTool, "Lasso Tool", "Lasso / cycle mode", "l"), tool(.blurTool, "Blur Tool", "Blur / Smudge / Liquify", "r"),
            tool(.cropTool, "Crop Tool", "Crop tool", "c"), tool(.swapColors, "Swap Colors", "Swap foreground/background", "x"),
            tool(.resetColors, "Reset Colors", "Reset colors", "d"), tool(.cycleToolMode, "Cycle Tool Mode", "Cycle tool mode", "\t"),
            .init(id: .temporaryHand, label: "Temporary Hand Tool", menu: "Canvas", bindings: [bind("Temporary Hand tool (hold)", .canvas, " ", match: .any)]),
            .init(id: .canvasDelete, label: "Delete", menu: "Canvas", bindings: [bind("Delete selection / layer / effect / lasso point", .canvas, "\u{7f}", match: .any)], undoable: true, historyOwner: .document),
            .init(id: .apply, label: "Apply", menu: "Canvas", bindings: [bind("Apply current canvas operation", .canvas, "\r", match: .any)], undoable: true, historyOwner: .document),
            .init(id: .cancel, label: "Cancel", menu: "Canvas", bindings: [bind("Cancel current canvas operation", .canvas, "\u{1b}", match: .any)]),
            .init(id: .brushSize, label: "Brush Size", menu: "Canvas", bindings: [bind("Decrease brush size", .canvas, "[", argument: "decrease"), bind("Increase brush size", .canvas, "]", argument: "increase")], parameters: choice("direction", ["decrease", "increase"])),
            .init(id: .brushHardness, label: "Brush Hardness", menu: "Canvas", bindings: [bind("Decrease brush hardness", .canvas, "[", 8, argument: "decrease"), bind("Increase brush hardness", .canvas, "]", 8, argument: "increase")], parameters: choice("direction", ["decrease", "increase"])),
            .init(id: .blendMode, label: "Blend Mode", menu: "Canvas", bindings: [bind("Previous blend mode", .canvas, "-", 8, argument: "previous"), bind("Next blend mode", .canvas, "=", 8, argument: "next")], parameters: choice("direction", ["previous", "next"]), undoable: true, historyOwner: .document),
            .init(id: .cycleShapeKind, label: "Cycle Shape Kind", menu: "Canvas", bindings: [bind("Cycle shape kind", .canvas, "u", 8)]),
            .init(id: .opacityDigit, label: "Opacity Digit", menu: "Canvas", bindings: (0...9).map { bind("Opacity digit \($0) (type two for exact %)", .canvas, String($0), argument: String($0)) }, parameters: choice("digit", (0...9).map(String.init)), undoable: true, historyOwner: .document)
        ]
        var nudges: [LensWorksCommandBinding] = [], moves: [LensWorksCommandBinding] = []
        for (direction, key) in directions {
            nudges += [bind("Nudge \(direction) 1 px", .canvas, key, argument: direction.lowercased() + ".1"), bind("Nudge \(direction) 10 px", .canvas, key, 8, argument: direction.lowercased() + ".10")]
            moves += [bind("Move selected pixels \(direction) 1 px", .canvas, key, 1, argument: direction.lowercased() + ".1"), bind("Move selected pixels \(direction) 10 px", .canvas, key, 9, argument: direction.lowercased() + ".10")]
        }
        let steps = directions.flatMap { [$0.name.lowercased() + ".1", $0.name.lowercased() + ".10"] }
        rows += [
            .init(id: .nudge, label: "Nudge", menu: "Canvas", bindings: nudges, parameters: choice("step", steps), undoable: true, historyOwner: .document),
            .init(id: .movePixels, label: "Move Selected Pixels", menu: "Canvas", bindings: moves, parameters: choice("step", steps), undoable: true, historyOwner: .document),
            .init(id: .finishText, label: "Finish Editing Text", menu: "Canvas", bindings: [bind("Finish editing text", .text, "\r", 1, match: .atLeast)], undoable: true, historyOwner: .document)
        ]
        for (id, label, decrease, increase) in [(LensWorksCommandID.tracking, "tracking", "\u{f702}", "\u{f703}"), (.leading, "leading", "\u{f700}", "\u{f701}")] {
            rows.append(.init(id: id, label: label.capitalized, menu: "Canvas", bindings: [
                bind("Decrease \(label)", .text, decrease, 2, argument: "decrease.1", match: .atLeast), bind("Decrease \(label) by 10", .text, decrease, 10, argument: "decrease.10", match: .atLeast),
                bind("Increase \(label)", .text, increase, 2, argument: "increase.1", match: .atLeast), bind("Increase \(label) by 10", .text, increase, 10, argument: "increase.10", match: .atLeast)
            ], parameters: choice("step", ["decrease.1", "decrease.10", "increase.1", "increase.10"]), undoable: true, historyOwner: .document))
        }
        rows += [
            .init(id: .levelsPreview, label: "Toggle Levels Preview", menu: "Canvas", bindings: [bind("Toggle Levels preview", .canvas, "p", 2, match: .atLeast)]),
            .init(id: .stepField, label: "Step Numeric Field", menu: "Fields", bindings: [
                bind("Step field up", .field, "\u{f700}", argument: "up.1", match: .atLeast), bind("Step field up by 10", .field, "\u{f700}", 8, argument: "up.10", match: .atLeast),
                bind("Step field down", .field, "\u{f701}", argument: "down.1", match: .atLeast), bind("Step field down by 10", .field, "\u{f701}", 8, argument: "down.10", match: .atLeast)
            ], parameters: choice("step", ["up.1", "up.10", "down.1", "down.10"])),
            // Escape (or ⌘.) in a focused field gives up the edit: SwiftUI's exit command and AppKit's cancelOperation.
            .init(id: .cancelField, label: "Cancel Field Editing", menu: "Fields", bindings: [
                bind("Cancel field editing", .field, "\u{1b}", match: .any), bind("Cancel field editing with Command-period", .field, ".", 1, argument: "commandPeriod")
            ]),
            .init(id: .saveShortcuts, label: "Save Keyboard Shortcuts", menu: "Shortcut Editor", bindings: [bind("Save keyboard shortcuts", .dialog, "\r")]),
            .init(id: .cancelShortcuts, label: "Cancel Keyboard Shortcuts", menu: "Shortcut Editor", bindings: [bind("Cancel keyboard shortcuts", .dialog, "\u{1b}")])
        ]
        return rows
    }()
    private static let panels: [LensWorksCommandDescriptor] = [
        .init(id: .cameraRawScope, label: "Camera Raw Scope", menu: "Camera Raw Scope", titles: ["Histogram", "Vectorscope"], parameters: choice("mode", ["histogram", "vectorscope"])),
        .init(id: .selectProjectTab, label: "Show Project Tab", menu: "Project Tabs", titleMatch: .any, parameters: reference("tab", "A project tab hidden in the tab strip's overflow menu.")),
        .init(id: .canvasPreset, label: "New Canvas Preset Size", menu: "New Canvas/Size", titleMatch: .any, parameters: reference("preset", "A preset size in the New Canvas sheet's size menu, or Custom."))
    ]
    private static func rateBindingTitle(_ value: Int) -> String {
        switch value { case 0: "Rate Unrated"; case 1: "Rate 1 star"; default: "Rate \(value) stars" }
    }
    private static let ratingTitles = ["Unrated"] + (1...5).map { String(repeating: "★", count: $0) }
    private static let catalogBrowser: [LensWorksCommandDescriptor] = [
        .init(id: .locateFolder, label: "Locate Moved Folder…", menu: "Catalog Folder", parameters: reference("folder", "A catalog folder whose source moved.")),
        .init(id: .addToVirtualFolder, label: "Add Selected Photos", menu: "Catalog Virtual Folder", parameters: reference("folder", "A virtual folder."), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .removeFromVirtualFolder, label: "Remove Selected Photos", menu: "Catalog Virtual Folder", parameters: reference("folder", "A virtual folder."), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .renameVirtualFolder, label: "Rename…", menu: "Catalog Virtual Folder", parameters: reference("folder", "A virtual folder."), historyOwner: .nativeMetadata),
        .init(id: .moveVirtualFolder, label: "Move Into…", menu: "Catalog Virtual Folder", parameters: reference("folder", "A virtual folder."), historyOwner: .nativeMetadata),
        .init(id: .deleteVirtualFolder, label: "Delete Empty Folder", menu: "Catalog Virtual Folder", parameters: reference("folder", "An empty virtual folder."), historyOwner: .nativeMetadata, requiresAgentConfirmation: true),
        .init(id: .showNestedKeywords, label: "Show Nested Keywords", menu: "Catalog Keyword", parameters: reference("keyword", "A hierarchical keyword.")),
        .init(id: .addKeyword, label: "Add to Selected Photos", menu: "Catalog Keyword", parameters: reference("keyword", "A catalog keyword."), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .removeKeyword, label: "Remove from Selected Photos", menu: "Catalog Keyword", parameters: reference("keyword", "A catalog keyword."), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .renameKeyword, label: "Rename…", menu: "Catalog Keyword", parameters: reference("keyword", "A catalog keyword."), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .moveKeyword, label: "Move…", menu: "Catalog Keyword", parameters: reference("keyword", "A hierarchical keyword."), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .addSynonym, label: "Add Synonym…", menu: "Catalog Keyword", parameters: reference("keyword", "A catalog keyword."), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .deleteKeyword, label: "Delete Keyword", menu: "Catalog Keyword", parameters: reference("keyword", "A catalog keyword."), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .openInEditor, label: "Open in Editor", menu: "Catalog Photo", parameters: reference("photo", "A photo in the catalog grid.")),
        .init(id: .sortBy, label: "Sort", menu: "Catalog Sort", titles: ["Sequence", "Capture Time", "Filename", "Rating"], parameters: choice("sort", ["sequence", "capture", "filename", "rating"])),
        .init(id: .sortDirection, label: "Sort Direction", menu: "Catalog Sort", titles: ["Ascending", "Descending"], parameters: choice("direction", ["ascending", "descending"])),
        .init(id: .ratePhotos, label: "Rate Photos", menu: "Catalog Rate", titles: ratingTitles,
              bindings: (0...5).map { (value: Int) -> LensWorksCommandBinding in bind(rateBindingTitle(value), .catalog, String(value), argument: String(value)) },
              parameters: choice("rating", (0...5).map(String.init)), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .flagPhotos, label: "Flag Photos", menu: "Catalog Flag", titles: ["Pick", "Reject", "Unflagged"],
              bindings: [bind("Flag Pick", .catalog, "p", argument: "pick"), bind("Flag Reject", .catalog, "x", argument: "reject"), bind("Flag Unflagged", .catalog, "u", argument: "unflagged")],
              parameters: choice("flag", ["pick", "reject", "unflagged"]), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .labelPhotos, label: "Label Photos", menu: "Catalog Label", titles: catalogLabels + ["None"],
              bindings: catalogLabels.prefix(4).enumerated().map { bind("Label \($0.element)", .catalog, String($0.offset + 6), argument: $0.element) },
              parameters: choice("label", catalogLabels + ["None"]), undoable: true, historyOwner: .nativeMetadata),
        .init(id: .moveCatalogSelection, label: "Move Photo Selection", menu: "Catalog Grid", bindings: [
            bind("Select previous photo", .catalog, "\u{f702}", argument: "previous", match: .atLeast), bind("Select next photo", .catalog, "\u{f703}", argument: "next", match: .atLeast),
            bind("Extend selection to previous photo", .catalog, "\u{f702}", 8, argument: "extendPrevious", match: .atLeast), bind("Extend selection to next photo", .catalog, "\u{f703}", 8, argument: "extendNext", match: .atLeast)
        ], parameters: choice("step", ["previous", "next", "extendPrevious", "extendNext"])),
        .init(id: .filterRating, label: "Filter by Rating", menu: "Catalog Filter/Rating", titles: ["Any", "Unrated (0)"] + (1...5).map { String(repeating: "★", count: $0) }, parameters: choice("rating", ["any"] + (0...5).map(String.init))),
        .init(id: .filterFlag, label: "Filter by Flag", menu: "Catalog Filter/Flag", titles: ["Any", "Pick", "Reject", "Unflagged"], parameters: choice("flag", ["any", "pick", "reject", "unflagged"])),
        .init(id: .filterLabel, label: "Filter by Label", menu: "Catalog Filter/Label", titles: ["Any"] + catalogLabels, parameters: choice("label", ["any"] + catalogLabels)),
        .init(id: .filterAnyKeyword, label: "Any Keyword", menu: "Catalog Filter"),
        .init(id: .clearFilters, label: "Clear Filters", menu: "Catalog Filter")
    ]

    private static let automation: [LensWorksCommandDescriptor] = [
        .init(id: .automationEnabled, label: "Allow AI Agents to Control LensWorks", menu: "Settings/Automation"),
        .init(id: .automationShowSecret, label: "Show Secret", menu: "Settings/Automation"),
        .init(id: .automationCopySecret, label: "Copy Secret", menu: "Settings/Automation"),
        .init(id: .automationRegenerateSecret, label: "Regenerate Secret", menu: "Settings/Automation"),
        .init(id: .automationRevokeSecret, label: "Revoke Secret", menu: "Settings/Automation"),
        .init(id: .automationCopyConfiguration, label: "Copy Client Configuration", menu: "Settings/Automation"),
        .init(id: .automationAllow, label: "Allow", menu: "Agent Confirmation"),
        .init(id: .automationDecline, label: "Don’t Allow", menu: "Agent Confirmation")
    ]

    static func menuLabel(_ label: String, reason: String?) -> String { label + (reason.map { " — " + $0 } ?? "") }
    static func descriptor(_ id: LensWorksCommandID) -> LensWorksCommandDescriptor {
        descriptors.first { $0.id == id }!
    }
    /// The reason a command is unavailable, or nil when it can run.
    static func unavailable(_ disabled: Bool, _ reason: String) -> String? { disabled ? reason : nil }
}
