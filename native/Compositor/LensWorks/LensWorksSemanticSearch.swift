import CryptoKit
import Foundation
import Observation

// Semantic (natural-language) search over a catalog. Image embeddings are computed from the
// catalog's stored previews, never from originals, so indexing and search work while originals
// are offline. The embedding model is leased through the model store, which never downloads on
// its own: without an installed, admitted model the feature says so and does nothing.

// MARK: - Embedding model

/// Why semantic search cannot embed right now, in words the search bar shows.
nonisolated enum LensWorksSemanticUnavailable: Error, Sendable, Equatable, LocalizedError {
    /// The model is not on this Mac; an explicit download in AI Models fixes it.
    case modelNotInstalled(String)
    /// The model's licence terms have not been accepted.
    case licenseRequired(String)
    /// The model, runtime or library cannot be used, and why.
    case modelUnavailable(String)
    var message: String {
        switch self { case .modelNotInstalled(let text), .licenseRequired(let text), .modelUnavailable(let text): text }
    }
    var errorDescription: String? { message }
}

nonisolated struct LensWorksSemanticModel: Sendable, Equatable {
    /// Everything the stored vectors depend on; a different identity invalidates the index.
    let identity: String
    let name: String
}

/// Produces image and text embeddings in one shared space. The app's implementation runs CLIP
/// through the inference runtime; fast tests substitute a deterministic one.
protocol LensWorksSemanticEmbedder: Sendable {
    func model() async -> Result<LensWorksSemanticModel, LensWorksSemanticUnavailable>
    func embed(images: [LWInferenceImage]) async throws -> [[Float]]
    func embed(text: String) async throws -> [Float]
    /// Drops what the embedder keeps loaded between batches.
    func release() async
}

/// CLIP ViT-L/14 through the model store and the inference runtime.
@MainActor final class LensWorksCLIPEmbedder: LensWorksSemanticEmbedder {
    static let modelID = "clip_vit_l14"
    /// How previews become model input; part of the index identity.
    static let preprocessing = "stored-thumbnail-srgb-v1"
    private let center: LWModelCenter
    private var keptLoaded = false
    init(center: LWModelCenter) { self.center = center }

    /// The model files, routes, runtime revision and preprocessing the vectors depend on.
    nonisolated static func identity(_ model: LWModelManifest.Model, inferenceRevision: String) -> String {
        var parts = [model.id, inferenceRevision, preprocessing]
        parts += model.routes.map { $0.task + ":" + $0.provider }.sorted()
        for component in model.components {
            parts.append(component.repository + "@" + component.revision)
            parts += component.files.map { $0.path + ":" + $0.sha256 }.sorted()
        }
        return SHA256.hash(data: Data(parts.joined(separator: "\n").utf8)).map { String(format: "%02x", $0) }.joined()
    }

    private func ready() async -> Result<LWModelStatus, LensWorksSemanticUnavailable> {
        guard let status = await center.status(Self.modelID) else {
            return .failure(.modelUnavailable(center.setupError ?? "The AI model store is unavailable."))
        }
        let name = status.model.name
        guard status.isAdmissible else { return .failure(.modelUnavailable("\(name) cannot run on this Mac. \(status.state.message)")) }
        guard status.state.isReady else {
            let text = "\(name): \(status.state.title). \(status.state.message)"
            return .failure(status.state.canDownload ? .modelNotInstalled(text + " Semantic search never downloads a model on its own; use AI Models.") : .modelUnavailable(text))
        }
        if status.needsLicenseAcknowledgement {
            return .failure(.licenseRequired("\(name) has licence terms to accept in AI Models before it is used."))
        }
        return .success(status)
    }

    func model() async -> Result<LensWorksSemanticModel, LensWorksSemanticUnavailable> {
        await ready().flatMap { status in
            guard let revision = center.manifestInferenceRevision else { return .failure(.modelUnavailable("The AI model store is unavailable.")) }
            return .success(.init(identity: Self.identity(status.model, inferenceRevision: revision), name: status.model.name))
        }
    }

    private func run(task: String, pixels: Int?, inputs: [LWInferenceImage], count: Int,
                     request: @escaping @Sendable (String, LWModelLease) -> LWInferenceRequest) async throws -> [[Float]] {
        let status = try await ready().get()
        guard let provider = status.model.routes.first(where: { $0.task == task })?.provider else {
            throw LensWorksSemanticUnavailable.modelUnavailable("\(status.model.name) has no \(task) route.")
        }
        let job: LWModelJob
        do { job = try await center.runJob(Self.modelID, pixels: pixels, inputs: inputs) { request(provider, $0) } }
        catch let error as LWModelStoreError { throw LensWorksSemanticUnavailable.modelUnavailable(String(describing: error)) }
        catch let error as LWInferenceError { throw LensWorksSemanticUnavailable.modelUnavailable(error.description) }
        return try await withTaskCancellationHandler {
            for await event in job.events {
                switch event {
                case .completed(let result):
                    guard let vectors = result.embeddings, vectors.count == count else { throw LWInferenceError.protocolViolation("The embedding job returned \(result.embeddings?.count ?? 0) vectors for \(count) inputs.") }
                    return vectors
                case .failed(let failure): throw LWInferenceError.rejected(kind: failure.kind, message: failure.message)
                case .cancelled: throw CancellationError()
                default: continue
                }
            }
            throw CancellationError()
        } onCancel: { job.cancel() }
    }

    func embed(images: [LWInferenceImage]) async throws -> [[Float]] {
        guard !images.isEmpty else { return [] }
        let indices = Array(images.indices)
        keptLoaded = true
        // Kept loaded between the batches of one indexing pass; `release` unloads it.
        return try await run(task: "embed_image", pixels: images.map { $0.width * $0.height }.max(), inputs: images, count: images.count) { provider, lease in
            .embedImage(provider: provider, weights: lease.weights, load: .init(residency: .keepLoaded), LWEmbedImageParams(inputs: indices))
        }
    }

    func embed(text: String) async throws -> [Float] {
        keptLoaded = true
        // Shares the residency of an indexing pass that is running; the search service releases it after the query otherwise.
        return try await run(task: "embed_text", pixels: nil, inputs: [], count: 1) { provider, lease in
            .embedText(provider: provider, weights: lease.weights, load: .init(residency: .keepLoaded), LWEmbedTextParams(texts: [text]))
        }[0]
    }

    func release() async {
        guard keptLoaded else { return }
        keptLoaded = false
        await center.releaseResidents()
    }
}

// MARK: - Catalog source

nonisolated struct LensWorksSemanticRow: Sendable, Equatable {
    let imageID: String
    let assetID: String
    let variantID: String
    let sequence: Int64
}

nonisolated struct LensWorksSemanticSourcePage: Sendable {
    let rows: [LensWorksSemanticRow]
    let next: String?
}

nonisolated struct LensWorksSemanticPreview: Sendable {
    let image: LWInferenceImage
    let revision: Int64
    let recipeDigest: String
}

nonisolated enum LensWorksSemanticSourceError: Error, Equatable {
    /// The page cursor went stale (the catalog changed); the pass starts its scan again.
    case restart
    /// Previews cannot be read for now (storage maintenance); the pass stops and says why.
    case paused(String)
}

/// The version of a photo's pixels: the recipe revision and digest its preview is rendered from.
nonisolated struct LensWorksSemanticVersion: Sendable, Equatable {
    let revision: Int64
    let recipeDigest: String
}

/// What indexing reads from a catalog: every photo newest first, each photo's stored preview, and
/// the version a photo's pixels are at now.
protocol LensWorksSemanticCatalogSource: Sendable {
    func semanticPage(cursor: String?) async throws -> LensWorksSemanticSourcePage
    func semanticPreview(_ row: LensWorksSemanticRow) async throws -> LensWorksSemanticPreview
    /// The photo's current version, or nil when the catalog no longer has it.
    func semanticVersion(_ row: LensWorksSemanticRow) async throws -> LensWorksSemanticVersion?
}

extension LensWorksCatalogService: LensWorksSemanticCatalogSource {
    private static let everyPhotoNewestFirst = LWApplicationBrowseOptions(text: nil, keyword: nil, keyword_direct: false, folder: nil, folder_recursive: true, collection: nil, date_from: nil, date_until: nil, camera_make: nil, camera: nil, lens: nil, format: nil, rating: nil, flag: nil, label: nil, only_conflicted: false, sort: .Sequence, direction: .Descending)

    func semanticPage(cursor: String?) async throws -> LensWorksSemanticSourcePage {
        do {
            let page = try await browseInBackground(options: Self.everyPhotoNewestFirst, cursor: cursor)
            guard !page.hasMore || (page.next != nil && page.next != cursor) else { throw LensWorksManagedError.protocolViolation("A continuing page did not advance its cursor authority.") }
            return .init(rows: page.rows.map { .init(imageID: $0.image_id, assetID: $0.key.asset_id, variantID: $0.key.variant_id, sequence: $0.sequence.value) },
                         next: page.hasMore ? page.next : nil)
        } catch LensWorksManagedError.native(let code, let message) where LensWorksCatalog.isStaleCursor(code, message) {
            throw LensWorksSemanticSourceError.restart
        }
    }

    func semanticPreview(_ row: LensWorksSemanticRow) async throws -> LensWorksSemanticPreview {
        let preview: LensWorksPreview
        do { preview = try await semanticThumbnail(LWCatalogEditsVariantKey(asset_id: row.assetID, variant_id: row.variantID)) }
        catch LensWorksCatalogError.message(LensWorksPreviewStore.pausedMessage) { throw LensWorksSemanticSourceError.paused(LensWorksPreviewStore.pausedMessage) }
        catch LensWorksManagedError.resourceLimit { throw CancellationError() } // the grid has the viewports; try again shortly
        return .init(image: try LWInferenceImage(cgImage: preview.image), revision: preview.status.revision.value, recipeDigest: preview.status.recipe_digest)
    }

    func semanticVersion(_ row: LensWorksSemanticRow) async throws -> LensWorksSemanticVersion? {
        do {
            let current = try await variant(LWCatalogEditsVariantKey(asset_id: row.assetID, variant_id: row.variantID))
            return .init(revision: current.revision.value, recipeDigest: current.recipe_digest)
        } catch LensWorksManagedError.native(let code, let message) where LensWorksCatalog.isMissingPhoto(code, message) { return nil }
    }
}

// MARK: - Indexing pass

nonisolated struct LensWorksSemanticPassOutcome: Sendable, Equatable {
    var preparation: LensWorksSemanticPreparation = .kept
    /// Photos embedded by this pass.
    var embedded = 0
    /// Photos this pass looked at.
    var examined = 0
    /// Photos left without an embedding for a stated reason (for example no stored preview while the original is offline).
    var failed = 0
    /// Photos whose preview request was interrupted by other preview work; a later pass retries them.
    var interrupted = 0
    /// Largest batch handed to the model.
    var largestBatch = 0
    /// Photos forgotten because the catalog no longer has them.
    var removed = 0
    /// Indexed photos found to have changed since they were embedded (edited outside this session), embedded again.
    var outdated = 0
    /// The stored watermark belonged to another catalog at the same path, so the whole catalog was scanned.
    var rescanned = false
}

/// One incremental pass: retry what is owed, then scan the catalog newest first, embedding
/// photos that have no embedding, and stop at the sequence an earlier pass finished through.
/// A scan of the whole catalog (the first one, after a rebuild, or when the stored watermark turns
/// out to belong to another catalog at the same path) also forgets photos the catalog no longer
/// has. Last, up to `verifyBatch` already indexed photos are compared with the catalog's current
/// version, so edits made outside this session are embedded again a slice at a time.
/// Work is bounded by `batchSize` previews at a time and stops at the next photo or model
/// event when its task is cancelled; everything stored before that stays.
nonisolated enum LensWorksSemanticPass {
    static let interruptedReason = "Its preview request was interrupted by other preview work."

    static func run(index: LensWorksSemanticIndex, embedder: any LensWorksSemanticEmbedder, source: any LensWorksSemanticCatalogSource,
                    batchSize: Int = 16, verifyBatch: Int = 128, progress: @Sendable (LensWorksSemanticPassOutcome) async -> Void = { _ in }) async throws -> LensWorksSemanticPassOutcome {
        let model = try await embedder.model().get()
        var outcome = LensWorksSemanticPassOutcome()
        outcome.preparation = try await index.prepare(model: model.identity)
        let generation = await index.generation
        let size = max(1, batchSize)

        func embed(_ rows: [LensWorksSemanticRow]) async throws {
            var images: [LWInferenceImage] = [], versions: [(LensWorksSemanticRow, Int64, String)] = [], unembedded: [LensWorksSemanticPending] = []
            for row in rows {
                try Task.checkCancellation()
                var reason: String?
                for attempt in 0..<3 {
                    do {
                        let preview = try await source.semanticPreview(row)
                        images.append(preview.image); versions.append((row, preview.revision, preview.recipeDigest))
                        reason = nil
                        break
                    } catch is CancellationError {
                        // Our own cancellation stops the pass; the preview store's (a page change) is retried.
                        try Task.checkCancellation()
                        reason = interruptedReason
                        if attempt < 2 { try await Task.sleep(for: .milliseconds(150)) }
                    } catch let error as LensWorksSemanticSourceError { throw error }
                    catch { reason = error.localizedDescription; break }
                }
                if let reason {
                    unembedded.append(.init(imageID: row.imageID, assetID: row.assetID, variantID: row.variantID, reason: reason))
                    if reason == interruptedReason { outcome.interrupted += 1 } else { outcome.failed += 1 }
                }
            }
            outcome.examined += rows.count
            try await index.markPending(unembedded)
            if !images.isEmpty {
                outcome.largestBatch = max(outcome.largestBatch, images.count)
                let vectors = try await embedder.embed(images: images)
                guard vectors.count == versions.count else { throw LensWorksSemanticIndexError.unavailable("The model returned \(vectors.count) embeddings for \(versions.count) photos.") }
                try await index.store(zip(versions, vectors).map { version, vector in
                    .init(imageID: version.0.imageID, assetID: version.0.assetID, variantID: version.0.variantID, revision: version.1, recipeDigest: version.2, vector: vector)
                })
                outcome.embedded += images.count
            }
            await progress(outcome)
        }

        // 1. What earlier passes or edits left owed.
        var after = ""
        while true {
            try Task.checkCancellation()
            let owed = try await index.pending(after: after, limit: size)
            guard let last = owed.last else { break }
            after = last.imageID
            try await embed(owed.map { .init(imageID: $0.imageID, assetID: $0.assetID, variantID: $0.variantID, sequence: 0) })
        }
        // 2. Newest first, down to what a finished pass already covered.
        var restarts = 0
        scan: while true {
            var floor = try await index.completeThrough()
            var cursor: String?, top: Int64?
            do {
                while true {
                    try Task.checkCancellation()
                    let page = try await source.semanticPage(cursor: cursor)
                    if cursor == nil {
                        top = page.rows.first?.sequence
                        // Sequences only grow within one catalog. A newest photo below the watermark, or at it
                        // but unknown to the index, means the watermark is another catalog's (recreated or
                        // restored at this path): everything is scanned, and what is not seen is forgotten.
                        if let covered = floor {
                            var foreign = true
                            if let newest = page.rows.first, newest.sequence >= covered {
                                let unknown = try await index.known([newest.imageID]).isEmpty
                                foreign = newest.sequence == covered && unknown
                            }
                            if foreign { try await index.setCompleteThrough(nil); floor = nil; outcome.rescanned = true }
                        }
                        if floor == nil { try await index.beginFullScan() }
                    }
                    if floor == nil { try await index.markSeen(page.rows.map(\.imageID)) }
                    let fresh = page.rows.filter { row in floor.map { row.sequence > $0 } ?? true }
                    let have = try await index.embedded(fresh.map(\.imageID))
                    // Photos already owed were attempted in step 1 of this pass.
                    let owed = try await index.owed(fresh.map(\.imageID))
                    let missing = fresh.filter { !have.contains($0.imageID) && !owed.contains($0.imageID) }
                    outcome.examined += fresh.count - missing.count
                    for start in stride(from: 0, to: missing.count, by: size) { try await embed(Array(missing[start..<min(start + size, missing.count)])) }
                    if missing.isEmpty { await progress(outcome) }
                    guard fresh.count == page.rows.count, let next = page.next else { break }
                    cursor = next
                }
            } catch LensWorksSemanticSourceError.restart {
                restarts += 1
                guard restarts <= 8 else { throw LensWorksSemanticIndexError.unavailable("The catalog kept changing while it was being indexed. Indexing continues on the next pass.") }
                continue scan
            }
            if let floor { try await index.finishScan(full: false, through: max(top ?? floor, floor), generation: generation) }
            else { outcome.removed += try await index.finishScan(full: true, through: top, generation: generation) }
            break
        }
        // 3. A bounded slice of the photos indexed earlier: has the catalog a newer version of them?
        if verifyBatch > 0 {
            let slice = try await index.verificationSlice(limit: verifyBatch)
            var gone: [String] = [], changed: [LensWorksSemanticRow] = []
            for entry in slice {
                try Task.checkCancellation()
                let row = LensWorksSemanticRow(imageID: entry.imageID, assetID: entry.assetID, variantID: entry.variantID, sequence: 0)
                guard let current = try await source.semanticVersion(row) else { gone.append(entry.imageID); continue }
                if current != LensWorksSemanticVersion(revision: entry.revision, recipeDigest: entry.recipeDigest) { changed.append(row) }
            }
            try await index.remove(gone)
            outcome.removed += gone.count; outcome.outdated += changed.count
            for start in stride(from: 0, to: changed.count, by: size) { try await embed(Array(changed[start..<min(start + size, changed.count)])) }
            // Fewer than a full slice means the end was reached: the next pass starts over.
            try await index.setVerifiedThrough(slice.count < verifyBatch ? nil : slice.last?.imageID)
        }
        return outcome
    }
}

// MARK: - Search service

/// Owns one catalog's semantic index: keeps it up to date in the background and reports an
/// honest state for the search bar.
@MainActor @Observable
final class LensWorksSemanticSearch {
    enum State: Equatable {
        /// No catalog is open.
        case noCatalog
        /// The model's availability has not been established yet.
        case checking
        case modelUnavailable(LensWorksSemanticUnavailable)
        case indexing(indexed: Int, examined: Int)
        /// Indexing was stopped by the person (or has not been started in this session).
        case paused(indexed: Int)
        /// Indexing cannot continue for now, and why.
        case waiting(String, indexed: Int)
        case ready(indexed: Int, unindexed: Int, reasons: [String])
        /// The index cannot be used, and why.
        case indexUnavailable(String)
    }

    private(set) var state: State = .noCatalog
    /// Completed passes, for tests and diagnostics.
    private(set) var passes = 0
    private(set) var lastOutcome: LensWorksSemanticPassOutcome?
    /// Why the last pass prepared the index the way it did (model changed, file replaced).
    private(set) var lastPreparation: LensWorksSemanticPreparation?

    @ObservationIgnored let embedder: any LensWorksSemanticEmbedder
    @ObservationIgnored private let directory: URL?
    @ObservationIgnored private let batchSize: Int
    @ObservationIgnored private let verifyBatch: Int
    /// Passes and description queries that are using the loaded model; it is released when none is.
    @ObservationIgnored private var modelUsers = 0
    @ObservationIgnored private var releasing: Task<Void, Never>?
    @ObservationIgnored private var index: LensWorksSemanticIndex?
    @ObservationIgnored private var source: (any LensWorksSemanticCatalogSource)?
    @ObservationIgnored private var task: Task<Void, Never>?
    @ObservationIgnored private var rerun = false
    @ObservationIgnored private var userPaused: Bool
    @ObservationIgnored private var generation: UInt64 = 0
    @ObservationIgnored private var queryVectors: [(model: String, text: String, vector: [Float])] = []

    /// `automatic: false` starts paused: nothing is embedded until the person resumes indexing.
    /// `verifyBatch` is how many already indexed photos each pass compares with the catalog's current version.
    init(embedder: any LensWorksSemanticEmbedder, directory: URL? = nil, batchSize: Int = 16, verifyBatch: Int = 128, automatic: Bool = true) {
        self.embedder = embedder; self.directory = directory; self.batchSize = batchSize; self.verifyBatch = verifyBatch; self.userPaused = !automatic
    }

    /// The app's service: CLIP through the shared model store. Under XCTest (the app as a test
    /// host or driven by a UI test) and in `--lensworks-…` automation launches (fixture imports,
    /// evidence runs) indexing starts paused unless LW_SEMANTIC_AUTO_INDEX=1, so those launches
    /// never start inference on their own.
    static func application() -> LensWorksSemanticSearch {
        let environment = ProcessInfo.processInfo.environment
        let unattended = environment["XCTestConfigurationFilePath"] != nil || NSClassFromString("XCTestCase") != nil
            || ProcessInfo.processInfo.arguments.contains { $0.hasPrefix("--lensworks-") }
        var directory: URL?
        #if DEBUG
        // Tests and evidence runs keep their index out of the app's own Application Support folder.
        if let root = environment["LW_SEMANTIC_INDEX_ROOT"], !root.isEmpty { directory = URL(fileURLWithPath: root, isDirectory: true) }
        #endif
        return LensWorksSemanticSearch(embedder: LensWorksCLIPEmbedder(center: .shared), directory: directory,
                                       automatic: !unattended || environment["LW_SEMANTIC_AUTO_INDEX"] == "1")
    }

    var indexURL: URL? { index?.url }
    var isIndexing: Bool { task != nil }
    var isPaused: Bool { userPaused }
    var indexedCount: Int {
        switch state {
        case .indexing(let indexed, _), .paused(let indexed), .waiting(_, let indexed), .ready(let indexed, _, _): indexed
        default: 0
        }
    }

    /// One line for the search bar.
    var summary: String {
        switch state {
        case .noCatalog: "Open a catalog to search it by description."
        case .checking: "Checking the semantic search model…"
        case .modelUnavailable(let reason): reason.message
        case .indexing(let indexed, let examined): "Indexing previews for semantic search · \(indexed) indexed · \(examined) checked in this pass. Results cover the photos indexed so far."
        case .paused(let indexed): "Semantic indexing is paused · \(indexed) photos indexed. Resume Indexing to continue."
        case .waiting(let reason, let indexed): "Semantic indexing is waiting · \(indexed) photos indexed. \(reason)"
        case .ready(let indexed, let unindexed, let reasons):
            unindexed == 0 ? "Semantic search covers \(indexed) photos."
                : "Semantic search covers \(indexed) photos; \(unindexed) could not be indexed. " + reasons.joined(separator: " ")
        case .indexUnavailable(let reason): reason
        }
    }

    /// Why a description search cannot run, or nil when it can (possibly over a partial index).
    var searchUnavailableReason: String? {
        switch state {
        case .noCatalog: "Open a catalog first."
        case .checking: "The semantic search model is still being checked."
        case .modelUnavailable(let reason): reason.message
        case .indexUnavailable(let reason): reason
        case .indexing, .paused, .waiting, .ready: nil
        }
    }
    var pauseUnavailableReason: String? {
        if index == nil { return "Open a catalog first." }
        return userPaused ? "Indexing is already paused." : nil
    }
    var resumeUnavailableReason: String? {
        if index == nil { return "Open a catalog first." }
        if userPaused { return nil }
        if case .waiting = state, !isIndexing { return nil } // a stopped pass can be retried by hand
        return isIndexing ? "Indexing is already running." : "Indexing is not paused; new photos are indexed automatically."
    }
    var rebuildUnavailableReason: String? {
        if index == nil { return "Open a catalog first." }
        if case .modelUnavailable(let reason) = state { return reason.message }
        return nil
    }

    // MARK: Catalog lifecycle

    func attach(catalogPath: String, source: any LensWorksSemanticCatalogSource) async {
        await detach()
        do {
            index = LensWorksSemanticIndex(url: try LensWorksSemanticIndex.location(catalogPath: catalogPath, directory: directory),
                                           catalog: LensWorksSemanticIndex.catalogStamp(catalogPath: catalogPath))
        }
        catch { state = .indexUnavailable(error.localizedDescription); return }
        self.source = source
        state = userPaused ? .paused(indexed: 0) : .checking
        schedule()
    }

    /// Stops indexing and forgets the catalog. Returns once no pass is running.
    func detach() async {
        generation &+= 1
        let running = task
        task = nil; rerun = false
        running?.cancel()
        await running?.value
        // A description query still embedding releases the model itself when it finishes.
        if index != nil, modelUsers == 0 { await embedder.release() }
        index = nil; source = nil; queryVectors = []
        state = .noCatalog
    }

    /// Asks for an indexing pass; a pass already running runs once more when it ends.
    func schedule() {
        guard !userPaused, let index, let source else { return }
        if task != nil { rerun = true; return }
        let admitted = generation, embedder = self.embedder, batchSize = self.batchSize, verifyBatch = self.verifyBatch
        task = Task { [weak self] in
            var retries = 0
            while !Task.isCancelled {
                await self?.useModel()
                let result: Result<LensWorksSemanticPassOutcome, any Error>
                do {
                    result = .success(try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: batchSize, verifyBatch: verifyBatch) { outcome in
                        let indexed = (try? await index.count()) ?? 0
                        await self?.report(.indexing(indexed: indexed, examined: outcome.examined), generation: admitted)
                    })
                } catch { result = .failure(error) }
                if let self { await self.doneWithModel() } else { await embedder.release() }
                guard let self, self.generation == admitted, !Task.isCancelled else { return }
                // Photos whose preview request lost to other preview work are retried a few times, then reported.
                var interrupted = false
                if case .success(let outcome) = result, outcome.interrupted > 0, retries < 5 { interrupted = true; retries += 1 }
                guard await self.finish(result, index: index, retryInterrupted: interrupted), self.generation == admitted else { break }
                if interrupted { try? await Task.sleep(for: .seconds(2)) }
            }
            if let self, self.generation == admitted { self.task = nil }
        }
    }

    /// Counts one more user of the loaded model, after any release in progress has finished.
    private func useModel() async {
        while let releasing { await releasing.value }
        modelUsers += 1
    }
    /// One user is done. The model is unloaded when no pass and no description query is embedding,
    /// so it never stays resident (and leased) on an idle index, and is never unloaded under a job.
    private func doneWithModel() async {
        modelUsers -= 1
        while let releasing { await releasing.value }
        guard modelUsers == 0 else { return }
        let embedder = self.embedder
        // Cleared by the release itself, before it completes: a waiter never finds a finished release still recorded.
        let release = Task { await embedder.release(); self.releasing = nil }
        releasing = release
        await release.value
    }

    private func report(_ state: State, generation admitted: UInt64) {
        guard generation == admitted, !userPaused else { return }
        self.state = state
    }

    /// Publishes a finished pass. Returns whether another pass should follow.
    private func finish(_ result: Result<LensWorksSemanticPassOutcome, any Error>, index: LensWorksSemanticIndex, retryInterrupted: Bool) async -> Bool {
        let indexed = (try? await index.count()) ?? 0
        let admitted = generation
        switch result {
        case .success(let outcome):
            passes += 1; lastOutcome = outcome; lastPreparation = outcome.preparation
            let failures = (try? await index.failures()) ?? (count: 0, reasons: [])
            guard generation == admitted else { return false }
            let again = rerun || retryInterrupted
            rerun = false
            state = again ? .indexing(indexed: indexed, examined: 0) : .ready(indexed: indexed, unindexed: failures.count, reasons: failures.reasons)
            return again
        case .failure(let error):
            rerun = false
            switch error {
            case let reason as LensWorksSemanticUnavailable: state = .modelUnavailable(reason)
            case LensWorksSemanticSourceError.paused(let reason): state = .waiting(reason + " Indexing continues when previews resume.", indexed: indexed)
            case LensWorksSemanticIndexError.recovered: state = .indexing(indexed: 0, examined: 0); return true
            case let failure as LensWorksSemanticIndexError: state = .indexUnavailable(failure.description)
            default: state = .waiting("The last pass stopped: \(error.localizedDescription) Indexing is retried when the catalog changes or you choose Resume Indexing.", indexed: indexed)
            }
            return false
        }
    }

    // MARK: Commands

    /// Stops the running pass at its next photo or model event. What it stored stays.
    func pause() async {
        guard index != nil else { return }
        userPaused = true
        let running = task
        task = nil; rerun = false
        generation &+= 1
        running?.cancel()
        await running?.value
        state = .paused(indexed: (try? await index?.count()) ?? 0)
    }

    func resume() {
        guard index != nil else { return }
        userPaused = false
        if case .paused(let indexed) = state { state = .indexing(indexed: indexed, examined: 0) }
        schedule()
    }

    /// Discards every stored vector and indexes the catalog again.
    func rebuild() async throws {
        guard let index else { return }
        let wasPaused = userPaused
        await pause()
        do {
            let model = try await embedder.model().get()
            try await index.prepare(model: model.identity)
            try await index.clear()
        } catch {
            // The rebuild did not start: indexing goes back to how it was, not left paused.
            if !wasPaused { resume() }
            throw error
        }
        userPaused = wasPaused
        if wasPaused { state = .paused(indexed: 0) } else { state = .indexing(indexed: 0, examined: 0); schedule() }
    }

    /// Photos whose pixels changed (or that were just created): their embeddings are owed again.
    /// Recording that needs only the index file, so an edit made while the model is unavailable is not lost.
    func invalidate(_ rows: [LensWorksSemanticPending]) async {
        guard let index, !rows.isEmpty else { return }
        try? await index.markPending(rows)
        schedule()
    }

    /// Photos the catalog no longer has.
    func forget(_ images: [String]) async { try? await index?.remove(images) }

    /// Looks again after the model's state may have changed (a download finished, a licence was accepted).
    func recheck() {
        guard index != nil else { return }
        guard case .modelUnavailable = state else { return }
        state = userPaused ? .paused(indexed: 0) : .checking
        schedule()
    }

    // MARK: Queries

    /// The index and the text's embedding, for ranking. Throws the reason search is unavailable.
    func query(_ text: String) async throws -> (index: LensWorksSemanticIndex, vector: [Float]) {
        guard let index else { throw LensWorksCatalogError.message("Open a catalog first.") }
        let model: LensWorksSemanticModel
        switch await embedder.model() {
        case .success(let value): model = value
        case .failure(let reason): state = .modelUnavailable(reason); throw reason
        }
        if case .modelUnavailable = state { recheck() }
        try await index.prepare(model: model.identity)
        if let cached = queryVectors.first(where: { $0.model == model.identity && $0.text == text }) { return (index, cached.vector) }
        await useModel()
        let vector: [Float]
        do { vector = try await embedder.embed(text: text) } catch { await doneWithModel(); throw error }
        await doneWithModel()
        queryVectors.append((model.identity, text, vector))
        if queryVectors.count > 16 { queryVectors.removeFirst() }
        return (index, vector)
    }
}
