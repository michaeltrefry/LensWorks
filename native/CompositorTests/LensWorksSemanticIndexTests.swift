import Foundation
import Testing
@testable import Compositor

/// Deterministic fixture embedder: each concept word owns one axis of a shared 4-d space, so a
/// text query and a photo tagged with the same concept land on the same axis.
private nonisolated final class FixtureEmbedder: LWSemanticEmbedder, @unchecked Sendable {
    static let concepts = ["beach", "forest", "city", "snow"]
    let imageSpace: String
    let textSpace: String
    private let lock = NSLock()
    private var _imageCalls = 0
    var imageCalls: Int { lock.lock(); defer { lock.unlock() }; return _imageCalls }

    init(imageSpace: String = "fixture", textSpace: String = "fixture") { self.imageSpace = imageSpace; self.textSpace = textSpace }

    func embedImages(_ images: [LWInferenceImage]) async throws -> LWSemanticVectors {
        lock.lock(); _imageCalls += images.count; lock.unlock()
        // The first pixel byte selects the concept axis (plus a small shared component).
        let vectors = images.map { image -> [Float] in
            var v: [Float] = [0.05, 0.05, 0.05, 0.05]
            v[Int(image.pixels[0]) % 4] = 1
            return v
        }
        return LWSemanticVectors(space: imageSpace, dimension: 4, vectors: vectors)
    }

    func embedTexts(_ texts: [String]) async throws -> LWSemanticVectors {
        let vectors = texts.map { text -> [Float] in
            var v: [Float] = [0, 0, 0, 0]
            for (i, word) in Self.concepts.enumerated() where text.lowercased().contains(word) { v[i] = 1 }
            return v.contains { $0 != 0 } ? v : [0.5, 0.5, 0.5, 0.5]
        }
        return LWSemanticVectors(space: textSpace, dimension: 4, vectors: vectors)
    }
}

private nonisolated func photo(_ id: String, concept: Int, stamp: String = "r1") -> LWSemanticCandidate {
    LWSemanticCandidate(id: id, stamp: stamp) {
        try LWInferenceImage(width: 1, height: 1, channels: 3, alpha: .none, pixels: Data([UInt8(concept), 0, 0]))
    }
}

private nonisolated func version(recipe: String = "recipe-1", assets: [String] = ["clip@aaaa"], space: String = "fixture") -> LWSemanticIndexVersion {
    LWSemanticIndexVersion(imageProvider: "img", textProvider: "txt", space: space, dimension: 4, assets: assets,
                           source: "catalog-preview-thumbnail-512", recipe: recipe)
}

private nonisolated func tempIndexURL() -> URL {
    FileManager.default.temporaryDirectory.appendingPathComponent("lw-semantic-\(UUID().uuidString)/Semantic.sqlite3")
}

@Suite(.serialized) nonisolated struct LensWorksSemanticIndexTests {
    static let library = [photo("beach-1", concept: 0), photo("forest-1", concept: 1), photo("city-1", concept: 2),
                          photo("snow-1", concept: 3), photo("beach-2", concept: 0)]

    @Test func textQueryRetrievesSemanticallyRelevantPhotos() async throws {
        let index = LensWorksSemanticIndex(url: tempIndexURL())
        let embedder = FixtureEmbedder()
        try await index.adopt(version())
        let report = try await index.sync(Self.library, embedder: embedder)
        #expect(report.embedded == 5)
        let beach = try await index.search("a sunny beach", embedder: embedder)
        #expect(Set(beach.prefix(2).map(\.id)) == ["beach-1", "beach-2"])
        let snow = try await index.search("snow", embedder: embedder)
        #expect(snow.first?.id == "snow-1")
    }

    @Test func searchCombinesWithCatalogFilters() async throws {
        let index = LensWorksSemanticIndex(url: tempIndexURL())
        let embedder = FixtureEmbedder()
        try await index.adopt(version())
        _ = try await index.sync(Self.library, embedder: embedder)
        // A catalog filter (for example a rating) admitted only these photos.
        let filtered = try await index.search("beach", within: ["beach-2", "city-1"], embedder: embedder)
        #expect(filtered.map(\.id) == ["beach-2", "city-1"])
        #expect(try await index.search("beach", within: [], embedder: embedder).isEmpty)
    }

    @Test func syncIsIncrementalAndInvalidatesStaleEntries() async throws {
        let index = LensWorksSemanticIndex(url: tempIndexURL())
        let embedder = FixtureEmbedder()
        try await index.adopt(version())
        _ = try await index.sync(Self.library, embedder: embedder)
        let again = try await index.sync(Self.library, embedder: embedder)
        #expect(again.embedded == 0 && again.upToDate == 5 && embedder.imageCalls == 5)
        // One photo was edited (new stamp) and now looks like a forest.
        let edited = Self.library.map { $0.id == "beach-2" ? photo("beach-2", concept: 1, stamp: "r2") : $0 }
        let changed = try await index.sync(edited, embedder: embedder)
        #expect(changed.embedded == 1 && embedder.imageCalls == 6)
        #expect(try await index.search("beach", embedder: embedder).first?.id == "beach-1")
        // A removed photo is pruned.
        #expect(try await index.prune(keeping: Set(edited.map(\.id)).subtracting(["city-1"])) == 1)
        #expect(try await index.count() == 4)
    }

    @Test func syncIsBoundedAndCancellable() async throws {
        let index = LensWorksSemanticIndex(url: tempIndexURL())
        let embedder = FixtureEmbedder()
        try await index.adopt(version())
        let bounded = try await index.sync(Self.library, limit: 3, embedder: embedder)
        #expect(bounded.embedded == 3 && bounded.remaining == 2)
        let task = Task { try await index.sync(Self.library, embedder: embedder) }
        task.cancel()
        let cancelled = try await task.value
        #expect(cancelled.cancelled)
        // Resuming completes the rest without redoing committed work.
        let before = embedder.imageCalls
        let resumed = try await index.sync(Self.library, embedder: embedder)
        #expect(try await index.count() == 5 && embedder.imageCalls - before == resumed.embedded)
    }

    @Test func versionChangeRebuildsAndDeletionRecovers() async throws {
        let url = tempIndexURL()
        let index = LensWorksSemanticIndex(url: url)
        let embedder = FixtureEmbedder()
        #expect(try await index.adopt(version()) == false)
        _ = try await index.sync(Self.library, embedder: embedder)
        #expect(try await index.adopt(version()) == false, "same version keeps entries")
        #expect(try await index.count() == 5)
        #expect(try await index.adopt(version(assets: ["clip@bbbb"])) == true, "a changed model asset invalidates")
        #expect(try await index.count() == 0)
        #expect(try await index.adopt(version(recipe: "recipe-2")) == true, "a changed recipe invalidates")
        // Deleting the index file recovers by rebuilding.
        await index.deleteIndexFiles()
        try await index.adopt(version())
        let rebuilt = try await index.sync(Self.library, embedder: embedder)
        #expect(rebuilt.embedded == 5)
    }

    @Test func mismatchedSpacesAreRejected() async throws {
        let index = LensWorksSemanticIndex(url: tempIndexURL())
        try await index.adopt(version())
        let wrongImages = FixtureEmbedder(imageSpace: "other")
        await #expect(throws: LWSemanticError.self) { _ = try await index.sync(Self.library, embedder: wrongImages) }
        #expect(try await index.count() == 0, "nothing from a mismatched space is stored")
        _ = try await index.sync(Self.library, embedder: FixtureEmbedder())
        let wrongText = FixtureEmbedder(textSpace: "other")
        await #expect(throws: LWSemanticError.self) { _ = try await index.search("beach", embedder: wrongText) }
    }

    @Test func unavailablePhotosAreReportedNotFatal() async throws {
        let index = LensWorksSemanticIndex(url: tempIndexURL())
        try await index.adopt(version())
        struct Offline: Error {}
        let offline = LWSemanticCandidate(id: "offline", stamp: "r1") { throw Offline() }
        let report = try await index.sync([offline, photo("snow-1", concept: 3)], embedder: FixtureEmbedder())
        #expect(report.unavailable == ["offline"] && report.embedded == 1)
    }

    @Test func adoptDuringSyncDiscardsVectorsOfTheOldVersion() async throws {
        let index = LensWorksSemanticIndex(url: tempIndexURL())
        try await index.adopt(version())
        let adopting = AdoptingEmbedder(index: index, replacement: version(assets: ["clip@bbbb"]))
        let report = try await index.sync(Self.library, embedder: adopting)
        #expect(report.cancelled && report.embedded == 0, "the superseded batch is not written")
        #expect(try await index.count() == 0)
        // Nothing stamped as current was kept, so the new version rebuilds every photo.
        let rebuilt = try await index.sync(Self.library, embedder: FixtureEmbedder())
        #expect(rebuilt.embedded == 5 && rebuilt.upToDate == 0)
    }

    @Test func foreignFileIsReplacedOnlyWhenItIsNotOurs() async throws {
        let url = tempIndexURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not a database at all, just bytes".utf8).write(to: url)
        let index = LensWorksSemanticIndex(url: url)
        try await index.adopt(version())
        #expect(try await index.count() == 0)
    }
}
