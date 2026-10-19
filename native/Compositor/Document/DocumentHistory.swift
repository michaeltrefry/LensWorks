import Foundation
import CoreGraphics
import Observation

/// Value snapshots share immutable CGImages; no pixel copies for layer edits.
@Observable
final class DocumentHistory {
    struct Snapshot {
        let document: CanvasDocument?
        let activeLayerID: UUID?
        let revision: UUID
        let versionContent: LensWorksVersionContent?
        init(document: CanvasDocument?, activeLayerID: UUID?, revision: UUID, versionContent: LensWorksVersionContent? = nil) {
            self.document = document; self.activeLayerID = activeLayerID; self.revision = revision; self.versionContent = versionContent
        }
    }
    struct Entry {
        var id = UUID()
        let name: String
        /// Who made the edit: an agent may step only over its own entries.
        let origin: LensWorksCommandOrigin
        let before: Snapshot
        let after: Snapshot
    }
    var protectedEntryIDs: Set<UUID> = []
    private var past: [Entry] = []
    private var future: [Entry] = []
    private var revision = UUID()
    private var savedRevision: UUID?
    private var pending: Snapshot?
    @ObservationIgnored private(set) var pendingAfterMetadataStorage:LWSourceMetadataStorage?
    private var pendingName = "Edit"
    private var pendingOrigin = LensWorksCommandOrigin.user
    private var depth = 0
    private var interactionToken: UUID?
    @ObservationIgnored private var adoptsNestedName = false
    /// Visit immutable owners in-place; Close must include a pending history
    /// snapshot without allocating another archive or transferring edit authority.
    func forEachRetainedDocument(_ visit: (CanvasDocument?) throws -> Void) rethrows {
        try visit(pending?.document)
        for entry in past { try visit(entry.before.document); try visit(entry.after.document) }
        for entry in future { try visit(entry.before.document); try visit(entry.after.document) }
    }
    /// With `adoptingNestedName`, the entry takes the name of the first edit made inside the interaction (labeled for
    /// its origin), so an agent's command is listed under the same name the menu's edit has.
    func beginInteraction(_ name: String, document: CanvasDocument?, selection: UUID?,afterMetadataStorage:LWSourceMetadataStorage? = nil, origin: LensWorksCommandOrigin = .user, adoptingNestedName: Bool = false) -> UUID? {
        guard depth == 0 else { return nil }
        let token = UUID(); interactionToken = token; adoptsNestedName = adoptingNestedName
        begin(name,document:document,selection:selection,afterMetadataStorage:afterMetadataStorage,origin:origin); return token
    }
    func endInteraction(_ token: UUID, document: CanvasDocument?, selection: UUID?) -> Bool {
        guard interactionToken == token, depth == 1 else { return false }
        interactionToken = nil; end(document: document, selection: selection); return true
    }
    func cancelInteraction(_ token: UUID) -> Snapshot? {
        guard interactionToken == token, depth == 1, let starting = pending else { return nil }
        interactionToken = nil; pending = nil;pendingAfterMetadataStorage=nil; depth = 0; return starting
    }
    var entryLimit: Int
    private let defaultEntryLimit: Int
    let retainedByteLimit: Int

    init(entryLimit: Int = 100, retainedByteLimit: Int = 256 * 1024 * 1024) {
        self.entryLimit = max(0, entryLimit)
        self.defaultEntryLimit = max(0, entryLimit)
        self.retainedByteLimit = max(0, retainedByteLimit)
        savedRevision = revision
    }

    /// The same transaction records serve every editor tool; saving never coalesces them.
    /// An unfinished gesture cannot be captured as a completed edit.
    func entries() throws -> (past: [Entry], future: [Entry]) {
        guard depth == 0 else { throw LensWorksCommandRefusal(reason: "Finish the current canvas edit before saving or naming a checkpoint. Your edits and Undo history have been kept.") }
        return (past, future)
    }

    func install(past: [Entry], future: [Entry], currentRevision: UUID, limit: Int, protected: Set<UUID>) {
        reset()
        self.past = past; self.future = future
        revision = currentRevision; savedRevision = currentRevision
        entryLimit = max(1, limit); protectedEntryIDs = protected
    }

    /// A whole-composition replacement made through the version controls uses
    /// the same timeline as ordinary editor transactions.
    func appendCaptured(id: UUID, name: String, before: CanvasDocument, selection: UUID?, after: CanvasDocument?, afterSelection: UUID?, beforeRevision: UUID, afterRevision: UUID) {
        let starting = Snapshot(document: before, activeLayerID: selection, revision: beforeRevision)
        revision = afterRevision
        past.append(Entry(id: id, name: name, origin: .user, before: starting,
            after: Snapshot(document: after, activeLayerID: afterSelection, revision: revision)))
        future.removeAll()
        trim(current: after)
    }

    func applyLimits(entryLimit: Int, protected: Set<UUID>, current: CanvasDocument?) {
        self.entryLimit = max(1, entryLimit); protectedEntryIDs = protected
        trim(current: current)
    }

    var canUndo: Bool { depth == 0 && !past.isEmpty }
    var canRedo: Bool { depth == 0 && !future.isEmpty }
    var undoName: String { past.last?.name ?? "" }
    var redoName: String { future.last?.name ?? "" }
    /// Who made the entry Undo (Redo) would step over, or nil when there is none.
    var undoOrigin: LensWorksCommandOrigin? { past.last?.origin }
    var redoOrigin: LensWorksCommandOrigin? { future.last?.origin }
    var isModified: Bool { revision != savedRevision }
    var undoCount: Int { past.count }
    func markSaved() { savedRevision = revision }
    /// The document as it stands, for a save that captures it now and finishes later.
    var currentRevision: UUID { revision }
    /// A save of `saved` finished. Edits made while it was writing leave the document modified; undoing back to it doesn't.
    func markSaved(_ saved: UUID) { savedRevision = saved }
    func reset() {
        protectedEntryIDs = []
        entryLimit = defaultEntryLimit
        past.removeAll()
        future.removeAll()
        pending = nil;pendingAfterMetadataStorage=nil
        depth = 0
        interactionToken = nil
        revision = UUID()
        savedRevision = revision
    }

    func begin(_ name: String, document: CanvasDocument?, selection: UUID?,afterMetadataStorage:LWSourceMetadataStorage? = nil, origin: LensWorksCommandOrigin = .user) {
        if depth == 0 {
            pendingOrigin = origin
            pendingAfterMetadataStorage=afterMetadataStorage
            pending = Snapshot(document: document, activeLayerID: selection, revision: revision)
            pendingName = name
        } else if depth == 1, adoptsNestedName, interactionToken != nil {
            pendingName = pendingOrigin.historyName(name); adoptsNestedName = false
        }
        depth += 1
    }

    func end(document: CanvasDocument?, selection: UUID?) {
        guard depth > 0 else { return }
        depth -= 1
        guard depth == 0, let before = pending else { return }
        pending = nil;pendingAfterMetadataStorage=nil
        // Selecting, navigating, and no-op edits must preserve redo history.
        guard before.document != document else { return }
        revision = UUID()
        past.append(Entry(name: pendingName, origin: pendingOrigin, before: before,
            after: Snapshot(document: document, activeLayerID: selection, revision: revision)))
        future.removeAll()
        trim(current: document)
    }

    func undo() -> Snapshot? {
        guard canUndo, let entry = past.popLast() else { return nil }
        future.append(entry)
        revision = entry.before.revision
        trim(current: entry.before.document)
        return entry.before
    }

    func redo() -> Snapshot? {
        guard canRedo, let entry = future.popLast() else { return nil }
        past.append(entry)
        revision = entry.after.revision
        trim(current: entry.after.document)
        return entry.after
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
                if layer.asset != nil { add(2) };if layer.mask?.asset != nil { add(2) }
                if let node=layer.liveSource { add(1);add(node.sampleComposites.count) }
            }
        }
        count(current)
        for entry in past { count(entry.before.document);count(entry.after.document) }
        for entry in future { count(entry.before.document);count(entry.after.document) }
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
            assetIDs(layer.asset);assetIDs(layer.mask?.asset)
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
                retainedAsset(layer.asset);retainedAsset(layer.mask?.asset)
            }
        }
        for entry in past { retainedDocument(entry.before.document);retainedDocument(entry.after.document) }
        for entry in future { retainedDocument(entry.before.document);retainedDocument(entry.after.document) }
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
        for entry in past {
            if !forEachAccountingReference(entry.before.document,visit) || !forEachAccountingReference(entry.after.document,visit) { return false }
        }
        for entry in future {
            if !forEachAccountingReference(entry.before.document,visit) || !forEachAccountingReference(entry.after.document,visit) { return false }
        }
        return true
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
            if !asset(layer.asset) || !asset(layer.mask?.asset) { return false }
        }
        return true
    }

    private func trim(current: CanvasDocument?) {
        while past.count + future.count > entryLimit || retainedBytes(current: current) > retainedByteLimit {
            if let index = past.firstIndex(where: { !protectedEntryIDs.contains($0.id) }) { past.remove(at: index) }
            else if let index = future.firstIndex(where: { !protectedEntryIDs.contains($0.id) }) { future.remove(at: index) }
            else { break }
        }
    }
}
