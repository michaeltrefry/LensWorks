import AppKit
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct CommandRegistryTests {
    private func session() throws -> EditorSession {
        let value = EditorSession(); value.createDocument(width: 8, height: 8); value.addBlankLayer(); value.history.reset(); return value
    }
    @Test func registryHasStableUniqueIDsAndTypedDescriptions() {
        let rows = LensWorksCommandRegistry.descriptors
        #expect(Set(rows.map(\.id)) == Set(LensWorksCommandID.allCases))
        #expect(Set(rows.map(\.id)).count == rows.count)
        #expect(rows.allSatisfy { !$0.label.isEmpty && !$0.menu.isEmpty && $0.parameters.allSatisfy { !$0.description.isEmpty } })
        #expect(LensWorksCommandRegistry.descriptor(.exposure).historyOwner == .nativeRecipe)
        #expect(LensWorksCommandRegistry.descriptor(.rating).historyOwner == .nativeMetadata)
    }
    @Test func hideMenuAndShortcutShareTheRegisteredIDAndOneUndo() throws {
        let session = try session(), id = try #require(session.activeLayerID)
        let shortcut = try #require(ShortcutDefinition.all.first { $0.commandID == .visibility })
        #expect(shortcut.id == LensWorksCommandID.visibility.rawValue)
        #expect(shortcut.original.key == LensWorksCommandRegistry.descriptor(.visibility).shortcut?.key)
        #expect(shortcut.original.modifiers == LensWorksCommandRegistry.descriptor(.visibility).shortcut?.modifiers)
        for _ in 0..<2 {
            _ = try session.dispatchCommand(session.admitCommand(.visibility([id], nil)))
            #expect(session.history.undoCount == 1 && session.history.undoName == "Hide Layer")
            session.undo(); #expect(session.activeLayer?.isVisible == true)
        }
    }
    @Test func layerMenuVisibilityItemAndItsKeyBindingResolveToTheSameCommand() async throws {
        // The effective binding registered for .visibility resolves back to that command alone.
        let binding = try #require(ShortcutDefinition.all.first { $0.commandID == .visibility })
        let chord = ShortcutSettings.shared.chord(binding)
        #expect(ShortcutDefinition.all.filter { $0.isMenu && ShortcutSettings.shared.chord($0) == chord }.map(\.commandID) == [.visibility])
        // The rendered Layer menu item for that command carries exactly that binding, and no
        // other item in the main menu claims it, so the key and the menu reach the same command.
        var layerMenu: NSMenu?
        for _ in 0..<50 where layerMenu == nil {
            layerMenu = NSApp.mainMenu?.items.first { $0.title == LensWorksCommandRegistry.descriptor(.visibility).menu }?.submenu
            if layerMenu == nil { try await Task.sleep(for: .milliseconds(100)) }
        }
        let menu = try #require(layerMenu)
        let titles = ["Hide Layer", "Show Layer"]
        let item = try #require(menu.items.first { item in titles.contains { item.title == $0 || item.title.hasPrefix($0 + " — ") } })
        let mask: NSEvent.ModifierFlags = [(chord.modifiers & 1 != 0 ? .command : []), (chord.modifiers & 2 != 0 ? .option : []),
                                           (chord.modifiers & 4 != 0 ? .control : []), (chord.modifiers & 8 != 0 ? .shift : [])]
        func claims(_ candidate: NSMenuItem) -> Bool {
            candidate.keyEquivalent.lowercased() == chord.key && candidate.keyEquivalentModifierMask.intersection([.command, .option, .control, .shift]) == mask
        }
        #expect(claims(item))
        func all(_ menu: NSMenu) -> [NSMenuItem] { menu.items.flatMap { [$0] + ($0.submenu.map(all) ?? []) } }
        #expect(all(try #require(NSApp.mainMenu)).filter(claims).count == 1)
    }
    @Test func renameMenuWithoutASelectedLayerSaysToSelectOne() throws {
        let session = try session()
        session.selectedLayerIDs = []; session.activeLayerID = nil
        #expect(session.layerMenuCommand(.beginRename) == nil)
        #expect(session.layerMenuAvailability(session.layerMenuCommand(.beginRename)) == "Select a layer first.")
        #expect(session.layerMenuAvailability(session.layerMenuCommand(.visibility)) == "Select a layer first.")
    }
    @Test func opacityBurstCreatesOneNamedUndoAndRedo() throws {
        let session = try session(), id = try #require(session.activeLayerID)
        let token = try session.beginCommandInteraction(.opacity([id], 1))
        for value in [0.9, 0.6, 0.25] { _ = try session.dispatchCommand(session.admitCommand(.opacity([id], value))) }
        #expect(!session.history.canUndo && session.canEditOpacity)
        try session.endCommandInteraction(token)
        #expect(session.history.undoCount == 1 && session.history.undoName == "Layer Opacity")
        session.undo(); #expect(session.activeLayer?.opacity == 1)
        session.redo(); #expect(session.activeLayer?.opacity == 0.25)
    }
    @Test func standaloneOpacityChangeCommitsOneCommandAndLeavesNoInteractionOpen() throws {
        let session = try session(), id = try #require(session.activeLayerID)
        var control = LayerOpacityInteraction()
        // A keyboard or accessibility increment arrives without onEditingChanged.
        control.set(0.4, session: session, layerID: id)
        #expect(control.token == nil && session.commandInteraction == nil)
        #expect(session.commandAvailability(.visibility([id], nil)) == nil)
        #expect(session.activeLayer?.opacity == 0.4)
        #expect(session.history.undoCount == 1 && session.history.undoName == "Layer Opacity")
        session.undo(); #expect(session.activeLayer?.opacity == 1 && session.history.undoCount == 0)
    }
    @Test func cancelRestoresStartingValueWithoutHistoryAndPreservesRedo() throws {
        let session = try session(), id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "Saved name"); session.undo()
        let before = session.document, revision = session.history.currentRevision
        let token = try session.beginCommandInteraction(.opacity([id], 1))
        _ = session.runCommand(.opacity([id], 0.1))
        try session.cancelCommandInteraction(token)
        #expect(session.document == before && session.history.currentRevision == revision)
        #expect(session.history.undoCount == 0 && session.history.canRedo)
        session.redo(); #expect(session.activeLayer?.name == "Saved name")
    }
    @Test(arguments: [Double.nan, .infinity, -0.1, 1.1])
    func invalidOpacityCannotMutateOrEnterHistory(_ value: Double) throws {
        let session = try session(), id = try #require(session.activeLayerID), before = session.document
        #expect(!session.runCommand(.opacity([id], value)))
        #expect(session.document == before && session.history.undoCount == 0 && session.commandRefusal != nil)
    }
    @Test func admissionRejectsDocumentSelectionAndRevisionABA() throws {
        let session = try session(), id = try #require(session.activeLayerID)
        let admission = try session.admitCommand(.rename(id, "Late"))
        session.renameLayer(id, to: "Intervening"); session.undo(); session.renameLayer(id, to: "Again")
        #expect(throws: LensWorksCommandRefusal.self) { try session.dispatchCommand(admission) }
        #expect(session.activeLayer?.name == "Again")
        let selected = try session.admitCommand(.visibility([id], nil))
        session.addBlankLayer()
        #expect(throws: LensWorksCommandRefusal.self) { try session.dispatchCommand(selected) }
    }
    @Test func disabledReasonIsTheRenderedMenuReasonAndDispatchRefusal() throws {
        let session = try session(), id = try #require(session.activeLayerID)
        session.isProjectBusy = true
        let command = LensWorksLayerCommand.visibility([id], nil)
        let reason = try #require(session.commandAvailability(command))
        #expect(LensWorksCommandRegistry.menuLabel("Hide Layer", reason: reason).contains(reason))
        do { _ = try session.admitCommand(command); Issue.record("Busy command was admitted") }
        catch let error as LensWorksCommandRefusal { #expect(error.reason == reason) }
        #expect(session.history.undoCount == 0 && session.activeLayer?.isVisible == true)
    }
    @Test func nestedInteractionAndForeignTokenCannotConsumeOwnership() throws {
        let session = try session(), id = try #require(session.activeLayerID)
        let token = try session.beginCommandInteraction(.opacity([id], 1))
        #expect(throws: LensWorksCommandRefusal.self) { try session.beginCommandInteraction(.opacity([id], 1)) }
        #expect(throws: LensWorksCommandRefusal.self) { try session.cancelCommandInteraction(UUID()) }
        #expect(session.commandInteraction?.token == token)
        try session.cancelCommandInteraction(token); #expect(session.commandInteraction == nil)
    }
    @Test func cancelCannotOverwriteAReplacementDocument() throws {
        let session = try session(), id = try #require(session.activeLayerID)
        let token = try session.beginCommandInteraction(.opacity([id], 1))
        let next = EditorSession(); next.createDocument(width: 9, height: 9)
        session.installProject(try #require(next.projectSnapshot()), from: URL(fileURLWithPath: "/tmp/Replacement.comp"))
        let replacement = session.document
        #expect(throws: LensWorksCommandRefusal.self) { try session.cancelCommandInteraction(token) }
        #expect(session.document == replacement)
    }
    @Test func visibilitySwipeUsesOneRegistryTransaction() throws {
        let session = try session(); session.addBlankLayer(); session.history.reset()
        let ids = try #require(session.document?.layers.map(\.id)), first = try #require(ids.first)
        #expect(session.beginVisibilitySwipe(first) == false)
        for id in ids { session.setVisibilityInSwipe(id, visible: false) }
        session.endVisibilitySwipe()
        #expect(session.history.undoCount == 1 && session.document?.layers.allSatisfy { !$0.isVisible } == true)
        session.undo(); #expect(session.document?.layers.allSatisfy(\.isVisible) == true)
    }
    @Test func renameRoundTripsAndRejectsEmptyOversizedNames() throws {
        let session = try session(), id = try #require(session.activeLayerID), old = session.activeLayer?.name
        session.renameLayer(id, to: "  New name  "); #expect(session.activeLayer?.name == "New name")
        session.renameLayer(id, to: " "); session.renameLayer(id, to: String(repeating: "a", count: 16_385))
        #expect(session.history.undoCount == 1)
        session.undo(); #expect(session.activeLayer?.name == old)
    }
    @Test func renamePromptRetainsClickTimeSnapshotAcrossSelectionAndReplacement() throws {
        let session = try session(), id = try #require(session.activeLayerID)
        _ = session.runCommand(.beginRename(id))
        #expect(session.commandRenameAdmission != nil)
        let before = session.document
        session.selectedLayerIDs = []
        session.renameLayer(id, to: "Late name")
        #expect(session.document == before && session.commandRefusal != nil)
    }
    @Test func layerCommandSerializationPreservesTypedReplayValues() throws {
        let id = UUID()
        for command in [LensWorksLayerCommand.visibility([id], false), .opacity([id], 0.25), .rename(id, "A recorded name")] {
            let data = try JSONEncoder().encode(command)
            #expect(try JSONDecoder().decode(LensWorksLayerCommand.self, from: data) == command)
        }
    }

    @Test func selectionABAAndInteractionCancelInvalidateHeldAdmissions() throws {
        let session = try session(); session.addBlankLayer(); session.history.reset()
        let ids = try #require(session.document?.layers.map(\.id)), selected = try #require(session.activeLayerID)
        let held = try session.admitCommand(.visibility([selected], nil))
        session.activeLayerID = ids.first; session.activeLayerID = selected
        #expect(throws: LensWorksCommandRefusal.self) { try session.dispatchCommand(held) }
        let beforeInteraction = try session.admitCommand(.opacity([selected], 0.3))
        let token = try session.beginCommandInteraction(.opacity([selected], 1))
        try session.cancelCommandInteraction(token)
        #expect(throws: LensWorksCommandRefusal.self) { try session.dispatchCommand(beforeInteraction) }
        #expect(session.activeLayer?.opacity == 1 && session.history.undoCount == 0)
    }


    @Test func samePrimarySelectionRetiresOwnedOpacityBeforeChangingEpoch() throws {
        let session = try session(); session.addBlankLayer(); session.history.reset()
        let ids = try #require(session.document?.layers.map(\.id)), b = try #require(session.activeLayerID)
        let a = try #require(ids.first { $0 != b })
        session.beginOpacityEdit()
        let token = try #require(session.commandInteraction?.token)
        session.setLayerOpacity(0.25)
        let delayed = try session.admitCommand(.opacity([b], 0.5))
        session.selectLayers([a, b], primary: b) // Production path; the primary does not change.
        #expect(session.commandInteraction == nil && session.opacityEditLayerID == nil)
        #expect(session.history.undoCount == 1 && session.history.canUndo && session.canEditLayers && session.canStartProjectOperation)
        #expect(session.selectedLayerIDs == [a, b] && session.activeLayerID == b)
        #expect(session.document?.layers.first { $0.id == a }?.opacity == 1 && session.activeLayer?.opacity == 0.25)
        #expect(throws: LensWorksCommandRefusal.self) { try session.dispatchCommand(delayed) }
        #expect(throws: LensWorksCommandRefusal.self) { try session.cancelCommandInteraction(token) }
        session.finishOpacityEdit() // A stale view finishing the retired interaction cannot add another entry.
        #expect(session.history.undoCount == 1)
        session.undo(); #expect(session.activeLayer?.opacity == 1 && session.history.canRedo)
    }

}
