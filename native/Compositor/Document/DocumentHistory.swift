import Foundation
import CoreGraphics
import Observation

/// Who made a history entry or a checkpoint, as the History folder spells it. Entries and checkpoints carry the
/// command origin (`LensWorksCommandOrigin`); the saved record has spelled the person "person" since the first
/// history schema, so that is what is written and read (`user` is accepted too). An entry saved before origins
/// existed reads as the person's.
nonisolated enum LWHistoryOriginCoding {
    static func encode(_ origin: LensWorksCommandOrigin) -> String { origin == .agent ? "agent" : "person" }
    static func decode(_ text: String?) throws -> LensWorksCommandOrigin {
        switch text {
        case nil, "person", "user": .user
        case "agent": .agent
        default: throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "Unknown history origin \(text ?? "")"))
        }
    }
}

/// Value snapshots share immutable CGImages; no pixel copies for layer edits.
///
/// Every entry runs between two states. A state's document is in memory (resident), in the project package's
/// History store (stored), or both, never neither: a stored state can leave memory when undo retains too much and
/// is read back when Undo, Redo or a checkpoint needs it. Checkpoints keep a state by name; pruning never takes one.
@Observable
final class DocumentHistory {
    struct Snapshot {
        let document: CanvasDocument?
        let activeLayerID: UUID?
        let selectedLayerIDs: Set<UUID>
        let revision: UUID
    }
    /// The layers selected at one end of an entry. It belongs to the entry, not to the state: the selection can
    /// change between two steps without the document changing.
    struct Selection: Codable, Equatable, Sendable {
        var active: UUID?
        var selected: Set<UUID> = []
    }
    /// One state of the document: where an entry starts or ends, or what a checkpoint keeps.
    final class State {
        let revision: UUID
        fileprivate(set) var document: CanvasDocument?
        fileprivate(set) var isResident: Bool
        /// In the History store of the package the session has open.
        fileprivate(set) var isStored: Bool
        fileprivate init(_ snapshot: Snapshot) {
            revision = snapshot.revision; document = snapshot.document; isResident = true; isStored = false
        }
        /// A state the package holds.
        fileprivate init(stored revision: UUID) {
            self.revision = revision; document = nil; isResident = false; isStored = true
        }
    }
    struct Entry: Identifiable {
        let id: UUID
        let name: String
        /// Who made the edit.
        let origin: LensWorksCommandOrigin
        let date: Date
        let before: State
        let after: State
        /// What was selected when the step began, and when it ended: Undo and Redo put it back.
        let beforeSelection: Selection
        let afterSelection: Selection
    }
    /// A state the person named. It is kept until they delete it.
    struct Checkpoint: Identifiable {
        let id: UUID
        var name: String
        let origin: LensWorksCommandOrigin
        let date: Date
        fileprivate(set) var state: State
        let selection: Selection
        var revision: UUID { state.revision }
    }
    /// What a save writes: the entries and checkpoints by identity, and the states they run between.
    struct Record: Codable, Equatable, Sendable {
        struct Entry: Codable, Equatable, Sendable {
            let id: UUID
            let name: String
            /// Missing in a record written before origins existed: the person.
            var origin: LensWorksCommandOrigin = .user
            let date: Date
            let before: UUID
            let after: UUID
            var beforeSelection = Selection()
            var afterSelection = Selection()
            enum CodingKeys: String, CodingKey { case id, name, origin, date, before, after, beforeSelection, afterSelection }
            init(id: UUID, name: String, origin: LensWorksCommandOrigin, date: Date, before: UUID, after: UUID, beforeSelection: Selection, afterSelection: Selection) {
                self.id = id; self.name = name; self.origin = origin; self.date = date; self.before = before; self.after = after
                self.beforeSelection = beforeSelection; self.afterSelection = afterSelection
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
                origin = try LWHistoryOriginCoding.decode(values.decodeIfPresent(String.self, forKey: .origin))
                date = try values.decode(Date.self, forKey: .date)
                before = try values.decode(UUID.self, forKey: .before); after = try values.decode(UUID.self, forKey: .after)
                beforeSelection = try values.decodeIfPresent(Selection.self, forKey: .beforeSelection) ?? Selection()
                afterSelection = try values.decodeIfPresent(Selection.self, forKey: .afterSelection) ?? Selection()
            }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
                try values.encode(LWHistoryOriginCoding.encode(origin), forKey: .origin); try values.encode(date, forKey: .date)
                try values.encode(before, forKey: .before); try values.encode(after, forKey: .after)
                try values.encode(beforeSelection, forKey: .beforeSelection); try values.encode(afterSelection, forKey: .afterSelection)
            }
        }
        struct Checkpoint: Codable, Equatable, Sendable {
            let id: UUID
            var name: String
            var origin: LensWorksCommandOrigin = .user
            let date: Date
            let state: UUID
            var selection = Selection()
            enum CodingKeys: String, CodingKey { case id, name, origin, date, state, selection }
            init(id: UUID, name: String, origin: LensWorksCommandOrigin, date: Date, state: UUID, selection: Selection) {
                self.id = id; self.name = name; self.origin = origin; self.date = date; self.state = state; self.selection = selection
            }
            init(from decoder: Decoder) throws {
                let values = try decoder.container(keyedBy: CodingKeys.self)
                id = try values.decode(UUID.self, forKey: .id); name = try values.decode(String.self, forKey: .name)
                origin = try LWHistoryOriginCoding.decode(values.decodeIfPresent(String.self, forKey: .origin))
                date = try values.decode(Date.self, forKey: .date); state = try values.decode(UUID.self, forKey: .state)
                selection = try values.decodeIfPresent(Selection.self, forKey: .selection) ?? Selection()
            }
            func encode(to encoder: Encoder) throws {
                var values = encoder.container(keyedBy: CodingKeys.self)
                try values.encode(id, forKey: .id); try values.encode(name, forKey: .name)
                try values.encode(LWHistoryOriginCoding.encode(origin), forKey: .origin); try values.encode(date, forKey: .date)
                try values.encode(state, forKey: .state); try values.encode(selection, forKey: .selection)
            }
        }
        /// Oldest first; the last is what Undo steps over.
        var past: [Entry] = []
        /// Furthest first; the last is what Redo steps over.
        var future: [Entry] = []
        var checkpoints: [Checkpoint] = []
        /// The state the document is in.
        var cursor: UUID
        var isEmpty: Bool { past.isEmpty && future.isEmpty && checkpoints.isEmpty }
        /// Every state an entry or a checkpoint needs, and the cursor.
        var states: Set<UUID> {
            Set(past.flatMap { [$0.before, $0.after] } + future.flatMap { [$0.before, $0.after] } + checkpoints.map(\.state) + [cursor])
        }
    }
    /// The point a save captured: the document's state, and the checkpoints as they were named then.
    struct SaveToken: Equatable { let revision: UUID; let annotations: UUID }

    private var past: [Entry] = []
    private var future: [Entry] = []
    private(set) var checkpoints: [Checkpoint] = []
    private var revision = UUID()
    private var savedRevision: UUID?
    /// Changes when a checkpoint is made, renamed or deleted: they are saved with the document too.
    private var annotations = UUID()
    private var savedAnnotations: UUID?
    /// The state the document is in, when an entry or a checkpoint already holds it.
    @ObservationIgnored private var current: State?
    private var pending: Snapshot?
    @ObservationIgnored private(set) var pendingAfterMetadataStorage:LWSourceMetadataStorage?
    private var pendingName = "Edit"
    private var pendingOrigin = LensWorksCommandOrigin.user
    private var depth = 0
    private var interactionToken: UUID?
    @ObservationIgnored private var adoptsNestedName = false
    /// Why the last Undo, Redo or checkpoint could not be read back; nil once one succeeds.
    private(set) var readFailure: String?
    /// Only the checkpoints' states count as held (see `checkpointBytes`).
    @ObservationIgnored private var countsCheckpointsOnly = false
    /// Called after history lets go of states, so what was kept only for them can go too.
    @ObservationIgnored var didRelease: (() -> Void)?

    /// Visit immutable owners in-place; Close must include a pending history
    /// snapshot without allocating another archive or transferring edit authority.
    func forEachRetainedDocument(_ visit: (CanvasDocument?) throws -> Void) rethrows {
        try visit(pending?.document)
        try forEachResidentDocument(visit)
    }
    /// Every document history holds in memory: the states of its entries and its checkpoints. A state two entries
    /// share is visited for each; the accounting counts an image once however often it is seen.
    private func forEachResidentDocument(_ visit: (CanvasDocument?) throws -> Void) rethrows {
        for entry in countsCheckpointsOnly ? [] : past {
            if entry.before.isResident { try visit(entry.before.document) }
            if entry.after.isResident { try visit(entry.after.document) }
        }
        for entry in countsCheckpointsOnly ? [] : future {
            if entry.before.isResident { try visit(entry.before.document) }
            if entry.after.isResident { try visit(entry.after.document) }
        }
        for checkpoint in checkpoints where checkpoint.state.isResident { try visit(checkpoint.state.document) }
    }
    /// With `adoptingNestedName`, the entry takes the name of the first edit made inside the interaction (labeled for
    /// its origin), so an agent's command is listed under the same name the menu's edit has.
    func beginInteraction(_ name: String, document: CanvasDocument?, selection: UUID?, selected: Set<UUID>? = nil, afterMetadataStorage:LWSourceMetadataStorage? = nil, origin: LensWorksCommandOrigin = .user, adoptingNestedName: Bool = false) -> UUID? {
        guard depth == 0 else { return nil }
        let token = UUID(); interactionToken = token; adoptsNestedName = adoptingNestedName
        begin(name,document:document,selection:selection,selected:selected,afterMetadataStorage:afterMetadataStorage,origin:origin); return token
    }
    func endInteraction(_ token: UUID, document: CanvasDocument?, selection: UUID?, selected: Set<UUID>? = nil) -> Bool {
        guard interactionToken == token, depth == 1 else { return false }
        interactionToken = nil; end(document: document, selection: selection, selected: selected); return true
    }
    func cancelInteraction(_ token: UUID) -> Snapshot? {
        guard interactionToken == token, depth == 1, let starting = pending else { return nil }
        interactionToken = nil; pending = nil;pendingAfterMetadataStorage=nil; depth = 0; return starting
    }
    /// The most undo steps kept, and the most memory the states held only for undo may use. A stored state leaves
    /// memory before any step is dropped; a step whose states are not stored is dropped oldest first.
    /// Lowering the step limit drops the steps beyond it at once, oldest first, so a save never writes (and an
    /// open never keeps) more than the limit allows.
    @ObservationIgnored var entryLimit: Int { didSet { entryLimit = max(0, entryLimit); if trimEntries() { didRelease?() } } }
    @ObservationIgnored var retainedByteLimit: Int

    init(entryLimit: Int = 100, retainedByteLimit: Int = 256 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.retainedByteLimit = max(0, retainedByteLimit)
        savedRevision = revision
        savedAnnotations = annotations
    }

    var canUndo: Bool { depth == 0 && !past.isEmpty }
    var canRedo: Bool { depth == 0 && !future.isEmpty }
    var undoName: String { past.last?.name ?? "" }
    var redoName: String { future.last?.name ?? "" }
    /// Who made the entry Undo (Redo) would step over, or nil when there is none.
    var undoOrigin: LensWorksCommandOrigin? { past.last?.origin }
    var redoOrigin: LensWorksCommandOrigin? { future.last?.origin }
    var isModified: Bool { revision != savedRevision || annotations != savedAnnotations }
    var undoCount: Int { past.count }
    var redoCount: Int { future.count }
    /// The entries, oldest first, then those Redo would replay, nearest first.
    var entries: [Entry] { past + future.reversed() }
    func markSaved() { savedRevision = revision; savedAnnotations = annotations }
    /// The document as it stands, for a save that captures it now and finishes later.
    var currentRevision: UUID { revision }
    var saveToken: SaveToken { SaveToken(revision: revision, annotations: annotations) }
    /// A save of `saved` finished. Edits made while it was writing leave the document modified; undoing back to it doesn't.
    func markSaved(_ saved: UUID) { savedRevision = saved }
    func markSaved(_ saved: SaveToken) { savedRevision = saved.revision; savedAnnotations = saved.annotations }
    func reset() {
        past.removeAll()
        future.removeAll()
        checkpoints.removeAll()
        current = nil
        pending = nil;pendingAfterMetadataStorage=nil
        depth = 0
        interactionToken = nil
        revision = UUID()
        savedRevision = revision
        annotations = UUID()
        savedAnnotations = annotations
        readFailure = nil
        didRelease?()
    }

    func begin(_ name: String, document: CanvasDocument?, selection: UUID?, selected: Set<UUID>? = nil, afterMetadataStorage:LWSourceMetadataStorage? = nil, origin: LensWorksCommandOrigin = .user) {
        if depth == 0 {
            pendingAfterMetadataStorage=afterMetadataStorage
            pending = Snapshot(document: document, activeLayerID: selection, selectedLayerIDs: Self.selected(selected, active: selection), revision: revision)
            pendingName = name
            pendingOrigin = origin
        } else if depth == 1, adoptsNestedName, interactionToken != nil {
            pendingName = pendingOrigin.historyName(name); adoptsNestedName = false
        }
        depth += 1
    }

    func end(document: CanvasDocument?, selection: UUID?, selected: Set<UUID>? = nil) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0, let before = pending else { return }
        pending = nil;pendingAfterMetadataStorage=nil
        // Selecting, navigating, and no-op edits must preserve redo history.
        guard before.document != document else { return }
        // The entry starts at the state the last one ended at (or a checkpoint keeps), so both are one state on
        // disk. When the document was changed outside history since then, what this step started from is a state
        // of its own: Undo returns to exactly what was there, as it always has.
        let start: State
        if let current, current.revision == before.revision {
            start = current.document == before.document ? current
                : State(Snapshot(document: before.document, activeLayerID: before.activeLayerID, selectedLayerIDs: before.selectedLayerIDs, revision: UUID()))
        } else { start = State(before) }
        revision = UUID()
        let ended = Selection(active: selection, selected: Self.selected(selected, active: selection))
        let after = State(Snapshot(document: document, activeLayerID: selection, selectedLayerIDs: ended.selected, revision: revision))
        past.append(Entry(id: UUID(), name: pendingName, origin: pendingOrigin, date: Date(), before: start, after: after,
            beforeSelection: Selection(active: before.activeLayerID, selected: before.selectedLayerIDs), afterSelection: ended))
        current = after
        future.removeAll()
        trim(current: document)
    }
    /// The layers selected with the active one: what the caller says, else the active layer alone.
    private static func selected(_ selected: Set<UUID>?, active: UUID?) -> Set<UUID> {
        selected ?? active.map { [$0] } ?? []
    }

    func undo() -> Snapshot? {
        guard canUndo, let entry = past.last, let target = snapshot(of: entry.before, entry.beforeSelection) else { return nil }
        past.removeLast()
        future.append(entry)
        revision = entry.before.revision
        current = entry.before
        trim(current: target.document)
        return target
    }

    func redo() -> Snapshot? {
        guard canRedo, let entry = future.last, let target = snapshot(of: entry.after, entry.afterSelection) else { return nil }
        future.removeLast()
        past.append(entry)
        revision = entry.after.revision
        current = entry.after
        trim(current: target.document)
        return target
    }

    /// A state's document. A state that has left memory is read back from the package first (off the main thread,
    /// by the session: see `stateToRead` and `install`); asked for before that, this is nil with `readFailure`
    /// saying why, and nothing in history changes.
    private func snapshot(of state: State, _ selection: Selection) -> Snapshot? {
        guard state.isResident else { readFailure = "This step’s saved state is not available."; return nil }
        readFailure = nil
        return Snapshot(document: state.document, activeLayerID: selection.active, selectedLayerIDs: selection.selected, revision: state.revision)
    }
    /// What Undo, Redo or restoring a checkpoint goes to.
    enum Destination: Equatable { case undo, redo, checkpoint(UUID) }
    /// The stored state `destination` needs read back before it can be gone to; nil when it is in memory (or there
    /// is nowhere to go).
    func stateToRead(for destination: Destination) -> UUID? {
        let state: State?
        switch destination {
        case .undo: state = canUndo ? past.last?.before : nil
        case .redo: state = canRedo ? future.last?.after : nil
        case .checkpoint(let id): state = checkpoints.first { $0.id == id }?.state
        }
        return state.flatMap { $0.isResident ? nil : $0.revision }
    }
    /// A stored state was read back: it is in memory again. False when no entry or checkpoint holds it any more.
    @discardableResult func install(_ revision: UUID, document: CanvasDocument?) -> Bool {
        var found = false
        forEachState { state in
            guard state.revision == revision else { return }
            if !state.isResident { state.document = document; state.isResident = true }
            found = true
        }
        if found { readFailure = nil }
        return found
    }
    /// A stored state could not be read back; Undo, Redo and Restore Checkpoint say why.
    func noteReadFailure(_ reason: String) { readFailure = reason }

    // MARK: Checkpoints

    /// Names the state the document is in. `document` and the selection are that state's, as for `begin`.
    @discardableResult
    func addCheckpoint(named name: String, origin: LensWorksCommandOrigin = .user, document: CanvasDocument?, selection: UUID?, selected: Set<UUID>? = nil, date: Date = Date()) -> Checkpoint? {
        guard depth == 0 else { return nil }
        let state: State
        if let current, current.revision == revision, current.document == document { state = current }
        else {
            // No entry holds this state yet, or the document was changed outside history since the one that does.
            let diverged = current?.revision == revision
            state = State(Snapshot(document: document, activeLayerID: selection, selectedLayerIDs: Self.selected(selected, active: selection),
                revision: diverged ? UUID() : revision))
            if !diverged { current = state }
        }
        let checkpoint = Checkpoint(id: UUID(), name: name, origin: origin, date: date, state: state,
            selection: Selection(active: selection, selected: Self.selected(selected, active: selection)))
        checkpoints.append(checkpoint); annotations = UUID()
        return checkpoint
    }
    @discardableResult func renameCheckpoint(_ id: UUID, to name: String) -> Bool {
        guard let index = checkpoints.firstIndex(where: { $0.id == id }), checkpoints[index].name != name else { return false }
        checkpoints[index].name = name; annotations = UUID(); return true
    }
    /// Lets a checkpoint go. Its state stays for as long as an entry still runs through it.
    @discardableResult func removeCheckpoint(_ id: UUID) -> Bool {
        guard let index = checkpoints.firstIndex(where: { $0.id == id }) else { return false }
        checkpoints.remove(at: index); annotations = UUID(); didRelease?(); return true
    }
    /// The state a checkpoint keeps, read back when it has left memory.
    func checkpointSnapshot(_ id: UUID) -> Snapshot? {
        guard let checkpoint = checkpoints.first(where: { $0.id == id }) else { return nil }
        return snapshot(of: checkpoint.state, checkpoint.selection)
    }

    // MARK: Persistence

    /// The entries and checkpoints as a save writes them.
    var record: Record {
        func entry(_ e: Entry) -> Record.Entry {
            .init(id: e.id, name: e.name, origin: e.origin, date: e.date, before: e.before.revision, after: e.after.revision,
                  beforeSelection: e.beforeSelection, afterSelection: e.afterSelection)
        }
        return Record(past: past.map(entry), future: future.map(entry),
            checkpoints: checkpoints.map { .init(id: $0.id, name: $0.name, origin: $0.origin, date: $0.date, state: $0.revision, selection: $0.selection) }, cursor: revision)
    }
    /// Each distinct state an entry or a checkpoint holds.
    func forEachState(_ visit: (State) -> Void) {
        var seen = Set<ObjectIdentifier>()
        func once(_ state: State) { if seen.insert(ObjectIdentifier(state)).inserted { visit(state) } }
        for entry in past { once(entry.before); once(entry.after) }
        for entry in future { once(entry.before); once(entry.after) }
        for checkpoint in checkpoints { once(checkpoint.state) }
    }
    /// Takes up the history a package holds, right after its document was installed: `document` is the state at the
    /// record's cursor, and every other state stays on disk until it is needed.
    func adopt(_ record: Record, document: CanvasDocument?) {
        reset()
        var states: [UUID: State] = [:]
        let cursor = State(Snapshot(document: document, activeLayerID: nil, selectedLayerIDs: [], revision: record.cursor))
        cursor.isStored = true
        states[record.cursor] = cursor
        func state(_ id: UUID) -> State {
            if let known = states[id] { return known }
            let made = State(stored: id)
            states[id] = made; return made
        }
        func entry(_ e: Record.Entry) -> Entry {
            Entry(id: e.id, name: e.name, origin: e.origin, date: e.date, before: state(e.before), after: state(e.after),
                  beforeSelection: e.beforeSelection, afterSelection: e.afterSelection)
        }
        past = record.past.map(entry); future = record.future.map(entry)
        checkpoints = record.checkpoints.map { Checkpoint(id: $0.id, name: $0.name, origin: $0.origin, date: $0.date, state: state($0.state), selection: $0.selection) }
        revision = record.cursor; savedRevision = revision
        current = cursor
        // A package saved under a higher step limit: the steps beyond this one's go now, not at the next edit.
        if trimEntries() { didRelease?() }
    }
    /// The document was changed outside history since the state at the cursor was recorded (a checkpoint or the
    /// last step still holds that state as it was). What the document is now is a state of its own: without this a
    /// save would write today's document under the held state's name, and a checkpoint would restore the wrong one.
    func reconcileCursor(with document: CanvasDocument?) {
        guard depth == 0, let current, current.revision == revision, current.isResident, current.document != document else { return }
        revision = UUID(); self.current = nil
    }
    /// A save finished: `stored` are the states its package now holds, `pruned` the entries it had to drop to stay
    /// within the storage limit. Entries made while it was writing are untouched.
    func applySave(stored: Set<UUID>, pruned: Set<UUID>) {
        forEachState { state in if stored.contains(state.revision) { state.isStored = true } }
        if current.map({ stored.contains($0.revision) }) == true { current?.isStored = true }
        if !pruned.isEmpty {
            // Only the ends go: the oldest steps, and the furthest redo steps.
            while let first = past.first, pruned.contains(first.id) { past.removeFirst() }
            while let first = future.first, pruned.contains(first.id) { future.removeFirst() }
            didRelease?()
        }
    }

    /// Bytes retained only by history, excluding images in the live document.
    func retainedBytes(current: CanvasDocument?) -> Int {
        // Pre-admit transient identity sets before they can grow. Walk source
        // and history containers in-place: no past+future/compactMap projections
        // are allocated merely to decide whether retained history must be trimmed.
        var identifiers=0,overflowed=false
        func add(_ n:Int) {
            let value=identifiers.addingReportingOverflow(n)
            if n<0 || value.overflow { overflowed=true } else { identifiers=value.partialValue }
        }
        func count(_ document:CanvasDocument?) {
            if let owner=document?.metadataStorage { add(1);add(owner.payloadOwnerCount) }
            for layer in document?.layers ?? [] {
                if layer.asset != nil { add(2) };if layer.mask?.asset != nil { add(2) };if layer.bakedCoverage != nil { add(2) }
                if let node=layer.liveSource { add(1);add(node.sampleComposites.count) }
            }
        }
        count(current)
        forEachResidentDocument { count($0) }
        guard !overflowed else { return Int.max }
        let set=current?.metadataStorage?.workingSet ?? .sourceGraphs
        guard let allowance=try? LWSourceMetadataStorage.collectionBytes(count:identifiers,stride:MemoryLayout<ObjectIdentifier>.stride*3),
            let observing=try? set.reserve(allowance) else { return exactRetainedBytesWithoutSets(current:current) }
        defer { withExtendedLifetime(observing) {} }
        var seen=Set<ObjectIdentifier>(),sourceOwners=Set<ObjectIdentifier>(),topologyOwners=Set<ObjectIdentifier>()
        func assetIDs(_ asset:ImportedImage?) {
            guard let asset else { return }
            seen.insert(ObjectIdentifier(asset.image));seen.insert(ObjectIdentifier(asset.thumbnail))
        }
        func visitSourceOwners(_ node:LWLiveSourceNode?,_ visit:(LWSourceMetadataStorage)->Void) {
            guard let node else { return }
            if let owner=node.metadataStorage { visit(owner) }
            for composite in node.sampleComposites { if let owner=composite.metadataStorage { visit(owner) } }
        }
        for layer in current?.layers ?? [] {
            assetIDs(layer.asset);assetIDs(layer.mask?.asset);assetIDs(layer.bakedCoverage)
            visitSourceOwners(layer.liveSource) { sourceOwners.insert(ObjectIdentifier($0)) }
        }
        if let owner=current?.metadataStorage {
            topologyOwners.insert(ObjectIdentifier(owner))
            owner.forEachPayloadOwner { topologyOwners.insert(ObjectIdentifier($0)) }
        }
        var bytes=0
        func charge(_ amount:Int) { let value=bytes.addingReportingOverflow(amount);bytes=value.overflow ? Int.max:value.partialValue }
        func retainedAsset(_ asset:ImportedImage?) {
            guard let asset else { return }
            if seen.insert(ObjectIdentifier(asset.image)).inserted {
                if let plane=asset.linearPlane { charge(plane.retainedMetadataBytes) }
                else {
                    let stored=asset.image.bytesPerRow.multipliedReportingOverflow(by:asset.image.height)
                    charge(stored.overflow ? Int.max:stored.partialValue)
                    if let linear=asset.linear { charge(linear.byteLength) }
                }
            }
            if seen.insert(ObjectIdentifier(asset.thumbnail)).inserted {
                let stored=asset.thumbnail.bytesPerRow.multipliedReportingOverflow(by:asset.thumbnail.height)
                charge(stored.overflow ? Int.max:stored.partialValue)
            }
        }
        func retainedDocument(_ document:CanvasDocument?) {
            if let owner=document?.metadataStorage {
                if topologyOwners.insert(ObjectIdentifier(owner)).inserted { charge(owner.capacity) }
                owner.forEachPayloadOwner { root in
                    if topologyOwners.insert(ObjectIdentifier(root)).inserted { charge(root.capacity) }
                }
            }
            for layer in document?.layers ?? [] {
                visitSourceOwners(layer.liveSource) { owner in
                    if sourceOwners.insert(ObjectIdentifier(owner)).inserted { charge(owner.capacity) }
                }
                retainedAsset(layer.asset);retainedAsset(layer.mask?.asset);retainedAsset(layer.bakedCoverage)
            }
        }
        forEachResidentDocument { retainedDocument($0) }
        return bytes
    }

    /// A bookkeeping reservation refusal is not evidence that Undo exceeds its
    /// retention cap. Under pressure use exact in-place prefix comparisons. This
    /// allocates no identity set or history projection and never changes history.
    /// The normal admitted path is linear; this bounded fallback is quadratic in
    /// the retained reference count and needs actual performance qualification.
    private func exactRetainedBytesWithoutSets(current:CanvasDocument?)->Int {
        func appeared(kind:Int,id:ObjectIdentifier,before:Int)->Bool {
            var found=false
            _=forEachAccountingReference(current) { k,identity,_ in
                if k==kind && identity==id { found=true;return false };return true
            }
            if found { return true }
            var position=0
            _=forEachHistoricalReference { k,identity,_ in
                guard position<before else { return false };position+=1
                if k==kind && identity==id { found=true;return false };return true
            }
            return found
        }
        var position=0,total=0
        _=forEachHistoricalReference { kind,id,amount in
            if !appeared(kind:kind,id:id,before:position) {
                let sum=total.addingReportingOverflow(amount);total=sum.overflow ? Int.max:sum.partialValue
            }
            position+=1;return true
        }
        return total
    }
    private func forEachHistoricalReference(_ visit:(Int,ObjectIdentifier,Int)->Bool)->Bool {
        var continuing=true
        forEachResidentDocument { document in
            if continuing { continuing=forEachAccountingReference(document,visit) }
        }
        return continuing
    }
    private func forEachAccountingReference(_ document:CanvasDocument?,_ visit:(Int,ObjectIdentifier,Int)->Bool)->Bool {
        if let owner=document?.metadataStorage {
            if !visit(2,ObjectIdentifier(owner),owner.capacity) { return false }
            var continuing=true
            owner.forEachPayloadOwner { payload in
                if continuing { continuing=visit(2,ObjectIdentifier(payload),payload.capacity) }
            }
            if !continuing { return false }
        }
        func asset(_ value:ImportedImage?)->Bool {
            guard let value else { return true }
            let pixels=value.image.bytesPerRow.multipliedReportingOverflow(by:value.image.height)
            let linear=(pixels.overflow ? Int.max:pixels.partialValue).addingReportingOverflow(value.linear?.byteLength ?? 0)
            let amount=value.linearPlane?.retainedMetadataBytes ?? (linear.overflow ? Int.max:linear.partialValue)
            if !visit(0,ObjectIdentifier(value.image),amount) { return false }
            let thumbnail=value.thumbnail.bytesPerRow.multipliedReportingOverflow(by:value.thumbnail.height)
            return visit(0,ObjectIdentifier(value.thumbnail),thumbnail.overflow ? Int.max:thumbnail.partialValue)
        }
        for layer in document?.layers ?? [] {
            if let node=layer.liveSource {
                if let owner=node.metadataStorage, !visit(1,ObjectIdentifier(owner),owner.capacity) { return false }
                for composite in node.sampleComposites {
                    if let owner=composite.metadataStorage, !visit(1,ObjectIdentifier(owner),owner.capacity) { return false }
                }
            }
            if !asset(layer.asset) || !asset(layer.mask?.asset) || !asset(layer.bakedCoverage) { return false }
        }
        return true
    }

    /// Keeps history within its step and memory limits. Memory first gives up states the package also holds, the
    /// ones furthest from where the document is; only then are steps dropped, oldest first. A checkpoint is never
    /// dropped: one that is not saved yet stays in memory whatever it costs.
    private func trim(current document: CanvasDocument?) {
        var released = trimEntries()
        if retainedBytes(current: document) > retainedByteLimit {
            var candidates: [State] = []
            var seen = Set<ObjectIdentifier>()
            func add(_ state: State) {
                if state.isStored, state.isResident, state !== current, seen.insert(ObjectIdentifier(state)).inserted { candidates.append(state) }
            }
            for entry in past { add(entry.before); add(entry.after) }
            for entry in future { add(entry.after); add(entry.before) }
            for checkpoint in checkpoints { add(checkpoint.state) }
            for state in candidates {
                state.document = nil; state.isResident = false; released = true
                if retainedBytes(current: document) <= retainedByteLimit { break }
            }
        }
        if retainedBytes(current: document) > retainedByteLimit {
            // What checkpoints hold cannot be freed by dropping a step (one not saved yet stays in memory whatever it
            // costs), so it does not count against the steps: they keep the limit for what only they hold. Counting
            // it would drop every step at every edit once an unsaved checkpoint alone is over the limit.
            let floor = retainedByteLimit.addingReportingOverflow(checkpointBytes(current: document))
            let allowed = floor.overflow ? Int.max : floor.partialValue
            while retainedBytes(current: document) > allowed {
                if !past.isEmpty { past.removeFirst() }
                else if !future.isEmpty { future.removeFirst() }
                else { break }
                released = true
            }
        }
        if released { didRelease?() }
    }
    /// Drops the steps beyond the step limit: the oldest undo steps, then the furthest redo steps.
    private func trimEntries() -> Bool {
        var released = false
        while past.count + future.count > entryLimit {
            if !past.isEmpty { past.removeFirst() } else { future.removeFirst() }
            released = true
        }
        return released
    }
    /// The memory held only by the states checkpoints keep: no step that is dropped gives any of it back.
    private func checkpointBytes(current document: CanvasDocument?) -> Int {
        countsCheckpointsOnly = true
        defer { countsCheckpointsOnly = false }
        return retainedBytes(current: document)
    }
}
