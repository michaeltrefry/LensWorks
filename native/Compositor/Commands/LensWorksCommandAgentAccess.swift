import Foundation

/// Why an agent cannot run a command. Every reason is true of exactly the commands that carry it and says what the
/// command is for; none says "not yet".
nonisolated enum LensWorksAgentExclusion: String, Codable, CaseIterable, Sendable {
    case automation = "Automation settings and confirmations are never available to agents."
    case appVisibility = "It hides or shows apps on the person’s screen and changes nothing in a document or the catalog."
    case opensWindow = "It only opens a window for the person (Keyboard Shortcuts or AI Models) and changes nothing."
    case recentList = "It clears the person’s Open Recent list, which macOS keeps for them and nothing can restore."
    case canvasZoom = "It changes only the zoom of the person’s canvas view; render_preview renders the document at any size."
    case viewPreference = "It is a display or snapping preference for the person’s pointer on the canvas and changes nothing in the document."
    case gridSheet = "It opens the Grid Settings sheet, which changes only how the person’s layout grid is drawn."
    case pointerTool = "It chooses the tool or tool mode the person’s pointer uses; a tool changes the document only through pointer gestures on the canvas, which agents cannot make."
    case brushTip = "It sets the brush tip for the person’s pointer strokes; agents cannot paint strokes."
    case pendingPointerOperation = "It applies or cancels the pointer operation the person has in progress on the canvas (a transform, crop, gradient or lasso); an agent never acts under the person’s open operation."
    case textEditing = "It acts on text the person is typing on the canvas, which needs the Type tool’s pointer and keyboard."
    case focusedField = "It steps or cancels a numeric field the person has focused in the window."
    case levelsDialog = "It toggles the preview in the Levels dialog the person has open; image.levels takes its settings directly."
    case cameraRawPanel = "It switches the scope shown in the Camera Raw panel the person has open."
    case newCanvasSheet = "It picks a preset in the New Canvas sheet the person has open; file.newCanvas takes width and height directly."
    case shortcutEditor = "It is the Save or Cancel button of the Keyboard Shortcuts window the person has open."
    case nameEditor = "It opens the layer’s name editor for the person to type in; layer.rename takes the name directly."
    case opacityKeys = "It types one digit of an opacity percentage and pairs with the person’s next key press; layer.opacity takes the value directly."
    case relinkReview = "It opens the relink review, where the person chooses the folder’s new location and confirms each match."
}

/// Whether an agent can run a command.
nonisolated enum LensWorksAgentAccess: Equatable, Sendable {
    /// Runnable through `invoke_command` and `batch`, with the descriptor's `parameters` as its arguments.
    case runnable(LensWorksAgentCommandKind)
    case notRunnable(LensWorksAgentExclusion)
    var isRunnable: Bool { if case .runnable = self { true } else { false } }
    var kind: LensWorksAgentCommandKind? { if case .runnable(let kind) = self { kind } else { nil } }
    var exclusion: LensWorksAgentExclusion? { if case .notRunnable(let reason) = self { reason } else { nil } }
}

/// What a runnable command acts on, which decides how it batches.
nonisolated enum LensWorksAgentCommandKind: String, Codable, Sendable {
    /// The open document: members of a batch share one history entry and roll back together.
    case document
    /// The open catalog: members of a batch run in order and stop at the first failure.
    case catalog
    /// Document history, project files, tabs and the open catalog itself: run one at a time, never in a batch.
    case standalone
}

/// When an agent's request waits for the person to confirm it in the app.
nonisolated enum LensWorksAgentConfirmationRule: String, Codable, Sendable {
    case never
    /// Whenever the command runs: it destroys something nothing can restore.
    case always
    /// When the file it writes already exists: the file's previous contents cannot be restored.
    case whenReplacingFile
}

/// How what a command changes can be put back.
nonisolated enum LensWorksCommandReversal: String, Codable, Sendable {
    /// Undo in the app (document history, or the catalog's own recipe and organization history).
    case history
    /// Running the command again with the previous value restores it; nothing is lost.
    case inverse
    /// It adds something new and replaces nothing (a new tab, a catalog copy, registered photos).
    case additive
    /// It changes nothing kept in a document, the catalog or a file (selection, navigation, a view, the clipboard).
    case transient
    /// It writes a file: replacing an existing one destroys that file's previous contents.
    case replacesFile
    /// It destroys something nothing can restore.
    case irreversible
    /// Whether `rule` puts the person's confirmation in front of everything this cannot put back.
    func isCovered(by rule: LensWorksAgentConfirmationRule) -> Bool {
        switch self {
        case .irreversible: rule == .always
        case .replacesFile: rule != .never
        default: true
        }
    }
}

extension LensWorksCommandID {
    /// Every command is either runnable by an agent or carries the reason it is not. The switch has no default: a
    /// new command does not compile until it is classified here.
    nonisolated var agentAccess: LensWorksAgentAccess {
        switch self {
        // The open document.
        case .visibility, .opacity, .rename, .selectLayers,
             .importImages, .cut, .copyPixels, .copyMerged, .paste, .fillForeground, .fillBackground, .clearSelectionPixels, .contentAwareFill,
             .clearGuides, .selectAll, .deselect, .inverseSelection, .selectLayerPixels, .selectSubject, .colorRange, .selectMaskBlack,
             .expandSelection, .contractSelection, .featherSelection,
             .curves, .levels, .hueSaturation, .imageAdjustment, .invert, .canvasSize, .imageSize, .trim, .flipCanvasHorizontal, .flipCanvasVertical, .filter,
             .newAdjustment, .editAdjustment, .transform, .layerViaCopy, .duplicateLayer, .clippingMask, .groupLayers, .ungroupLayers, .moveOutOfFolder,
             .newBlankLayer, .moveLayerUp, .moveLayerDown, .mergeLayers, .flipLayerHorizontal, .flipLayerVertical, .deleteLayer,
             .addMask, .toggleMask, .deleteMask, .linkMask, .addEffect, .blendMode,
             .swapColors, .resetColors, .canvasDelete, .nudge, .movePixels:
            .runnable(.document)
        // The open catalog.
        case .firstVariants, .moreVariants, .selectVariant, .copy, .exposure, .undoRecipe, .redoRecipe, .rating,
             .addToVirtualFolder, .removeFromVirtualFolder, .renameVirtualFolder, .moveVirtualFolder, .deleteVirtualFolder,
             .showNestedKeywords, .addKeyword, .removeKeyword, .renameKeyword, .moveKeyword, .addSynonym, .deleteKeyword,
             .sortBy, .sortDirection, .ratePhotos, .flagPhotos, .labelPhotos, .moveCatalogSelection, .selectPhotos,
             .filterRating, .filterFlag, .filterLabel, .filterAnyKeyword, .clearFilters:
            .runnable(.catalog)
        // History steps, project files, tabs and the catalog itself.
        case .undo, .redo, .openCatalog, .newCatalog, .addPhotos, .newCanvas, .openProject, .openRecent, .save, .saveAs,
             .exportPNG, .exportJPEG, .closeProject, .selectProjectTab, .openInEditor:
            .runnable(.standalone)
        case .automationEnabled, .automationShowSecret, .automationCopySecret, .automationRegenerateSecret, .automationRevokeSecret,
             .automationCopyConfiguration, .automationAllow, .automationDecline, .automationGrantFolder, .automationRevokeFolder:
            .notRunnable(.automation)
        case .hideApp, .hideOthers, .showAll: .notRunnable(.appVisibility)
        case .keyboardShortcuts, .aiModels: .notRunnable(.opensWindow)
        case .clearRecent: .notRunnable(.recentList)
        case .fitCanvas, .actualPixels, .zoomIn, .zoomOut: .notRunnable(.canvasZoom)
        case .pixelGrid, .smartSnap, .transformControls, .showGrid, .showGuides, .rulers, .snap, .snapToGuides, .snapToGrid,
             .snapToLayers, .snapToBounds, .lockGuides:
            .notRunnable(.viewPreference)
        case .gridSettings: .notRunnable(.gridSheet)
        case .selectTool, .moveTool, .handTool, .zoomTool, .brushTool, .eraserTool, .spotHealingTool, .cloneStampTool, .typeTool,
             .gradientTool, .shapeTool, .eyedropperTool, .marqueeTool, .magicTool, .lassoTool, .blurTool, .cropTool,
             .cycleToolMode, .temporaryHand, .cycleShapeKind:
            .notRunnable(.pointerTool)
        case .brushSize, .brushHardness: .notRunnable(.brushTip)
        case .apply, .cancel: .notRunnable(.pendingPointerOperation)
        case .finishText, .tracking, .leading: .notRunnable(.textEditing)
        case .stepField, .cancelField: .notRunnable(.focusedField)
        case .levelsPreview: .notRunnable(.levelsDialog)
        case .cameraRawScope: .notRunnable(.cameraRawPanel)
        case .canvasPreset: .notRunnable(.newCanvasSheet)
        case .saveShortcuts, .cancelShortcuts: .notRunnable(.shortcutEditor)
        case .beginRename: .notRunnable(.nameEditor)
        case .opacityDigit: .notRunnable(.opacityKeys)
        case .locateFolder: .notRunnable(.relinkReview)
        }
    }

    /// How what the command changes can be put back. An agent reaches an irreversible change only through the
    /// person's confirmation (`LensWorksCommandDescriptor.agentConfirmation`).
    nonisolated var reversal: LensWorksCommandReversal {
        switch self {
        case .deleteVirtualFolder: return .irreversible
        // The saved project file is replaced by the document as it stands.
        case .save: return .irreversible
        case .saveAs, .exportPNG, .exportJPEG: return .replacesFile
        case .renameVirtualFolder, .moveVirtualFolder, .rating, .openCatalog, .closeProject: return .inverse
        case .copy, .newCatalog, .addPhotos, .newCanvas, .openProject, .openRecent, .openInEditor: return .additive
        case .firstVariants, .moreVariants, .selectVariant, .showNestedKeywords, .sortBy, .sortDirection, .moveCatalogSelection,
             .selectPhotos, .filterRating, .filterFlag, .filterLabel, .filterAnyKeyword, .clearFilters, .selectProjectTab,
             .selectLayers, .copyPixels, .copyMerged, .swapColors, .resetColors:
            return .transient
        default:
            // Everything else an agent can run enters document history or the catalog's recipe or organization
            // history (a deleted keyword too: the person is still asked, because its menu marks it destructive).
            return agentAccess.isRunnable ? .history : .transient
        }
    }
}

extension LensWorksCommandRegistry {
    /// The commands an agent can run, in registry order.
    nonisolated static let agentCommands: [LensWorksCommandID] = descriptors.map(\.id).filter { $0.agentAccess.isRunnable }
}
