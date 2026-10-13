import AppKit
import CoreGraphics
import Foundation
import Testing
@testable import Compositor

// MARK: - Deterministic stand-ins (no weights, no catalog engine)

/// A deterministic embedder: an image embeds as its mean colour about mid-grey, a text as the
/// colour it names, so "red" ranks the reddest photo first. It records every call.
nonisolated final class LensWorksStubEmbedder: LensWorksSemanticEmbedder, @unchecked Sendable {
    static let colors: [String: [Float]] = [
        "red": [1, 0, 0], "green": [0, 1, 0], "blue": [0, 0, 1], "yellow": [1, 1, 0], "cyan": [0, 1, 1], "magenta": [1, 0, 1],
    ]
    private let lock = NSLock()
    private var _identity: String
    private var _unavailable: LensWorksSemanticUnavailable?
    private var _batches: [Int] = []
    private var _texts: [String] = []
    private var _releases = 0
    private var _embedding = 0
    private var _releasesUnderAnEmbed = 0
    /// Called before each image batch is embedded (a test can hold or cancel there).
    var beforeBatch: (@Sendable (Int) async throws -> Void)?
    /// Called before a text is embedded (a test can hold there).
    var beforeText: (@Sendable (String) async throws -> Void)?
    /// Called before the model's availability is answered (a test can hold there).
    var beforeModel: (@Sendable () async -> Void)?

    init(identity: String = "stub-model-a", unavailable: LensWorksSemanticUnavailable? = nil) { _identity = identity; _unavailable = unavailable }

    private func locked<T>(_ body: () -> T) -> T { lock.lock(); defer { lock.unlock() }; return body() }
    var identity: String { get { locked { _identity } } set { locked { _identity = newValue } } }
    var unavailable: LensWorksSemanticUnavailable? { get { locked { _unavailable } } set { locked { _unavailable = newValue } } }
    var batches: [Int] { locked { _batches } }
    var imagesEmbedded: Int { locked { _batches.reduce(0, +) } }
    var texts: [String] { locked { _texts } }
    var releases: Int { locked { _releases } }
    /// How many times the model was released while an embedding job was still running.
    var releasesUnderAnEmbed: Int { locked { _releasesUnderAnEmbed } }

    func model() async -> Result<LensWorksSemanticModel, LensWorksSemanticUnavailable> {
        await beforeModel?()
        if let unavailable { return .failure(unavailable) }
        return .success(.init(identity: identity, name: "Stub"))
    }

    static func vector(_ image: LWInferenceImage) -> [Float] {
        var sums = [Double](repeating: 0, count: 3)
        image.pixels.withUnsafeBytes { raw in
            for y in 0..<image.height {
                for x in 0..<image.width {
                    let at = y * image.rowBytes + x * image.channels
                    for c in 0..<3 { sums[c] += Double(raw[at + min(c, image.channels - 1)]) }
                }
            }
        }
        let count = Double(image.width * image.height) * 255
        return sums.map { Float($0 / count) - 0.5 } + [0.01]
    }

    func embed(images: [LWInferenceImage]) async throws -> [[Float]] {
        locked { _embedding += 1 }; defer { locked { _embedding -= 1 } }
        let batch = locked { _batches.count }
        try await beforeBatch?(batch)
        try Task.checkCancellation()
        if let unavailable { throw unavailable }
        locked { _batches.append(images.count) }
        return images.map(Self.vector)
    }

    func embed(text: String) async throws -> [Float] {
        locked { _embedding += 1 }; defer { locked { _embedding -= 1 } }
        try await beforeText?(text)
        if let unavailable { throw unavailable }
        locked { _texts.append(text) }
        var sum: [Float] = [0, 0, 0]
        for word in text.lowercased().split(separator: " ") { if let color = Self.colors[String(word)] { for c in 0..<3 { sum[c] += color[c] } } }
        let peak = max(sum.max() ?? 0, 1)
        return sum.map { $0 / peak - 0.5 } + [0.01]
    }

    func release() async { locked { _releases += 1; if _embedding > 0 { _releasesUnderAnEmbed += 1 } } }
}

/// An in-memory catalog: photos with a colour, newest sequence first, paged like the engine.
actor LensWorksFakeSemanticSource: LensWorksSemanticCatalogSource {
    struct Photo { let row: LensWorksSemanticRow; var rgb: [UInt8]; var revision: Int64 }
    private var photos: [Photo] = []
    private var failing: [String: String] = [:]
    private(set) var pageFetches = 0
    private(set) var previewFetches: [String] = []
    private(set) var versionChecks: [String] = []
    private var previewsPaused: String?
    private var staleOnce = false
    var pageSize = 100

    func setPageSize(_ size: Int) { pageSize = size }
    func add(_ id: String, rgb: [UInt8]) {
        photos.append(.init(row: .init(imageID: id, assetID: "asset-" + id, variantID: "master", sequence: Int64(photos.count + 1)), rgb: rgb, revision: 1))
    }
    func edit(_ id: String, rgb: [UInt8]) {
        guard let index = photos.firstIndex(where: { $0.row.imageID == id }) else { return }
        photos[index].rgb = rgb; photos[index].revision += 1
    }
    /// Changes a photo's pixels the way an edit outside this session would: nobody tells the index.
    func remove(_ id: String) { photos.removeAll { $0.row.imageID == id } }
    func pausePreviews(_ reason: String?) { previewsPaused = reason }
    func fail(_ id: String, _ reason: String?) { failing[id] = reason }
    func goStaleOnce() { staleOnce = true }
    func resetCounters() { pageFetches = 0; previewFetches = []; versionChecks = [] }
    func row(_ id: String) -> LensWorksSemanticRow? { photos.first { $0.row.imageID == id }?.row }

    func semanticPage(cursor: String?) async throws -> LensWorksSemanticSourcePage {
        pageFetches += 1
        let offset = cursor.flatMap(Int.init) ?? 0
        if staleOnce, offset > 0 { staleOnce = false; throw LensWorksSemanticSourceError.restart }
        let newestFirst = photos.reversed().map(\.row)
        let end = min(offset + pageSize, newestFirst.count)
        return .init(rows: Array(newestFirst[offset..<end]), next: end < newestFirst.count ? String(end) : nil)
    }

    func semanticPreview(_ row: LensWorksSemanticRow) async throws -> LensWorksSemanticPreview {
        if let previewsPaused { throw LensWorksSemanticSourceError.paused(previewsPaused) }
        previewFetches.append(row.imageID)
        if let reason = failing[row.imageID] { throw LensWorksCatalogError.message(reason) }
        guard let photo = photos.first(where: { $0.row.imageID == row.imageID }) else { throw LensWorksCatalogError.message("The catalog no longer has this photo.") }
        return .init(image: try LWInferenceImage(width: 2, height: 2, channels: 3, alpha: .none, pixels: Data((0..<4).flatMap { _ in photo.rgb })),
                     revision: photo.revision, recipeDigest: "digest-\(photo.revision)")
    }

    func semanticVersion(_ row: LensWorksSemanticRow) async throws -> LensWorksSemanticVersion? {
        versionChecks.append(row.imageID)
        return photos.first { $0.row.imageID == row.imageID }.map { .init(revision: $0.revision, recipeDigest: "digest-\($0.revision)") }
    }
}

private nonisolated let stubPalette: [(String, [UInt8])] = [
    ("red", [230, 20, 20]), ("green", [20, 230, 20]), ("blue", [20, 20, 230]), ("yellow", [230, 230, 20]), ("cyan", [20, 230, 230]), ("magenta", [230, 20, 230]),
]

private nonisolated func temporaryDirectory() throws -> URL {
    // The physical path: the catalog metadata index (used as a foreign database below) refuses redirected parents.
    guard let physical = realpath(FileManager.default.temporaryDirectory.path, nil) else { throw LensWorksCatalogError.message("No temporary directory.") }
    defer { free(physical) }
    let url = URL(fileURLWithPath: String(cString: physical)).appendingPathComponent("lw-semantic-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// `count` photos cycling through the palette: "photo-0003-yellow". `shift` starts the cycle
/// elsewhere, so the same ids can carry other pixels.
private nonisolated func populatedSource(_ count: Int, prefix: String = "photo", shift: Int = 0) async -> LensWorksFakeSemanticSource {
    let source = LensWorksFakeSemanticSource()
    for number in 0..<count {
        let name = stubPalette[number % stubPalette.count].0, rgb = stubPalette[(number + shift) % stubPalette.count].1
        await source.add(prefix + String(format: "-%04d-", number) + name, rgb: rgb)
    }
    return source
}

// MARK: - Index and indexing pass

@Suite nonisolated struct LensWorksSemanticIndexTests {
    @Test func storedVectorsRankByCosineSimilarityAndScoreChosenPhotos() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        #expect(try await index.prepare(model: "m") == .created)
        #expect(try await index.nearest([1, 0, 0], limit: 5).isEmpty, "an empty index answers with no matches")
        try await index.store([
            .init(imageID: "a", assetID: "A", variantID: "master", revision: 3, recipeDigest: "d3", vector: [4, 0, 0]),
            .init(imageID: "b", assetID: "B", variantID: "master", revision: 1, recipeDigest: "d1", vector: [1, 1, 0]),
            .init(imageID: "c", assetID: "C", variantID: "copy", revision: 1, recipeDigest: "d1", vector: [0, 0, 2]),
        ])
        let ranked = try await index.nearest([10, 0, 0], limit: 2)
        #expect(ranked.map(\.imageID) == ["a", "b"] && ranked[0].assetID == "A")
        #expect(abs(ranked[0].score - 1) < 1e-3 && abs(ranked[1].score - 0.7071) < 1e-3, "vectors and queries are unit length: \(ranked)")
        let chosen = try await index.scores([0, 0, 1], images: ["c", "a", "missing"])
        #expect(Set(chosen.keys) == ["a", "c"] && abs(chosen["c"]! - 1) < 1e-3 && abs(chosen["a"]!) < 1e-3)
        #expect(try await index.version("a")?.revision == 3)
        #expect(try await index.version("a")?.recipeDigest == "d3")
        // Replacing a photo's vector keeps one row.
        try await index.store([.init(imageID: "a", assetID: "A", variantID: "master", revision: 4, recipeDigest: "d4", vector: [0, 3, 0])])
        #expect(try await index.count() == 3)
        #expect(try await index.nearest([0, 1, 0], limit: 1).first?.imageID == "a")
        await #expect(throws: LensWorksSemanticIndexError.dimension(expected: 3, found: 2)) { try await index.nearest([1, 0], limit: 1) }
        await #expect(throws: LensWorksSemanticIndexError.dimension(expected: 3, found: 4)) {
            try await index.store([.init(imageID: "d", assetID: "D", variantID: "master", revision: 1, recipeDigest: "", vector: [1, 0, 0, 0])])
        }
        await #expect(throws: LensWorksSemanticIndexError.self) {
            try await index.store([.init(imageID: "d", assetID: "D", variantID: "master", revision: 1, recipeDigest: "", vector: [0, 0, 0])])
        }
        #expect(try await index.count() == 3, "a refused batch stores nothing")
        // A second connection to the same file sees the same vectors (they are on disk, not in memory).
        let reopened = LensWorksSemanticIndex(url: index.url)
        #expect(try await reopened.prepare(model: "m") == .kept)
        #expect(try await reopened.nearest([0, 0, 1], limit: 1).first?.imageID == "c")
    }

    @Test func aPassEmbedsEveryPhotoInBoundedBatchesAndLaterPassesOnlyEmbedWhatIsNew() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(250)
        let first = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 16)
        #expect(first.preparation == .created && first.embedded == 250 && first.failed == 0)
        #expect(first.largestBatch == 16 && embedder.batches.max() == 16, "no batch exceeds the bound: \(embedder.batches)")
        #expect(try await index.count() == 250)
        #expect(try await index.completeThrough() == 250)
        #expect(try await index.nearest(embedder.embed(text: "blue"), limit: 3).allSatisfy { $0.imageID.hasSuffix("blue") })

        // Nothing changed: one page is read to see that, and no preview or model work happens.
        await source.resetCounters()
        let idle = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 16)
        #expect(idle.preparation == .kept && idle.embedded == 0)
        #expect(await source.previewFetches.isEmpty)
        #expect(await source.pageFetches == 1)
        #expect(embedder.imagesEmbedded == 250)

        // Five new photos: exactly those are embedded, and the scan stops where the last pass finished.
        for number in 250..<255 { await source.add(String(format: "photo-%04d-cyan", number), rgb: [20, 230, 230]) }
        await source.resetCounters()
        let incremental = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 16)
        #expect(incremental.embedded == 5 && embedder.imagesEmbedded == 255)
        #expect(await source.previewFetches.count == 5)
        #expect(await source.pageFetches == 1)
        #expect(try await index.count() == 255)
        #expect(try await index.completeThrough() == 255)

        // An edited photo is owed again and only it is re-embedded, replacing its vector.
        let edited = try #require(await source.row("photo-0000-red"))
        await source.edit(edited.imageID, rgb: [20, 20, 230])
        try await index.markPending([.init(imageID: edited.imageID, assetID: edited.assetID, variantID: edited.variantID)])
        #expect(try await index.embedded([edited.imageID]).isEmpty, "an owed photo is not reported as embedded")
        await source.resetCounters()
        let reembedded = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 16)
        #expect(reembedded.embedded == 1)
        #expect(await source.previewFetches == [edited.imageID])
        #expect(try await index.version(edited.imageID)?.revision == 2)
        #expect(try await index.count() == 255)
        #expect(try await index.pendingCount() == 0)
        #expect(try await index.scores(embedder.embed(text: "blue"), images: [edited.imageID])[edited.imageID]! > 0.9)
    }

    @Test func aStaleCatalogCursorRestartsTheScanWithoutEmbeddingAnythingTwice() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(30)
        await source.setPageSize(10)
        await source.goStaleOnce()
        let outcome = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 8)
        #expect(outcome.embedded == 30 && embedder.imagesEmbedded == 30)
        #expect(try await index.count() == 30)
        #expect(try await index.completeThrough() == 30)
    }

    @Test func cancellingAPassStopsItKeepsWhatWasStoredAndTheNextPassFinishes() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(100)
        let (reached, signal) = AsyncStream.makeStream(of: Void.self)
        embedder.beforeBatch = { batch in
            guard batch == 2 else { return }
            signal.yield()
            try await Task.sleep(for: .seconds(30)) // held until cancelled
        }
        let pass = Task { try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 16) }
        for await _ in reached { break }
        let started = ContinuousClock.now
        pass.cancel()
        await #expect(throws: CancellationError.self) { try await pass.value }
        #expect(ContinuousClock.now - started < .seconds(5), "cancellation does not wait for the pass to finish")
        #expect(try await index.count() == 32)
        #expect(try await index.completeThrough() == nil, "two finished batches stay; the pass is not marked complete")
        embedder.beforeBatch = nil
        let resumed = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 16)
        #expect(resumed.embedded == 68 && embedder.imagesEmbedded == 100, "only the photos not yet embedded are embedded")
        #expect(try await index.count() == 100)
        #expect(try await index.completeThrough() == 100)
    }

    @Test func photosWithoutAPreviewAreReportedWithTheirReasonAndRetried() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(12)
        let reason = "No stored preview, and the original is offline."
        await source.fail("photo-0003-yellow", reason); await source.fail("photo-0007-green", reason)
        let outcome = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 5)
        #expect(outcome.embedded == 10 && outcome.failed == 2)
        let failures = try await index.failures()
        #expect(failures.count == 2 && failures.reasons == [reason])
        #expect(try await index.count() == 10)
        #expect(try await index.completeThrough() == 12, "the pass still completes; the two photos stay owed")
        // The original comes back: the next pass embeds just those two.
        await source.fail("photo-0003-yellow", nil); await source.fail("photo-0007-green", nil)
        await source.resetCounters()
        let retried = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 5)
        #expect(retried.embedded == 2 && retried.failed == 0)
        #expect(await Set(source.previewFetches) == ["photo-0003-yellow", "photo-0007-green"])
        #expect(try await index.count() == 12)
        #expect(try await index.failures().count == 0)
    }

    @Test func equalScoresAreOrderedByImageSoTheSameIndexAlwaysAnswersInTheSameOrder() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        try await index.prepare(model: "m")
        // Stored in an order that is neither ascending nor descending by image.
        for image in ["m", "b", "x", "a", "q"] {
            try await index.store([.init(imageID: image, assetID: image, variantID: "master", revision: 1, recipeDigest: "d", vector: [1, 0, 0])])
        }
        try await index.store([.init(imageID: "best", assetID: "best", variantID: "master", revision: 1, recipeDigest: "d", vector: [1, 0.1, 0])])
        #expect(try await index.nearest([1, 0.1, 0], limit: 6).map(\.imageID) == ["best", "a", "b", "m", "q", "x"])
        #expect(try await index.nearest([1, 0.1, 0], limit: 3).map(\.imageID) == ["best", "a", "b"], "the cut-off keeps the same photos whatever order they were stored in")
    }

    /// Edits made outside this session (nobody told the index) are found by comparing a bounded
    /// slice of indexed photos with the catalog's current version on each pass.
    @Test func editsMadeOutsideTheSessionAreFoundASliceAtATimeAndPhotosTheCatalogLostAreForgotten() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(10)
        _ = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, verifyBatch: 0)
        #expect(await source.versionChecks.isEmpty, "a pass asked to verify nothing reads no versions")
        // Photo 1 and photo 6 are edited and photo 3 is deleted, all without a word to the index.
        await source.edit("photo-0001-green", rgb: [20, 20, 230]); await source.edit("photo-0006-red", rgb: [20, 20, 230])
        await source.remove("photo-0003-yellow")
        await source.resetCounters()
        let first = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, verifyBatch: 4)
        #expect(await source.versionChecks == ["photo-0000-red", "photo-0001-green", "photo-0002-blue", "photo-0003-yellow"], "one bounded slice, in image order")
        #expect(first.outdated == 1 && first.removed == 1 && first.embedded == 1)
        #expect(await source.previewFetches == ["photo-0001-green"])
        #expect(try await index.version("photo-0001-green")?.revision == 2)
        #expect(try await index.version("photo-0006-red")?.revision == 1, "the next slice has not been reached yet")
        #expect(try await index.count() == 9)
        #expect(try await index.version("photo-0003-yellow") == nil)
        await source.resetCounters()
        let second = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, verifyBatch: 4)
        #expect(await source.versionChecks == ["photo-0004-cyan", "photo-0005-magenta", "photo-0006-red", "photo-0007-green"], "the next pass continues after the last one")
        #expect(second.outdated == 1 && second.embedded == 1)
        #expect(try await index.version("photo-0006-red")?.revision == 2)
        #expect(try await index.scores(embedder.embed(text: "blue"), images: ["photo-0006-red"])["photo-0006-red"]! > 0.9, "the vector follows the new pixels")
        await source.resetCounters()
        _ = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, verifyBatch: 4)
        #expect(await source.versionChecks == ["photo-0008-blue", "photo-0009-yellow"])
        await source.resetCounters()
        let wrapped = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, verifyBatch: 4)
        #expect(await source.versionChecks == ["photo-0000-red", "photo-0001-green", "photo-0002-blue", "photo-0004-cyan"], "after the last photo it starts over")
        #expect(wrapped.outdated == 0 && wrapped.embedded == 0 && embedder.imagesEmbedded == 12)
    }

    /// A catalog recreated (or restored from a backup) at the same path reuses the index file, but its
    /// sequences start again: the stored watermark is another catalog's, and so are the stored vectors.
    @Test func aWatermarkFromAnotherCatalogAtTheSamePathIsDiscardedAndItsPhotosAreForgotten() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        let embedder = LensWorksStubEmbedder()
        _ = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: await populatedSource(30), verifyBatch: 0)
        #expect(try await index.completeThrough() == 30)
        // Fewer photos: the newest sequence is below the watermark.
        let smaller = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: await populatedSource(5, prefix: "other"), verifyBatch: 0)
        #expect(smaller.rescanned && smaller.embedded == 5 && smaller.removed == 30)
        #expect(try await index.count() == 5)
        #expect(try await index.completeThrough() == 5)
        #expect(try await index.nearest(embedder.embed(text: "red"), limit: 10).allSatisfy { $0.imageID.hasPrefix("other-") })
        // As many photos as before: the newest sequence equals the watermark, but the index has never heard of that photo.
        let same = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: await populatedSource(5, prefix: "third"), verifyBatch: 0)
        #expect(same.rescanned && same.embedded == 5 && same.removed == 5)
        #expect(try await index.nearest(embedder.embed(text: "red"), limit: 10).allSatisfy { $0.imageID.hasPrefix("third-") })
        // The same catalog again: nothing is rescanned or embedded.
        let third = await populatedSource(5, prefix: "third")
        let idle = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: third, verifyBatch: 0)
        #expect(!idle.rescanned && idle.embedded == 0 && idle.removed == 0)
        #expect(await third.pageFetches == 1)
        // An emptied catalog forgets everything.
        let emptied = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: await populatedSource(0), verifyBatch: 0)
        #expect(emptied.rescanned && emptied.removed == 5)
        #expect(try await index.count() == 0)
    }

    // MARK: Recovery

    /// The index file is named by the catalog's path; its contents are bound to the catalog's creation stamp.
    @Test func anIndexBoundToAnotherCatalogsCreationStampIsDiscardedEvenWhenThePhotoIdsMatch() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite3")
        let embedder = LensWorksStubEmbedder()
        let first = LensWorksSemanticIndex(url: url, catalog: "born-1.0")
        _ = try await LensWorksSemanticPass.run(index: first, embedder: embedder, source: await populatedSource(6), verifyBatch: 0)
        #expect(try await LensWorksSemanticIndex(url: url, catalog: "born-1.0").prepare(model: embedder.identity) == .kept)
        #expect(try await LensWorksSemanticIndex(url: url).prepare(model: embedder.identity) == .kept, "a catalog whose stamp cannot be read keeps the index")
        // Another catalog at the same path with the very same ids and sequences, but other pixels.
        let other = LensWorksSemanticIndex(url: url, catalog: "born-2.0")
        #expect(try await other.prepare(model: embedder.identity) == .catalogChanged)
        #expect(try await other.count() == 0)
        #expect(try await other.completeThrough() == nil)
        let outcome = try await LensWorksSemanticPass.run(index: other, embedder: embedder, source: await populatedSource(6, shift: 2), verifyBatch: 0)
        #expect(outcome.embedded == 6 && embedder.imagesEmbedded == 12)
        #expect(try await other.nearest(embedder.embed(text: "blue"), limit: 1).first?.imageID == "photo-0000-red", "the vectors are the new catalog's")
        // The stamp itself: a directory's stays put while it is used and changes when it is created again.
        let catalog = directory.appendingPathComponent("Demo.catalog")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
        let born = try #require(LensWorksSemanticIndex.catalogStamp(catalogPath: catalog.path))
        try Data("x".utf8).write(to: catalog.appendingPathComponent("file"))
        #expect(LensWorksSemanticIndex.catalogStamp(catalogPath: catalog.path) == born)
        try FileManager.default.removeItem(at: catalog)
        #expect(LensWorksSemanticIndex.catalogStamp(catalogPath: catalog.path) == nil)
        try await Task.sleep(for: .milliseconds(20))
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
        let recreated = try #require(LensWorksSemanticIndex.catalogStamp(catalogPath: catalog.path))
        #expect(recreated != born)
        // A restore replaces the database inside the same folder: the stamp is the database's.
        let database = catalog.appendingPathComponent("catalog.sqlite3")
        try await Task.sleep(for: .milliseconds(20))
        try Data("first".utf8).write(to: database)
        let original = try #require(LensWorksSemanticIndex.catalogStamp(catalogPath: catalog.path))
        #expect(original != recreated)
        try FileManager.default.removeItem(at: database)
        try await Task.sleep(for: .milliseconds(20))
        try Data("restored".utf8).write(to: database)
        #expect(LensWorksSemanticIndex.catalogStamp(catalogPath: catalog.path) != original)
    }

    /// A pass whose index is deleted under it has lost what it stored before: it must not call the catalog covered.
    @Test func aPassWhoseIndexIsDeletedMidwayDoesNotRecordItselfCompleteAndTheNextPassIndexesEverything() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite3")
        let index = LensWorksSemanticIndex(url: url)
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(40)
        embedder.beforeBatch = { batch in
            if batch == 2 { for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) } }
        }
        await #expect(throws: LensWorksSemanticIndexError.recovered) { try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 8, verifyBatch: 0) }
        #expect(try await index.completeThrough() == nil)
        #expect(try await index.count() == 24, "what was stored after the deletion stays")
        embedder.beforeBatch = nil
        let finished = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 8, verifyBatch: 0)
        #expect(finished.embedded == 16)
        #expect(try await index.count() == 40)
        #expect(try await index.completeThrough() == 40)
    }

    @Test func deletingTheIndexRebuildsItOnTheNextPass() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite3")
        let index = LensWorksSemanticIndex(url: url)
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(40)
        _ = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source)
        let expected = try await index.nearest(embedder.embed(text: "green"), limit: 40).map(\.imageID)
        // Deleted while the app still has it open: the same index object notices and starts over.
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        #expect(try await index.count() == 0)
        #expect(try await index.completeThrough() == nil, "a deleted index reads as empty, not as its old contents")
        let rebuilt = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source)
        #expect(rebuilt.preparation == .created || rebuilt.preparation == .kept)
        #expect(rebuilt.embedded == 40 && FileManager.default.fileExists(atPath: url.path))
        #expect(try await index.nearest(embedder.embed(text: "green"), limit: 40).map(\.imageID) == expected)
        // Deleted while the app was not running: a fresh object creates it.
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: url.path + suffix) }
        let fresh = LensWorksSemanticIndex(url: url)
        let again = try await LensWorksSemanticPass.run(index: fresh, embedder: embedder, source: source)
        #expect(again.preparation == .created && again.embedded == 40)
        #expect(try await fresh.nearest(embedder.embed(text: "green"), limit: 40).map(\.imageID) == expected)
    }

    @Test func changingTheEmbeddingModelDiscardsOldVectorsAndReembedsEverything() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        let embedder = LensWorksStubEmbedder(identity: "model-a"), source = await populatedSource(30)
        _ = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source)
        embedder.identity = "model-b"
        // Opening for the new model is enough to drop the other model's vectors: none can be ranked by mistake.
        #expect(try await index.prepare(model: "model-b") == .modelChanged)
        #expect(try await index.count() == 0)
        #expect(try await index.completeThrough() == nil)
        #expect(try await index.nearest([1, 0, 0, 0], limit: 5).isEmpty)
        let outcome = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source)
        #expect(outcome.embedded == 30 && embedder.imagesEmbedded == 60)
        #expect(try await index.count() == 30)
        #expect(try await index.completeThrough() == 30)
        // Back to the first model: again a full re-embed, never a mix.
        embedder.identity = "model-a"
        let back = try await LensWorksSemanticPass.run(index: LensWorksSemanticIndex(url: index.url), embedder: embedder, source: source)
        #expect(back.preparation == .modelChanged && back.embedded == 30)
    }

    @Test func aRebuildInterruptedPartWayFinishesToTheSameIndexAfterReopening() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite3")
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(90)
        let reference = LensWorksSemanticIndex(url: directory.appendingPathComponent("reference.sqlite3"))
        _ = try await LensWorksSemanticPass.run(index: reference, embedder: embedder, source: source)
        let query = try await embedder.embed(text: "magenta")
        let expected = try await reference.nearest(query, limit: 90)

        var index: LensWorksSemanticIndex? = LensWorksSemanticIndex(url: url)
        _ = try await LensWorksSemanticPass.run(index: index!, embedder: embedder, source: source)
        try await index!.clear() // the rebuild starts
        #expect(try await index!.count() == 0)
        #expect(try await index!.completeThrough() == nil)
        let before = embedder.batches.count
        embedder.beforeBatch = { batch in if batch == before + 2 { throw CancellationError() } } // the process dies here
        await #expect(throws: CancellationError.self) { try await LensWorksSemanticPass.run(index: index!, embedder: embedder, source: source, batchSize: 16) }
        #expect(try await index!.count() == 32)
        index = nil // the app quits; nothing is flushed or repaired by hand
        embedder.beforeBatch = nil
        let reopened = LensWorksSemanticIndex(url: url)
        let finished = try await LensWorksSemanticPass.run(index: reopened, embedder: embedder, source: source, batchSize: 16)
        #expect(finished.preparation == .kept && finished.embedded == 58)
        #expect(try await reopened.count() == 90)
        #expect(try await reopened.completeThrough() == 90)
        let ranked = try await reopened.nearest(query, limit: 90)
        #expect(Set(ranked.map(\.imageID)) == Set(expected.map(\.imageID)))
        #expect(zip(ranked, expected).allSatisfy { abs($0.score - $1.score) < 1e-6 }, "the finished rebuild scores exactly like an index built in one go")
    }

    @Test func anUnreadableIndexFileIsReplacedAndRebuilt() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("index.sqlite3")
        try Data(repeating: 0x5a, count: 8192).write(to: url)
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(10)
        let index = LensWorksSemanticIndex(url: url)
        let outcome = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source)
        #expect(outcome.preparation == .replacedUnreadable && outcome.embedded == 10)
        #expect(try await index.count() == 10)
        // Another application's database is not a semantic index either, and is not read as one.
        let foreign = directory.appendingPathComponent("foreign.sqlite3")
        let other = LensWorksCatalogIndex(url: foreign)
        _ = try await other.selection(owner: "x")
        let replaced = LensWorksSemanticIndex(url: foreign)
        #expect(try await replaced.prepare(model: "m") == .replacedUnreadable)
        // A directory at the index path is left alone and reported.
        let blocked = directory.appendingPathComponent("blocked.sqlite3")
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: false)
        await #expect(throws: LensWorksSemanticIndexError.self) { try await LensWorksSemanticIndex(url: blocked).prepare(model: "m") }
        #expect(FileManager.default.fileExists(atPath: blocked.path))
    }

    @Test func eachCatalogHasItsOwnIndexFileNamedByItsCanonicalPath() throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let a = try LensWorksSemanticIndex.location(catalogPath: "/Volumes/Photos/A.catalog", directory: directory)
        let again = try LensWorksSemanticIndex.location(catalogPath: "/Volumes/Photos/./A.catalog", directory: directory)
        let b = try LensWorksSemanticIndex.location(catalogPath: "/Volumes/Photos/B.catalog", directory: directory)
        #expect(a == again && a != b && a.deletingLastPathComponent().path == directory.path && a.pathExtension == "sqlite3")
    }
}

// MARK: - Search service states

@Suite(.serialized) @MainActor struct LensWorksSemanticSearchServiceTests {
    private func settle(_ service: LensWorksSemanticSearch, _ done: (LensWorksSemanticSearch.State) -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while !(done(service.state) && !service.isIndexing) {
            guard ContinuousClock.now < deadline else { throw LensWorksCatalogError.message("Semantic state stayed \(service.state)") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    private func isReady(_ state: LensWorksSemanticSearch.State) -> Bool { if case .ready = state { true } else { false } }

    @Test func aMissingModelIsStatedAndNothingIsIndexedUntilItIsInstalled() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let missing = LensWorksSemanticUnavailable.modelNotInstalled("CLIP ViT-L/14: Not installed. Download it in AI Models.")
        let embedder = LensWorksStubEmbedder(unavailable: missing), source = await populatedSource(20)
        let service = LensWorksSemanticSearch(embedder: embedder, directory: directory)
        #expect(service.state == .noCatalog && service.searchUnavailableReason == "Open a catalog first.")
        await service.attach(catalogPath: "/catalog/one", source: source)
        try await settle(service) { $0 == .modelUnavailable(missing) }
        #expect(service.searchUnavailableReason == missing.message && service.summary == missing.message)
        #expect(service.rebuildUnavailableReason == missing.message)
        #expect(await source.pageFetches == 0)
        #expect(embedder.imagesEmbedded == 0, "no catalog or model work without a model")
        await #expect(throws: LensWorksSemanticUnavailable.self) { _ = try await service.query("red") }
        // The model is installed (an explicit download finished): indexing starts by itself.
        embedder.unavailable = nil
        service.recheck()
        try await settle(service, isReady)
        #expect(service.state == .ready(indexed: 20, unindexed: 0, reasons: []) && service.searchUnavailableReason == nil)
        #expect(service.summary == "Semantic search covers 20 photos.")
        let (index, vector) = try await service.query("red")
        #expect(try await index.nearest(vector, limit: 1).first?.imageID.hasSuffix("red") == true)
        _ = try await service.query("red")
        #expect(embedder.texts == ["red"], "a repeated description is not embedded again")
        await service.detach()
        #expect(service.state == .noCatalog && embedder.releases >= 1, "closing the catalog releases the model")
    }

    @Test func indexingReportsProgressCanBePausedResumedAndRebuilt() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(64)
        let (reached, signal) = AsyncStream.makeStream(of: Void.self)
        embedder.beforeBatch = { batch in
            guard batch == 2 else { return }
            signal.yield()
            try await Task.sleep(for: .seconds(30))
        }
        let service = LensWorksSemanticSearch(embedder: embedder, directory: directory, batchSize: 8)
        await service.attach(catalogPath: "/catalog/two", source: source)
        for await _ in reached { break }
        guard case .indexing(let indexed, let examined) = service.state else { Issue.record("expected indexing, found \(service.state)"); return }
        #expect(indexed == 16 && examined == 16 && service.isIndexing, "progress counts the photos stored so far")
        #expect(service.summary.contains("16 indexed") && service.searchUnavailableReason == nil, "a partial index is searchable and says so")
        #expect(service.pauseUnavailableReason == nil && service.resumeUnavailableReason == "Indexing is already running.")
        await service.pause()
        #expect(service.state == .paused(indexed: 16) && !service.isIndexing)
        #expect(service.pauseUnavailableReason == "Indexing is already paused." && service.resumeUnavailableReason == nil)
        service.schedule() // new photos arriving do not restart paused indexing
        #expect(!service.isIndexing)
        embedder.beforeBatch = nil
        service.resume()
        try await settle(service, isReady)
        #expect(service.state == .ready(indexed: 64, unindexed: 0, reasons: []) && embedder.imagesEmbedded == 64)

        // A photo edited in the catalog is re-embedded alone.
        let row = try #require(await source.row("photo-0001-green"))
        await source.edit(row.imageID, rgb: [230, 20, 20])
        await service.invalidate([.init(imageID: row.imageID, assetID: row.assetID, variantID: row.variantID)])
        try await settle(service, isReady)
        #expect(embedder.imagesEmbedded == 65)

        try await service.rebuild()
        try await settle(service, isReady)
        #expect(service.state == .ready(indexed: 64, unindexed: 0, reasons: []) && embedder.imagesEmbedded == 129)
        await service.detach()
    }

    @Test func indexingThatStartsPausedDoesNoWorkUntilResumedAndUnindexedPhotosAreCounted() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(6)
        await source.fail("photo-0002-blue", "No stored preview, and the original is offline.")
        let service = LensWorksSemanticSearch(embedder: embedder, directory: directory, automatic: false)
        await service.attach(catalogPath: "/catalog/three", source: source)
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.state == .paused(indexed: 0) && !service.isIndexing)
        #expect(await source.pageFetches == 0)
        #expect(embedder.imagesEmbedded == 0)
        service.resume()
        try await settle(service, isReady)
        #expect(service.state == .ready(indexed: 5, unindexed: 1, reasons: ["No stored preview, and the original is offline."]))
        #expect(service.summary == "Semantic search covers 5 photos; 1 could not be indexed. No stored preview, and the original is offline.")
        // Switching catalogs opens a separate index; coming back finds the first one intact.
        let other = await populatedSource(3)
        await service.attach(catalogPath: "/catalog/four", source: other)
        try await settle(service, isReady)
        #expect(service.indexedCount == 3)
        await source.fail("photo-0002-blue", nil)
        await source.resetCounters()
        await service.attach(catalogPath: "/catalog/three", source: source)
        try await settle(service, isReady)
        #expect(service.state == .ready(indexed: 6, unindexed: 0, reasons: []))
        #expect(await source.previewFetches == ["photo-0002-blue"], "only the photo that was owed is embedded")
        await service.detach()
    }

    /// The reviewer's case: a catalog recreated or restored at the same path must not inherit the old index.
    @Test func aDifferentCatalogAtTheSamePathIsIndexedFromScratch() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let embedder = LensWorksStubEmbedder()
        let service = LensWorksSemanticSearch(embedder: embedder, directory: directory)
        await service.attach(catalogPath: "/catalog/recreated", source: await populatedSource(30))
        try await settle(service, isReady)
        #expect(service.state == .ready(indexed: 30, unindexed: 0, reasons: []))
        await service.attach(catalogPath: "/catalog/recreated", source: await populatedSource(5, prefix: "restored"))
        try await settle(service, isReady)
        #expect(service.state == .ready(indexed: 5, unindexed: 0, reasons: []))
        #expect(service.lastOutcome?.rescanned == true && service.lastOutcome?.removed == 30)
        let (index, vector) = try await service.query("green")
        #expect(try await index.nearest(vector, limit: 1).first?.imageID == "restored-0001-green")
        await service.detach()

        // A real catalog folder deleted and created again keeps its path, ids and sequences: only its
        // creation stamp says it is another catalog.
        let catalog = directory.appendingPathComponent("Demo.catalog")
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
        await service.attach(catalogPath: catalog.path, source: await populatedSource(6))
        try await settle(service, isReady)
        let embedded = embedder.imagesEmbedded
        await service.attach(catalogPath: catalog.path, source: await populatedSource(6))
        try await settle(service, isReady)
        #expect(embedder.imagesEmbedded == embedded && service.lastPreparation == .kept, "reopening the same catalog embeds nothing")
        try FileManager.default.removeItem(at: catalog)
        try await Task.sleep(for: .milliseconds(20))
        try FileManager.default.createDirectory(at: catalog, withIntermediateDirectories: false)
        await service.attach(catalogPath: catalog.path, source: await populatedSource(6, shift: 3))
        try await settle(service, isReady)
        #expect(service.lastPreparation == .catalogChanged && embedder.imagesEmbedded == embedded + 6)
        #expect(service.state == .ready(indexed: 6, unindexed: 0, reasons: []))
        await service.detach()
    }

    @Test func aDescriptionQueryOnAnIdleIndexReleasesTheModelButNeverUnderAnEmbedStillRunning() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(12)
        let service = LensWorksSemanticSearch(embedder: embedder, directory: directory)
        await service.attach(catalogPath: "/catalog/idle", source: source)
        try await settle(service, isReady)
        let settled = embedder.releases
        _ = try await service.query("red")
        #expect(embedder.releases == settled + 1, "the model does not stay loaded after a search on an idle index")
        _ = try await service.query("red")
        #expect(embedder.releases == settled + 1, "a cached description loads nothing, so releases nothing")

        // Two searches overlap: the first to finish must not unload the model under the other.
        let (reached, signal) = AsyncStream.makeStream(of: Void.self)
        let (resume, gate) = AsyncStream.makeStream(of: Void.self)
        embedder.beforeText = { text in
            guard text == "blue" else { return }
            signal.yield()
            for await _ in resume { break }
        }
        let slow = Task { try await service.query("blue") }
        for await _ in reached { break }
        let before = embedder.releases
        _ = try await service.query("green")
        #expect(embedder.releases == before, "the model is still in use by the other search")
        gate.yield()
        _ = try await slow.value
        #expect(embedder.releases == before + 1 && embedder.releasesUnderAnEmbed == 0)

        // A search during an indexing pass shares the pass's residency: the pass releases when it ends.
        embedder.beforeText = nil
        let (held, holding) = AsyncStream.makeStream(of: Void.self)
        let (finish, finishing) = AsyncStream.makeStream(of: Void.self)
        embedder.beforeBatch = { _ in holding.yield(); for await _ in finish { break } }
        await source.add("photo-new-cyan", rgb: [20, 230, 230])
        service.schedule()
        for await _ in held { break }
        let during = embedder.releases
        _ = try await service.query("cyan")
        #expect(embedder.releases == during, "an indexing pass is embedding")
        finishing.yield()
        try await settle(service, isReady)
        #expect(embedder.releases == during + 1 && embedder.releasesUnderAnEmbed == 0)
        await service.detach()
    }

    @Test func anEditMadeWhileTheModelIsUnavailableIsStillOwedWhenTheModelReturns() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let missing = LensWorksSemanticUnavailable.modelUnavailable("The model volume is offline.")
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(20)
        // No verification slice: only the recorded edit may cause the re-embed.
        let first = LensWorksSemanticSearch(embedder: embedder, directory: directory, verifyBatch: 0)
        await first.attach(catalogPath: "/catalog/offline", source: source)
        try await settle(first, isReady)
        await first.detach()
        // A new session in which the model was never available, so the index was never opened for one.
        embedder.unavailable = missing
        let service = LensWorksSemanticSearch(embedder: embedder, directory: directory, verifyBatch: 0)
        await service.attach(catalogPath: "/catalog/offline", source: source)
        try await settle(service) { $0 == .modelUnavailable(missing) }
        let row = try #require(await source.row("photo-0004-cyan"))
        await source.edit(row.imageID, rgb: [230, 20, 20])
        await service.invalidate([.init(imageID: row.imageID, assetID: row.assetID, variantID: row.variantID)])
        try await settle(service) { $0 == .modelUnavailable(missing) }
        #expect(embedder.imagesEmbedded == 20)
        embedder.unavailable = nil
        await source.resetCounters()
        service.recheck()
        try await settle(service, isReady)
        #expect(embedder.imagesEmbedded == 21, "exactly the edited photo is embedded again")
        #expect(await source.previewFetches == [row.imageID])
        #expect(service.state == .ready(indexed: 20, unindexed: 0, reasons: []))
        await service.detach()
    }

    @Test func aRebuildThatCannotStartLeavesIndexingAsItWasAndRecheckOnlyRunsWhenTheModelWasMissing() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let missing = LensWorksSemanticUnavailable.modelNotInstalled("CLIP ViT-L/14: Not installed.")
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(8)
        let service = LensWorksSemanticSearch(embedder: embedder, directory: directory)
        await service.attach(catalogPath: "/catalog/rebuild", source: source)
        try await settle(service, isReady)

        // The model list changing (any download's progress) does not start a pass on a healthy index.
        let passes = service.passes
        for _ in 0..<5 { service.recheck() }
        #expect(!service.isIndexing)
        try await Task.sleep(for: .milliseconds(100))
        #expect(service.passes == passes && service.state == .ready(indexed: 8, unindexed: 0, reasons: []))

        embedder.unavailable = missing
        await #expect(throws: LensWorksSemanticUnavailable.self) { try await service.rebuild() }
        #expect(!service.isPaused && service.pauseUnavailableReason == nil, "a rebuild that could not start does not leave indexing paused")
        try await settle(service) { $0 == .modelUnavailable(missing) }
        // Indexing is automatic again: a new photo is embedded once the model is back, without Resume.
        await source.add("photo-new-red", rgb: [230, 20, 20])
        embedder.unavailable = nil
        service.recheck()
        try await settle(service, isReady)
        #expect(service.state == .ready(indexed: 9, unindexed: 0, reasons: []) && embedder.imagesEmbedded == 9)

        // Paused before the rebuild: it stays paused, whether the rebuild starts or not.
        await service.pause()
        embedder.unavailable = missing
        await #expect(throws: LensWorksSemanticUnavailable.self) { try await service.rebuild() }
        #expect(service.isPaused && service.state == .paused(indexed: 9))
        embedder.unavailable = nil
        await service.detach()
    }

    @Test func waitingCheckingUnusableIndexAndLicenceStatesSayWhy() async throws {
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        // Previews held for storage maintenance: indexing waits, says why, and can be resumed by hand.
        let embedder = LensWorksStubEmbedder(), source = await populatedSource(4)
        await source.pausePreviews("Previews are paused for storage maintenance.")
        let service = LensWorksSemanticSearch(embedder: embedder, directory: directory)
        await service.attach(catalogPath: "/catalog/waiting", source: source)
        try await settle(service) { if case .waiting = $0 { true } else { false } }
        #expect(service.state == .waiting("Previews are paused for storage maintenance. Indexing continues when previews resume.", indexed: 0))
        #expect(service.summary == "Semantic indexing is waiting · 0 photos indexed. Previews are paused for storage maintenance. Indexing continues when previews resume.")
        #expect(service.resumeUnavailableReason == nil && service.searchUnavailableReason == nil && service.pauseUnavailableReason == nil)
        await source.pausePreviews(nil)
        service.resume()
        try await settle(service, isReady)
        #expect(service.state == .ready(indexed: 4, unindexed: 0, reasons: []))
        #expect(service.resumeUnavailableReason == "Indexing is not paused; new photos are indexed automatically.")
        await service.detach()

        // The model's availability is still being established.
        let (asked, asking) = AsyncStream.makeStream(of: Void.self)
        let (answer, answering) = AsyncStream.makeStream(of: Void.self)
        let slow = LensWorksStubEmbedder()
        slow.beforeModel = { asking.yield(); for await _ in answer { break } }
        let checking = LensWorksSemanticSearch(embedder: slow, directory: directory)
        await checking.attach(catalogPath: "/catalog/checking", source: source)
        for await _ in asked { break }
        #expect(checking.state == .checking && checking.summary == "Checking the semantic search model…")
        #expect(checking.searchUnavailableReason == "The semantic search model is still being checked.")
        slow.beforeModel = nil
        answering.yield()
        try await settle(checking, isReady)
        await checking.detach()

        // Something that is not a file sits where the index belongs: it is left alone and reported.
        let blocked = try LensWorksSemanticIndex.location(catalogPath: "/catalog/blocked", directory: directory)
        try FileManager.default.createDirectory(at: blocked, withIntermediateDirectories: true)
        let unusable = LensWorksSemanticSearch(embedder: LensWorksStubEmbedder(), directory: directory)
        await unusable.attach(catalogPath: "/catalog/blocked", source: source)
        try await settle(unusable) { if case .indexUnavailable = $0 { true } else { false } }
        guard case .indexUnavailable(let reason) = unusable.state else { Issue.record("expected an unusable index"); return }
        #expect(reason.hasPrefix("The semantic index is unavailable: ") && unusable.summary == reason && unusable.searchUnavailableReason == reason)
        #expect(FileManager.default.fileExists(atPath: blocked.path) && unusable.indexedCount == 0)
        await unusable.detach()

        // Licence terms not accepted yet.
        let terms = LensWorksSemanticUnavailable.licenseRequired("CLIP ViT-L/14 has licence terms to accept in AI Models before it is used.")
        let licensed = LensWorksSemanticSearch(embedder: LensWorksStubEmbedder(unavailable: terms), directory: directory)
        await licensed.attach(catalogPath: "/catalog/licence", source: source)
        try await settle(licensed) { $0 == .modelUnavailable(terms) }
        #expect(licensed.searchUnavailableReason == terms.message && licensed.summary == terms.message && licensed.rebuildUnavailableReason == terms.message)
        await licensed.detach()
    }

    @Test func theClipModelIdentityFollowsItsFilesRoutesAndRuntimeAndAnAbsentModelIsNeverDownloaded() async throws {
        let manifest = try LWModelManifest.bundled()
        let clip = try #require(manifest.models.first { $0.id == LensWorksCLIPEmbedder.modelID })
        #expect(Set(clip.routes.map(\.task)) == ["embed_image", "embed_text"])
        let identity = LensWorksCLIPEmbedder.identity(clip, inferenceRevision: manifest.inferenceRevision)
        #expect(identity.count == 64 && identity == LensWorksCLIPEmbedder.identity(clip, inferenceRevision: manifest.inferenceRevision))
        #expect(identity != LensWorksCLIPEmbedder.identity(clip, inferenceRevision: String(repeating: "0", count: 40)), "a runtime change re-indexes")
        let other = try #require(manifest.models.first { $0.id != clip.id })
        #expect(identity != LensWorksCLIPEmbedder.identity(other, inferenceRevision: manifest.inferenceRevision), "different files re-index")

        // A store whose libraries do not hold the model: stated, not downloaded.
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let facts = LWModelRuntimeFacts(inferenceRevision: manifest.inferenceRevision, routes: Set(manifest.models.flatMap { $0.routes.map { $0.task + ":" + $0.provider } }), licenses: [:])
        let store = LWModelStore(manifest: manifest, configuration: .init(sceneWorksLibraries: [directory.appendingPathComponent("hub")], managedRoot: directory.appendingPathComponent("Models"),
                                                                         ledgerURL: directory.appendingPathComponent("ModelStore.json"), availableMemory: 64 << 30), facts: facts)
        let embedder = LensWorksCLIPEmbedder(center: LWModelCenter(store: store))
        guard case .failure(.modelNotInstalled(let message)) = await embedder.model() else { Issue.record("an absent model is reported as not installed"); return }
        #expect(message.contains("CLIP ViT-L/14") && message.contains("never downloads"))
        await #expect(throws: LensWorksSemanticUnavailable.self) { _ = try await embedder.embed(text: "a red apple") }
        #expect((try? FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("Models").path))?.isEmpty ?? true, "nothing was downloaded")
    }

    @Test func descriptionSearchCommandsAreRegistered() {
        let ids: [LensWorksCommandID] = [.semanticSearch, .clearSemanticSearch, .pauseSemanticIndexing, .resumeSemanticIndexing, .rebuildSemanticIndex]
        for id in ids { #expect(LensWorksCommandRegistry.descriptor(id).menus == ["Catalog Semantic Search"]) }
        #expect(LensWorksCommandRegistry.descriptor(.aiModels).menus.contains("Catalog Semantic Search"))
        #expect(LensWorksCommandAudit.registryProblems().isEmpty)
    }
}

// MARK: - Declared fixtures and real queries (real weights)

/// The repository's declared semantic-search acceptance set: SEMANTIC_SEARCH_FIXTURES.json.
nonisolated struct LensWorksSemanticFixtureDeclaration: Decodable {
    struct Query: Decodable { let text: String; let relevant: [String]; let minimumRank: Int }
    let schema: String
    let model: String
    let edge: Int
    let photos: [String]
    let queries: [Query]

    static func load() throws -> LensWorksSemanticFixtureDeclaration {
        let repository = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try JSONDecoder().decode(Self.self, from: Data(contentsOf: repository.appendingPathComponent("SEMANTIC_SEARCH_FIXTURES.json")))
    }
}

/// Draws the declared photographs: simple, unambiguous scenes made only with Core Graphics and
/// the system font (no external asset; the drawings are CC0-1.0).
@MainActor enum LensWorksSemanticFixtures {
    static func image(_ name: String, edge: Int) throws -> CGImage {
        let size = CGFloat(edge)
        guard let context = CGContext(data: nil, width: edge, height: edge, bitsPerComponent: 8, bytesPerRow: edge * 4, space: LWInferenceImage.sRGB,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw LensWorksCatalogError.message("No drawing context.") }
        func fill(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat) { context.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)) }
        func rect(_ x: CGFloat, _ y: CGFloat, _ w: CGFloat, _ h: CGFloat) { context.fill(CGRect(x: x * size, y: y * size, width: w * size, height: h * size)) }
        func disc(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) { context.fillEllipse(in: CGRect(x: (x - radius) * size, y: (y - radius) * size, width: radius * 2 * size, height: radius * 2 * size)) }
        func polygon(_ points: [(CGFloat, CGFloat)]) {
            context.beginPath()
            context.addLines(between: points.map { CGPoint(x: $0.0 * size, y: $0.1 * size) })
            context.closePath(); context.fillPath()
        }
        func gradient(_ top: (CGFloat, CGFloat, CGFloat), _ bottom: (CGFloat, CGFloat, CGFloat), from: CGFloat, to: CGFloat) {
            let colors = [CGColor(srgbRed: bottom.0, green: bottom.1, blue: bottom.2, alpha: 1), CGColor(srgbRed: top.0, green: top.1, blue: top.2, alpha: 1)] as CFArray
            guard let gradient = CGGradient(colorsSpace: LWInferenceImage.sRGB, colors: colors, locations: [0, 1]) else { return }
            context.saveGState(); context.clip(to: CGRect(x: 0, y: from * size, width: size, height: (to - from) * size))
            context.drawLinearGradient(gradient, start: CGPoint(x: 0, y: from * size), end: CGPoint(x: 0, y: to * size), options: [])
            context.restoreGState()
        }
        func text(_ string: String, height: CGFloat, y: CGFloat, color: NSColor) {
            let attributed = NSAttributedString(string: string, attributes: [.font: NSFont.boldSystemFont(ofSize: height * size), .foregroundColor: color])
            let previous = NSGraphicsContext.current
            NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
            let bounds = attributed.size()
            attributed.draw(at: CGPoint(x: (size - bounds.width) / 2, y: y * size))
            NSGraphicsContext.current = previous
        }
        // Core Graphics' origin is bottom-left: y = 0 is the bottom of the photograph.
        switch name {
        case "sunset-over-sea":
            gradient((0.35, 0.12, 0.35), (1.0, 0.55, 0.1), from: 0.45, to: 1)
            fill(1, 0.85, 0.3); disc(0.5, 0.47, 0.13)
            gradient((0.75, 0.35, 0.15), (0.05, 0.1, 0.3), from: 0, to: 0.45)
            fill(1, 0.7, 0.25); for step in 0..<6 { rect(0.42 - CGFloat(step) * 0.01, 0.4 - CGFloat(step) * 0.06, 0.16 + CGFloat(step) * 0.02, 0.02) }
        case "night-sky-crescent-moon":
            fill(0.02, 0.03, 0.12); rect(0, 0, 1, 1)
            fill(1, 1, 1)
            for star in 0..<60 { let x = CGFloat((star * 37) % 97) / 97, y = CGFloat((star * 61) % 89) / 89; disc(x, y, star % 5 == 0 ? 0.008 : 0.004) }
            fill(0.98, 0.95, 0.75); disc(0.68, 0.7, 0.14)
            fill(0.02, 0.03, 0.12); disc(0.74, 0.74, 0.13)
        case "green-meadow-blue-sky":
            gradient((0.2, 0.5, 0.95), (0.6, 0.8, 1), from: 0.4, to: 1)
            gradient((0.3, 0.75, 0.2), (0.1, 0.45, 0.1), from: 0, to: 0.4)
            fill(1, 1, 1); for (x, y) in [(0.25, 0.8), (0.33, 0.83), (0.4, 0.8), (0.7, 0.68), (0.78, 0.7)] as [(CGFloat, CGFloat)] { disc(x, y, 0.07) }
        case "snowy-mountains":
            gradient((0.25, 0.5, 0.9), (0.75, 0.88, 1), from: 0, to: 1)
            fill(0.38, 0.4, 0.46); polygon([(0, 0), (0.3, 0.72), (0.6, 0)]); polygon([(0.35, 0), (0.7, 0.85), (1, 0.1), (1, 0)])
            fill(1, 1, 1); polygon([(0.3, 0.72), (0.22, 0.53), (0.3, 0.57), (0.38, 0.53)]); polygon([(0.7, 0.85), (0.6, 0.6), (0.7, 0.66), (0.79, 0.6)])
        case "red-stop-sign":
            fill(0.6, 0.75, 0.9); rect(0, 0, 1, 1)
            fill(0.45, 0.45, 0.45); rect(0.47, 0, 0.06, 0.3)
            fill(1, 1, 1); polygon(octagon(0.5, 0.57, 0.37))
            fill(0.8, 0.05, 0.08); polygon(octagon(0.5, 0.57, 0.34))
            text("STOP", height: 0.2, y: 0.45, color: .white)
        case "chessboard":
            for row in 0..<8 { for column in 0..<8 {
                if (row + column) % 2 == 0 { fill(0.93, 0.9, 0.82) } else { fill(0.1, 0.1, 0.1) }
                rect(CGFloat(column) / 8, CGFloat(row) / 8, 0.125, 0.125)
            } }
        case "rainbow":
            gradient((0.35, 0.6, 0.95), (0.7, 0.85, 1), from: 0, to: 1)
            let bands: [(CGFloat, CGFloat, CGFloat)] = [(0.9, 0.1, 0.1), (1, 0.5, 0), (1, 0.9, 0.1), (0.1, 0.7, 0.2), (0.1, 0.35, 0.9), (0.45, 0.15, 0.65)]
            for (index, band) in bands.enumerated() { fill(band.0, band.1, band.2); disc(0.5, 0.1, 0.48 - CGFloat(index) * 0.045) }
            fill(0.55, 0.75, 0.98); disc(0.5, 0.1, 0.48 - CGFloat(bands.count) * 0.045)
            fill(0.2, 0.6, 0.2); rect(0, 0, 1, 0.12)
        case "red-heart":
            fill(1, 1, 1); rect(0, 0, 1, 1)
            fill(0.88, 0.05, 0.12); disc(0.36, 0.62, 0.17); disc(0.64, 0.62, 0.17); polygon([(0.205, 0.54), (0.795, 0.54), (0.5, 0.16)])
        case "yellow-smiley-face":
            fill(0.3, 0.55, 0.85); rect(0, 0, 1, 1)
            fill(1, 0.86, 0.1); disc(0.5, 0.5, 0.4)
            fill(0.1, 0.1, 0.1); disc(0.37, 0.62, 0.05); disc(0.63, 0.62, 0.05)
            disc(0.5, 0.42, 0.2); fill(1, 0.86, 0.1); disc(0.5, 0.47, 0.2)
        case "flag-of-japan":
            fill(1, 1, 1); rect(0, 0, 1, 1)
            fill(0.74, 0, 0.18); disc(0.5, 0.5, 0.2)
        case "flag-of-france":
            fill(0, 0.14, 0.58); rect(0, 0, 1 / 3, 1)
            fill(1, 1, 1); rect(1 / 3, 0, 1 / 3, 1)
            fill(0.93, 0.16, 0.22); rect(2 / 3, 0, 1 / 3, 1)
        case "traffic-light":
            fill(0.65, 0.8, 0.95); rect(0, 0, 1, 1)
            fill(0.12, 0.12, 0.12); rect(0.36, 0.1, 0.28, 0.82)
            fill(0.9, 0.1, 0.1); disc(0.5, 0.77, 0.1)
            fill(1, 0.8, 0.1); disc(0.5, 0.51, 0.1)
            fill(0.1, 0.8, 0.25); disc(0.5, 0.25, 0.1)
        default: throw LensWorksCatalogError.message("Undeclared semantic fixture \(name).")
        }
        guard let image = context.makeImage() else { throw LensWorksCatalogError.message("The fixture could not be drawn.") }
        return image
    }
    private static func octagon(_ x: CGFloat, _ y: CGFloat, _ radius: CGFloat) -> [(CGFloat, CGFloat)] {
        (0..<8).map { step in
            let angle = (CGFloat(step) + 0.5) * .pi / 4
            return (x + radius * cos(angle), y + radius * sin(angle))
        }
    }
}

/// Serves the declared fixtures as a catalog's stored previews.
actor LensWorksFixtureSemanticSource: LensWorksSemanticCatalogSource {
    private let previews: [(LensWorksSemanticRow, LWInferenceImage)]
    init(_ images: [(String, LWInferenceImage)]) {
        previews = images.enumerated().map { (.init(imageID: $0.element.0, assetID: $0.element.0, variantID: "master", sequence: Int64($0.offset + 1)), $0.element.1) }
    }
    func semanticPage(cursor: String?) async throws -> LensWorksSemanticSourcePage { .init(rows: previews.reversed().map(\.0), next: nil) }
    func semanticPreview(_ row: LensWorksSemanticRow) async throws -> LensWorksSemanticPreview {
        guard let image = previews.first(where: { $0.0.imageID == row.imageID })?.1 else { throw LensWorksCatalogError.message("No such fixture.") }
        return .init(image: image, revision: 1, recipeDigest: "fixture")
    }
    func semanticVersion(_ row: LensWorksSemanticRow) async throws -> LensWorksSemanticVersion? { .init(revision: 1, recipeDigest: "fixture") }
}

/// The fixture drawings and declaration themselves (no weights): every declared photo draws,
/// the photos differ, and every query names declared photos.
@Suite @MainActor struct LensWorksSemanticFixtureTests {
    @Test func declaredFixturesDrawDeterministicallyAndQueriesNameDeclaredPhotos() throws {
        let declaration = try LensWorksSemanticFixtureDeclaration.load()
        #expect(declaration.schema == "lensworks.s31.semantic-search-fixtures.v1" && declaration.model == LensWorksCLIPEmbedder.modelID)
        #expect(declaration.photos.count >= 12 && Set(declaration.photos).count == declaration.photos.count && declaration.queries.count >= 12)
        var seen = Set<Data>()
        for name in declaration.photos {
            let first = try LWInferenceImage(cgImage: LensWorksSemanticFixtures.image(name, edge: declaration.edge))
            let second = try LWInferenceImage(cgImage: LensWorksSemanticFixtures.image(name, edge: declaration.edge))
            #expect(first.width == declaration.edge && first.pixels == second.pixels, "\(name) draws the same pixels each time")
            #expect(seen.insert(first.pixels).inserted, "\(name) is a distinct photograph")
        }
        for query in declaration.queries {
            #expect(!query.text.isEmpty && !query.relevant.isEmpty && query.minimumRank >= 1 && query.minimumRank <= 3)
            #expect(Set(query.relevant).isSubset(of: Set(declaration.photos)), "\(query.text) names declared photos")
        }
        #expect(Set(declaration.queries.flatMap(\.relevant)) == Set(declaration.photos), "every photo is the answer to some query")
    }
}

private nonisolated let semanticInferenceLibrary = ProcessInfo.processInfo.environment["LW_INFERENCE_LIBRARY"].map { FileManager.default.fileExists(atPath: $0) } ?? false
private nonisolated let semanticRequireReal = ProcessInfo.processInfo.environment["LW_REQUIRE_REAL"] == "1"

/// The Hugging Face cache ("hub") that holds CLIP, and whether this test host may read its files:
/// `LW_INFERENCE_CLIP_HUB` (resolved by the runner script outside the test host), else the
/// SceneWorks cache when `LW_INFERENCE_REAL_WEIGHTS=1`.
private nonisolated let semanticClipGate: (hub: URL?, gate: RealWeightGate) = {
    let environment = ProcessInfo.processInfo.environment
    var hub = environment["LW_INFERENCE_CLIP_HUB"].flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0, isDirectory: true) }
    if hub == nil, environment["LW_INFERENCE_REAL_WEIGHTS"] == "1" { hub = LWModelStore.Configuration.defaultLibraries().first }
    guard semanticInferenceLibrary, let hub else { return (nil, .skip("Set LW_INFERENCE_LIBRARY and LW_INFERENCE_CLIP_HUB (or LW_INFERENCE_REAL_WEIGHTS=1)")) }
    guard let manifest = try? LWModelManifest.bundled(), let clip = manifest.models.first(where: { $0.id == LensWorksCLIPEmbedder.modelID }), let component = clip.components.first else {
        return (nil, .fail("The bundled manifest has no CLIP model."))
    }
    let snapshot = LWModelProbe.hubSnapshot(hub, component)
    let gate = RealWeightGate.evaluate(component.files.map { snapshot.appendingPathComponent($0.path) }, require: semanticRequireReal)
    if case .skip(let reason) = gate { print("::warning::Real-weight semantic search test skipped. \(reason)") }
    return (hub, gate)
}()

@Suite(.serialized, .enabled(if: semanticInferenceLibrary, "Set TEST_RUNNER_LW_INFERENCE_LIBRARY to liblensworks_inference.dylib"))
@MainActor struct LensWorksSemanticSearchRealWeightTests {
    /// AC1: real text queries retrieve the declared relevant photographs, through the real model
    /// store lease, the real inference runtime and the real index.
    @Test(.enabled("The test host cannot read the CLIP weights (see the warning); LW_REQUIRE_REAL=1 makes this a failure") { semanticClipGate.gate.shouldRun })
    func realTextQueriesRetrieveTheDeclaredRelevantPhotographs() async throws {
        if case .fail(let reason) = semanticClipGate.gate { Issue.record("\(reason)"); return }
        let hub = try #require(semanticClipGate.hub)
        let declaration = try LensWorksSemanticFixtureDeclaration.load()
        let directory = try temporaryDirectory(); defer { try? FileManager.default.removeItem(at: directory) }
        let runtime = try LWInferenceRuntime.installed()
        let store = LWModelStore(manifest: try LWModelManifest.bundled(),
                                 configuration: .init(sceneWorksLibraries: [hub], managedRoot: directory.appendingPathComponent("Models"),
                                                      ledgerURL: directory.appendingPathComponent("ModelStore.json"), availableMemory: LWMemoryBudget.current(), probeStall: 120),
                                 facts: LWModelRuntimeFacts(capabilities: try await runtime.capabilities()))
        let embedder = LensWorksCLIPEmbedder(center: LWModelCenter(store: store))
        let model = try await embedder.model().get()
        let source = LensWorksFixtureSemanticSource(try declaration.photos.map { ($0, try LWInferenceImage(cgImage: LensWorksSemanticFixtures.image($0, edge: declaration.edge))) })
        let index = LensWorksSemanticIndex(url: directory.appendingPathComponent("index.sqlite3"))
        let outcome = try await LensWorksSemanticPass.run(index: index, embedder: embedder, source: source, batchSize: 8)
        #expect(outcome.embedded == declaration.photos.count && outcome.failed == 0 && outcome.largestBatch <= 8)
        #expect(await store.residentModels == [LensWorksCLIPEmbedder.modelID], "the model stays leased while it is loaded between batches")
        #expect(try await index.count() == declaration.photos.count)

        var report: [String] = []
        for query in declaration.queries {
            let ranked = try await index.nearest(try await embedder.embed(text: query.text), limit: declaration.photos.count)
            let ranks = query.relevant.compactMap { name in ranked.firstIndex { $0.imageID == name }.map { $0 + 1 } }
            let best = ranks.min() ?? Int.max
            report.append("\(best <= query.minimumRank ? "ok  " : "MISS") rank \(best) (needs ≤ \(query.minimumRank)) “\(query.text)” → \(ranked.prefix(3).map { "\($0.imageID) \(String(format: "%.3f", $0.score))" }.joined(separator: ", "))")
            #expect(best <= query.minimumRank, "“\(query.text)” should rank one of \(query.relevant) within the top \(query.minimumRank); got \(ranked.prefix(3).map(\.imageID))")
        }
        print("Semantic search fixtures (\(model.name)):\n" + report.joined(separator: "\n"))

        // The same vectors answer from a reopened index (nothing lives only in memory), and a pass over
        // an unchanged catalog embeds nothing.
        let reopened = LensWorksSemanticIndex(url: index.url)
        let idle = try await LensWorksSemanticPass.run(index: reopened, embedder: embedder, source: source, batchSize: 8)
        #expect(idle.preparation == .kept && idle.embedded == 0)
        await embedder.release()
        #expect(await store.residentModels.isEmpty)
        #expect(await store.leases.modelLeaseCounts[LensWorksCLIPEmbedder.modelID] == nil, "releasing unloads the model and drops its lease")
    }
}
