import SwiftUI

@main
struct CompositorApp: App {
    @NSApplicationDelegateAdaptor(CompositorApplicationDelegate.self) private var applicationDelegate
    private var session: EditorSession { applicationDelegate.session }
    var body: some Scene {
        Window("LensWorks", id: "editor") {
            ProjectWorkspaceView(applicationDelegate: applicationDelegate).roundedControls()
                .overlay(alignment: .bottom) {
                    if let reason = session.commandRefusal { Text(reason).padding(8).background(.regularMaterial).accessibilityIdentifier("LensWorks.commandRefusal") }
                }
                .onAppear { LensWorksLaunchTrace.record("window.editor.onAppear") }
                .sheet(item: Binding(get: { applicationDelegate.automation.pendingConfirmation }, set: { if $0 == nil { applicationDelegate.automation.resolveConfirmation(false) } })) { confirmation in
                    LensWorksAgentConfirmationSheet(automation: applicationDelegate.automation, confirmation: confirmation)
                }
        }
            .defaultSize(width: 1180, height: 780)
            // Files opened from Finder or dropped on the Dock icon go to the app delegate, which imports them into
            // the open window. Left to SwiftUI, each one builds a throwaway window and fades the editor out and back.
            .handlesExternalEvents(matching: [])
            // A first launch fills the screen (without going full screen); after that macOS reopens the window at the
            // size it was left.
            .defaultWindowPlacement { _, context in
                WindowPlacement(size: context.defaultDisplay.visibleRect.size)
            }
            // The project's name is already on its tab, so the toolbar doesn't repeat it as a window title.
            .windowToolbarStyle(.unifiedCompact(showsTitle: false))
            .commands {
                // Every item is a registered command (LensWorksCommandCatalog.swift): the registry supplies its title,
                // shortcut and dispatch, and the command audit fails on any item added outside it.
                CommandGroup(replacing: .undoRedo) {
                    // Dialog text fields keep native text undo; document history
                    // is unavailable while an import or modal edit is active.
                    if session.textDraft != nil || session.levels != nil || session.isProjectBusy || session.showsNewDocument || session.showsImporter || session.renamingLayerID != nil || session.transformEdit?.persistent == true {
                        LensWorksCommandButton(.undo) {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(NSSelectorFromString("undo:"), to: nil, from: nil)
                            }
                        }
                        LensWorksCommandButton(.redo) {
                            if NSApp.keyWindow?.firstResponder is NSTextView {
                                NSApp.sendAction(NSSelectorFromString("redo:"), to: nil, from: nil)
                            }
                        }
                    } else {
                        LensWorksCommandButton(.undo, title: session.history.canUndo ? "Undo \(session.history.undoName)" : "Undo",
                                               reason: session.commandReason(!session.canUndo, "There is nothing to undo.")) { session.undo() }
                        LensWorksCommandButton(.redo, title: session.history.canRedo ? "Redo \(session.history.redoName)" : "Redo",
                                               reason: session.commandReason(!session.canRedo, "There is nothing to redo.")) { session.redo() }
                    }
                }
                CommandGroup(replacing: .newItem) {
                    LensWorksCommandButton(.openCatalog) { Task { await applicationDelegate.catalog.openCatalog(create: false, window: applicationDelegate.workspace.window) } }
                    LensWorksCommandButton(.newCatalog) { Task { await applicationDelegate.catalog.openCatalog(create: true, window: applicationDelegate.workspace.window) } }
                    LensWorksCommandButton(.addPhotos, reason: applicationDelegate.catalog.catalogPath == nil ? "Open a catalog first."
                                           : applicationDelegate.catalog.isBusy ? "Finish the current catalog operation first." : nil) {
                        Task { await applicationDelegate.catalog.importFolder(window: applicationDelegate.workspace.window) }
                    }
                    Divider()
                    LensWorksCommandButton(.newCanvas, reason: startReason) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.newCanvas() }
                    }
                    LensWorksCommandButton(.openProject, reason: startReason) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.open() }
                    }
                    Menu("Open Recent") {
                        ForEach(RecentProjects.shared.urls, id: \.self) { url in
                            LensWorksCommandButton(.openRecent, argument: url.path, title: RecentProjects.menuTitle(url)) {
                                applicationDelegate.showEditor?()
                                Task { await applicationDelegate.projects.open(url) }
                            }
                        }
                        Divider()
                        LensWorksCommandButton(.clearRecent, reason: LensWorksCommandRegistry.unavailable(RecentProjects.shared.urls.isEmpty, "There are no recent projects.")) {
                            RecentProjects.shared.clear()
                        }
                    }
                        .disabled(!applicationDelegate.projects.canStart)
                    LensWorksCommandButton(.importImages, reason: session.levels != nil || session.showsBusy || session.isImporting || session.showsNewDocument
                                           ? "Finish the current dialog or project operation first." : nil) { session.showsImporter = true }
                }
                CommandGroup(replacing: .saveItem) {
                    LensWorksCommandButton(.save, reason: projectReason) { Task { await applicationDelegate.projects.save() } }
                    LensWorksCommandButton(.saveAs, reason: projectReason) { Task { await applicationDelegate.projects.save(asNew: true) } }
                    Divider()
                    LensWorksCommandButton(.exportPNG, reason: projectReason) { Task { await applicationDelegate.projects.exportPNG() } }
                    LensWorksCommandButton(.exportJPEG, reason: projectReason) { Task { await applicationDelegate.projects.exportJPEG() } }
                    Divider()
                    LensWorksCommandButton(.closeProject, reason: startReason) {
                        if let window = applicationDelegate.projects.window {
                            Task { await applicationDelegate.projects.close(window) }
                        }
                    }
                }
                // Grouped: a commands builder takes at most ten items.
                Group {
                    CommandGroup(after: .toolbar) {
                        // With a dialog's preview open (Export JPEG), these zoom that preview rather than the canvas.
                        LensWorksCommandButton(.fitCanvas, reason: documentReason) {
                            if let preview = session.previewZoom { preview(.fit) } else { session.fit() }
                        }
                        LensWorksCommandButton(.actualPixels, reason: documentReason) {
                            if let preview = session.previewZoom { preview(.actual) } else { session.zoom(to: 1) }
                        }
                        LensWorksCommandButton(.zoomIn, reason: documentReason) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomIn) } else { session.zoomKeyboard(by: 1) }
                        }
                        LensWorksCommandButton(.zoomOut, reason: documentReason) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomOut) } else { session.zoomKeyboard(by: -1) }
                        }
                        LensWorksCommandToggle(.pixelGrid, isOn: Binding(get: { session.showsPixelGrid }, set: { session.showsPixelGrid = $0 }))
                        LensWorksCommandToggle(.smartSnap, isOn: Binding(get: { session.snappingEnabled }, set: { session.snappingEnabled = $0 }))
                        LensWorksCommandToggle(.transformControls, reason: documentReason ?? LensWorksCommandRegistry.unavailable(session.tool != .move, "Choose the Move tool first."),
                                               isOn: Binding(get: { session.showsTransformControls }, set: { session.showsTransformControls = $0 }))
                        Group {
                            Divider()
                            Menu("Show") {
                                LensWorksCommandToggle(.showGrid, reason: documentReason, isOn: Binding(get: { session.showsGrid }, set: { session.showsGrid = $0 }))
                                LensWorksCommandToggle(.showGuides, reason: documentReason, isOn: Binding(get: { session.showsGuides }, set: { session.showsGuides = $0 }))
                            }
                            LensWorksCommandButton(.gridSettings, reason: documentReason) { Task { await applicationDelegate.projects.gridSettings() } }
                            LensWorksCommandToggle(.rulers, reason: documentReason, isOn: Binding(get: { session.showsRulers }, set: { session.showsRulers = $0 }))
                            Divider()
                            LensWorksCommandToggle(.snap, reason: documentReason, isOn: Binding(get: { session.snapEnabled }, set: { session.snapEnabled = $0 }))
                            Menu("Snap To") {
                                LensWorksCommandToggle(.snapToGuides, reason: documentReason, isOn: Binding(get: { session.snapToGuides }, set: { session.snapToGuides = $0 }))
                                LensWorksCommandToggle(.snapToGrid, reason: documentReason, isOn: Binding(get: { session.snapToGrid }, set: { session.snapToGrid = $0 }))
                                LensWorksCommandToggle(.snapToLayers, reason: documentReason, isOn: Binding(get: { session.snapToLayers }, set: { session.snapToLayers = $0 }))
                                LensWorksCommandToggle(.snapToBounds, reason: documentReason, isOn: Binding(get: { session.snapToDocumentBounds }, set: { session.snapToDocumentBounds = $0 }))
                            }
                            Divider()
                            LensWorksCommandToggle(.lockGuides, reason: documentReason, isOn: Binding(get: { session.locksGuides }, set: { session.locksGuides = $0 }))
                            LensWorksCommandButton(.clearGuides, reason: session.commandReason(!session.canClearGuides, "There are no guides to clear.")) { session.clearGuides() }
                        }
                    }
                    // ⌘H toggles the Move tool's transform controls instead of hiding the app, so Hide keeps its
                    // place in the app menu without the shortcut.
                    CommandGroup(replacing: .appVisibility) {
                        LensWorksCommandButton(.hideApp) { NSApp.hide(nil) }
                        LensWorksCommandButton(.hideOthers) { NSApp.hideOtherApplications(nil) }
                        LensWorksCommandButton(.showAll) { NSApp.unhideAllApplications(nil) }
                    }
                }
                CommandGroup(replacing: .pasteboard) {
                    // Canvas pixels when the canvas has focus; text fields keep their own editing.
                    // Cut, Copy and Paste check when chosen rather than through .disabled: what they depend on
                    // (the pasteboard, the copied pixels, the busy flag) isn't observed, so a disabled state could
                    // go stale — the first Paste after a Copy used to beep until something else refreshed the menu.
                    LensWorksCommandButton(.cut) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.cut(_:)), to: nil, from: nil) }
                        else if session.selection != nil, session.canCopyPixels { Task { await session.cutSelection() } }
                        else { NSSound.beep() }
                    }
                    LensWorksCommandButton(.copyPixels) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil) }
                        else if session.canCopyPixels || session.canCopyLayer { session.copySelection() }
                        else { NSSound.beep() }
                    }
                    LensWorksCommandButton(.copyMerged, reason: session.commandReason(!session.canCopyMerged, "Make a selection on a visible document first.")) { session.copyMergedSelection() }
                    LensWorksCommandButton(.paste) {
                        if NSApp.keyWindow?.firstResponder is NSTextView { NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil) }
                        else if applicationDelegate.workspace.pasteCopiedLayer() { }
                        else if session.canPaste { session.paste() }
                        else { NSSound.beep() }
                    }
                }
                CommandGroup(after: .pasteboard) {
                    Divider()
                    LensWorksCommandButton(.keyboardShortcuts) { ShortcutSettings.shared.show() }
                    LensWorksCommandButton(.aiModels) { LWModelCenter.shared.show() }
                    // Photoshop's fill shortcuts; in a text field they keep their text meaning.
                    LensWorksCommandButton(.fillForeground, reason: pixelReason) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteWordBackward(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .foreground) } }
                    }
                    LensWorksCommandButton(.fillBackground, reason: pixelReason) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .background) } }
                    }
                    LensWorksCommandButton(.clearSelectionPixels, reason: session.commandReason(session.selection == nil, "Make a selection first.") ?? pixelReason) {
                        Task { await session.clearSelectedPixels() }
                    }
                    LensWorksCommandButton(.contentAwareFill, reason: session.commandReason(!session.canContentAwareFill, "Select an area of an editable pixel layer first.")) {
                        session.beginFilter(.contentAwareFill)
                    }
                }
                CommandMenu("Select") {
                    // A field being edited keeps its own Select All: offer it to the responder chain
                    // first, which covers every kind of text control rather than NSTextView alone,
                    // and select the canvas only when nothing there wanted it.
                    // Never disabled: on macOS this menu item is what binds Cmd-A to selectAll:, so
                    // switching it off takes Select All away from every text field too. With no
                    // document and nothing being edited the action simply does nothing.
                    LensWorksCommandButton(.selectAll) {
                        if NSApp.sendAction(#selector(NSText.selectAll(_:)), to: nil, from: nil) { return }
                        guard session.document != nil else { return }
                        session.selectAll()
                    }
                    LensWorksCommandButton(.deselect, reason: session.commandReason(session.selection == nil, "There is no selection.") ?? selectionReason) { session.deselect() }
                    LensWorksCommandButton(.inverseSelection, reason: session.commandReason(session.selection == nil, "There is no selection.") ?? selectionReason) { session.invertSelection() }
                    LensWorksCommandButton(.selectLayerPixels, reason: session.commandReason(session.activeLayer?.asset == nil, "Select a pixel layer first.") ?? selectionReason) {
                        if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
                    }
                    LensWorksCommandButton(.selectSubject, reason: session.commandReason(!session.canSelectSubject, "Finish the current tool, dialog or layer edit first.")) { Task { await session.selectSubject() } }
                    LensWorksCommandButton(.colorRange, reason: session.commandReason(!session.canSelectColorRange, "Finish the current tool, dialog or layer edit first.")) { session.beginColorRange() }
                    LensWorksCommandButton(.selectMaskBlack, reason: session.commandReason(session.activeLayer?.mask == nil, "Select a layer with a mask first.") ?? selectionReason) {
                        if let id = session.activeLayerID { session.loadMaskSelection(layerID: id) }
                    }
                    Divider()
                    LensWorksCommandButton(.expandSelection, reason: modifySelectionReason) { session.promptSelectionAmount(.expand) }
                    LensWorksCommandButton(.contractSelection, reason: modifySelectionReason) { session.promptSelectionAmount(.contract) }
                    LensWorksCommandButton(.featherSelection, reason: modifySelectionReason) { session.promptSelectionAmount(.feather) }
                }
                CommandMenu("Image") {
                    LensWorksCommandButton(.curves, reason: adjustReason) { session.beginFilter(.curves) }
                    LensWorksCommandButton(.levels, reason: adjustReason) { session.beginLevels() }
                    LensWorksCommandButton(.hueSaturation, reason: session.commandReason(!session.canAdjustColors, "Select an editable pixel layer first.")) { session.beginHueSaturation() }
                    ForEach(LensWorksCommandRegistry.imageAdjustmentKinds, id: \.self) { kind in
                        LensWorksCommandButton(.imageAdjustment, argument: kind.rawValue, title: "\(kind.rawValue)…", reason: adjustReason) { session.beginFilter(kind) }
                    }
                    LensWorksCommandButton(.invert, title: session.isMaskSelected ? "Invert Mask" : "Invert",
                                           reason: session.commandReason(!session.canInvert, "Select an editable pixel layer or mask first.")) { Task { await session.invertPixels() } }
                    Divider()
                    LensWorksCommandButton(.canvasSize, reason: projectReason) { Task { await applicationDelegate.projects.canvasSize() } }
                    LensWorksCommandButton(.imageSize, reason: projectReason) { Task { await applicationDelegate.projects.imageSize() } }
                    LensWorksCommandButton(.trim, reason: projectReason) { Task { await applicationDelegate.projects.trim() } }
                    Group {
                        Divider()
                        LensWorksCommandButton(.flipCanvasHorizontal, reason: layerEditReason) { session.flipCanvas(horizontally: true) }
                        LensWorksCommandButton(.flipCanvasVertical, reason: layerEditReason) { session.flipCanvas(horizontally: false) }
                    }
                }
                CommandMenu("Filter") {
                    ForEach(LensWorksCommandRegistry.filterMenuKinds, id: \.self) { kind in
                        LensWorksCommandButton(.filter, argument: kind.rawValue, title: "\(kind.rawValue)…",
                                               reason: session.commandReason(!(kind == .vignette ? session.canVignette : session.canAdjustColors), "Select an editable pixel layer first.")
                                                ?? LensWorksCommandRegistry.unavailable(session.hueSaturation != nil, "Finish Hue/Saturation first.")) { session.beginFilter(kind) }
                    }
                }
                CommandMenu("Layer") {
                    Menu("New Adjustment Layer") {
                        ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                            LensWorksCommandButton(.newAdjustment, argument: kind.rawValue, title: kind.rawValue + (kind.isEditable ? "…" : "")) { session.addAdjustment(kind) }
                        }
                    }.disabled(!session.canEditLayers || session.document == nil)
                    LensWorksCommandButton(.editAdjustment, reason: layerEditReason ?? session.commandReason(session.activeLayer?.adjustment == nil, "Select an adjustment layer first.")) {
                        session.adjustmentEditingID = session.activeLayerID
                    }
                    Divider()
                    LensWorksCommandButton(.transform, title: session.canTransformSelection ? "Transform Selection" : "Transform Layer",
                                           reason: session.commandReason(!session.canTransform && !session.canTransformSelection, "Select a layer that can be transformed first.")) { session.transformCommand() }
                    LensWorksCommandButton(.layerViaCopy, title: session.selection == nil ? "Duplicate Layer" : "Layer via Copy",
                                           reason: session.commandReason(!session.canCopyPixels && !(session.selection == nil && session.canEditLayers && session.activeLayer != nil), "Select a layer or an area of pixels first.")) { session.layerViaCopy() }
                    Divider()
                    LensWorksCommandButton(.clippingMask, title: session.activeLayer?.maskSourceID == nil ? "Create Clipping Mask" : "Release Clipping Mask",
                                           reason: session.commandReason(session.activeLayerID.map { !session.canToggleClippingMask($0) } ?? true, "Select a layer above another layer first.")) {
                        if let id = session.activeLayerID { session.toggleClippingMask(id) }
                    }
                    Divider()
                    LensWorksCommandButton(.groupLayers, reason: layerEditReason) { session.groupSelectedLayers() }
                    LensWorksCommandButton(.ungroupLayers, reason: session.commandReason(!session.canUngroupLayers, "Select a folder first.")) { session.ungroupLayers() }
                    LensWorksCommandButton(.moveOutOfFolder, reason: layerEditReason ?? session.commandReason(session.activeLayer?.parentID == nil, "Select a layer inside a folder first.")) { session.moveActiveLayerOutOfGroup() }
                    LensWorksCommandButton(.newBlankLayer, reason: layerEditReason) { session.addBlankLayer() }
                    LensWorksLayerCommandButton(session: session, id: .beginRename)
                    LensWorksLayerCommandButton(session: session, id: .visibility,
                        label: session.activeLayer?.isVisible == false ? "Show Layer" : "Hide Layer")
                        .registeredCommandShortcut(.visibility)
                    Divider()
                    LensWorksCommandButton(.moveLayerUp, reason: session.commandReason(!session.canMoveActiveLayer(by: 1), "The layer cannot move up.")) { session.moveActiveLayer(by: 1) }
                    LensWorksCommandButton(.moveLayerDown, reason: session.commandReason(!session.canMoveActiveLayer(by: -1), "The layer cannot move down.")) { session.moveActiveLayer(by: -1) }
                    Group {
                        LensWorksCommandButton(.mergeLayers, title: session.mergeTitle, reason: session.commandReason(!session.canMergeLayers, "Select layers that can be merged first.")) { session.mergeLayers() }
                        Divider()
                        LensWorksCommandButton(.flipLayerHorizontal, reason: session.commandReason(!session.canTransform, "Select a layer that can be transformed first.")) { session.flipLayers(horizontally: true) }
                        LensWorksCommandButton(.flipLayerVertical, reason: session.commandReason(!session.canTransform, "Select a layer that can be transformed first.")) { session.flipLayers(horizontally: false) }
                    }
                    Divider()
                    LensWorksCommandButton(.deleteLayer, title: session.selectedEffect != nil ? "Delete " + session.selectedEffect!.kind.rawValue : session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Layer Mask" : session.selectedLayerIDs.count > 1 ? "Delete Layers" : "Delete Layer",
                                           reason: layerEditReason ?? session.commandReason(session.activeLayer == nil, "Select a layer first.")) {
                        session.deleteLayerOrMask()
                    }
                }
            }
        Settings { LensWorksAutomationSettingsView(automation: applicationDelegate.automation) }
    }
    private var startReason: String? {
        LensWorksCommandRegistry.unavailable(!applicationDelegate.projects.canStart, "Finish the current project operation first.")
    }
    private var documentReason: String? { LensWorksCommandRegistry.unavailable(session.document == nil, "Open a document first.") }
    private var projectReason: String? { documentReason ?? startReason }
    private var pixelReason: String? { session.commandReason(!session.canEditPixels, "Select an editable pixel layer first.") }
    private var selectionReason: String? { session.commandReason(!session.canEditSelection, "Finish the current tool, dialog or layer edit first.") }
    private var modifySelectionReason: String? { session.commandReason(!session.canModifySelection, "Make a selection first.") }
    private var layerEditReason: String? { session.commandReason(!session.canEditLayers, "Finish the current tool, dialog or layer edit first.") }
    private var adjustReason: String? {
        session.commandReason(!session.canAdjustColors, "Select an editable pixel layer first.")
            ?? LensWorksCommandRegistry.unavailable(session.hueSaturation != nil, "Finish Hue/Saturation first.")
    }
}
