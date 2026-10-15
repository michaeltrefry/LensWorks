import Foundation

/// What the saved history of the open document takes on disk.
struct HistoryUsage: Equatable {
    let bytes: Int64
    /// The part only checkpoints and the current state need: pruning never frees it.
    let protectedBytes: Int64
    /// The limit the save worked to; zero when none applied (or the figures were read when the document opened).
    let limitBytes: Int64
}
/// Checkpoints and the current state alone are over the storage limit. No checkpoint was removed, but every undo
/// and redo step was (they are all that can go), and each later save removes the steps made since for as long as
/// this is so: the person decides whether to raise the limit, delete checkpoints, or leave it.
struct HistoryStorageWarning: Equatable {
    let protectedBytes: Int64
    let limitBytes: Int64
    let checkpoints: [String]
    /// The undo and redo steps this save removed.
    var removedSteps = 0
    var message: String {
        let style = ByteCountFormatStyle(style: .file)
        let steps = removedSteps == 0 ? "This save had no undo steps left to remove."
            : "This save removed \(HistoryPruneNotice.steps(removedSteps)) from this document; they can no longer be undone."
        return "This document’s checkpoints and current state take \(protectedBytes.formatted(style)), more than the \(limitBytes.formatted(style)) history storage limit. Checkpoints are never pruned, so all \(checkpoints.count) were kept, but no undo step fits beside them: \(steps) Every save will remove the undo steps made since the last one until there is room. Raise the limit in Edit › History Storage…, or delete checkpoints you no longer need."
    }
}
/// A save removed undo steps from the document, and from Undo in the open session, to keep its saved history
/// within the storage limit.
struct HistoryPruneNotice: Equatable {
    let removedSteps: Int
    let limitBytes: Int64
    let checkpoints: Int
    static func steps(_ count: Int) -> String { count == 1 ? "1 undo step" : "\(count) undo steps" }
    var message: String {
        let kept = checkpoints == 0 ? "" : checkpoints == 1 ? " Its checkpoint was kept." : " Its \(checkpoints) checkpoints were kept."
        return "Saving removed \(Self.steps(removedSteps)) from this document, oldest first, to keep its saved history within the \(limitBytes.formatted(ByteCountFormatStyle(style: .file))) history storage limit. They can no longer be undone.\(kept) This happens at every save while the document’s history is at the limit, and is reported once. Raise the limit in Edit › History Storage… to keep more."
    }
}

extension EditorSession {
    /// Takes up the history the package holds, right after its document was installed.
    func adoptHistory(_ snapshot: ProjectSnapshot) {
        historyAssets.reset(); historyUsage = nil; historyStorageWarning = nil; historyPruneNotice = nil
        newerHistorySchema = snapshot.newerHistorySchema
        bindHistoryStore()
        guard let index = snapshot.history else { historyAssets.setDurable(snapshot, rasters: [:]); return }
        var rasters: [UUID: String] = [:]
        for (id, file) in index.document { if let id = UUID(uuidString: id) { rasters[id] = file } }
        historyAssets.setDurable(snapshot, rasters: rasters)
        history.adopt(index.record, document: document)
        historyUsage = HistoryUsage(bytes: index.bytes, protectedBytes: index.protectedBytes, limitBytes: 0)
    }
    /// Lets what history no longer holds go from the History name table too.
    func bindHistoryStore() {
        history.didRelease = { [weak self] in self?.releaseHistoryAssets() }
    }
    /// Reads the stored state `destination` needs back from the open package, then carries on with `then`.
    /// False when the state is already in memory and there is nothing to wait for.
    ///
    /// A state that left memory (or was never in it, after a reopen) is read from the package's files and, for a
    /// live source layer, developed again from its source: on a large or float document that takes long enough
    /// to stall the window, so it runs off the main thread while the session is busy, as an open does.
    func readStoredState(for destination: DocumentHistory.Destination, then: @escaping (EditorSession) -> Void) -> Bool {
        guard let revision = history.stateToRead(for: destination) else { return false }
        guard let url = projectURL else {
            history.noteReadFailure("This step’s saved state is not available."); commandRefusal = history.readFailure; return true
        }
        isProjectBusy = true
        let assets = historyAssets
        historyRead = Task { @MainActor [weak self] in
            let result: Result<LWHistoryArchive.Restored, Error>
            do {
                result = .success(try await Task.detached(priority: .userInitiated) {
                    try await LWHistoryArchive.restore(revision, package: url, assets: assets)
                }.value)
            } catch { result = .failure(error) }
            guard let self else { return }
            self.isProjectBusy = false; self.historyRead = nil
            switch result {
            case .success(let restored):
                // The session waited for this: nothing else could have changed the document or its history.
                guard self.projectURL == url, self.history.install(revision, document: restored.document),
                      self.history.stateToRead(for: destination) == nil else { return }
                then(self)
            case .failure(let error):
                self.history.noteReadFailure("This step’s saved state could not be read: " + error.localizedDescription)
                self.commandRefusal = self.history.readFailure
            }
        }
        return true
    }
    /// Waits for a stored state that Undo, Redo or Restore Checkpoint is reading back.
    func finishHistoryRead() async { while let reading = historyRead { await reading.value } }
    /// Lets the History name table drop every image no document in memory still uses.
    func releaseHistoryAssets() {
        var images = Set<ObjectIdentifier>(), planes = Set<String>()
        func visit(_ document: CanvasDocument?) {
            for layer in document?.layers ?? [] {
                if let image = layer.asset?.image { images.insert(ObjectIdentifier(image)) }
                if let image = layer.mask?.asset.image { images.insert(ObjectIdentifier(image)) }
                if let image = layer.bakedCoverage?.image { images.insert(ObjectIdentifier(image)) }
                if let node = layer.liveSource { for backing in node.planeAssets.values { planes.insert(backing.reference.manifestSHA256) } }
            }
        }
        visit(document); history.forEachRetainedDocument(visit)
        historyAssets.prune(keeping: images, planes: planes)
    }

    /// History as a save writes it, captured with the document: every state in memory as a project snapshot, and
    /// the states the open package already holds by name.
    func historyCapture(limitBytes: Int64) throws -> LWHistoryArchive.Capture {
        // Before anything is read: the state at the cursor is the document as it is now, under a name of its own
        // when the document was changed outside history since a checkpoint or step recorded it.
        history.reconcileCursor(with: document)
        let record = history.record
        var live: [UUID: LWHistoryArchive.LiveState] = [:], stored = Set<UUID>()
        func state(_ document: CanvasDocument?) throws -> LWHistoryArchive.LiveState {
            .init(snapshot: try document.map { try Self.projectSnapshot(of: $0, activeLayerID: nil) }, selection: document?.selection)
        }
        var failure: Error?
        history.forEachState { held in
            if held.isStored { stored.insert(held.revision) }
            guard held.isResident, failure == nil else { return }
            do { live[held.revision] = try state(held.document) } catch { failure = error }
        }
        if let failure { throw failure }
        live[record.cursor] = try state(document)
        return LWHistoryArchive.Capture(record: record, live: live, stored: stored, source: projectURL, assets: historyAssets, limitBytes: limitBytes)
    }
    /// A save that carried history finished: what it kept is now in the package, what it pruned is gone from undo.
    func applyHistorySave(_ commit: LWHistoryArchive.Commit, snapshot: ProjectSnapshot) {
        historyAssets.setDurable(snapshot, rasters: commit.rasters)
        history.applySave(stored: commit.stored, pruned: commit.pruned)
        historyUsage = HistoryUsage(bytes: commit.bytes, protectedBytes: commit.protectedBytes, limitBytes: commit.limitBytes)
        // The steps the limit took are gone from Undo in this session as well: say so, with how many and the limit.
        historyPruneNotice = commit.prunedNames.isEmpty ? nil
            : HistoryPruneNotice(removedSteps: commit.prunedNames.count, limitBytes: commit.limitBytes, checkpoints: history.checkpoints.count)
        historyStorageWarning = commit.protectedExceedsLimit
            ? HistoryStorageWarning(protectedBytes: commit.protectedBytes, limitBytes: commit.limitBytes, checkpoints: history.checkpoints.map(\.name),
                                    removedSteps: commit.prunedNames.count) : nil
        // The package this session saved holds only history this build wrote.
        newerHistorySchema = nil
        bindHistoryStore()
        releaseHistoryAssets()
    }

    // MARK: Checkpoints

    static func checkpointName(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty || trimmed.utf8.count > 1_024 ? nil : trimmed
    }
    /// Why a checkpoint cannot be made, restored, renamed or deleted right now; nil when it can.
    var checkpointUnavailableReason: String? {
        if document == nil { return "Open a document first." }
        return canUseHistory ? nil : "Finish the current edit or dialog first."
    }
    /// Names the document as it is now. It is saved with the document and survives until it is deleted.
    @discardableResult
    func createCheckpoint(named name: String, origin: LensWorksCommandOrigin = .user) -> DocumentHistory.Checkpoint? {
        guard checkpointUnavailableReason == nil, let name = Self.checkpointName(name) else { return nil }
        resolveGradient()
        let made = history.addCheckpoint(named: name, origin: origin, document: document, selection: activeLayerID, selected: selectedLayerIDs)
        if made != nil { commandContextEpoch &+= 1 }
        return made
    }
    @discardableResult func renameCheckpoint(_ id: UUID, to name: String) -> Bool {
        guard checkpointUnavailableReason == nil, let name = Self.checkpointName(name) else { return false }
        return history.renameCheckpoint(id, to: name)
    }
    /// Puts the document back as the checkpoint has it, as one undoable step: the state left behind stays in undo.
    /// A checkpoint whose state has left memory is read back first (see `readStoredState`); true then means the
    /// restore is under way.
    @discardableResult func restoreCheckpoint(_ id: UUID, origin: LensWorksCommandOrigin = .user) -> Bool {
        guard checkpointUnavailableReason == nil, let checkpoint = history.checkpoints.first(where: { $0.id == id }) else { return false }
        if readStoredState(for: .checkpoint(id), then: { $0.restoreCheckpoint(id, origin: origin) }) { return true }
        guard let snapshot = history.checkpointSnapshot(id) else { commandRefusal = history.readFailure; return false }
        cancelCrop(); cancelGradient()
        history.begin(origin.historyName("Restore “\(checkpoint.name)”"), document: document, selection: activeLayerID, selected: selectedLayerIDs, origin: origin)
        restore(snapshot)
        endEdit()
        return true
    }
    /// Restore Checkpoint for a caller that waits for it (an agent): nil once the document is back at the
    /// checkpoint, else why it is not.
    func restoreCheckpointAndWait(_ id: UUID, origin: LensWorksCommandOrigin) async -> String? {
        guard restoreCheckpoint(id, origin: origin) else {
            return commandRefusal ?? checkpointUnavailableReason ?? "That checkpoint is no longer in this document."
        }
        await finishHistoryRead()
        return history.readFailure
    }
    /// Deleting a checkpoint cannot be undone, so it takes the person's confirmation that this checkpoint may go
    /// (see ProjectController): a confirmation given for anything else deletes nothing.
    @discardableResult func deleteCheckpoint(_ id: UUID, confirmation: LWLossConfirmation) -> Bool {
        guard checkpointUnavailableReason == nil, confirmation.subject == id else { return false }
        let removed = history.removeCheckpoint(id)
        if removed { commandContextEpoch &+= 1 }
        return removed
    }
}
