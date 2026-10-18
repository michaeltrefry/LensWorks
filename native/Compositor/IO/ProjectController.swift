import AppKit
import CryptoKit
import ImageIO
import UniformTypeIdentifiers
import SwiftUI

@MainActor
final class ProjectController {
    let session: EditorSession
    weak var window: NSWindow?
    weak var workspace: ProjectWorkspace?
    var workingVersion: LensWorksWorkingVersion? { didSet { if workingVersion?.id != relinkedOriginal?.version { relinkedOriginal = nil } } }
    /// Package-persisted LensWorks versions, checkpoints and the ordinary editor Undo/Redo timeline.
    var lensWorksDocument: LensWorksPhotoDocument?
    var lensWorksDocumentAssets: [String: Data] = [:]
    var lensWorksDocumentPlanes: [String: LWFloatPlane] = [:]
    /// The version selected by the LensWorks history controls for this open photo.
    var selectedLensWorksVersionID: UUID?
    /// Kept separate from canvas history so changing a persisted LensWorks record still prompts to save.
    var lensWorksDocumentModified = false
    /// A durable capture may safely replace this exact canvas revision; later
    /// session edits must be saved/captured before Undo, Redo or checkpoint restore.
    private var capturedLensWorksCanvasRevision: UUID?
    private var capturedLensWorksCanvasDocument: CanvasDocument?
    private var representedCanvasStepIDs: Set<UUID> = []

    /// Protected history is never discarded merely to honor a limit; this is surfaced by the editor controls instead.
    var lensWorksHistoryWarning: String?
    /// The original location a catalog relink assigned to the open working version this session.
    /// It is recorded by the next save and survives reloads of a package written elsewhere.
    var relinkedOriginal: (version: UUID, path: String, native: LWCatalogNativePath?)?
    private var saveGeneration = 0
    /// Whether opening and saving add the project to File › Open Recent (macOS keeps that list for the person; tests
    /// turn this off so a fixture never lands in it).
    var recordsRecentProjects = true
    /// Whether saving a catalog working version records it in the app's shared version index and as the last one
    /// opened (tests turn this off so a fixture never lands in the person's own).
    var sharesWorkingVersions = true
    private(set) var sourceCloseRequested = false
    private var standaloneCloseConfirmed = false
    /// Keeps the document in step with its package when something else writes it. See ProjectController+ExternalChanges.
    let externalChanges = ExternalChangeState()
    var canStart: Bool {
        session.canStartProjectOperation && workspace?.isManaging != true
    }
    init(session: EditorSession) { self.session = session }

    /// Starts the persisted native record for a catalog working version. The initial graph is copied out of the editor,
    /// so later version changes do not share mutable state with its siblings.
    func initializeLensWorksDocument(photoID: String, named name: String, sourceReference: LensWorksSourceReference? = nil) throws {
        guard lensWorksDocument == nil, !photoID.isEmpty else { return }
        var document = LensWorksPhotoDocument(photoID: photoID)
        let versionID = document.addVersion(named: name)
        var content = LensWorksVersionContent()
        guard let snapshot = session.projectSnapshot() else { throw ProjectError.invalid }
        var assets = lensWorksDocumentAssets, planes = lensWorksDocumentPlanes
        content.layerGraph = try retainedGraph(snapshot, assets: &assets, planes: &planes)
        lensWorksDocumentAssets = assets
        lensWorksDocumentPlanes = planes
        document.selectedVersionID = versionID
        if let sourceReference { content.sourceReferences = [sourceReference] }
        guard let index = document.versions.firstIndex(where: { $0.id == versionID }) else { return }
        document.versions[index].content = content
        lensWorksDocument = document
        selectedLensWorksVersionID = versionID
        session.history.applyLimits(entryLimit: document.maxUndoSteps, protected: [], current: session.document)
        capturedLensWorksCanvasRevision = session.history.currentRevision
        capturedLensWorksCanvasDocument = session.document
        lensWorksDocumentModified = true
    }

    func addLensWorksVersion(named name: String) throws {
        guard var document = lensWorksDocument, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let snapshot = session.projectSnapshot() else { throw ProjectError.invalid }
        var assets = lensWorksDocumentAssets, planes = lensWorksDocumentPlanes
        let graph = try retainedGraph(snapshot, assets: &assets, planes: &planes)
        let versionID = document.addVersion(named: name)
        document.versions[document.versions.count - 1].content.layerGraph = graph
        document.selectedVersionID = versionID
        lensWorksDocument = document
        lensWorksDocumentAssets = assets; lensWorksDocumentPlanes = planes
        selectedLensWorksVersionID = versionID
        session.history.reset()
        session.history.applyLimits(entryLimit: document.maxUndoSteps, protected: [], current: session.document)
        representedCanvasStepIDs = []
        capturedLensWorksCanvasRevision = session.history.currentRevision
        capturedLensWorksCanvasDocument = session.document
        lensWorksDocumentModified = true
    }

    func duplicateLensWorksVersion(_ id: UUID, named name: String) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError.invalid }
        if selectedLensWorksVersionID == id { try captureLensWorksComposition(in: id) }
        guard var document = lensWorksDocument, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError.invalid }
        // Duplicate the chosen record, but do not replace a different canvas or lose
        // uncaptured edits merely by changing the selection as a side effect.
        let copy = try document.duplicateVersion(id, named: name)
        lensWorksDocument = document
        lensWorksDocumentModified = true
        if selectedLensWorksVersionID == id {
            selectedLensWorksVersionID = copy
            lensWorksDocument?.selectedVersionID = copy
            session.history.reset()
            session.history.applyLimits(entryLimit: document.maxUndoSteps, protected: [], current: session.document)
            representedCanvasStepIDs = []
            capturedLensWorksCanvasRevision = session.history.currentRevision
            capturedLensWorksCanvasDocument = session.document
        }
    }

    /// Copies the snapshot's layer pixels into content-addressed document assets and returns the graph that names them,
    /// so every captured composition keeps the bytes it needs however the canvas changes afterwards.
    private func retainedGraph(_ snapshot: ProjectSnapshot, assets: inout [String: Data], planes: inout [String: LWFloatPlane]) throws -> LensWorksLayerGraph {
        var manifest = try snapshot.manifest.metadataCopy()
        var records = manifest.layers
        var references: [String: LWFloatPlaneArchive.Reference] = [:]
        for i in records.indices {
            let layerID = records[i].id
            for isMask in [false, true] {
                guard (isMask ? records[i].maskFile : records[i].imageFile) != nil else { continue }
                guard let asset = (isMask ? snapshot.masks : snapshot.images)[layerID] else { throw ProjectError.missingImage }
                if let plane = asset.linearPlane {
                    let reference = try LWFloatPlaneArchive.reference(plane)
                    let id = reference.manifestSHA256 + ".plane"
                    planes[id] = plane; references[id] = reference
                    if isMask { records[i].maskFile = id; records[i].maskPlaneArchiveReference = reference }
                    else { records[i].imageFile = id; records[i].planeArchiveReference = reference }
                    continue
                }
                if let linear = asset.linear, !isMask {
                    let data = try linear.packageData(maximumFileBytes: 512 * 1024 * 1024)
                    let id = LWSourcePackageArchive.digest(data) + ".f32"
                    assets[id] = data; records[i].imageFile = id
                    continue
                }
                let data = NSMutableData()
                guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ProjectError.encode }
                CGImageDestinationAddImage(destination, asset.image, nil)
                guard CGImageDestinationFinalize(destination) else { throw ProjectError.encode }
                let digest = SHA256.hash(data: data as Data).map { String(format: "%02x", $0) }.joined()
                let id = digest + (isMask ? ".mask.png" : ".png")
                assets[id] = data as Data
                if isMask { records[i].maskFile = id } else { records[i].imageFile = id }
            }
        }
        manifest.layers = records
        let projection = try LWSourcePackageArchive.externalize(manifest, maximumBytes: LWSourceDeveloper.maximumResultBytes)
        for (id, bytes) in projection.assets { assets[id] = bytes }
        for (id, asset) in projection.planes {
            guard let plane = asset.plane else { throw ProjectError.missingImage }
            planes[id] = plane; references[id] = asset.reference
        }
        var composition = projection.manifest
        composition.layers = []
        return LensWorksLayerGraph(layers: projection.manifest.layers, composition: composition,
            retainedAssetIDs: projection.assets.keys.sorted(), planeReferences: references)
    }

    private final class CanvasHistoryDecodeCache {
        var images: [String: ImportedImage] = [:]
        var masks: [String: ImportedImage] = [:]
        let sources = LWSourcePackageArchive.HydrationCache()
    }

    /// Puts a version's stored layer graph on the canvas, decoding its retained assets back into layers.
    private func decodedLensWorksContent(_ content: LensWorksVersionContent, package: ProjectSnapshot? = nil, cache suppliedCache: CanvasHistoryDecodeCache? = nil) throws -> ProjectSnapshot {
        let cache = suppliedCache ?? CanvasHistoryDecodeCache()
        let retainedAssets = package?.lensWorksDocumentAssets ?? lensWorksDocumentAssets
        let retainedPlanes = package?.lensWorksDocumentPlanes ?? lensWorksDocumentPlanes
        guard let graph = content.layerGraph, let base = package ?? session.projectSnapshot() else { throw ProjectError.invalid }
        var captured = graph.composition ?? base.manifest
        if graph.composition == nil, let active = captured.activeLayerID,
           !graph.layers.contains(where: { $0.id == active }) {
            // Older graphs did not capture selection; do not carry a foreign
            // current-canvas layer ID into the restored graph's validation.
            captured = ProjectManifest(workingSpace: captured.workingSpace, workingSample: captured.workingSample,
                resolution: captured.resolution, documentID: captured.documentID, width: captured.width,
                height: captured.height, activeLayerID: nil, layers: [], guides: captured.guides,
                metadataStorage: captured.metadataStorage)
        }
        captured.layers = graph.layers
        captured = try LWSourcePackageArchive.hydrate(captured, read: { id, maximum in
            guard let bytes = retainedAssets[id], bytes.count <= maximum else { throw ProjectError.missingImage }
            return bytes
        }, readPlane: { id, reference in
            guard let plane = retainedPlanes[id],
                  try LWFloatPlaneArchive.reference(plane) == reference else { throw ProjectError.missingImage }
            return plane
        }, cache: cache.sources)
        var records = captured.layers
        var images: [UUID: ImportedImage] = [:], masks: [UUID: ImportedImage] = [:]
        var pixels = 0, maskPixels = 0
        func admit(width: Int, height: Int, isMask: Bool) throws {
            if isMask { try ProjectStore.checkSize(width: width, height: height, used: &maskPixels) }
            else { try ProjectStore.checkSize(width: width, height: height, used: &pixels) }
        }
        func decode(_ id: String, name: String, isMask: Bool) throws -> ImportedImage {
            if let asset = (isMask ? cache.masks : cache.images)[id] {
                try admit(width: asset.image.width, height: asset.image.height, isMask: isMask)
                return asset
            }
            let asset = try decodeUncached(id, name: name, isMask: isMask)
            if isMask { cache.masks[id] = asset } else { cache.images[id] = asset }
            return asset
        }
        func decodeUncached(_ id: String, name: String, isMask: Bool) throws -> ImportedImage {
            if let reference = graph.planeReferences?[id] {
                guard let plane = retainedPlanes[id],
                      try LWFloatPlaneArchive.reference(plane) == reference else { throw ProjectError.missingImage }
                try admit(width: plane.width, height: plane.height, isMask: isMask)
                return try isMask ? ImportedImage(maskPlane: plane, name: name) : ImportedImage(plane: plane, name: name)
            }
            if id.hasSuffix(".f32") {
                guard !isMask, let bytes = retainedAssets[id] else { throw ProjectError.missingImage }
                let extent = try LWLinearSurface.packageExtent(bytes, maximumFileBytes: 512 * 1024 * 1024)
                try admit(width: extent.width, height: extent.height, isMask: false)
                let linear = try LWLinearSurface.package(bytes, maximumFileBytes: 512 * 1024 * 1024)
                return try ImportedImage(linear: linear, name: name)
            }
            guard let bytes = retainedAssets[id],
                  let source = CGImageSourceCreateWithData(bytes as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
                  CGImageSourceGetType(source) as String? == UTType.png.identifier,
                  CGImageSourceGetCount(source) == 1,
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  (properties[kCGImagePropertyDepth] as? Int ?? 8) <= 8 else { throw ProjectError.missingImage }
            try admit(width: width, height: height, isMask: isMask)
            guard let image = CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  let thumbnail = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 96,
                      kCGImageSourceShouldCacheImmediately: true] as CFDictionary),
                  !isMask || LayerMask.isValid(image) else { throw ProjectError.missingImage }
            return ImportedImage(image: image, thumbnail: thumbnail, name: name)
        }
        for i in records.indices {
            let layer = records[i]
            if let file = layer.imageFile {
                images[layer.id] = try decode(file, name: layer.name, isMask: false)
                records[i].imageFile = "\(layer.id.uuidString)." + (images[layer.id]?.linearPlane != nil ? "plane" : images[layer.id]?.linear != nil ? "f32" : "png")
            }
            if let file = layer.maskFile {
                masks[layer.id] = try decode(file, name: layer.name, isMask: true)
                records[i].maskFile = "\(layer.id.uuidString).mask." + (masks[layer.id]?.linearPlane != nil ? "plane" : "png")
            }
        }
        captured.layers = records
        try ProjectStore.validate(captured)
        return ProjectSnapshot(manifest: captured, images: images, masks: masks)
    }

    private func isCanvasStep(_ step: LensWorksHistoryStep) -> Bool {
        guard step.content.layerGraph != nil,
              step.oppositeContent == nil || step.oppositeContent?.layerGraph != nil else { return false }
        switch step.command {
        case .replaceLayerGraph, .replaceLiveSource, nil: return true
        default: return false // Legacy scalar metadata has separate version-control Undo ownership.
        }
    }

    /// Decode every retained state before touching the live canvas. Corrupt history
    /// must fail the whole replacement, not partially install a version.
    private func decodedCanvasHistory(_ version: LensWorksPhotoVersion, package: ProjectSnapshot? = nil) throws -> (past: [DocumentHistory.Entry], future: [DocumentHistory.Entry], revision: UUID, snapshot: ProjectSnapshot) {
        let ids = (version.undo + version.redo).map(\.id)
        guard Set(ids).count == ids.count else { throw ProjectError.invalid }
        let cache = CanvasHistoryDecodeCache()
        let present = try decodedLensWorksContent(version.content, package: package, cache: cache)
        var current = DocumentHistory.Snapshot(document: EditorSession.canvasDocument(present),
            activeLayerID: present.manifest.activeLayerID, revision: version.canvasRevision ?? UUID())
        let revision = current.revision
        var past: [DocumentHistory.Entry] = [], future: [DocumentHistory.Entry] = []
        for step in version.undo.reversed() {
            guard isCanvasStep(step) else { break } // Legacy scalar history stays on the version controls.
            let decoded = try decodedLensWorksContent(step.content, package: package, cache: cache)
            let before = DocumentHistory.Snapshot(document: EditorSession.canvasDocument(decoded), activeLayerID: decoded.manifest.activeLayerID, revision: step.canvasBeforeRevision ?? UUID())
            let after: DocumentHistory.Snapshot
            if let opposite = step.oppositeContent {
                let decoded = try decodedLensWorksContent(opposite, package: package, cache: cache)
                let canvas = EditorSession.canvasDocument(decoded)
                after = DocumentHistory.Snapshot(document: canvas, activeLayerID: decoded.manifest.activeLayerID,
                    revision: step.canvasAfterRevision ?? (canvas == current.document ? current.revision : UUID()))
            } else { after = current }
            past.append(DocumentHistory.Entry(id: step.id, name: step.name, origin: step.attributedToAgent ? .agent : .user, before: before, after: after))
            current = before
        }
        past.reverse()
        current = DocumentHistory.Snapshot(document: EditorSession.canvasDocument(present),
            activeLayerID: present.manifest.activeLayerID, revision: revision)
        for step in version.redo.reversed() {
            guard isCanvasStep(step) else { break }
            let decoded = try decodedLensWorksContent(step.content, package: package, cache: cache)
            let after = DocumentHistory.Snapshot(document: EditorSession.canvasDocument(decoded), activeLayerID: decoded.manifest.activeLayerID, revision: step.canvasAfterRevision ?? UUID())
            let before: DocumentHistory.Snapshot
            if let opposite = step.oppositeContent {
                let decoded = try decodedLensWorksContent(opposite, package: package, cache: cache)
                let canvas = EditorSession.canvasDocument(decoded)
                before = DocumentHistory.Snapshot(document: canvas, activeLayerID: decoded.manifest.activeLayerID,
                    revision: step.canvasBeforeRevision ?? (canvas == current.document ? current.revision : UUID()))
            } else { before = current }
            future.append(DocumentHistory.Entry(id: step.id, name: step.name, origin: step.attributedToAgent ? .agent : .user, before: before, after: after))
            current = after
        }
        future.reverse()
        return (past, future, revision, present)
    }

    private func installLensWorksVersion(_ version: LensWorksPhotoVersion, limit: Int) throws {
        guard session.canStartProjectOperation, session.canEditLayers, session.opacityEditLayerID == nil else {
            throw LensWorksCommandRefusal(reason: "Finish the current canvas edit before switching or restoring versions. Your edits and Undo history have been kept.")
        }
        guard version.content.layerGraph != nil else {
            // A legacy metadata operation is its own Undo owner. End the native
            // suffix at that boundary; its older steps remain in version history
            // in their original order, not moved before/after later metadata.
            session.history.reset()
            session.history.applyLimits(entryLimit: limit, protected: [], current: session.document)
            representedCanvasStepIDs = []
            capturedLensWorksCanvasRevision = session.history.currentRevision
            capturedLensWorksCanvasDocument = session.document
            return
        }
        let history = try decodedCanvasHistory(version)
        let url = session.projectURL
        session.installProject(history.snapshot, from: url ?? URL(fileURLWithPath: "/"))
        session.projectURL = url
        session.history.install(past: history.past, future: history.future, currentRevision: history.revision,
            limit: limit, protected: Set(version.checkpoints.compactMap(\.pinnedStepID)))
        representedCanvasStepIDs = Set((history.past + history.future).map(\.id))
        capturedLensWorksCanvasRevision = session.history.currentRevision
        capturedLensWorksCanvasDocument = session.document
    }

    /// Prepared off to the side, then installed along with a successfully loaded package.
    func prepareLensWorksCanvasHistory(_ snapshot: ProjectSnapshot) throws -> (() -> Void) {
        guard let document = snapshot.lensWorksDocument,
              let version = document.versions.first(where: { $0.id == (document.selectedVersionID ?? document.versions.first?.id) }),
              version.content.layerGraph != nil else { return { [self] in
                  representedCanvasStepIDs = []
                  capturedLensWorksCanvasRevision = session.history.currentRevision
                  capturedLensWorksCanvasDocument = session.document
                  session.history.applyLimits(entryLimit: snapshot.lensWorksDocument?.maxUndoSteps ?? 100, protected: [], current: session.document)
              } }
        let history = try decodedCanvasHistory(version, package: snapshot)
        return { [self] in
            session.history.install(past: history.past, future: history.future, currentRevision: history.revision,
                limit: document.maxUndoSteps, protected: Set(version.checkpoints.compactMap(\.pinnedStepID)))
            representedCanvasStepIDs = Set((history.past + history.future).map(\.id))
            capturedLensWorksCanvasRevision = session.history.currentRevision
            capturedLensWorksCanvasDocument = session.document
        }
    }

    /// Selects a version and shows its stored composition on the canvas.
    func selectLensWorksVersion(_ id: UUID) throws {
        guard let version = lensWorksDocument?.versions.first(where: { $0.id == id }) else { throw ProjectError.invalid }
        guard selectedLensWorksVersionID != id else { return }
        // Replacing the canvas resets its session undo. Never do that to unsaved work.
        guard !session.isModified else {
            throw LensWorksCommandRefusal(reason: "Save your canvas edits before switching versions. Your edits and Undo history have been kept.")
        }
        if let departing = selectedLensWorksVersionID { try captureLensWorksComposition(in: departing) }
        try installLensWorksVersion(version, limit: lensWorksDocument?.maxUndoSteps ?? 100)
        selectedLensWorksVersionID = id
        lensWorksDocument?.selectedVersionID = id
        lensWorksDocumentModified = true
    }

    /// Commits a changed document only after the version's content is on the canvas.
    private func commit(_ document: LensWorksPhotoDocument, showing id: UUID) throws {
        guard !session.isModified || capturedLensWorksCanvasRevision == session.history.currentRevision else {
            throw LensWorksCommandRefusal(reason: "Save or capture your canvas edits before restoring version history. Your edits and Undo history have been kept.")
        }
        if let version = document.versions.first(where: { $0.id == id }) { try installLensWorksVersion(version, limit: document.maxUndoSteps) }
        lensWorksDocument = document
        selectedLensWorksVersionID = id
        lensWorksDocument?.selectedVersionID = id
        capturedLensWorksCanvasRevision = session.history.currentRevision
        capturedLensWorksCanvasDocument = session.document
        pruneRetainedLensWorksAssets()
        lensWorksDocumentModified = true
    }

    /// Serializes the central editor transaction log, not a tool-specific subset.
    /// Both stacks keep their identities, labels, origin and exact compositions.
    /// All encoding completes in local values before any controller state changes.
    func captureLensWorksComposition(in id: UUID) throws {
        guard selectedLensWorksVersionID == id, var document = lensWorksDocument,
              let index = document.versions.firstIndex(where: { $0.id == id }),
              let snapshot = session.projectSnapshot() else { throw ProjectError.invalid }
        let history = try session.history.entries()
        var assets = lensWorksDocumentAssets, planes = lensWorksDocumentPlanes
        let previous = document.versions[index]
        let allSteps = previous.undo + previous.redo
        guard Set(allSteps.map(\.id)).count == allSteps.count else { throw ProjectError.invalid }
        let oldSteps = Dictionary(uniqueKeysWithValues: allSteps.map { ($0.id, $0) })
        struct SnapshotKey: Hashable { let revision: UUID; let selection: UUID? }
        var graphs: [SnapshotKey: LensWorksLayerGraph] = [:]
        func graph(_ state: DocumentHistory.Snapshot) throws -> LensWorksLayerGraph {
            let key = SnapshotKey(revision: state.revision, selection: state.activeLayerID)
            if let cached = graphs[key] { return cached }
            guard let snapshot = session.projectSnapshot(document: state.document, selection: state.activeLayerID) else { throw ProjectError.invalid }
            let value = try retainedGraph(snapshot, assets: &assets, planes: &planes)
            graphs[key] = value
            return value
        }
        func step(_ entry: DocumentHistory.Entry, redo: Bool) throws -> LensWorksHistoryStep {
            let value = try graph(redo ? entry.after : entry.before)
            var content = oldSteps[entry.id]?.content ?? previous.content
            content.layerGraph = value
            var opposite = oldSteps[entry.id]?.oppositeContent ?? previous.content
            opposite.layerGraph = try graph(redo ? entry.before : entry.after)
            let command: LensWorksDocumentCommand?
            if let original = oldSteps[entry.id] { command = original.command }
            else { command = .replaceLayerGraph(try graph(entry.after)) }
            return LensWorksHistoryStep(id: entry.id, name: entry.name, command: command, content: content,
                oppositeContent: opposite, canvasBeforeRevision: entry.before.revision, canvasAfterRevision: entry.after.revision,
                attributedToAgent: entry.origin == .agent)
        }
        // Initial import/create entries may start with no document; they are not
        // edits of this photo. Every completed edit of its document is retained.
        let past = history.past.filter { $0.before.document?.id == snapshot.manifest.documentID && $0.after.document?.id == snapshot.manifest.documentID }
        let future = history.future.filter { $0.before.document?.id == snapshot.manifest.documentID && $0.after.document?.id == snapshot.manifest.documentID }
        let canvasIDs = Set((past + future).map(\.id))
        let pinned = Set(previous.checkpoints.compactMap(\.pinnedStepID))
        // Scalar-only legacy commands and protected steps trimmed from the native
        // in-memory byte budget remain independently available in the version UI.
        let prefix = previous.undo.filter { !canvasIDs.contains($0.id) && (!representedCanvasStepIDs.contains($0.id) || pinned.contains($0.id)) }
        document.versions[index].undo = prefix + (try past.map { try step($0, redo: false) })
        let legacyRedo = previous.redo.filter { !representedCanvasStepIDs.contains($0.id) && !canvasIDs.contains($0.id) }
        document.versions[index].redo = legacyRedo + (try future.map { try step($0, redo: true) })
        let current = try retainedGraph(snapshot, assets: &assets, planes: &planes)
        var capturedReplacement: (LensWorksHistoryStep, ProjectSnapshot)?
        // Explicit captures also handle programmatic document replacements that
        // have no editor transaction. Normal edits already have one entry each.
        let recordedCurrent = [past.last?.after, future.last?.before].compactMap { $0 }.contains {
            $0.revision == session.history.currentRevision && $0.document == session.document
        }
        // Loading may migrate compact floats to bounded planes without an edit.
        // Do not turn that backing-only normalization into an extra Undo step.
        let visibleChanged = capturedLensWorksCanvasDocument != session.document
        if previous.content.layerGraph != nil && current != previous.content.layerGraph && !recordedCurrent && visibleChanged {
            let before = try decodedLensWorksContent(previous.content)
            let command = LensWorksDocumentCommand.replaceLayerGraph(current)
            let beforeContent = previous.content
            var afterContent = previous.content; afterContent.layerGraph = current
            let step = LensWorksHistoryStep(name: command.label, command: command, content: beforeContent, oppositeContent: afterContent,
                canvasBeforeRevision: previous.canvasRevision ?? session.history.currentRevision, canvasAfterRevision: UUID())
            document.versions[index].undo.append(step)
            document.versions[index].redo = []
            document.versions[index].content.layerGraph = current
            capturedReplacement = (step, before)
        } else { document.versions[index].content.layerGraph = current }
        document.versions[index].canvasRevision = capturedReplacement?.0.canvasAfterRevision ?? session.history.currentRevision
        let report = document.setMaxUndoSteps(document.maxUndoSteps)
        let changed = document != lensWorksDocument
        lensWorksDocumentAssets = assets; lensWorksDocumentPlanes = planes
        lensWorksDocument = document
        if let (step, before) = capturedReplacement, let beforeRevision = step.canvasBeforeRevision, let afterRevision = step.canvasAfterRevision {
            session.history.appendCaptured(id: step.id, name: step.name, before: EditorSession.canvasDocument(before),
                selection: before.manifest.activeLayerID, after: session.document, afterSelection: session.activeLayerID,
                beforeRevision: beforeRevision, afterRevision: afterRevision)
            representedCanvasStepIDs.insert(step.id)
        }
        capturedLensWorksCanvasRevision = session.history.currentRevision
        capturedLensWorksCanvasDocument = session.document
        representedCanvasStepIDs.formUnion(canvasIDs)
        session.history.entryLimit = document.maxUndoSteps
        session.history.protectedEntryIDs = pinned
        record(report)
        pruneRetainedLensWorksAssets()
        if changed { lensWorksDocumentModified = true }
    }

    func undoLensWorksVersion(_ id: UUID) throws {
        guard var document = lensWorksDocument else { throw ProjectError.invalid }
        try document.undo(id)
        try commit(document, showing: id)
    }

    func redoLensWorksVersion(_ id: UUID) throws {
        guard var document = lensWorksDocument else { throw ProjectError.invalid }
        let report = try document.redo(id)
        try commit(document, showing: id)
        record(report)
    }

    func addLensWorksCheckpoint(named name: String, to id: UUID) throws {
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ProjectError.invalid }
        guard selectedLensWorksVersionID == id else { throw LensWorksCommandRefusal(reason: "Select the version before naming a checkpoint of its canvas.") }
        guard session.canStartProjectOperation, session.canEditLayers, session.opacityEditLayerID == nil else {
            throw LensWorksCommandRefusal(reason: "Finish the current canvas edit before naming a checkpoint. Your edits and Undo history have been kept.")
        }
        try captureLensWorksComposition(in: id)
        guard var document = lensWorksDocument else { throw ProjectError.invalid }
        _ = try document.addCheckpoint(named: name, to: id)
        lensWorksDocument = document
        session.history.protectedEntryIDs = Set(document.versions.first(where: { $0.id == id })?.checkpoints.compactMap(\.pinnedStepID) ?? [])
        lensWorksDocumentModified = true
    }

    func restoreLensWorksCheckpoint(_ checkpoint: UUID, in id: UUID) throws {
        guard var document = lensWorksDocument else { throw ProjectError.invalid }
        let report = try document.restoreCheckpoint(checkpoint, in: id)
        try commit(document, showing: id)
        record(report)
    }

    func setLensWorksMaxUndoSteps(_ limit: Int) throws {
        guard limit > 0 else { throw ProjectError.invalid }
        if let id = selectedLensWorksVersionID { try captureLensWorksComposition(in: id) }
        guard var document = lensWorksDocument, limit > 0 else { throw ProjectError.invalid }
        record(document.setMaxUndoSteps(limit))
        session.history.applyLimits(entryLimit: limit,
            protected: Set(document.versions.first(where: { $0.id == selectedLensWorksVersionID })?.checkpoints.compactMap(\.pinnedStepID) ?? []), current: session.document)
        lensWorksDocument = document
        pruneRetainedLensWorksAssets()
        lensWorksDocumentModified = true
    }

    private func pruneRetainedLensWorksAssets() {
        guard let document = lensWorksDocument else { return }
        let reachable = document.reachableAssets
        lensWorksDocumentAssets = lensWorksDocumentAssets.filter { reachable.contains($0.key) }
        lensWorksDocumentPlanes = lensWorksDocumentPlanes.filter { reachable.contains($0.key) }
    }

    private func record(_ report: LensWorksPruneReport) {
        lensWorksHistoryWarning = report.warnings.isEmpty ? nil : report.warnings.joined(separator: "\n")
    }

    private func begin() -> Bool {
        guard session.canStartProjectOperation else { return false }
        session.cancelCrop()
        session.commitTransform()
        session.isProjectBusy = true
        return true
    }

    @discardableResult
    func save(asNew: Bool = false, to suppliedDestination: URL? = nil) async -> Bool {
        guard session.document != nil else { return false }
        // Another save still writing finishes first; then this one saves whatever has changed since.
        await finishWriting()
        guard begin() else { return false }
        let prepared = await prepareSave(asNew: asNew, suppliedDestination: suppliedDestination)
        // Only the snapshot (and the Save panel) holds the tools. The document is captured, so editing can go on
        // while the package is written in the background, as in Photoshop.
        session.isProjectBusy = false
        guard let prepared else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision, workingVersion: prepared.workingVersion)
    }

    /// Points the open working version at its original's current (relinked) location. Identity,
    /// photo, copy and project are unchanged; Save As and export guards use the new location.
    func relinkOriginal(path: String, native: LWCatalogNativePath?) {
        guard let version = workingVersion, version.originalPath != path || version.originalNativePath != native else { return }
        workingVersion = version.relinked(originalPath: path, native: native)
        relinkedOriginal = (version.id, path, native)
    }

    /// The save still writing, if any. Close, quit and replacing the document wait for it.
    private var writing: Task<Bool, Never>?
    func finishWriting() async { if let writing { _ = await writing.value } }

    /// Save and every export must carry historical original authority too.
    private func snapshotWithLensWorksHistory() -> ProjectSnapshot? {
        guard var snapshot = session.projectSnapshot() else { return nil }
        snapshot.lensWorksDocument = lensWorksDocument
        snapshot.lensWorksDocumentAssets = lensWorksDocumentAssets
        snapshot.lensWorksDocumentPlanes = lensWorksDocumentPlanes
        return snapshot
    }

    func exportPNG() async {
        guard session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = snapshotWithLensWorksHistory() else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.png]
        panel.canCreateDirectories = true
        panel.isExtensionHidden = false
        panel.title = "Export PNG"
        panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".png"
        let response: NSApplication.ModalResponse
        if let window { response = await panel.beginSheetModal(for: window) }
        else { response = await panel.begin() }
        guard response == .OK, let url = panel.url else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        do {
            try await ImageExporter.shared.exportPNG(snapshot, to: url, workingVersion: workingVersion)
        }
        catch { await showError("Couldn’t export PNG", error: error) }
    }

    /// Export PNG straight to `url`, for a caller that already chose the destination (an agent's granted path).
    func exportPNG(to url: URL) async throws {
        guard session.document != nil, begin() else { throw LensWorksCommandRefusal(reason: "Finish the current project operation first.") }
        defer { session.isProjectBusy = false }
        guard let snapshot = snapshotWithLensWorksHistory() else { throw ProjectError.invalid }
        try await ImageExporter.shared.exportPNG(snapshot, to: url, workingVersion: workingVersion)
    }
    /// Export JPEG straight to `url` with `options`, without the export sheet.
    func exportJPEG(to url: URL, options: JPEGOptions) async throws {
        guard session.document != nil, begin() else { throw LensWorksCommandRefusal(reason: "Finish the current project operation first.") }
        defer { session.isProjectBusy = false }
        guard let snapshot = snapshotWithLensWorksHistory() else { throw ProjectError.invalid }
        let raster = try await ImageExporter.shared.render(snapshot)
        let data = try await ImageExporter.shared.jpegFile(raster, options: options)
        try data.check()
        try await ImageExporter.shared.write(data.file, to: url, workingVersion: workingVersion)
    }

    func canvasSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: CanvasSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Canvas Size"
            sheet.contentViewController = NSHostingController(rootView: CanvasSizeSheet(document: document, session: session) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let admission=try session.captureDocumentEditAdmission()
            let resized = try await CanvasResizer.shared.resize(snapshot, to: options)
            try session.applyDocumentSize(resized,actionName:"Canvas Size",admission:admission)
        } catch { await showError("Couldn’t change canvas size", error: error) }
    }

    func imageSize() async {
        guard let window, let document = session.document, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: ImageSizeOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Image Size"
            sheet.contentViewController = NSHostingController(rootView: ImageSizeSheet(document: document) { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let admission=try session.captureDocumentEditAdmission()
            let resized = try await ImageResizer.shared.resize(snapshot, to: options)
            try session.applyDocumentSize(resized,actionName:"Image Size",admission:admission)
        } catch { await showError("Couldn’t resize the image", error: error) }
    }

    func trim() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        let options: TrimOptions? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Trim"
            sheet.contentViewController = NSHostingController(rootView: TrimSheet { options in
                window.endSheet(sheet)
                sheet.orderOut(nil)
                sheet.contentViewController = nil
                continuation.resume(returning: options)
            })
            window.beginSheet(sheet)
        }
        guard let options, let snapshot = session.projectSnapshot() else { return }
        do {
            let admission=try session.captureDocumentEditAdmission()
            guard let resized = try await ImageTrim.trim(snapshot, options: options) else {
                return
            }
            try session.applyDocumentSize(resized,actionName:"Trim",admission:admission)
        } catch { await showError("Couldn’t trim image", error: error) }
    }

    /// View > Grid Settings…: changes only how the grid is drawn and snapped to, so nothing is saved or undone. The
    /// grid shows while the sheet is open, changing as it's edited, and goes back to how it was on Cancel.
    func gridSettings() async {
        guard let window, window.attachedSheet == nil else { return }
        let original = (grid: session.layoutGrid, appearance: session.gridAppearance, shown: session.showsGrid)
        session.showsGrid = true
        let settings: (LayoutGrid, GridAppearance)? = await withCheckedContinuation { continuation in
            let sheet = NSWindow()
            sheet.styleMask = [.titled, .fullSizeContentView]
            sheet.title = "Grid"
            sheet.contentViewController = NSHostingController(rootView: GridSettingsSheet(
                session: session, grid: original.grid, appearance: original.appearance,
                preview: { [session] grid, appearance in
                    session.layoutGrid = grid
                    session.gridAppearance = appearance
                }) { settings in
                    window.endSheet(sheet)
                    sheet.orderOut(nil)
                    sheet.contentViewController = nil
                    continuation.resume(returning: settings)
                })
            window.beginSheet(sheet)
        }
        session.showsGrid = original.shown
        session.layoutGrid = settings?.0 ?? original.grid
        session.gridAppearance = settings?.1 ?? original.appearance
    }

    func exportJPEG() async {
        guard let window, session.document != nil, begin() else { return }
        defer { session.isProjectBusy = false }
        guard let snapshot = snapshotWithLensWorksHistory() else { return }
        do {
            let raster = try await ImageExporter.shared.render(snapshot)
            let data: JPEGFileResult? = await withCheckedContinuation { continuation in
                let sheet = NSWindow()
                sheet.styleMask = [.titled, .fullSizeContentView]
                sheet.title = "Export JPEG"
                sheet.contentViewController = NSHostingController(rootView: JPEGExportSheet(raster: raster, session: session) { data in
                    window.endSheet(sheet)
                    sheet.orderOut(nil)
                    // Release the hosted view and its closure after dismissal.
                    sheet.contentViewController = nil
                    continuation.resume(returning: data)
                })
                window.beginSheet(sheet)
            }
            guard let data else { return }
            try data.check()
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.jpeg]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.title = "Export JPEG"
            panel.nameFieldStringValue = (session.projectURL?.deletingPathExtension().lastPathComponent ?? "Untitled") + ".jpg"
            guard await panel.beginSheetModal(for: window) == .OK, let url = panel.url else { return }
            let scoped = url.startAccessingSecurityScopedResource()
            defer { if scoped { url.stopAccessingSecurityScopedResource() } }
            try data.check()
            try await ImageExporter.shared.write(data.file,to:url,workingVersion:workingVersion)
        } catch { await showError("Couldn’t export JPEG", error: error) }
    }

    private func saveCurrent(asNew: Bool = false) async -> Bool {
        guard session.document != nil else { return true }
        guard let prepared = await prepareSave(asNew: asNew) else { return false }
        return await write(prepared.snapshot, to: prepared.destination, revision: prepared.revision, workingVersion: prepared.workingVersion)
    }

    /// The document as it is now, and where it goes: asks with the Save panel when it has no file yet (or Save As).
    private func prepareSave(asNew: Bool, suppliedDestination: URL? = nil) async -> (snapshot: ProjectSnapshot, destination: URL, revision: UUID, workingVersion: LensWorksWorkingVersion?)? {
        // Saving is the safe bridge from session edits to the selected durable version.
        // Otherwise a subsequent (now clean) version switch would still lose saved edits.
        if let id = selectedLensWorksVersionID {
            do { try captureLensWorksComposition(in: id) }
            catch { await showError("Couldn’t capture the current version", error: error); return nil }
        }
        let revision = session.history.currentRevision
        guard let snapshot = snapshotWithLensWorksHistory() else { return nil }
        var destination = suppliedDestination ?? (asNew ? nil : session.projectURL)
        if destination == nil {
            let panel = NSSavePanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.canCreateDirectories = true
            panel.isExtensionHidden = false
            panel.nameFieldStringValue = session.projectURL?.lastPathComponent ?? "Untitled.comp"
            panel.title = asNew ? "Save Project As" : "Save Project"
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return nil }
            destination = url
        }
        guard let destination else { return nil }
        do {
            let version = try await LensWorksVersionStore.shared.versionForDestination(workingVersion, destination: destination)
            return (snapshot, destination, revision, version)
        } catch { await showError("Destination protected", error: error); return nil }
    }

    /// Writes a captured document in the background. Only that captured version counts as saved.
    private func write(_ snapshot: ProjectSnapshot, to destination: URL, revision: UUID, workingVersion savedVersion: LensWorksWorkingVersion?) async -> Bool {
        let task = Task { @MainActor [self] () -> Bool in
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            // Our own save changes the package too; the watch ignores events until the saved bytes are remembered.
            externalChanges.saving = true
            defer { externalChanges.saving = false }
            do {
                let quickLook = try await ImageExporter.shared.quickLookImages(snapshot)
                try await ProjectStore.shared.save(snapshot, to: destination, quickLook: quickLook, workingVersion: savedVersion)
                if var version = savedVersion {
                    version.projectPath = destination.path
                    workingVersion = version
                    if sharesWorkingVersions { LensWorksUserState.defaults.set(destination.path, forKey: "LensWorks.lastWorkingVersion") }
                }
                // Register before publishing the URL: the catalog lists working versions again when the project URL
                // changes, and a listing that reached the index before this registration would miss the saved version.
                var registrationError: Error?
                if savedVersion != nil, sharesWorkingVersions {
                    do { guard try await LensWorksCatalogIndex.shared.register(destination) else { throw LensWorksCatalogError.message("The saved package no longer contains its LensWorks source record.") } }
                    catch { registrationError = error }
                }
                session.projectURL = destination
                session.history.markSaved(revision)
                if lensWorksDocument == snapshot.lensWorksDocument, lensWorksDocumentAssets == snapshot.lensWorksDocumentAssets {
                    lensWorksDocumentModified = false
                }
                saveGeneration += 1
                if recordsRecentProjects { RecentProjects.shared.note(destination) }
                await rememberProjectDigest(for: destination)
                watchProject(at: destination)
                if let registrationError { await showError("The project was saved; its catalog registration needs reconciliation", error: registrationError) }
                return true
            } catch {
                await showError("Couldn’t save the project", error: error)
                return false
            }
        }
        writing = task
        let saved = await task.value
        if writing == task { writing = nil }
        return saved
    }

    @discardableResult
    func open(_ suppliedURL: URL? = nil) async -> Bool {
        if let workspace { return await workspace.open(suppliedURL) }
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        var source = suppliedURL
        if source == nil {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.compositorProject]
            panel.allowsMultipleSelection = false
            panel.canChooseDirectories = false
            panel.treatsFilePackagesAsDirectories = false
            panel.title = "Open Project"
            let response: NSApplication.ModalResponse
            if let window { response = await panel.beginSheetModal(for: window) }
            else { response = await panel.begin() }
            guard response == .OK, let url = panel.url else { return false }
            source = url
        }
        guard let source else { return false }
        // A recent project deleted in Finder: name the project, not the manifest inside it the load would miss.
        guard FileManager.default.fileExists(atPath: source.path) else {
            RecentProjects.shared.refresh()
            await showError("Couldn’t open the project", error: CocoaError(.fileNoSuchFile, userInfo: [NSFilePathErrorKey: source.path]))
            return false
        }
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }
        do {
            // Validate first. A corrupt project never discards the live document.
            var snapshot = try await ProjectStore.shared.load(from: source)
            try agentRequest?.admit(snapshot)
            let previousSave = saveGeneration
            guard await confirmReplacement() else { return false }
            // Saving in the confirmation can replace the very file being opened.
            if saveGeneration != previousSave,
               session.projectURL?.resolvingSymlinksInPath() == source.resolvingSymlinksInPath() {
                snapshot = try await ProjectStore.shared.load(from: source)
                try agentRequest?.admit(snapshot)
            }
            let installHistory = try prepareLensWorksCanvasHistory(snapshot)
            session.installProject(snapshot, from: source)
            installHistory()
            workingVersion = snapshot.workingVersion
            lensWorksDocument = snapshot.lensWorksDocument
            lensWorksDocumentAssets = snapshot.lensWorksDocumentAssets
            lensWorksDocumentPlanes = snapshot.lensWorksDocumentPlanes
            selectedLensWorksVersionID = lensWorksDocument?.selectedVersionID ?? lensWorksDocument?.versions.first?.id
            lensWorksDocumentModified = false
            lensWorksHistoryWarning = nil
            if recordsRecentProjects { RecentProjects.shared.note(source) }
            await rememberProjectDigest(for: source)
            watchProject(at: source)
            return true
        } catch {
            await showError("Couldn’t open the project", error: error)
            return false
        }
    }

    func newCanvas() async {
        if let workspace { workspace.newCanvas(); return }
        guard await closeStandaloneSourceProject() else { return }
        do { try session.resumeAfterCheckedSourceClose(); sourceCloseRequested = false; standaloneCloseConfirmed = false }
        catch { session.commandRefusal = error.localizedDescription }
    }

    func close(_ window: NSWindow) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.close(tab.id); return
        }
        guard await closeStandaloneSourceProject() else { return }
        window.close()
    }
    private func closeStandaloneSourceProject() async -> Bool {
        if !standaloneCloseConfirmed {
            guard begin() else { return false }
            let proceed = await confirmReplacement()
            session.isProjectBusy = false
            guard proceed else { return false }
            standaloneCloseConfirmed = true
        }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(30000))
        do {
            try await releaseConfirmedSourceProject(deadline: deadline)
            try session.finishConfirmedSourceRetirement(protectedOwners: [], deadline: deadline)
            try await LWSourceDeveloper.shared.drainRetainedSessions(deadline: deadline)
            return true
        } catch { session.commandRefusal = "Source Close failed; retry Close: " + error.localizedDescription; return false }
    }

    /// Only a confirmed Close may discard retained failed autosave snapshots.
    /// No new writes/watch callbacks may retain a project while source owners drain.
    func releaseConfirmedSourceProject(deadline: ContinuousClock.Instant) async throws {
        await finishWriting()
        guard writing == nil else { throw ProjectError.invalid }
        try session.beginConfirmedSourceClose()
        sourceCloseRequested = true
        stopWatchingProject()
        while externalChanges.checkTask != nil || externalChanges.checking {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else { throw LWSourceCleanupFailure(operation:nil,cleanup:"Project reload is still draining; retry Close.") }
            try await Task.sleep(for: .milliseconds(25))
        }
        try await session.releaseConfirmedSourceProject(deadline: deadline)
        capturedLensWorksCanvasDocument = nil
        capturedLensWorksCanvasRevision = nil
        workingVersion = nil
    }

    func confirmQuit() async -> Bool {
        guard begin() else { return false }
        defer { session.isProjectBusy = false }
        return await confirmReplacement()
    }

    private func confirmReplacement() async -> Bool {
        // A save still writing finishes before the project can be closed or replaced, so its file is never cut short.
        await finishWriting()
        guard (session.isModified || lensWorksDocumentModified), session.document != nil else { return true }
        let alert = NSAlert()
        alert.messageText = "Save changes to \(session.projectURL?.lastPathComponent ?? "Untitled")?"
        alert.informativeText = "Your changes will be lost if you don’t save them."
        alert.addButton(withTitle: "Save")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Don’t Save")
        let response = await show(alert)
        if response == .alertFirstButtonReturn { return await saveCurrent() }
        return response == .alertThirdButtonReturn
    }

    /// Set on the one controller an agent's file command is driving, for as long as it runs: an error there goes back
    /// to the agent instead of into an alert. Every other project's errors still reach the person.
    var agentRequest: ProjectAgentRequest?
    private func showError(_ title: String, error: Error) async {
        if let agentRequest { agentRequest.failure = agentRequest.failure ?? title + ": " + error.localizedDescription; return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: "OK")
        _ = await show(alert)
    }

    private func show(_ alert: NSAlert) async -> NSApplication.ModalResponse {
        if let window { return await alert.beginSheetModal(for: window) }
        return alert.runModal()
    }

    private struct Incoming {
        let files: [(URL, Bool)]
        let point: CGPoint?
        let completion: CheckedContinuation<Void, Never>
    }
    private var incoming: [Incoming] = []
    private var processing = false

    func receive(_ urls: [URL], at point: CGPoint? = nil) async {
        if let workspace, let tab = workspace.tabs.first(where: { $0.controller === self }) {
            await workspace.receive(urls, into: tab.id, at: point); return
        }
        guard !urls.isEmpty else { return }
        let files = urls.map { ($0, $0.startAccessingSecurityScopedResource()) }
        await withCheckedContinuation { completion in
            incoming.append(Incoming(files: files, point: point, completion: completion))
            if !processing {
                processing = true
                Task { await drainIncoming() }
            }
        }
    }

    private func drainIncoming() async {
        while !incoming.isEmpty {
            let request = incoming.removeFirst()
            await session.waitForFileRequest()
            let urls = request.files.map(\.0)
            let projects = urls.filter { $0.pathExtension.lowercased() == "comp" }
            if projects.count > 1 {
                await showError("Open one project at a time", error: ProjectError.invalid)
            } else {
                var proceed = true
                if let project = projects.first { proceed = await open(project) }
                if proceed {
                    await session.importImages(urls.filter { $0.pathExtension.lowercased() != "comp" },
                                               at: projects.isEmpty ? request.point : nil)
                }
            }
            for (url, scoped) in request.files where scoped { url.stopAccessingSecurityScopedResource() }
            request.completion.resume()
        }
        processing = false
    }
}

/// What an agent's file command supplies in place of the person on the controller it drives: where a failure goes
/// instead of an alert, and a check on a project that was read before it is installed.
@MainActor final class ProjectAgentRequest {
    var failure: String?
    var admit: (ProjectSnapshot) throws -> Void = { _ in }
}
