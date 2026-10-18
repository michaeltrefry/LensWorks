import CryptoKit
import Foundation
import SQLite3
import Darwin

// Rebuildable semantic search index: image embeddings of catalog previews and paired text-query
// embeddings in one shared space. The index file holds only derived vectors; deleting it, changing
// the model or source recipe, or an interrupted rebuild never touches originals, previews or any
// catalog/document record. Entries are keyed by photo and carry the source stamp (revision + recipe
// digest) they were computed from, so a changed photo is re-embedded and a removed one is pruned.

/// Embeds images and text queries. Both sides must report the same space and dimension.
nonisolated protocol LWSemanticEmbedder: Sendable {
    func embedImages(_ images: [LWInferenceImage]) async throws -> LWSemanticVectors
    func embedTexts(_ texts: [String]) async throws -> LWSemanticVectors
}

nonisolated struct LWSemanticVectors: Sendable, Equatable {
    let space: String
    let dimension: Int
    let vectors: [[Float]]
}

nonisolated enum LWSemanticError: Error, Equatable, CustomStringConvertible {
    case spaceMismatch(image: String, text: String)
    case dimensionMismatch(expected: Int, found: Int)
    case invalidVector(String)
    case embedder(String)
    case storage(String)

    var description: String {
        switch self {
        case .spaceMismatch(let image, let text): "Image embeddings are in space “\(image)” but text queries are in “\(text)”; they cannot be compared."
        case .dimensionMismatch(let expected, let found): "Expected \(expected)-dimensional embeddings, found \(found)."
        case .invalidVector(let detail): "Embedding rejected: \(detail)"
        case .embedder(let detail): detail
        case .storage(let detail): "The semantic index could not be used: \(detail)"
        }
    }
}

/// Everything an entry's validity depends on besides the photo itself. A different value means a
/// different index: stored vectors are discarded and rebuilt incrementally.
nonisolated struct LWSemanticIndexVersion: Sendable, Equatable, Codable {
    let imageProvider: String
    let textProvider: String
    let space: String
    let dimension: Int
    /// Pinned model assets, for example `openai/clip-vit-large-patch14@<revision>`.
    let assets: [String]
    /// What pixels are embedded, for example `catalog-preview-thumbnail-512`.
    let source: String
    /// Preprocessing and normalization recipe.
    let recipe: String

    var key: String {
        let canonical = [imageProvider, textProvider, space, String(dimension), assets.sorted().joined(separator: ","), source, recipe].joined(separator: "\n")
        return SHA256.hash(data: Data(canonical.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

/// One photo to index. `stamp` identifies its current source state (revision and recipe digest).
nonisolated struct LWSemanticCandidate: Sendable {
    let id: String
    let stamp: String
    /// Loads the pixels to embed; throws when they are unavailable (for example no retained preview).
    let image: @Sendable () async throws -> LWInferenceImage
}

nonisolated struct LWSemanticSyncReport: Sendable, Equatable {
    var embedded = 0
    var upToDate = 0
    var unavailable: [String] = []
    /// Candidates left unprocessed because the run hit its bound or was cancelled.
    var remaining = 0
    var cancelled = false
}

nonisolated struct LWSemanticMatch: Sendable, Equatable {
    let id: String
    let score: Float
}

actor LensWorksSemanticIndex {
    static let batchSize = 8
    static let maximumResults = 500
    static let maximumQueryBytes = 4096

    private let url: URL
    private var database: OpaquePointer?
    private var version: LWSemanticIndexVersion?
    /// Bumped for invalidation and newer pending source observations, even without a stored row.
    /// A sync suspended across such a change must not write vectors from the superseded state.
    private var generation = 0
    private let applicationID: Int32 = 0x4c575349

    init(url: URL) { self.url = url }
    deinit { if let database { sqlite3_close_v2(database) } }

    // MARK: Storage

    private func failure() -> LWSemanticError {
        .storage(database.map { String(cString: sqlite3_errmsg($0)) } ?? "it could not be opened")
    }

    private func execute(_ sql: String) throws {
        try open()
        guard sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else { throw failure() }
    }

    private func statement<R>(_ sql: String, _ bind: (OpaquePointer) -> Void = { _ in }, body: (OpaquePointer) throws -> R) throws -> R {
        try open()
        var pointer: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &pointer, nil) == SQLITE_OK, let pointer else { throw failure() }
        defer { sqlite3_finalize(pointer) }
        bind(pointer)
        return try body(pointer)
    }

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
    private static func text(_ s: OpaquePointer, _ i: Int32, _ value: String) { sqlite3_bind_text(s, i, value, -1, transient) }

    /// Opens the file, replacing it when it is unreadable or not an index of ours: it is derived
    /// data only, so rebuilding is always safe. Other files are never deleted.
    private func open() throws {
        guard database == nil else { return }
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !tryOpen() {
            discardFiles()
            guard tryOpen() else { throw failure() }
        }
    }

    private func tryOpen() -> Bool {
        var pointer: OpaquePointer?
        guard sqlite3_open_v2(url.path, &pointer, SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let pointer else {
            if let pointer { sqlite3_close_v2(pointer) }
            return false
        }
        sqlite3_busy_timeout(pointer, 3000)
        var identity: Int32 = 0
        var check: OpaquePointer?
        if sqlite3_prepare_v2(pointer, "PRAGMA application_id", -1, &check, nil) == SQLITE_OK, sqlite3_step(check) == SQLITE_ROW {
            identity = sqlite3_column_int(check, 0)
        } else { sqlite3_finalize(check); sqlite3_close_v2(pointer); return false }
        sqlite3_finalize(check)
        var empty = false
        var tables: OpaquePointer?
        if sqlite3_prepare_v2(pointer, "SELECT COUNT(*) FROM sqlite_master", -1, &tables, nil) == SQLITE_OK, sqlite3_step(tables) == SQLITE_ROW {
            empty = sqlite3_column_int(tables, 0) == 0
        } else { sqlite3_finalize(tables); sqlite3_close_v2(pointer); return false }
        sqlite3_finalize(tables)
        guard identity == applicationID || (identity == 0 && empty) else { sqlite3_close_v2(pointer); return false }
        let schema = "PRAGMA application_id=\(applicationID); PRAGMA journal_mode=WAL; CREATE TABLE IF NOT EXISTS meta(id INTEGER PRIMARY KEY CHECK(id=1),version TEXT NOT NULL,description BLOB NOT NULL); CREATE TABLE IF NOT EXISTS entries(photo TEXT PRIMARY KEY,stamp TEXT NOT NULL,vector BLOB NOT NULL);"
        guard sqlite3_exec(pointer, schema, nil, nil, nil) == SQLITE_OK else { sqlite3_close_v2(pointer); return false }
        database = pointer
        return true
    }

    /// Removes only this index's own files.
    private func discardFiles() {
        if let database { sqlite3_close_v2(database); self.database = nil }
        for suffix in ["", "-wal", "-shm", "-journal"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
    }

    // MARK: Versioning

    /// Binds the index to `version`. A different stored version invalidates every entry.
    /// Returns whether existing entries were discarded.
    @discardableResult
    func adopt(_ newVersion: LWSemanticIndexVersion) throws -> Bool {
        let stored = try statement("SELECT version FROM meta WHERE id=1") { s -> String? in
            sqlite3_step(s) == SQLITE_ROW ? String(cString: sqlite3_column_text(s, 0)) : nil
        }
        self.version = newVersion
        if stored == newVersion.key { return false }
        generation &+= 1
        let description = try JSONEncoder().encode(newVersion)
        try execute("BEGIN IMMEDIATE")
        do {
            try execute("DELETE FROM entries")
            try statement("INSERT OR REPLACE INTO meta(id,version,description) VALUES(1,?,?)", { s in
                Self.text(s, 1, newVersion.key)
                _ = description.withUnsafeBytes { sqlite3_bind_blob(s, 2, $0.baseAddress, Int32($0.count), Self.transient) }
            }) { s in guard sqlite3_step(s) == SQLITE_DONE else { throw failure() } }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
        return stored != nil
    }

    var currentVersion: LWSemanticIndexVersion? { version }

    func count() throws -> Int {
        try statement("SELECT COUNT(*) FROM entries") { s in sqlite3_step(s) == SQLITE_ROW ? Int(sqlite3_column_int64(s, 0)) : 0 }
    }

    /// Deletes every vector (user-initiated reset). Originals and catalog records are untouched.
    func reset() throws {
        generation &+= 1
        try execute("DELETE FROM entries")
    }

    /// Deletes the index file entirely; the next `adopt` recreates it.
    func deleteIndexFiles() {
        generation &+= 1
        discardFiles()
        version = nil
    }

    // MARK: Incremental build

    /// Embeds candidates whose stored stamp differs, at most `limit` per call, in bounded batches
    /// committed one at a time: cancelling or crashing between batches loses only the batch in
    /// flight, and the next call resumes from what was committed.
    func sync(_ candidates: [LWSemanticCandidate], limit: Int = 256, embedder: any LWSemanticEmbedder,
              progress: @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> LWSemanticSyncReport {
        guard let version else { throw LWSemanticError.storage("no index version has been adopted") }
        var report = LWSemanticSyncReport()
        var pending: [LWSemanticCandidate] = []
        var stale: [String] = []
        for candidate in candidates {
            let stored = try storedStamp(candidate.id)
            if stored == candidate.stamp { report.upToDate += 1 } else {
                pending.append(candidate)
                if stored != nil { stale.append(candidate.id) }
            }
        }
        // Validity is independent of the replacement budget and preview availability. Commit
        // invalidation before the first suspension so search never ranks an obsolete vector,
        // including after cancellation, a failed embedding, or reopening a partial rebuild.
        if !pending.isEmpty { generation &+= 1 }
        try remove(stale)
        let epoch = generation
        let budget = max(0, limit)
        if pending.count > budget { report.remaining = pending.count - budget; pending = Array(pending.prefix(budget)) }
        let total = pending.count
        var index = 0
        while index < pending.count {
            if Task.isCancelled { report.cancelled = true; report.remaining += pending.count - index; break }
            let slice = Array(pending[index..<min(pending.count, index + Self.batchSize)])
            index += slice.count
            var loaded: [(LWSemanticCandidate, LWInferenceImage)] = []
            for candidate in slice {
                do { loaded.append((candidate, try await candidate.image())) }
                catch is CancellationError { report.cancelled = true; break }
                catch { report.unavailable.append(candidate.id) }
                if Task.isCancelled { report.cancelled = true; break }
            }
            // None of this slice has committed, including the successfully loaded images.
            if report.cancelled { report.remaining += pending.count - index + slice.count; break }
            guard !loaded.isEmpty else { continue }
            let vectors: LWSemanticVectors
            do { vectors = try await embedder.embedImages(loaded.map(\.1)) }
            catch is CancellationError { report.cancelled = true; report.remaining += pending.count - index + loaded.count; break }
            // Both awaits are behind us and nothing below suspends: if the index was adopted anew,
            // reset or deleted meanwhile, these vectors belong to the old state and are dropped.
            guard !Task.isCancelled, generation == epoch else { report.cancelled = true; report.remaining += pending.count - index + loaded.count; break }
            try validate(vectors, count: loaded.count, against: version)
            try execute("BEGIN IMMEDIATE")
            do {
                for (entry, vector) in zip(loaded, vectors.vectors) {
                    let blob = Self.encode(Self.normalized(vector))
                    try statement("INSERT OR REPLACE INTO entries(photo,stamp,vector) VALUES(?,?,?)", { s in
                        Self.text(s, 1, entry.0.id); Self.text(s, 2, entry.0.stamp)
                        _ = blob.withUnsafeBytes { sqlite3_bind_blob(s, 3, $0.baseAddress, Int32($0.count), Self.transient) }
                    }) { s in guard sqlite3_step(s) == SQLITE_DONE else { throw failure() } }
                }
                try execute("COMMIT")
            } catch { try? execute("ROLLBACK"); throw error }
            report.embedded += loaded.count
            progress(report.embedded, total)
        }
        return report
    }

    /// Drops entries for photos no longer in the catalog (`keeping` is the complete live id set).
    @discardableResult
    func prune(keeping live: Set<String>) throws -> Int {
        // Also supersede batches with no committed row yet; an authoritative catalog snapshot
        // must not let a suspended sync insert a photo that has since left the catalog.
        generation &+= 1
        let stored = try statement("SELECT photo FROM entries") { s -> [String] in
            var ids: [String] = []
            while sqlite3_step(s) == SQLITE_ROW { ids.append(String(cString: sqlite3_column_text(s, 0))) }
            return ids
        }
        let stale = stored.filter { !live.contains($0) }
        try remove(stale)
        return stale.count
    }

    /// Invalidates entries immediately (for example a photo's edit or removal).
    func remove(_ ids: [String]) throws {
        guard !ids.isEmpty else { return }
        generation &+= 1
        try execute("BEGIN IMMEDIATE")
        do {
            for id in ids {
                try statement("DELETE FROM entries WHERE photo=?", { Self.text($0, 1, id) }) { s in guard sqlite3_step(s) == SQLITE_DONE else { throw failure() } }
            }
            try execute("COMMIT")
        } catch { try? execute("ROLLBACK"); throw error }
    }

    private func storedStamp(_ id: String) throws -> String? {
        try statement("SELECT stamp FROM entries WHERE photo=?", { Self.text($0, 1, id) }) { s in
            sqlite3_step(s) == SQLITE_ROW ? String(cString: sqlite3_column_text(s, 0)) : nil
        }
    }

    private func validate(_ vectors: LWSemanticVectors, count: Int, against version: LWSemanticIndexVersion) throws {
        guard vectors.space == version.space else { throw LWSemanticError.spaceMismatch(image: vectors.space, text: version.space) }
        guard vectors.dimension == version.dimension else { throw LWSemanticError.dimensionMismatch(expected: version.dimension, found: vectors.dimension) }
        guard vectors.vectors.count == count else { throw LWSemanticError.invalidVector("\(vectors.vectors.count) vectors for \(count) inputs") }
        for vector in vectors.vectors {
            guard vector.count == version.dimension else { throw LWSemanticError.dimensionMismatch(expected: version.dimension, found: vector.count) }
            guard vector.allSatisfy(\.isFinite), vector.contains(where: { $0 != 0 }) else { throw LWSemanticError.invalidVector("non-finite or zero vector") }
        }
    }

    // MARK: Search

    /// Ranks indexed photos against a text query. `within` restricts results to the photos that
    /// pass the active catalog filters (nil = no restriction); photos without an entry are simply
    /// not ranked, so filters, offline state and partial indexes combine without special cases.
    func search(_ query: String, within: Set<String>? = nil, limit: Int = 50, embedder: any LWSemanticEmbedder) async throws -> [LWSemanticMatch] {
        guard let version else { throw LWSemanticError.storage("no index version has been adopted") }
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= Self.maximumQueryBytes else { return [] }
        let epoch = generation
        let embedded = try await embedder.embedTexts([trimmed])
        guard generation == epoch else { throw CancellationError() }
        try validate(embedded, count: 1, against: version)
        return try rank(Self.normalized(embedded.vectors[0]), within: within, limit: limit)
    }

    func rank(_ query: [Float], within: Set<String>?, limit: Int) throws -> [LWSemanticMatch] {
        let cap = min(max(0, limit), Self.maximumResults)
        guard cap > 0 else { return [] }
        let dimension = query.count
        var top: [LWSemanticMatch] = []
        try statement("SELECT photo,vector FROM entries") { s in
            while sqlite3_step(s) == SQLITE_ROW {
                if Task.isCancelled { throw CancellationError() }
                let id = String(cString: sqlite3_column_text(s, 0))
                if let within, !within.contains(id) { continue }
                guard Int(sqlite3_column_bytes(s, 1)) == dimension * MemoryLayout<Float>.size, let raw = sqlite3_column_blob(s, 1) else { continue }
                let vector = raw.bindMemory(to: Float.self, capacity: dimension)
                var score: Float = 0
                for i in 0..<dimension { score += vector[i] * query[i] }
                if top.count < cap || score > top[top.count - 1].score {
                    let match = LWSemanticMatch(id: id, score: score)
                    let at = top.firstIndex { $0.score < score || ($0.score == score && $0.id > id) } ?? top.count
                    top.insert(match, at: at)
                    if top.count > cap { top.removeLast() }
                }
            }
        }
        return top
    }

    // MARK: Vectors

    static func normalized(_ vector: [Float]) -> [Float] {
        let norm = vector.reduce(Float(0)) { $0 + $1 * $1 }.squareRoot()
        return norm > 0 ? vector.map { $0 / norm } : vector
    }

    private static func encode(_ vector: [Float]) -> Data {
        vector.withUnsafeBufferPointer { Data(buffer: $0) }
    }
}

// MARK: - Production embedder

/// Embeds through admitted model-store jobs. Image and text providers must share one space; the
/// space reported with each result is checked by the index against its version.
nonisolated struct LWModelStoreEmbedder: LWSemanticEmbedder {
    /// Starts an admitted job on the model: (model id, pixels, inputs, request builder).
    typealias Start = @Sendable (String, Int?, [LWInferenceImage], @escaping @Sendable (LWModelLease) -> LWInferenceRequest) async throws -> LWModelJob
    static let defaultModelID = "clip_vit_l14"
    static let defaultImageProvider = "clip_vit_l14"
    static let defaultTextProvider = "clip_vit_l14_text"

    let start: Start
    var modelID = defaultModelID
    var imageProvider = defaultImageProvider
    var textProvider = defaultTextProvider

    init(store: LWModelStore, runtime: any LWInferenceJobStarting) {
        start = { id, pixels, inputs, request in try await store.runJob(id, pixels: pixels, inputs: inputs, runtime: runtime, request: request) }
    }

    init(start: @escaping Start) { self.start = start }

    /// The application's embedder: jobs run through the shared AI Models center, so admission,
    /// licence acknowledgement and memory leases apply and nothing is downloaded on its own.
    static var application: LWModelStoreEmbedder {
        LWModelStoreEmbedder { id, pixels, inputs, request in
            try await LWModelCenter.shared.runJob(id, pixels: pixels, inputs: inputs, request: request)
        }
    }

    func embedImages(_ images: [LWInferenceImage]) async throws -> LWSemanticVectors {
        let pixels = images.map { $0.width * $0.height }.max()
        let provider = imageProvider
        return try await run(pixels: pixels, inputs: images) { lease in
            .embedImage(provider: provider, weights: lease.weights, LWEmbedImageParams(inputs: Array(images.indices)))
        }
    }

    func embedTexts(_ texts: [String]) async throws -> LWSemanticVectors {
        let provider = textProvider
        return try await run(pixels: nil, inputs: []) { lease in
            .embedText(provider: provider, weights: lease.weights, LWEmbedTextParams(texts: texts))
        }
    }

    private func run(pixels: Int?, inputs: [LWInferenceImage], request: @escaping @Sendable (LWModelLease) -> LWInferenceRequest) async throws -> LWSemanticVectors {
        let job = try await start(modelID, pixels, inputs, request)
        return try await LWSemanticJob.vectors(events: job.events, cancel: job.cancel)
    }
}

nonisolated enum LWSemanticJob {
    /// Reads one embedding job to its terminal event; cancelling the task cancels the job.
    static func vectors(events: AsyncStream<LWInferenceEvent>, cancel: @escaping @Sendable () -> Void) async throws -> LWSemanticVectors {
        try await withTaskCancellationHandler {
            for await event in events {
                switch event {
                case .completed(let result):
                    guard let vectors = result.embeddings, let dimension = result.embeddingDim, let space = result.space else {
                        throw LWSemanticError.embedder("The embedding job returned no vectors.")
                    }
                    return LWSemanticVectors(space: space, dimension: dimension, vectors: vectors)
                case .failed(let failure): throw LWSemanticError.embedder(failure.message)
                case .cancelled: throw CancellationError()
                default: continue
                }
            }
            throw Task.isCancelled ? CancellationError() : LWSemanticError.embedder("The embedding job ended without a result.")
        } onCancel: { cancel() }
    }
}
