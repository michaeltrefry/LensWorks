import Foundation

/// A reference to another catalog source revision. This is deliberately a LensWorks record rather than a
/// PhotoCatalog recipe so document versions can retain their source dependency independently.
nonisolated struct LensWorksSourceReference: Codable, Sendable, Equatable, Hashable {
    var photoID: String
    var revision: String? = nil
    var assetID: String? = nil

    init(photoID: String, revision: String? = nil, assetID: String? = nil) {
        self.photoID = photoID
        self.revision = revision
        self.assetID = assetID
    }

    init(legacyValue: String) {
        let parts = legacyValue.split(separator: "@", maxSplits: 1).map(String.init)
        self.init(photoID: parts[0], revision: parts.count == 2 ? parts[1] : nil)
    }
}

/// The complete native layer graph of one LensWorks version. `ProjectLayerRecord` already owns the
/// Codable representation for transforms, groups, masks, adjustments, effects, text and live RAW sources.
nonisolated struct LensWorksLayerGraph: Codable, Sendable, Equatable {
    var layers: [ProjectLayerRecord] = []

    var assetIDs: Set<String> {
        Set(layers.flatMap { [$0.imageFile, $0.maskFile, $0.liveSourceFile].compactMap { $0 } })
    }

    static func == (lhs: Self, rhs: Self) -> Bool {
        // ProjectLayerRecord intentionally has no Equatable conformance because its runtime graph has
        // ownership-only state. Its persisted representation is the document contract.
        (try? JSONEncoder().encode(lhs)) == (try? JSONEncoder().encode(rhs))
    }
}

/// What one photo version holds: legacy scalar values, the native layer/RAW graph and source references.
/// It is LensWorks' own versioned record, separate from PhotoCatalog's strict recipe schema.
nonisolated struct LensWorksVersionContent: Codable, Sendable, Equatable {
    struct Layer: Codable, Sendable, Equatable, Identifiable {
        var id: UUID
        var name: String
        /// Pixel data lives in a document asset; nil for adjustment-style layers.
        var assetID: String?
    }
    /// Kept to read schema 1/2 documents. Schema 3 graph commands use typed `liveSource` records instead.
    var rawSettings: [String: Double] = [:]
    /// Kept to read schema 1/2 documents. New documents store their complete graph in `layerGraph`.
    var layers: [Layer] = []
    var layerGraph: LensWorksLayerGraph? = nil
    var sourceReferences: [LensWorksSourceReference] = []

    var assetIDs: Set<String> {
        var ids = Set(layers.compactMap(\.assetID))
        if let layerGraph { ids.formUnion(layerGraph.assetIDs) }
        ids.formUnion(sourceReferences.compactMap(\.assetID))
        return ids
    }

    private enum Keys: String, CodingKey { case rawSettings, layers, layerGraph, sourceReferences }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        rawSettings = try c.decodeIfPresent([String: Double].self, forKey: .rawSettings) ?? [:]
        layers = try c.decodeIfPresent([Layer].self, forKey: .layers) ?? []
        layerGraph = try c.decodeIfPresent(LensWorksLayerGraph.self, forKey: .layerGraph)
        if let references = try? c.decode([LensWorksSourceReference].self, forKey: .sourceReferences) {
            sourceReferences = references
        } else {
            sourceReferences = try c.decodeIfPresent([String].self, forKey: .sourceReferences)?.map(LensWorksSourceReference.init(legacyValue:)) ?? []
        }
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(rawSettings, forKey: .rawSettings)
        try c.encode(layers, forKey: .layers)
        try c.encodeIfPresent(layerGraph, forKey: .layerGraph)
        try c.encode(sourceReferences, forKey: .sourceReferences)
    }
}

/// Every supported document edit. Commands are Codable so schema upgrades can roundtrip them.
nonisolated enum LensWorksDocumentCommand: Codable, Sendable, Equatable {
    case setRaw(key: String, value: Double)
    case addLayer(LensWorksVersionContent.Layer)
    case removeLayer(UUID)
    case addSourceReference(String)
    case addSourceReferenceRecord(LensWorksSourceReference)
    /// Atomically replaces the native graph, including groups, masks, transforms and live RAW nodes.
    case replaceLayerGraph(LensWorksLayerGraph)
    /// Replaces a live RAW node without reducing it to a scalar recipe.
    case replaceLiveSource(layerID: UUID, source: LWLiveSourceNode?)

    var label: String {
        switch self {
        case .setRaw(let key, _): "Set \(key)"
        case .addLayer(let layer): "Add Layer “\(layer.name)”"
        case .removeLayer: "Delete Layer"
        case .addSourceReference, .addSourceReferenceRecord: "Add Source Reference"
        case .replaceLayerGraph: "Update Layer Graph"
        case .replaceLiveSource: "Update Live RAW"
        }
    }

    func apply(to content: inout LensWorksVersionContent) throws {
        switch self {
        case .setRaw(let key, let value): content.rawSettings[key] = value
        case .addLayer(let layer):
            guard !content.layers.contains(where: { $0.id == layer.id }) else { throw LensWorksDocumentError.duplicateLayer }
            content.layers.append(layer)
        case .removeLayer(let id):
            guard content.layers.contains(where: { $0.id == id }) else { throw LensWorksDocumentError.missingLayer }
            content.layers.removeAll { $0.id == id }
        case .addSourceReference(let reference):
            let record = LensWorksSourceReference(legacyValue: reference)
            if !content.sourceReferences.contains(record) { content.sourceReferences.append(record) }
        case .addSourceReferenceRecord(let reference):
            if !content.sourceReferences.contains(reference) { content.sourceReferences.append(reference) }
        case .replaceLayerGraph(let graph): content.layerGraph = graph
        case .replaceLiveSource(let layerID, let source):
            guard var graph = content.layerGraph, let index = graph.layers.firstIndex(where: { $0.id == layerID }) else {
                throw LensWorksDocumentError.missingLayer
            }
            graph.layers[index].liveSource = source
            graph.layers[index].liveSourceFile = nil
            content.layerGraph = graph
        }
    }
}

nonisolated enum LensWorksDocumentError: Error, Equatable {
    case duplicateLayer, missingLayer, unknownVersion, unknownCheckpoint, unsupportedSchema(Int), nothingToUndo, nothingToRedo
}

nonisolated struct LensWorksHistoryStep: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var command: LensWorksDocumentCommand?
    /// The content the step restores when it is undone (or redone).
    var content: LensWorksVersionContent
    var attributedToAgent = false
}

nonisolated struct LensWorksCheckpoint: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var content: LensWorksVersionContent
    /// The undo step that was on top when the checkpoint was named; it is kept while the checkpoint exists.
    var pinnedStepID: UUID?
}

nonisolated struct LensWorksPhotoVersion: Codable, Sendable, Equatable, Identifiable {
    var id = UUID()
    var name: String
    var content = LensWorksVersionContent()
    var undo: [LensWorksHistoryStep] = []
    var redo: [LensWorksHistoryStep] = []
    var checkpoints: [LensWorksCheckpoint] = []

    /// Assets that current content, checkpoints and the retained undo/redo steps still need.
    var reachableAssets: Set<String> {
        var assets = content.assetIDs
        for step in undo + redo { assets.formUnion(step.content.assetIDs) }
        for checkpoint in checkpoints { assets.formUnion(checkpoint.content.assetIDs) }
        return assets
    }
}

nonisolated struct LensWorksPruneReport: Sendable, Equatable {
    var prunedSteps = 0
    /// Protected steps that keep a version over the limit; the person is told rather than data being deleted.
    var warnings: [String] = []
}

/// A catalog photo's versioned document. Versions never share mutable state: duplication copies values.
nonisolated struct LensWorksPhotoDocument: Codable, Sendable, Equatable {
    static let currentSchema = 2
    var schema = LensWorksPhotoDocument.currentSchema
    var photoID: String
    var versions: [LensWorksPhotoVersion] = []
    /// Configurable bound on undo steps kept per version.
    var maxUndoSteps = 100

    init(photoID: String, maxUndoSteps: Int = 100) {
        self.photoID = photoID
        self.maxUndoSteps = max(1, maxUndoSteps)
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let schema = try c.decodeIfPresent(Int.self, forKey: .schema) ?? 1
        guard (1...Self.currentSchema).contains(schema) else { throw LensWorksDocumentError.unsupportedSchema(schema) }
        photoID = try c.decode(String.self, forKey: .photoID)
        versions = try c.decode([LensWorksPhotoVersion].self, forKey: .versions)
        // Schema 1 predates the configurable limit.
        maxUndoSteps = max(1, try c.decodeIfPresent(Int.self, forKey: .maxUndoSteps) ?? 100)
        self.schema = Self.currentSchema
    }

    private enum Keys: String, CodingKey { case schema, photoID, versions, maxUndoSteps }

    private func index(_ id: UUID) throws -> Int {
        guard let i = versions.firstIndex(where: { $0.id == id }) else { throw LensWorksDocumentError.unknownVersion }
        return i
    }

    @discardableResult
    mutating func addVersion(named name: String) -> UUID {
        let version = LensWorksPhotoVersion(name: name)
        versions.append(version)
        return version.id
    }

    /// A new version with the same content and checkpoints but its own identity and history.
    mutating func duplicateVersion(_ id: UUID, named name: String) throws -> UUID {
        var copy = versions[try index(id)]
        copy.id = UUID()
        copy.name = name
        copy.undo = []
        copy.redo = []
        copy.checkpoints = copy.checkpoints.map { var c = $0; c.id = UUID(); c.pinnedStepID = nil; return c }
        versions.append(copy)
        return copy.id
    }

    @discardableResult
    mutating func perform(_ command: LensWorksDocumentCommand, on id: UUID, agent: Bool = false) throws -> LensWorksPruneReport {
        let i = try index(id)
        var next = versions[i].content
        try command.apply(to: &next)
        versions[i].undo.append(LensWorksHistoryStep(name: command.label, command: command, content: versions[i].content, attributedToAgent: agent))
        versions[i].content = next
        versions[i].redo = []
        return prune(i)
    }

    mutating func undo(_ id: UUID) throws {
        let i = try index(id)
        guard let step = versions[i].undo.popLast() else { throw LensWorksDocumentError.nothingToUndo }
        versions[i].redo.append(LensWorksHistoryStep(id: step.id, name: step.name, command: step.command, content: versions[i].content, attributedToAgent: step.attributedToAgent))
        versions[i].content = step.content
    }

    /// Returns pruning warnings because redoing can grow the retained undo stack after its limit changed.
    @discardableResult
    mutating func redo(_ id: UUID) throws -> LensWorksPruneReport {
        let i = try index(id)
        guard let step = versions[i].redo.popLast() else { throw LensWorksDocumentError.nothingToRedo }
        versions[i].undo.append(LensWorksHistoryStep(id: step.id, name: step.name, command: step.command, content: versions[i].content, attributedToAgent: step.attributedToAgent))
        versions[i].content = step.content
        return prune(i)
    }

    @discardableResult
    mutating func addCheckpoint(named name: String, to id: UUID) throws -> UUID {
        let i = try index(id)
        let checkpoint = LensWorksCheckpoint(name: name, content: versions[i].content, pinnedStepID: versions[i].undo.last?.id)
        versions[i].checkpoints.append(checkpoint)
        return checkpoint.id
    }

    /// Restoring is itself an undoable step.
    @discardableResult
    mutating func restoreCheckpoint(_ checkpoint: UUID, in id: UUID) throws -> LensWorksPruneReport {
        let i = try index(id)
        guard let saved = versions[i].checkpoints.first(where: { $0.id == checkpoint }) else { throw LensWorksDocumentError.unknownCheckpoint }
        versions[i].undo.append(LensWorksHistoryStep(name: "Restore “\(saved.name)”", command: nil, content: versions[i].content))
        versions[i].content = saved.content
        versions[i].redo = []
        return prune(i)
    }

    mutating func setMaxUndoSteps(_ limit: Int) -> LensWorksPruneReport {
        maxUndoSteps = max(1, limit)
        var report = LensWorksPruneReport()
        for i in versions.indices {
            let r = prune(i)
            report.prunedSteps += r.prunedSteps
            report.warnings += r.warnings
        }
        return report
    }

    /// Drops the oldest undo steps that no checkpoint pins until the limit is met.
    @discardableResult
    private mutating func prune(_ i: Int) -> LensWorksPruneReport {
        var report = LensWorksPruneReport()
        let pinned = Set(versions[i].checkpoints.compactMap(\.pinnedStepID))
        while versions[i].undo.count > maxUndoSteps,
              let victim = versions[i].undo.firstIndex(where: { !pinned.contains($0.id) }) {
            versions[i].undo.remove(at: victim)
            report.prunedSteps += 1
        }
        if versions[i].undo.count > maxUndoSteps {
            report.warnings.append("“\(versions[i].name)” keeps \(versions[i].undo.count) undo steps, above the limit of \(maxUndoSteps), because named checkpoints protect them.")
        }
        return report
    }

    /// Assets that must be retained: everything any version, step or checkpoint can still reach.
    var reachableAssets: Set<String> { versions.reduce(into: Set<String>()) { $0.formUnion($1.reachableAssets) } }
}

/// Persists a document and its assets in a package directory (`document.json`, `assets/<id>`).
nonisolated struct LensWorksDocumentStore: Sendable {
    let directory: URL
    var documentURL: URL { directory.appendingPathComponent("document.json") }
    var assetsURL: URL { directory.appendingPathComponent("assets", isDirectory: true) }

    func save(_ document: LensWorksPhotoDocument) throws {
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(document).write(to: documentURL, options: .atomic)
    }

    func load() throws -> LensWorksPhotoDocument {
        try JSONDecoder().decode(LensWorksPhotoDocument.self, from: Data(contentsOf: documentURL))
    }

    func writeAsset(_ id: String, data: Data) throws {
        guard Self.isValidAssetID(id) else { throw ProjectError.invalid }
        try FileManager.default.createDirectory(at: assetsURL, withIntermediateDirectories: true)
        try data.write(to: assetsURL.appendingPathComponent(id), options: .atomic)
    }

    func storedAssets() -> Set<String> {
        Set((try? FileManager.default.contentsOfDirectory(atPath: assetsURL.path)) ?? []).filter(Self.isValidAssetID)
    }

    static func isValidAssetID(_ id: String) -> Bool {
        !id.isEmpty && id.utf8.count <= 255 && !id.contains("/") && !id.contains("\\") && !id.contains("\0") && id != "." && id != ".."
    }

    /// Deletes stored assets no version, step or checkpoint can reach; returns the removed IDs.
    @discardableResult
    func collectUnreachableAssets(for document: LensWorksPhotoDocument) throws -> Set<String> {
        let doomed = storedAssets().subtracting(document.reachableAssets)
        for id in doomed { try FileManager.default.removeItem(at: assetsURL.appendingPathComponent(id)) }
        return doomed
    }
}
