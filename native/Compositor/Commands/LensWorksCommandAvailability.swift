import Foundation

extension EditorSession {
    /// Why a menu-bar command is unavailable for this document as it stands, or nil when it can run. The menus show
    /// this reason on the disabled item and an agent is refused with the same words: one function answers both.
    /// `argument` is the item's own (a filter or adjustment kind); `canStart` is whether a project operation can begin.
    func menuReason(_ id: LensWorksCommandID, argument: String? = nil, canStart: Bool) -> String? {
        let documentReason = LensWorksCommandRegistry.unavailable(document == nil, "Open a document first.")
        let startReason = LensWorksCommandRegistry.unavailable(!canStart, "Finish the current project operation first.")
        let projectReason = documentReason ?? startReason
        let pixelReason = commandReason(!canEditPixels, "Select an editable pixel layer first.")
        let selectionReason = commandReason(!canEditSelection, "Finish the current tool, dialog or layer edit first.")
        let modifySelectionReason = commandReason(!canModifySelection, "Make a selection first.")
        let layerEditReason = commandReason(!canEditLayers, "Finish the current tool, dialog or layer edit first.")
        let adjustReason = commandReason(!canAdjustColors, "Select an editable pixel layer first.")
            ?? LensWorksCommandRegistry.unavailable(hueSaturation != nil, "Finish Hue/Saturation first.")
        switch id {
        case .undo: return commandReason(!canUndo, "There is nothing to undo.")
        case .redo: return commandReason(!canRedo, "There is nothing to redo.")
        case .newCanvas, .openProject, .closeProject: return startReason
        case .importImages:
            return levels != nil || showsBusy || isImporting || showsNewDocument ? "Finish the current dialog or project operation first." : nil
        case .save, .saveAs, .exportPNG, .exportJPEG, .canvasSize, .imageSize, .trim: return projectReason
        case .fitCanvas, .actualPixels, .zoomIn, .zoomOut, .showGrid, .showGuides, .gridSettings, .rulers, .snap, .snapToGuides,
             .snapToGrid, .snapToLayers, .snapToBounds, .lockGuides:
            return documentReason
        case .transformControls: return documentReason ?? LensWorksCommandRegistry.unavailable(tool != .move, "Choose the Move tool first.")
        case .clearGuides: return commandReason(!canClearGuides, "There are no guides to clear.")
        case .copyMerged: return commandReason(!canCopyMerged, "Make a selection on a visible document first.")
        case .fillForeground, .fillBackground: return pixelReason
        case .clearSelectionPixels: return commandReason(selection == nil, "Make a selection first.") ?? pixelReason
        case .contentAwareFill: return commandReason(!canContentAwareFill, "Select an area of an editable pixel layer first.")
        case .deselect, .inverseSelection: return commandReason(selection == nil, "There is no selection.") ?? selectionReason
        case .selectLayerPixels: return commandReason(activeLayer?.asset == nil, "Select a pixel layer first.") ?? selectionReason
        case .selectSubject: return commandReason(!canSelectSubject, "Finish the current tool, dialog or layer edit first.")
        case .colorRange: return commandReason(!canSelectColorRange, "Finish the current tool, dialog or layer edit first.")
        case .selectMaskBlack: return commandReason(activeLayer?.mask == nil, "Select a layer with a mask first.") ?? selectionReason
        case .expandSelection, .contractSelection, .featherSelection: return modifySelectionReason
        case .curves, .levels, .imageAdjustment: return adjustReason
        case .hueSaturation: return commandReason(!canAdjustColors, "Select an editable pixel layer first.")
        case .invert: return commandReason(!canInvert, "Select an editable pixel layer or mask first.")
        case .flipCanvasHorizontal, .flipCanvasVertical, .groupLayers, .newBlankLayer: return layerEditReason
        case .filter:
            let vignette = argument == FilterKind.vignette.rawValue
            return commandReason(!(vignette ? canVignette : canAdjustColors), "Select an editable pixel layer first.")
                ?? LensWorksCommandRegistry.unavailable(hueSaturation != nil, "Finish Hue/Saturation first.")
        case .runPlugin:
            return commandReason(!canAdjustColors, "Select an editable pixel layer first.")
                ?? LensWorksCommandRegistry.unavailable(hueSaturation != nil, "Finish Hue/Saturation first.")
        case .editAdjustment: return layerEditReason ?? commandReason(activeLayer?.adjustment == nil, "Select an adjustment layer first.")
        case .transform: return commandReason(!canTransform && !canTransformSelection, "Select a layer that can be transformed first.")
        case .layerViaCopy:
            return commandReason(!canCopyPixels && !(selection == nil && canEditLayers && activeLayer != nil), "Select a layer or an area of pixels first.")
        case .clippingMask:
            return commandReason(activeLayerID.map { !canToggleClippingMask($0) } ?? true, "Select a layer above another layer first.")
        case .ungroupLayers: return commandReason(!canUngroupLayers, "Select a folder first.")
        case .moveOutOfFolder: return layerEditReason ?? commandReason(activeLayer?.parentID == nil, "Select a layer inside a folder first.")
        case .moveLayerUp: return commandReason(!canMoveActiveLayer(by: 1), "The layer cannot move up.")
        case .moveLayerDown: return commandReason(!canMoveActiveLayer(by: -1), "The layer cannot move down.")
        case .mergeLayers: return commandReason(!canMergeLayers, "Select layers that can be merged first.")
        case .flipLayerHorizontal, .flipLayerVertical: return commandReason(!canTransform, "Select a layer that can be transformed first.")
        case .deleteLayer: return layerEditReason ?? commandReason(activeLayer == nil, "Select a layer first.")
        default: return nil
        }
    }
}
