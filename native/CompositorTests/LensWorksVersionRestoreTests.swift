import AppKit
import Testing
@testable import Compositor

@MainActor
struct LensWorksVersionRestoreTests {
    private func image(_ color: CGColor) throws -> ImportedImage {
        let context = try BrushRaster.context(width: 8, height: 8, mask: false)
        context.setFillColor(color)
        context.fill(CGRect(x: 0, y: 0, width: 8, height: 8))
        let image = try #require(context.makeImage())
        return ImportedImage(image: image, thumbnail: image, name: "Layer")
    }

    private func save(_ controller: ProjectController, to file: URL) async throws {
        controller.agentRequest = ProjectAgentRequest()
        let saved = await controller.save(to: file)
        try #require(saved, Comment(rawValue: controller.agentRequest?.failure ?? "Save failed"))
    }

    private func open(_ controller: ProjectController, from file: URL) async throws {
        controller.agentRequest = ProjectAgentRequest()
        let opened = await controller.open(file)
        try #require(opened, Comment(rawValue: controller.agentRequest?.failure ?? "Open failed"))
    }

    private func manifest(_ session: EditorSession) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        return try encoder.encode(#require(session.projectSnapshot()).manifest)
    }

    private func controller() -> ProjectController {
        let controller = ProjectController(session: EditorSession())
        controller.recordsRecentProjects = false; controller.sharesWorkingVersions = false
        return controller
    }

    @Test func ordinaryEditorTransactionsAndPendingRedoSurviveRepeatedSaveAndReopen() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("ordinary-history-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let editor = controller(), session = editor.session
        session.createDocument(width: 32, height: 24)
        session.insert(try image(CGColor(gray: 0.5, alpha: 1)))
        session.history.reset() // Fixture import is the baseline, not one of the edits under test.
        try editor.initializeLensWorksDocument(photoID: "p", named: "A")
        try await save(editor, to: file)
        let id = try #require(session.activeLayerID)
        var states = [try manifest(session)]
        // These are the production editor commands, not document-history commands
        // or explicit composition captures. Every one has its own Undo boundary.
        session.renameLayer(id, to: "Renamed"); states.append(try manifest(session))
        session.toggleLayerVisibility(id); states.append(try manifest(session))
        session.toggleLayerVisibility(id); states.append(try manifest(session))
        session.setLayerOpacity(0.4); states.append(try manifest(session))
        session.nudgeLayer(dx: 3, dy: 2); states.append(try manifest(session))
        session.addLayerMask(revealing: false); states.append(try manifest(session))
        session.addBlankLayer(); states.append(try manifest(session))
        session.undo() // Saving must not turn this pending redo into an edit or lose it.
        #expect(try manifest(session) == states[states.count - 2])
        try await save(editor, to: file)
        let first = try #require(editor.lensWorksDocument?.versions.first)
        #expect(first.undo.count == states.count - 2 && first.redo.count == 1)
        try await save(editor, to: file)
        #expect(editor.lensWorksDocument?.versions.first?.undo.map(\.id) == first.undo.map(\.id))
        #expect(editor.lensWorksDocument?.versions.first?.redo.map(\.id) == first.redo.map(\.id))
        let closeDeadline = ContinuousClock.now.advanced(by: .seconds(10))
        try await editor.releaseConfirmedSourceProject(deadline: closeDeadline)
        try session.finishConfirmedSourceRetirement(protectedOwners: [], deadline: closeDeadline)
        #expect(session.document == nil)

        let reopened = controller()
        try await open(reopened, from: file)
        #expect(try manifest(reopened.session) == states[states.count - 2])
        #expect(reopened.session.canRedo)
        reopened.session.redo()
        #expect(try manifest(reopened.session) == states.last)
        for expected in states.dropLast().reversed() {
            try #require(reopened.session.canUndo)
            reopened.session.undo()
            #expect(try manifest(reopened.session) == expected)
        }
        #expect(!reopened.session.canUndo)
        for expected in states.dropFirst() {
            try #require(reopened.session.canRedo)
            reopened.session.redo()
            #expect(try manifest(reopened.session) == expected)
        }
        reopened.session.undo()
        let active = try #require(reopened.session.activeLayerID)
        reopened.session.renameLayer(active, to: "New branch")
        #expect(!reopened.session.canRedo)
        try await save(reopened, to: file)
        let branched = controller()
        try await open(branched, from: file)
        #expect(!branched.session.canRedo)
        #expect(branched.session.activeLayer?.name == "New branch")
    }

    @Test func dirtyCanvasCheckpointCapturesVisibleStateAndRetainsOrdinaryUndo() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("dirty-checkpoint-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let editor = controller(), session = editor.session
        session.createDocument(width: 32, height: 24, emptyLayer: true)
        try editor.initializeLensWorksDocument(photoID: "p", named: "A")
        let version = try #require(editor.selectedLensWorksVersionID)
        try await save(editor, to: file)
        let id = try #require(session.activeLayerID)
        session.renameLayer(id, to: "Checkpoint canvas")
        session.addBlankLayer()
        let checkpointState = try manifest(session), revision = session.history.currentRevision
        try editor.addLensWorksCheckpoint(named: "Visible edits", to: version)
        #expect(session.history.currentRevision == revision && session.isModified)
        let checkpoint = try #require(editor.lensWorksDocument?.versions.first?.checkpoints.first?.id)
        session.renameLayer(try #require(session.activeLayerID), to: "Later")
        try await save(editor, to: file)
        let reopened = controller()
        try await open(reopened, from: file)
        try reopened.restoreLensWorksCheckpoint(checkpoint, in: version)
        #expect(try manifest(reopened.session) == checkpointState)
        reopened.session.undo() // Restore itself is also in the ordinary editor timeline.
        #expect(reopened.session.activeLayer?.name == "Later")
    }

    @Test func versionCanvasTimelinesStayIndependentAcrossReopen() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("version-timelines-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let editor = controller(), session = editor.session
        session.createDocument(width: 32, height: 24, emptyLayer: true)
        try editor.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(editor.selectedLensWorksVersionID)
        session.renameLayer(try #require(session.activeLayerID), to: "A edit")
        session.addBlankLayer(); session.undo()
        try await save(editor, to: file)
        try editor.addLensWorksVersion(named: "B")
        let second = try #require(editor.selectedLensWorksVersionID)
        session.renameLayer(try #require(session.activeLayerID), to: "B edit")
        try await save(editor, to: file)
        let reopened = controller()
        try await open(reopened, from: file)
        #expect(reopened.selectedLensWorksVersionID == second)
        #expect(reopened.session.history.undoCount == 1 && !reopened.session.canRedo)
        try reopened.selectLensWorksVersion(first)
        #expect(reopened.session.history.undoCount == 1 && reopened.session.canRedo)
        reopened.session.redo()
        #expect(reopened.session.document?.layers.count == 2)
        reopened.session.undo()
        #expect(reopened.session.activeLayer?.name == "A edit")
        // A return to the saved revision is clean, so switching loses nothing.
        try reopened.selectLensWorksVersion(second)
        reopened.session.undo()
        #expect(reopened.session.activeLayer?.name == "A edit")
    }

    @Test func ordinaryGestureOriginAndProtectedPruningSurviveReopen() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("pruned-editor-history-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let editor = controller(), session = editor.session
        session.createDocument(width: 32, height: 24, emptyLayer: true)
        try editor.initializeLensWorksDocument(photoID: "p", named: "A")
        let version = try #require(editor.selectedLensWorksVersionID), layer = try #require(session.activeLayerID)
        try editor.setLensWorksMaxUndoSteps(3)
        _ = try session.dispatchCommand(session.admitCommand(.rename(layer, "Agent edit"), origin: .agent))
        try editor.addLensWorksCheckpoint(named: "Agent checkpoint", to: version)
        session.beginOpacityEdit()
        for value in [0.9, 0.7, 0.4] { session.setLayerOpacity(value) }
        session.finishOpacityEdit()
        try editor.addLensWorksCheckpoint(named: "Gesture checkpoint", to: version)
        try editor.setLensWorksMaxUndoSteps(1)
        try #require(editor.lensWorksHistoryWarning != nil) // Both protected edits survive a one-step limit.
        try await save(editor, to: file)
        let reopened = controller()
        try await open(reopened, from: file)
        #expect(reopened.session.history.undoCount == 2)
        #expect(reopened.session.history.undoOrigin == .user)
        reopened.session.undo()
        #expect(reopened.session.activeLayer?.opacity == 1)
        #expect(reopened.session.history.undoOrigin == .agent)
        #expect(reopened.session.history.undoName.contains("Agent"))
        reopened.session.undo()
        #expect(reopened.session.activeLayer?.name == "Layer 1")
        #expect(reopened.session.canRedo)
        try await save(reopened, to: file)
        let redone = controller()
        try await open(redone, from: file)
        redone.session.redo(); redone.session.redo()
        #expect(redone.session.activeLayer?.name == "Agent edit" && redone.session.activeLayer?.opacity == 0.4)
        let protected = try #require(redone.lensWorksDocument).reachableAssets
        #expect(protected.allSatisfy { redone.lensWorksDocumentAssets[$0] != nil || redone.lensWorksDocumentPlanes[$0] != nil })
    }

    @Test func pinnedInteriorPruningKeepsBothEndpointsAndRevisionSemantics() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-gap-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let editor = controller(), session = editor.session
        session.createDocument(width: 32, height: 24, emptyLayer: true)
        try editor.initializeLensWorksDocument(photoID: "p", named: "A")
        let version = try #require(editor.selectedLensWorksVersionID), id = try #require(session.activeLayerID)
        try editor.setLensWorksMaxUndoSteps(2)
        session.renameLayer(id, to: "A")
        try editor.addLensWorksCheckpoint(named: "Pin A", to: version)
        session.renameLayer(id, to: "B")
        session.renameLayer(id, to: "C") // B's entry is pruned, leaving A and C.
        session.undo()
        #expect(session.activeLayer?.name == "B")
        try await save(editor, to: file) // Save inside the gap, with C on Redo.
        session.undo(); session.redo()
        #expect(session.activeLayer?.name == "A" && session.isModified)
        let reopened = controller()
        try await open(reopened, from: file)
        #expect(reopened.session.activeLayer?.name == "B" && !reopened.session.isModified)
        reopened.session.undo()
        #expect(reopened.session.activeLayer?.name == "Layer 1")
        reopened.session.redo()
        #expect(reopened.session.activeLayer?.name == "A" && reopened.session.isModified)
        reopened.session.redo()
        #expect(reopened.session.activeLayer?.name == "C")
        reopened.session.undo()
        #expect(reopened.session.activeLayer?.name == "B" && !reopened.session.isModified)
    }

    @Test func cleanVersionSwitchCapturesFreshPendingRedo() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("clean-redo-switch-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let editor = controller(), session = editor.session
        session.createDocument(width: 32, height: 24, emptyLayer: true)
        try editor.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(editor.selectedLensWorksVersionID)
        try await save(editor, to: file)
        try editor.addLensWorksVersion(named: "B")
        let second = try #require(editor.selectedLensWorksVersionID)
        try await save(editor, to: file)
        try editor.selectLensWorksVersion(first)
        session.renameLayer(try #require(session.activeLayerID), to: "Fresh redo")
        session.undo()
        #expect(!session.isModified && session.canRedo)
        try editor.selectLensWorksVersion(second)
        try await save(editor, to: file)
        let reopened = controller()
        try await open(reopened, from: file)
        try reopened.selectLensWorksVersion(first)
        #expect(reopened.session.canRedo)
        reopened.session.redo()
        #expect(reopened.session.activeLayer?.name == "Fresh redo")
    }

    @Test(arguments: [1, 2]) func graphlessLegacyOrdinarySaveKeepsBothScalarStacks(schema: Int) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("legacy-save-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let seed = EditorSession()
        seed.createDocument(width: 32, height: 24, emptyLayer: true)
        var document = LensWorksPhotoDocument(photoID: "legacy")
        let version = document.addVersion(named: "Original")
        try document.perform(.setRaw(key: "exposure", value: 1), on: version)
        try document.perform(.setRaw(key: "exposure", value: 2), on: version)
        try document.undo(version)
        _ = try document.addCheckpoint(named: "Legacy checkpoint", to: version)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        var legacy = try #require(JSONSerialization.jsonObject(with: encoder.encode(document)) as? [String: Any])
        legacy["schema"] = schema
        var versions = try #require(legacy["versions"] as? [[String: Any]])
        for index in versions.indices {
            versions[index].removeValue(forKey: "canvasRevision")
            for key in ["undo", "redo"] {
                var steps = try #require(versions[index][key] as? [[String: Any]])
                for step in steps.indices {
                    for field in ["oppositeContent", "canvasBeforeRevision", "canvasAfterRevision"] { steps[step].removeValue(forKey: field) }
                }
                versions[index][key] = steps
            }
        }
        legacy["versions"] = versions
        var snapshot = try #require(seed.projectSnapshot())
        snapshot.lensWorksDocument = try JSONDecoder().decode(LensWorksPhotoDocument.self, from: JSONSerialization.data(withJSONObject: legacy))
        try await ProjectStore.shared.save(snapshot, to: file)
        let editor = controller()
        try await open(editor, from: file)
        try await save(editor, to: file) // No canvas edit: migration must still save.
        #expect(editor.lensWorksDocument?.versions[0].undo.count == 1)
        #expect(editor.lensWorksDocument?.versions[0].redo.count == 1)
        editor.session.renameLayer(try #require(editor.session.activeLayerID), to: "Ordinary edit")
        try await save(editor, to: file)
        let reopened = controller()
        try await open(reopened, from: file)
        #expect(reopened.lensWorksDocument?.versions[0].redo.count == 1)
        #expect(reopened.lensWorksDocument?.versions[0].checkpoints.first?.content.rawSettings["exposure"] == 1)
        try reopened.redoLensWorksVersion(version)
        #expect(reopened.lensWorksDocument?.versions[0].content.rawSettings["exposure"] == 2)
        try await save(reopened, to: file)
        let cycled = controller()
        try await open(cycled, from: file)
        try cycled.undoLensWorksVersion(version)
        #expect(cycled.lensWorksDocument?.versions[0].content.rawSettings["exposure"] == 1)
        #expect(cycled.session.activeLayer?.name == "Ordinary edit")
        try cycled.undoLensWorksVersion(version)
        #expect(cycled.session.activeLayer?.name == "Layer 1")
        try cycled.redoLensWorksVersion(version)
        #expect(cycled.session.activeLayer?.name == "Ordinary edit")
        try cycled.redoLensWorksVersion(version)
        #expect(cycled.lensWorksDocument?.versions[0].content.rawSettings["exposure"] == 2)
    }

    @Test(arguments: [false, true]) func configuredHistoryLimitAppliesBeforeNewVersionFirstSave(duplicate: Bool) async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("configured-version-cap-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let editor = controller(), session = editor.session
        session.createDocument(width: 32, height: 24, emptyLayer: true)
        try editor.initializeLensWorksDocument(photoID: "p", named: "A")
        try editor.setLensWorksMaxUndoSteps(200)
        if duplicate { try editor.duplicateLensWorksVersion(try #require(editor.selectedLensWorksVersionID), named: "B") }
        else { try editor.addLensWorksVersion(named: "B") }
        let id = try #require(session.activeLayerID)
        for index in 0..<101 { session.renameLayer(id, to: "Edit \(index)") }
        #expect(session.history.undoCount == 101)
        try await save(editor, to: file)
        let reopened = controller()
        try await open(reopened, from: file)
        #expect(reopened.session.history.undoCount == 101)
        try reopened.setLensWorksMaxUndoSteps(2)
        try reopened.addLensWorksVersion(named: "C")
        let newID = try #require(reopened.session.activeLayerID)
        for index in 0..<3 { reopened.session.renameLayer(newID, to: "Small cap \(index)") }
        #expect(reopened.session.history.undoCount == 2)
    }

    @Test func equalCompositionsDoNotCollapseDistinctPrunedRevisions() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("equal-revisions-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let editor = controller(), session = editor.session
        session.createDocument(width: 32, height: 24, emptyLayer: true)
        try editor.initializeLensWorksDocument(photoID: "p", named: "A")
        let version = try #require(editor.selectedLensWorksVersionID), id = try #require(session.activeLayerID)
        try editor.setLensWorksMaxUndoSteps(2)
        session.renameLayer(id, to: "A")
        try editor.addLensWorksCheckpoint(named: "Pin first A", to: version)
        session.renameLayer(id, to: "B"); session.renameLayer(id, to: "A"); session.renameLayer(id, to: "D")
        session.undo(); session.undo(); session.redo()
        try await save(editor, to: file) // Saved the first A, not the later equal A.
        session.redo(); session.undo()
        #expect(session.activeLayer?.name == "A" && session.isModified)
        let reopened = controller()
        try await open(reopened, from: file)
        reopened.session.redo(); reopened.session.undo()
        #expect(reopened.session.activeLayer?.name == "A" && reopened.session.isModified)
    }

    @Test func pendingGestureCheckpointRefusesAtomically() throws {
        let editor = controller(), session = editor.session
        session.createDocument(width: 32, height: 24, emptyLayer: true)
        try editor.initializeLensWorksDocument(photoID: "p", named: "A")
        let version = try #require(editor.selectedLensWorksVersionID)
        let document = editor.lensWorksDocument, assets = editor.lensWorksDocumentAssets
        let token = try #require(session.history.beginInteraction("Pending", document: session.document, selection: session.activeLayerID))
        defer { _ = session.history.cancelInteraction(token) }
        #expect(throws: LensWorksCommandRefusal.self) { try editor.addLensWorksCheckpoint(named: "Not yet", to: version) }
        #expect(editor.lensWorksDocument == document && editor.lensWorksDocumentAssets == assets)
    }

    @Test func undoAndCheckpointRestoreChangeTheCanvasAndRetainAssets() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(try image(CGColor(srgbRed: 1, green: 0, blue: 0, alpha: 1)))
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p1", named: "A")
        let version = try #require(controller.selectedLensWorksVersionID)
        let first = session.document?.layers.count ?? 0

        try controller.captureLensWorksComposition(in: version)
        try controller.addLensWorksCheckpoint(named: "one", to: version)
        let checkpoint = try #require(controller.lensWorksDocument?.versions.first?.checkpoints.first?.id)
        session.insert(try image(CGColor(srgbRed: 0, green: 0, blue: 1, alpha: 1)))
        #expect(session.document?.layers.count == first + 1)
        try controller.captureLensWorksComposition(in: version)

        try controller.undoLensWorksVersion(version)
        #expect(session.document?.layers.count == first)
        try controller.redoLensWorksVersion(version)
        #expect(session.document?.layers.count == first + 1)
        try controller.restoreLensWorksCheckpoint(checkpoint, in: version)
        #expect(session.document?.layers.count == first)

        let reachable = try #require(controller.lensWorksDocument).reachableAssets
        #expect(!reachable.isEmpty && reachable.allSatisfy { controller.lensWorksDocumentAssets[$0] != nil })
    }
    @Test func newNamedVersionCapturesTheVisibleComposition() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        session.insert(try image(CGColor(gray: 0, alpha: 1)))
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        session.insert(try image(CGColor(gray: 1, alpha: 1)))
        let count = session.document?.layers.count
        try controller.addLensWorksVersion(named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        #expect(controller.lensWorksDocument?.selectedVersionID == second)
        session.history.markSaved()
        try controller.selectLensWorksVersion(first)
        #expect(session.document?.layers.count == (count ?? 0) - 1)
        try controller.selectLensWorksVersion(second)
        #expect(session.document?.layers.count == count)
        #expect(session.document?.width == 32 && session.document?.height == 24)
    }

    @Test func dirtySwitchRefusesWithoutChangingCanvasUndoOrModifiedState() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(try image(CGColor(gray: 0.5, alpha: 1)))
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        try controller.duplicateLensWorksVersion(first, named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        session.history.markSaved()
        try controller.selectLensWorksVersion(first)
        controller.lensWorksDocumentModified = false
        session.insert(try image(CGColor(gray: 1, alpha: 1)))
        let revision = session.history.currentRevision, undo = session.history.undoCount
        let count = session.document?.layers.count
        #expect(throws: LensWorksCommandRefusal.self) { try controller.selectLensWorksVersion(second) }
        #expect(controller.selectedLensWorksVersionID == first)
        #expect(session.document?.layers.count == count && session.history.currentRevision == revision)
        #expect(session.history.undoCount == undo && session.isModified)
        session.undo()
        #expect(session.document?.layers.count == (count ?? 0) - 1)
    }

    @Test(arguments: ["undo", "redo", "checkpoint"])
    func dirtyHistoryReplacementKeepsEditsAndUndo(action: String) throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(try image(CGColor(gray: 0, alpha: 1)))
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let version = try #require(controller.selectedLensWorksVersionID)
        try controller.addLensWorksCheckpoint(named: "start", to: version)
        let checkpoint = try #require(controller.lensWorksDocument?.versions[0].checkpoints[0].id)
        session.insert(try image(CGColor(gray: 0.5, alpha: 1)))
        try controller.captureLensWorksComposition(in: version)
        if action == "redo" { try controller.undoLensWorksVersion(version) }
        session.insert(try image(CGColor(gray: 1, alpha: 1)))
        let count = session.document?.layers.count, revision = session.history.currentRevision
        let document = controller.lensWorksDocument
        #expect(throws: LensWorksCommandRefusal.self) {
            switch action {
            case "undo": try controller.undoLensWorksVersion(version)
            case "redo": try controller.redoLensWorksVersion(version)
            default: try controller.restoreLensWorksCheckpoint(checkpoint, in: version)
            }
        }
        #expect(controller.lensWorksDocument == document)
        #expect(session.document?.layers.count == count && session.history.currentRevision == revision)
        session.undo()
        #expect(session.document?.layers.count == (count ?? 0) - 1)
    }

    @Test func invalidStoredCompositionCannotReplaceTheCanvas() throws {
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        try controller.duplicateLensWorksVersion(first, named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        session.history.markSaved()
        try controller.selectLensWorksVersion(first)
        controller.lensWorksDocument?.versions[1].content.layerGraph?.composition?.width = 0
        let revision = session.history.currentRevision
        #expect(throws: ProjectError.self) { try controller.selectLensWorksVersion(second) }
        #expect(controller.selectedLensWorksVersionID == first)
        #expect(session.document?.width == 32 && session.history.currentRevision == revision)
    }

    @Test func savedCanvasEditsSurviveVersionSwitchAndReopen() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("versions-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let session = EditorSession()
        session.createDocument(width: 32, height: 32)
        session.insert(try image(CGColor(gray: 0, alpha: 1)))
        let controller = ProjectController(session: session)
        controller.recordsRecentProjects = false; controller.sharesWorkingVersions = false
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        try controller.duplicateLensWorksVersion(first, named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        session.history.markSaved()
        try controller.selectLensWorksVersion(first)
        session.insert(try image(CGColor(gray: 1, alpha: 1)))
        let count = session.document?.layers.count
        try await save(controller, to: file)
        try controller.selectLensWorksVersion(second)
        #expect(session.document?.layers.count == (count ?? 0) - 1)
        #expect(controller.lensWorksDocumentModified)
        try controller.selectLensWorksVersion(first)
        #expect(session.document?.layers.count == count)
        try await save(controller, to: file)
        let reopened = ProjectController(session: EditorSession())
        reopened.recordsRecentProjects = false; reopened.sharesWorkingVersions = false
        try await open(reopened, from: file)
        #expect(reopened.selectedLensWorksVersionID == first)
        #expect(reopened.session.document?.layers.count == count)
        try reopened.selectLensWorksVersion(second)
        #expect(reopened.session.document?.layers.count == (count ?? 0) - 1)
        try reopened.selectLensWorksVersion(first)
        #expect(reopened.session.document?.layers.count == count)
    }

    @Test func completeCompositionRestoresAcrossUndoCheckpointAndPackage() async throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("composition-\(UUID()).comp")
        defer { try? FileManager.default.removeItem(at: file) }
        let session = EditorSession()
        session.createDocument(width: 32, height: 24)
        session.insert(try image(CGColor(gray: 0, alpha: 1)))
        let guide = CanvasGuide(id: UUID(), axis: .horizontal, position: 12)
        session.document?.resolution = 144; session.document?.guides = [guide]
        let controller = ProjectController(session: session)
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let version = try #require(controller.selectedLensWorksVersionID)
        try controller.addLensWorksCheckpoint(named: "small", to: version)
        let checkpoint = try #require(controller.lensWorksDocument?.versions[0].checkpoints[0].id)
        let old = try #require(session.document)
        session.document = CanvasDocument(id: old.id, width: 64, height: 48, layers: old.layers, resolution: 300)
        try controller.captureLensWorksComposition(in: version)
        try controller.undoLensWorksVersion(version)
        #expect(session.document?.width == 32 && session.document?.height == 24)
        #expect(session.document?.resolution == 144 && session.document?.guides == [guide])
        try controller.redoLensWorksVersion(version)
        #expect(session.document?.width == 64 && session.document?.height == 48)
        #expect(session.document?.resolution == 300 && session.document?.guides == [])
        let snapshot = try #require(session.projectSnapshot())
        try await ProjectStore.shared.save(ProjectSnapshot(manifest: snapshot.manifest, images: snapshot.images,
            lensWorksDocument: controller.lensWorksDocument, lensWorksDocumentAssets: controller.lensWorksDocumentAssets), to: file)
        let reopened = try await ProjectStore.shared.load(from: file)
        let restored = ProjectController(session: EditorSession())
        restored.session.installProject(reopened, from: file)
        restored.lensWorksDocument = reopened.lensWorksDocument
        restored.lensWorksDocumentAssets = reopened.lensWorksDocumentAssets
        try restored.restoreLensWorksCheckpoint(checkpoint, in: version)
        #expect(restored.session.document?.width == 32 && restored.session.document?.height == 24)
        #expect(restored.session.document?.resolution == 144 && restored.session.document?.guides == [guide])
    }
    @Test(arguments: [false, true])
    func liveRawVersionsKeepExactSamplesSettingsAndSourceAcrossReopen(tiled: Bool) async throws {
        let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("raw-versions-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
        let directory = try #require(temporary.physicalFileURL)
        defer { try? FileManager.default.removeItem(at: directory) }
        let original = directory.appendingPathComponent("original.dng")
        try ProceduralDNG.write(to: original, width: 32, height: 24)
        let originalBytes = try Data(contentsOf: original)
        let file = directory.appendingPathComponent("versions.comp")
        // A real original and decoder authority exercise the normal save's
        // mandatory full-resolution QuickLook development, not a fake RAW cache.
        let (source, decoded) = try await LWSourceDeveloper.shared.createPlane(original: LWCatalogNativePath(fileURL: original), rawHint: true)
        let range = LWFloatRange(x: 0, y: 0, width: decoded.width, height: decoded.height)
        let tile = try decoded.read(range)
        let surface = try LWLinearSurface(width: decoded.width, height: decoded.height,
            pixels: Array(tile.surface.pixels), maximumBytes: 1024 * 1024)
        let image = tiled ? try ImportedImage(plane: decoded, name: "RAW") : try ImportedImage(linear: surface, name: "RAW")
        let session = EditorSession()
        session.createDocument(width: decoded.width, height: decoded.height)
        session.insert(image)
        let layerID = try #require(session.activeLayerID)
        let index = try #require(session.document?.layers.firstIndex { $0.id == layerID })
        session.document?.layers[index].liveSource = source
        let controller = ProjectController(session: session)
        controller.recordsRecentProjects = false; controller.sharesWorkingVersions = false
        try controller.initializeLensWorksDocument(photoID: "p", named: "A")
        let first = try #require(controller.selectedLensWorksVersionID)
        let initial = try #require(controller.lensWorksDocument?.versions[0].content.layerGraph)
        #expect(initial.layers.first { $0.id == layerID }?.liveSourceFile != nil)
        try controller.duplicateLensWorksVersion(first, named: "B")
        let second = try #require(controller.selectedLensWorksVersionID)
        // Alter the native live RAW graph, rather than the legacy scalar test-only dictionary.
        session.document?.layers[index].liveSource?.settings.exposure = 1.5
        try controller.captureLensWorksComposition(in: second)
        try controller.addLensWorksCheckpoint(named: "bright", to: second)
        let checkpoint = try #require(controller.lensWorksDocument?.versions[1].checkpoints.first?.id)
        try await save(controller, to: file)
        let stored = try await ProjectStore.shared.load(from: file)
        let rasterOnly = ProjectManifest(documentID: UUID(), width: decoded.width, height: decoded.height, activeLayerID: nil, layers: [])
        let historical = ProjectSnapshot(manifest: rasterOnly, images: [:], lensWorksDocument: stored.lensWorksDocument,
            lensWorksDocumentAssets: stored.lensWorksDocumentAssets, lensWorksDocumentPlanes: stored.lensWorksDocumentPlanes)
        let authority = try LWSourceDestinationAuthority(historical)
        #expect(throws: ProjectError.self) { try authority.validate(original) }
        #expect(throws: ProjectError.self) { try authority.validate(directory) }
        let exporter = ProjectController(session: EditorSession())
        exporter.session.installProject(ProjectSnapshot(manifest: rasterOnly, images: [:]), from: file)
        exporter.lensWorksDocument = stored.lensWorksDocument
        exporter.lensWorksDocumentAssets = stored.lensWorksDocumentAssets
        exporter.lensWorksDocumentPlanes = stored.lensWorksDocumentPlanes
        await #expect(throws: ProjectError.self) { try await exporter.exportPNG(to: original) }
        await #expect(throws: ProjectError.self) { try await exporter.exportJPEG(to: original, options: JPEGOptions()) }
        #expect(try Data(contentsOf: original) == originalBytes)
        let reopened = ProjectController(session: EditorSession())
        reopened.recordsRecentProjects = false; reopened.sharesWorkingVersions = false
        try await open(reopened, from: file)
        func exposure() -> Double? { reopened.session.document?.layers.first { $0.id == layerID }?.liveSource?.settings.exposure }
        #expect(exposure() == 1.5)
        try reopened.selectLensWorksVersion(first)
        #expect(exposure() == 0)
        try reopened.selectLensWorksVersion(second)
        #expect(exposure() == 1.5)
        try reopened.undoLensWorksVersion(second)
        #expect(exposure() == 0)
        try reopened.redoLensWorksVersion(second)
        #expect(exposure() == 1.5)
        try reopened.restoreLensWorksCheckpoint(checkpoint, in: second)
        #expect(exposure() == 1.5)
        let restored = try #require(reopened.session.document?.layers.first { $0.id == layerID }?.asset)
        if let plane = restored.linearPlane {
            let tile = try plane.read(range)
            for i in surface.pixels.indices { for channel in 0..<4 { #expect(tile.surface.pixels[i][channel].bitPattern == surface.pixels[i][channel].bitPattern) } }
        } else {
            let samples = try #require(restored.linear)
            for i in surface.pixels.indices { for channel in 0..<4 { #expect(samples.pixels[i][channel].bitPattern == surface.pixels[i][channel].bitPattern) } }
        }
        #expect(try Data(contentsOf: original) == originalBytes)
    }

}
