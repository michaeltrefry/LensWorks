import CryptoKit
import Foundation

/// Binds a catalog to its rebuildable semantic index and the matched image/text embedder. The index
/// file lives in LensWorks' own application support (never in the catalog, never beside originals);
/// its version records the pinned model assets, the embedded pixel source and the recipe, and the
/// embedding space and dimension the model itself reports for text queries. Image vectors must
/// arrive in that same space or the index refuses to store them.
@MainActor
final class LensWorksSemanticSearch {
    static let source = "catalog-preview-thumbnail-512"
    static let recipe = "clip-vit-l14 rgb8 sRGB preview, L2-normalized, cosine"
    /// Interactive searches embed at most this many missing photos before ranking.
    static let searchSyncBudget = 256

    let index: LensWorksSemanticIndex
    let embedder: any LWSemanticEmbedder
    private let assets: [String]
    private let imageProvider: String
    private let textProvider: String
    private var preparing: Task<Void, any Error>?
    private var prepared = false

    init(indexURL: URL, embedder: any LWSemanticEmbedder, assets: [String],
         imageProvider: String = LWModelStoreEmbedder.defaultImageProvider, textProvider: String = LWModelStoreEmbedder.defaultTextProvider) {
        index = LensWorksSemanticIndex(url: indexURL)
        self.embedder = embedder; self.assets = assets
        self.imageProvider = imageProvider; self.textProvider = textProvider
    }

    /// `Semantic/<digest of the catalog path>.sqlite3` under Application Support.
    static func indexURL(forCatalog path: String, in support: URL = LensWorksUserState.applicationSupport) -> URL {
        let digest = SHA256.hash(data: Data(path.utf8)).prefix(12).map { String(format: "%02x", $0) }.joined()
        return support.appendingPathComponent("Semantic", isDirectory: true).appendingPathComponent(digest + ".sqlite3")
    }

    /// The application's search for one catalog, or nil when the bundled manifest cannot name the model.
    static func application(catalogPath: String) -> LensWorksSemanticSearch? {
        guard let manifest = try? LWModelManifest.bundled(),
              let model = manifest.models.first(where: { $0.id == LWModelStoreEmbedder.defaultModelID }) else { return nil }
        return LensWorksSemanticSearch(indexURL: indexURL(forCatalog: catalogPath), embedder: LWModelStoreEmbedder.application,
                                       assets: assets(of: model))
    }

    nonisolated static func assets(of model: LWModelManifest.Model) -> [String] {
        model.components.map { "\($0.repository)@\($0.revision)" }
    }

    /// Adopts the index version. The space and dimension come from the model's text side; a first
    /// image embedding in a different space is rejected by the index when it is synchronized.
    func prepare() async throws {
        if prepared { return }
        if let preparing { return try await preparing.value }
        let task = Task { [self] in
            let probe = try await embedder.embedTexts(["lensworks"])
            let version = LWSemanticIndexVersion(imageProvider: imageProvider, textProvider: textProvider, space: probe.space,
                                                 dimension: probe.dimension, assets: assets, source: Self.source, recipe: Self.recipe)
            try await index.adopt(version)
            prepared = true
        }
        preparing = task
        defer { preparing = nil }
        try await task.value
    }

    func sync(_ candidates: [LWSemanticCandidate], limit: Int) async throws -> LWSemanticSyncReport {
        try await prepare()
        return try await index.sync(candidates, limit: limit, embedder: embedder)
    }

    func search(_ query: String, within: Set<String>, limit: Int) async throws -> [LWSemanticMatch] {
        try await prepare()
        return try await index.search(query, within: within, limit: limit, embedder: embedder)
    }
}
