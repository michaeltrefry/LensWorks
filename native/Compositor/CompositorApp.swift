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
                                               reason: reason(.undo)) { session.undo() }
                        LensWorksCommandButton(.redo, title: session.history.canRedo ? "Redo \(session.history.redoName)" : "Redo",
                                               reason: reason(.redo)) { session.redo() }
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
                    LensWorksCommandButton(.newCanvas, reason: reason(.newCanvas)) {
                        applicationDelegate.showEditor?()
                        Task { await applicationDelegate.projects.newCanvas() }
                    }
                    LensWorksCommandButton(.openProject, reason: reason(.openProject)) {
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
                    LensWorksCommandButton(.importImages, reason: reason(.importImages)) { session.showsImporter = true }
                }
                CommandGroup(replacing: .saveItem) {
                    LensWorksCommandButton(.save, reason: reason(.save)) { Task { await applicationDelegate.projects.save() } }
                    LensWorksCommandButton(.saveAs, reason: reason(.saveAs)) { Task { await applicationDelegate.projects.save(asNew: true) } }
                    Divider()
                    LensWorksCommandButton(.exportPNG, reason: reason(.exportPNG)) { Task { await applicationDelegate.projects.exportPNG() } }
                    LensWorksCommandButton(.exportJPEG, reason: reason(.exportJPEG)) { Task { await applicationDelegate.projects.exportJPEG() } }
                    Divider()
                    LensWorksCommandButton(.closeProject, reason: reason(.closeProject)) {
                        if let window = applicationDelegate.projects.window {
                            Task { await applicationDelegate.projects.close(window) }
                        }
                    }
                }
                // Grouped: a commands builder takes at most ten items.
                Group {
                    CommandGroup(after: .toolbar) {
                        // With a dialog's preview open (Export JPEG), these zoom that preview rather than the canvas.
                        LensWorksCommandButton(.fitCanvas, reason: reason(.fitCanvas)) {
                            if let preview = session.previewZoom { preview(.fit) } else { session.fit() }
                        }
                        LensWorksCommandButton(.actualPixels, reason: reason(.actualPixels)) {
                            if let preview = session.previewZoom { preview(.actual) } else { session.zoom(to: 1) }
                        }
                        LensWorksCommandButton(.zoomIn, reason: reason(.zoomIn)) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomIn) } else { session.zoomKeyboard(by: 1) }
                        }
                        LensWorksCommandButton(.zoomOut, reason: reason(.zoomOut)) {
                            guard !(NSApp.keyWindow?.firstResponder is NSText) else { return }
                            if let preview = session.previewZoom { preview(.zoomOut) } else { session.zoomKeyboard(by: -1) }
                        }
                        LensWorksCommandToggle(.pixelGrid, isOn: Binding(get: { session.showsPixelGrid }, set: { session.showsPixelGrid = $0 }))
                        LensWorksCommandToggle(.smartSnap, isOn: Binding(get: { session.snappingEnabled }, set: { session.snappingEnabled = $0 }))
                        LensWorksCommandToggle(.transformControls, reason: reason(.transformControls),
                                               isOn: Binding(get: { session.showsTransformControls }, set: { session.showsTransformControls = $0 }))
                        Group {
                            Divider()
                            Menu("Show") {
                                LensWorksCommandToggle(.showGrid, reason: reason(.showGrid), isOn: Binding(get: { session.showsGrid }, set: { session.showsGrid = $0 }))
                                LensWorksCommandToggle(.showGuides, reason: reason(.showGuides), isOn: Binding(get: { session.showsGuides }, set: { session.showsGuides = $0 }))
                            }
                            LensWorksCommandButton(.gridSettings, reason: reason(.gridSettings)) { Task { await applicationDelegate.projects.gridSettings() } }
                            LensWorksCommandToggle(.rulers, reason: reason(.rulers), isOn: Binding(get: { session.showsRulers }, set: { session.showsRulers = $0 }))
                            Divider()
                            LensWorksCommandToggle(.snap, reason: reason(.snap), isOn: Binding(get: { session.snapEnabled }, set: { session.snapEnabled = $0 }))
                            Menu("Snap To") {
                                LensWorksCommandToggle(.snapToGuides, reason: reason(.snapToGuides), isOn: Binding(get: { session.snapToGuides }, set: { session.snapToGuides = $0 }))
                                LensWorksCommandToggle(.snapToGrid, reason: reason(.snapToGrid), isOn: Binding(get: { session.snapToGrid }, set: { session.snapToGrid = $0 }))
                                LensWorksCommandToggle(.snapToLayers, reason: reason(.snapToLayers), isOn: Binding(get: { session.snapToLayers }, set: { session.snapToLayers = $0 }))
                                LensWorksCommandToggle(.snapToBounds, reason: reason(.snapToBounds), isOn: Binding(get: { session.snapToDocumentBounds }, set: { session.snapToDocumentBounds = $0 }))
                            }
                            Divider()
                            LensWorksCommandToggle(.lockGuides, reason: reason(.lockGuides), isOn: Binding(get: { session.locksGuides }, set: { session.locksGuides = $0 }))
                            LensWorksCommandButton(.clearGuides, reason: reason(.clearGuides)) { session.clearGuides() }
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
                    LensWorksCommandButton(.copyMerged, reason: reason(.copyMerged)) { session.copyMergedSelection() }
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
                    LensWorksCommandButton(.fillForeground, reason: reason(.fillForeground)) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteWordBackward(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .foreground) } }
                    }
                    LensWorksCommandButton(.fillBackground, reason: reason(.fillBackground)) {
                        if NSApp.keyWindow?.firstResponder is NSTextView {
                            NSApp.sendAction(#selector(NSResponder.deleteToBeginningOfLine(_:)), to: nil, from: nil)
                        } else { Task { await session.fillSelection(with: .background) } }
                    }
                    LensWorksCommandButton(.clearSelectionPixels, reason: reason(.clearSelectionPixels)) {
                        Task { await session.clearSelectedPixels() }
                    }
                    LensWorksCommandButton(.contentAwareFill, reason: reason(.contentAwareFill)) {
                        session.beginFilter(.contentAwareFill)
                    }
                }
                // The commands builder takes ten children, so the Photo menu rides in a group with Select.
                Group {
                CommandMenu("Photo") {
                    LensWorksCommandButton(.mergeToHDR, reason: applicationDelegate.catalog.hdrMergeUnavailableReason) {
                        Task { await applicationDelegate.catalog.promptMergeSelectionToHDR() }
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
                    LensWorksCommandButton(.deselect, reason: reason(.deselect)) { session.deselect() }
                    LensWorksCommandButton(.inverseSelection, reason: reason(.inverseSelection)) { session.invertSelection() }
                    LensWorksCommandButton(.selectLayerPixels, reason: reason(.selectLayerPixels)) {
                        if let id = session.activeLayerID { session.loadLayerSelection(layerID: id) }
                    }
                    LensWorksCommandButton(.selectSubject, reason: reason(.selectSubject)) { Task { await session.selectSubject() } }
                    LensWorksCommandButton(.colorRange, reason: reason(.colorRange)) { session.beginColorRange() }
                    LensWorksCommandButton(.selectMaskBlack, reason: reason(.selectMaskBlack)) {
                        if let id = session.activeLayerID { session.loadMaskSelection(layerID: id) }
                    }
                    Divider()
                    LensWorksCommandButton(.expandSelection, reason: reason(.expandSelection)) { session.promptSelectionAmount(.expand) }
                    LensWorksCommandButton(.contractSelection, reason: reason(.contractSelection)) { session.promptSelectionAmount(.contract) }
                    LensWorksCommandButton(.featherSelection, reason: reason(.featherSelection)) { session.promptSelectionAmount(.feather) }
                }
                }
                CommandMenu("Image") {
                    LensWorksCommandButton(.curves, reason: reason(.curves)) { session.beginFilter(.curves) }
                    LensWorksCommandButton(.levels, reason: reason(.levels)) { session.beginLevels() }
                    LensWorksCommandButton(.hueSaturation, reason: reason(.hueSaturation)) { session.beginHueSaturation() }
                    ForEach(LensWorksCommandRegistry.imageAdjustmentKinds, id: \.self) { kind in
                        LensWorksCommandButton(.imageAdjustment, argument: kind.rawValue, title: "\(kind.rawValue)…", reason: reason(.imageAdjustment, kind.rawValue)) { session.beginFilter(kind) }
                    }
                    LensWorksCommandButton(.invert, title: session.isMaskSelected ? "Invert Mask" : "Invert",
                                           reason: reason(.invert)) { Task { await session.invertPixels() } }
                    Divider()
                    LensWorksCommandButton(.canvasSize, reason: reason(.canvasSize)) { Task { await applicationDelegate.projects.canvasSize() } }
                    LensWorksCommandButton(.imageSize, reason: reason(.imageSize)) { Task { await applicationDelegate.projects.imageSize() } }
                    LensWorksCommandButton(.trim, reason: reason(.trim)) { Task { await applicationDelegate.projects.trim() } }
                    Group {
                        Divider()
                        LensWorksCommandButton(.flipCanvasHorizontal, reason: reason(.flipCanvasHorizontal)) { session.flipCanvas(horizontally: true) }
                        LensWorksCommandButton(.flipCanvasVertical, reason: reason(.flipCanvasVertical)) { session.flipCanvas(horizontally: false) }
                    }
                }
                CommandMenu("Filter") {
                    ForEach(LensWorksCommandRegistry.filterMenuKinds, id: \.self) { kind in
                        LensWorksCommandButton(.filter, argument: kind.rawValue, title: "\(kind.rawValue)…",
                                               reason: reason(.filter, kind.rawValue)) { session.beginFilter(kind) }
                    }
                }
                CommandMenu("Layer") {
                    Menu("New Adjustment Layer") {
                        ForEach(AdjustmentKind.allCases, id: \.self) { kind in
                            LensWorksCommandButton(.newAdjustment, argument: kind.rawValue, title: kind.rawValue + (kind.isEditable ? "…" : "")) { session.addAdjustment(kind) }
                        }
                    }.disabled(!session.canEditLayers || session.document == nil)
                    LensWorksCommandButton(.editAdjustment, reason: reason(.editAdjustment)) {
                        session.adjustmentEditingID = session.activeLayerID
                    }
                    Divider()
                    LensWorksCommandButton(.transform, title: session.canTransformSelection ? "Transform Selection" : "Transform Layer",
                                           reason: reason(.transform)) { session.transformCommand() }
                    LensWorksCommandButton(.layerViaCopy, title: session.selection == nil ? "Duplicate Layer" : "Layer via Copy",
                                           reason: reason(.layerViaCopy)) { session.layerViaCopy() }
                    Divider()
                    LensWorksCommandButton(.clippingMask, title: session.activeLayer?.maskSourceID == nil ? "Create Clipping Mask" : "Release Clipping Mask",
                                           reason: reason(.clippingMask)) {
                        if let id = session.activeLayerID { session.toggleClippingMask(id) }
                    }
                    Divider()
                    LensWorksCommandButton(.groupLayers, reason: reason(.groupLayers)) { session.groupSelectedLayers() }
                    LensWorksCommandButton(.ungroupLayers, reason: reason(.ungroupLayers)) { session.ungroupLayers() }
                    LensWorksCommandButton(.moveOutOfFolder, reason: reason(.moveOutOfFolder)) { session.moveActiveLayerOutOfGroup() }
                    LensWorksCommandButton(.newBlankLayer, reason: reason(.newBlankLayer)) { session.addBlankLayer() }
                    LensWorksLayerCommandButton(session: session, id: .beginRename)
                    LensWorksLayerCommandButton(session: session, id: .visibility,
                        label: session.activeLayer?.isVisible == false ? "Show Layer" : "Hide Layer")
                        .registeredCommandShortcut(.visibility)
                    Divider()
                    LensWorksCommandButton(.moveLayerUp, reason: reason(.moveLayerUp)) { session.moveActiveLayer(by: 1) }
                    LensWorksCommandButton(.moveLayerDown, reason: reason(.moveLayerDown)) { session.moveActiveLayer(by: -1) }
                    Group {
                        LensWorksCommandButton(.mergeLayers, title: session.mergeTitle, reason: reason(.mergeLayers)) { session.mergeLayers() }
                        Divider()
                        LensWorksCommandButton(.flipLayerHorizontal, reason: reason(.flipLayerHorizontal)) { session.flipLayers(horizontally: true) }
                        LensWorksCommandButton(.flipLayerVertical, reason: reason(.flipLayerVertical)) { session.flipLayers(horizontally: false) }
                    }
                    Divider()
                    LensWorksCommandButton(.deleteLayer, title: session.selectedEffect != nil ? "Delete " + session.selectedEffect!.kind.rawValue : session.isMaskSelected && session.activeLayer?.mask != nil ? "Delete Layer Mask" : session.selectedLayerIDs.count > 1 ? "Delete Layers" : "Delete Layer",
                                           reason: reason(.deleteLayer)) {
                        session.deleteLayerOrMask()
                    }
                }
            }
        Settings { LensWorksAutomationSettingsView(automation: applicationDelegate.automation) }
    }
    /// The reason a menu-bar command is unavailable: the one answer the menu item shows and an agent is refused with.
    private func reason(_ id: LensWorksCommandID, _ argument: String? = nil) -> String? {
        session.menuReason(id, argument: argument, canStart: applicationDelegate.projects.canStart)
    }
}
