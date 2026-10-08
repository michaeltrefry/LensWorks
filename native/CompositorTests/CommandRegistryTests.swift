import AppKit
import Testing
@testable import Compositor

@Suite(.serialized)
@MainActor
struct CommandRegistryTests {
    private func session() throws -> EditorSession {
        let value = EditorSession(); value.createDocument(width: 8, height: 8); value.addBlankLayer(); value.history.reset(); return value
    }
    private func root() throws -> URL {
        let path = FileManager.default.temporaryDirectory.appendingPathComponent("LWCommands-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: path, withIntermediateDirectories: false); return path
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
    @Test func atomicProjectPersistsUndoRedoAndCurrentStateAcrossReopen() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(), id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "Persistent"); session.setLayerOpacity(0.4); session.undo()
        let file = root.appendingPathComponent("History.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: file)
        let loaded = try await ProjectStore.shared.load(from: file), reopened = EditorSession()
        reopened.installProject(loaded, from: file)
        #expect(reopened.activeLayer?.name == "Persistent" && reopened.activeLayer?.opacity == 1)
        #expect(reopened.history.canUndo && reopened.history.canRedo)
        reopened.redo(); #expect(reopened.activeLayer?.opacity == 0.4)
        reopened.undo(); reopened.undo(); #expect(reopened.activeLayer?.name != "Persistent")
    }
    @Test func corruptedHistoryIsRefusedBeforeReplacingTheLiveDocument() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(), id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "Durable")
        let file = root.appendingPathComponent("History.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: file)
        let metadata = file.appendingPathComponent("History/index.json")
        var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        index["revision"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: index).write(to: metadata)
        do { _ = try await ProjectStore.shared.load(from: file); Issue.record("Broken history was accepted") } catch { }
        #expect(session.activeLayer?.name == "Durable" && session.history.undoCount == 1)
    }
    @Test func autosaveCapturesHistoryAndUntitledRecoveryWithoutFirstSaveRetarget() async throws {
        let session = try session(), controller = ProjectController(session: session), id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "Recovered")
        await controller.finishWriting()
        let draft = try #require(controller.commandRecoveryURL)
        defer { try? FileManager.default.removeItem(at: draft) }
        #expect(session.projectURL == nil)
        let before = try ProjectDigest.compute(for: draft)
        let workspace = ProjectWorkspace()
        #expect(await workspace.open(draft)) // Ordinary Open follows the production controller/recovery path.
        let recovered = workspace.current.session, openedController = workspace.current.controller
        #expect(recovered.projectURL == nil && recovered.isModified && openedController.workingVersion == nil)
        #expect(openedController.commandRecoveryURL == draft)
        #expect(recovered.activeLayer?.name == "Recovered" && recovered.history.canUndo)
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let firstSave = root.appendingPathComponent("FirstSave.comp")
        #expect(await openedController.save(to: firstSave))
        #expect(recovered.projectURL == firstSave && !recovered.isModified && openedController.commandRecoveryURL == nil)
        #expect(try ProjectDigest.compute(for: draft) == before)
        let saved = try await ProjectStore.shared.load(from: firstSave)
        #expect(saved.manifest.recoveryDocumentID == nil && saved.workingVersion == nil)
        let reopened = EditorSession(); reopened.installProject(saved, from: firstSave)
        #expect(reopened.activeLayer?.name == "Recovered" && reopened.history.canUndo)
        reopened.undo(); #expect(reopened.activeLayer?.name != "Recovered")
    }
    @Test func savedDocumentAutosavePublishesCapturedRevisionAndHistory() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(), controller = ProjectController(session: session), id = try #require(session.activeLayerID)
        session.projectURL = root.appendingPathComponent("Saved.comp")
        for name in ["one", "two", "three"] { session.renameLayer(id, to: name) }
        await controller.finishWriting()
        let loaded = try await ProjectStore.shared.load(from: try #require(session.projectURL)), reopened = EditorSession()
        reopened.installProject(loaded, from: session.projectURL!)
        #expect(reopened.activeLayer?.name == "three" && reopened.history.undoCount == 3 && !session.isModified)
        reopened.undo(); #expect(reopened.activeLayer?.name == "two")
    }
    @Test func failedAutosaveDoesNotReportSavedOrEraseUndo() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let blocked = root.appendingPathComponent("parent"); try Data([1]).write(to: blocked)
        let session = try session(), controller = ProjectController(session: session), id = try #require(session.activeLayerID)
        session.projectURL = blocked.appendingPathComponent("Never.comp")
        session.renameLayer(id, to: "Retained"); await controller.finishWriting()
        #expect(session.isModified && session.history.canUndo && session.commandRefusal?.contains("autosave failed") == true)
        #expect(!FileManager.default.fileExists(atPath: session.projectURL!.path))
    }
    @Test(arguments: ["missing", "bad-index", "wrong-current", "unbound-asset", "symlink-history"])
    func malformedPersistentHistoryFailsClosed(_ fault: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(), id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "Unchanged live")
        let file = root.appendingPathComponent("History.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: file)
        let history = file.appendingPathComponent("History"), metadata = history.appendingPathComponent("index.json")
        if fault == "missing" { try FileManager.default.removeItem(at: history) }
        else if fault == "symlink-history" {
            let moved = root.appendingPathComponent("MovedHistory")
            try FileManager.default.moveItem(at: history, to: moved)
            try FileManager.default.createSymbolicLink(at: history, withDestinationURL: moved)
        } else {
            var index = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
            if fault == "bad-index" {
                var past = try #require(index["past"] as? [[String: Any]])
                past[0]["after"] = 999_999; index["past"] = past
            } else if fault == "wrong-current" {
                let stateURL = history.appendingPathComponent("states/1.json")
                var state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateURL)) as? [String: Any])
                var manifest = try #require(state["manifest"] as? [String: Any])
                manifest["documentID"] = UUID().uuidString; state["manifest"] = manifest
                try JSONSerialization.data(withJSONObject: state).write(to: stateURL)
            } else { index["assets"] = ["../../Original.png"] }
            try JSONSerialization.data(withJSONObject: index).write(to: metadata)
        }
        do { _ = try await ProjectStore.shared.load(from: file); Issue.record("Malformed history was accepted: \(fault)") } catch { }
        #expect(session.activeLayer?.name == "Unchanged live" && session.history.undoCount == 1)
    }
    @Test func historyAssetFailureLeavesPreviouslyPublishedPackageUnchanged() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(), id = try #require(session.activeLayerID)
        let destination = root.appendingPathComponent("Published.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: destination)
        let before = try ProjectDigest.compute(for: destination)
        var broken = try #require(session.projectSnapshot())
        var manifest = broken.manifest
        let record = try #require(manifest.layers.first)
        manifest.layers = [ProjectLayerRecord(id: id, name: record.name, isVisible: record.isVisible, transform: record.transform, imageFile: id.uuidString + ".png")]
        let state = ProjectHistoryState(project: ProjectSnapshot(manifest: manifest, images: [:]), revision: UUID())
        broken.history = .init(past: [.init(name: "Broken", before: state, after: state)], future: [], revision: state.revision)
        do { try await ProjectStore.shared.save(broken, to: destination); Issue.record("Malformed history replaced the published package") } catch ProjectError.missingImage { }
        #expect(try ProjectDigest.compute(for: destination) == before)
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
    @Test(arguments: ["middle", "past-future", "backing"])
    func semanticHistoryCorruptionWithUnchangedRevisionIsRefused(_ fault: String) async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session()
        for gray in [CGFloat(0.2), CGFloat(0.8)] {
            let context = try #require(CGContext(data: nil, width: 8, height: 8, bitsPerComponent: 8,
                bytesPerRow: 32, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
            context.setFillColor(CGColor(gray: gray, alpha: 1)); context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
            let image = try #require(context.makeImage())
            session.insert(ImportedImage(image: image, thumbnail: image, name: "Backing"))
        }
        session.history.reset()
        let id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "One"); session.renameLayer(id, to: "Two")
        if fault == "past-future" { session.undo() }
        let live = session.document, revision = session.history.currentRevision
        let file = root.appendingPathComponent("History.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: file)
        let stateFile = file.appendingPathComponent("History/states/2.json") // Second entry before-state; keep revision untouched.
        var state = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: stateFile)) as? [String: Any])
        if fault == "backing" {
            // Codable UUID-key dictionaries are alternating-key/value arrays, not guessed JSON objects.
            var references = try #require(state["images"] as? [String]); #expect(references.count == 4)
            references[1] = references[3]; state["images"] = references
        } else {
            var manifest = try #require(state["manifest"] as? [String: Any])
            var layers = try #require(manifest["layers"] as? [[String: Any]])
            layers[0]["opacity"] = 0.375; manifest["layers"] = layers; state["manifest"] = manifest
        }
        try JSONSerialization.data(withJSONObject: state).write(to: stateFile)
        do { _ = try await ProjectStore.shared.load(from: file); Issue.record("Semantic history corruption accepted: \(fault)") }
        catch ProjectError.invalid { }
        #expect(session.document == live && session.history.currentRevision == revision)
    }
    @Test func historyNavigationSelectionMayDifferWithoutBreakingSemanticContinuity() async throws {
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let session = try session(); session.addBlankLayer(); session.history.reset()
        let ids = try #require(session.document?.layers.map(\.id)), first = try #require(ids.first), second = try #require(ids.last)
        session.selectLayers([first], primary: first); session.renameLayer(first, to: "First")
        session.selectLayers([second], primary: second); session.renameLayer(second, to: "Second")
        session.undo() // Both past/future semantic endpoints agree despite intervening navigation.
        let file = root.appendingPathComponent("Navigation.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: file)
        let loaded = try await ProjectStore.shared.load(from: file), reopened = EditorSession()
        reopened.installProject(loaded, from: file)
        #expect(reopened.history.canUndo && reopened.history.canRedo)
        reopened.redo(); #expect(reopened.activeLayer?.name == "Second")
        reopened.undo(); reopened.undo(); #expect(reopened.document?.layers.first { $0.id == first }?.name != "First")
    }
    @Test func recoveryRequiresValidatedMarkerAndManagedBackingWithoutFirstSaveRetarget() async throws {
        let session = try session(), controller = ProjectController(session: session), id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "Recovery source"); await controller.finishWriting()
        let draft = try #require(controller.commandRecoveryURL)
        defer { try? FileManager.default.removeItem(at: draft) }
        let snapshot = try await ProjectStore.shared.load(from: draft)
        #expect(try ProjectController.isCommandRecovery(snapshot, source: draft))
        let root = try root(); defer { try? FileManager.default.removeItem(at: root) }
        let displaced = root.appendingPathComponent(draft.lastPathComponent)
        try FileManager.default.copyItem(at: draft, to: displaced)
        #expect(throws: ProjectError.self) { try ProjectController.isCommandRecovery(snapshot, source: displaced) }
        // A normal package with that same filename has no recovery identity and is not classified by its name.
        let normal = root.appendingPathComponent("Normal.comp")
        try await ProjectStore.shared.save(try #require(session.projectSnapshot()), to: normal)
        let ordinary = try await ProjectStore.shared.load(from: normal)
        #expect(try !ProjectController.isCommandRecovery(ordinary, source: normal))
        let metadata = draft.appendingPathComponent("manifest.json")
        var manifest = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        manifest["recoveryDocumentID"] = UUID().uuidString
        try JSONSerialization.data(withJSONObject: manifest).write(to: metadata)
        do { _ = try await ProjectStore.shared.load(from: draft); Issue.record("Mismatched recovery identity accepted") }
        catch ProjectError.invalid { }
    }

}
