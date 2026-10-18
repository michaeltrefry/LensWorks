import CoreGraphics
import Foundation
import Testing
@testable import Compositor

/// Re-enters the index (adopting a new version) while its `sync` is suspended in the embedder.
nonisolated final class AdoptingEmbedder: LWSemanticEmbedder, @unchecked Sendable {
    let index: LensWorksSemanticIndex
    let replacement: LWSemanticIndexVersion
    init(index: LensWorksSemanticIndex, replacement: LWSemanticIndexVersion) { self.index = index; self.replacement = replacement }

    func embedImages(_ images: [LWInferenceImage]) async throws -> LWSemanticVectors {
        try await index.adopt(replacement)
        return LWSemanticVectors(space: "fixture", dimension: 4, vectors: images.map { _ in [1, 0, 0, 0] })
    }
    func embedTexts(_ texts: [String]) async throws -> LWSemanticVectors {
        LWSemanticVectors(space: "fixture", dimension: 4, vectors: texts.map { _ in [1, 0, 0, 0] })
    }
}

/// The production embedder against a scripted job: requests name the matched CLIP routes and the
/// reported space and dimension flow through unchanged for the index to check.
@Suite(.serialized) nonisolated struct LensWorksModelStoreEmbedderTests {
    private final class Recorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _requests: [String] = []
        var requests: [String] { lock.lock(); defer { lock.unlock() }; return _requests }
        func add(_ json: String) { lock.lock(); _requests.append(json); lock.unlock() }
    }

    private static func embedder(recorder: Recorder, imageSpace: String = "clip-l14", textSpace: String = "clip-l14", dimension: Int = 3) -> LWModelStoreEmbedder {
        LWModelStoreEmbedder { id, _, inputs, request in
            let registry = LWModelLeaseRegistry()
            let root = FileManager.default.temporaryDirectory
            let lease = LWModelLease(modelID: id, roots: [LWComponentRoot(root: root, source: .managed)], weights: .dir(root), tokenizer: nil, registry: registry)
            let built = request(lease)
            let json = String(decoding: built.json, as: UTF8.self)
            recorder.add(json)
            let isImage = json.contains("\"task\":\"embed_image\"")
            let count = isImage ? inputs.count : 1
            let body = """
            {"task":"\(isImage ? "embed_image" : "embed_text")","provider":"p","inference_revision":"r","model_reused":false,"input_conversions":[],
             "embeddings":\(Array(repeating: Array(repeating: 0.5, count: dimension), count: count)),"embedding_dim":\(dimension),"space":"\(isImage ? imageSpace : textSpace)"}
            """
            let decoder = JSONDecoder()
            decoder.keyDecodingStrategy = .convertFromSnakeCase
            let result = try decoder.decode(LWInferenceResult.self, from: Data(body.utf8))
            let (stream, continuation) = AsyncStream.makeStream(of: LWInferenceEvent.self)
            continuation.yield(.completed(result)); continuation.finish()
            return LWModelJob(lease: lease, events: stream, cancel: {})
        }
    }

    @Test func imageAndTextRequestsUseTheMatchedClipRoutes() async throws {
        let recorder = Recorder()
        let embedder = Self.embedder(recorder: recorder)
        let image = try LWInferenceImage(width: 1, height: 1, channels: 3, alpha: .none, pixels: Data([1, 2, 3]))
        let images = try await embedder.embedImages([image, image])
        let texts = try await embedder.embedTexts(["a beach"])
        #expect(images.vectors.count == 2 && texts.vectors.count == 1)
        #expect(images.space == texts.space && images.dimension == texts.dimension)
        let sent = recorder.requests
        #expect(sent.count == 2 && sent[0].contains("\"provider\":\"clip_vit_l14\"") && sent[1].contains("\"provider\":\"clip_vit_l14_text\""))
    }

    @Test func indexRejectsAnImageSpaceThatDiffersFromTheTextSpace() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-semantic-\(UUID().uuidString)/Semantic.sqlite3")
        let index = LensWorksSemanticIndex(url: url)
        let version = LWSemanticIndexVersion(imageProvider: "clip_vit_l14", textProvider: "clip_vit_l14_text", space: "clip-l14", dimension: 3,
                                             assets: ["openai/clip-vit-large-patch14@32bd64288804d66eefd0ccbe215aa642df71cc41"],
                                             source: "catalog-preview-thumbnail-512", recipe: "r")
        try await index.adopt(version)
        let candidate = LWSemanticCandidate(id: "a", stamp: "s") { try LWInferenceImage(width: 1, height: 1, channels: 3, alpha: .none, pixels: Data([1, 2, 3])) }
        let mismatched = Self.embedder(recorder: Recorder(), imageSpace: "other-space")
        await #expect(throws: LWSemanticError.self) { _ = try await index.sync([candidate], embedder: mismatched) }
        let wrongDimension = Self.embedder(recorder: Recorder(), dimension: 5)
        await #expect(throws: LWSemanticError.self) { _ = try await index.sync([candidate], embedder: wrongDimension) }
        #expect(try await index.count() == 0)
        let matched = try await index.sync([candidate], embedder: Self.embedder(recorder: Recorder()))
        #expect(matched.embedded == 1)
    }

    @Test func shippedManifestDeclaresBothRoutesOfTheSemanticModel() throws {
        let manifest = try LWModelManifest.bundled()
        let model = try #require(manifest.models.first { $0.id == LWModelStoreEmbedder.defaultModelID })
        let routes = Set(model.routes.map(\.key))
        #expect(routes == ["embed_image:\(LWModelStoreEmbedder.defaultImageProvider)", "embed_text:\(LWModelStoreEmbedder.defaultTextProvider)"])
        #expect(LensWorksSemanticSearch.assets(of: model) == ["openai/clip-vit-large-patch14@32bd64288804d66eefd0ccbe215aa642df71cc41"])
    }
}

// MARK: - Real weights

private nonisolated let semanticLibrary = ProcessInfo.processInfo.environment["LW_INFERENCE_LIBRARY"]
private nonisolated let semanticClipDirectory = ProcessInfo.processInfo.environment["LW_SEMANTIC_CLIP_DIR"]
private nonisolated let runSemanticRealWeights = (semanticLibrary.map { FileManager.default.fileExists(atPath: $0) } ?? false)
    && (semanticClipDirectory.map { FileManager.default.fileExists(atPath: $0 + "/model.safetensors") } ?? false)

/// The real inference runtime on the CLIP ViT-L/14 weights, with no model store in between.
private nonisolated struct RuntimeClipEmbedder: LWSemanticEmbedder {
    let runtime: LWInferenceRuntime
    let weights: URL

    func embedImages(_ images: [LWInferenceImage]) async throws -> LWSemanticVectors {
        let job = try await runtime.start(.embedImage(provider: "clip_vit_l14", weights: .dir(weights), LWEmbedImageParams(inputs: Array(images.indices))), inputs: images)
        defer { job.release() }
        return try await LWSemanticJob.vectors(events: job.events, cancel: { job.cancel() })
    }

    func embedTexts(_ texts: [String]) async throws -> LWSemanticVectors {
        let job = try await runtime.start(.embedText(provider: "clip_vit_l14_text", weights: .dir(weights), LWEmbedTextParams(texts: texts)))
        defer { job.release() }
        return try await LWSemanticJob.vectors(events: job.events, cancel: { job.cancel() })
    }
}

/// Declared evaluation fixtures: solid colour photographs and the plain-language queries that must
/// retrieve them first. Runs only where the pinned CLIP weights are present
/// (`LW_INFERENCE_LIBRARY` and `LW_SEMANTIC_CLIP_DIR` naming the snapshot directory).
@Suite(.serialized, .enabled(if: runSemanticRealWeights, "Set LW_INFERENCE_LIBRARY and LW_SEMANTIC_CLIP_DIR (CLIP ViT-L/14 snapshot) to run real-weight semantic retrieval"))
nonisolated struct LensWorksSemanticRealWeightTests {
    static let fixtures: [(id: String, rgb: (UInt8, UInt8, UInt8), query: String)] = [
        ("red", (220, 30, 30), "a solid red color"),
        ("green", (30, 170, 50), "a solid green color"),
        ("blue", (30, 60, 220), "a solid blue color"),
        ("black", (8, 8, 8), "a solid black color"),
        ("white", (247, 247, 247), "a solid white color"),
    ]

    private static func swatch(_ rgb: (UInt8, UInt8, UInt8)) throws -> LWInferenceImage {
        var data = Data(count: 64 * 64 * 4)
        data.withUnsafeMutableBytes { raw in
            for i in stride(from: 0, to: raw.count, by: 4) { raw[i] = rgb.0; raw[i + 1] = rgb.1; raw[i + 2] = rgb.2; raw[i + 3] = 255 }
        }
        return try LWInferenceImage(width: 64, height: 64, channels: 4, alpha: .straight, pixels: data)
    }

    @Test func realClipRetrievesTheDeclaredFixtures() async throws {
        let embedder = RuntimeClipEmbedder(runtime: try LWInferenceRuntime.installed(), weights: URL(fileURLWithPath: try #require(semanticClipDirectory)))
        let probe = try await embedder.embedTexts(["probe"])
        let images = try await embedder.embedImages([try Self.swatch(Self.fixtures[0].rgb)])
        #expect(images.space == probe.space && images.dimension == probe.dimension, "image and text sides share one space and dimension")
        #expect(probe.dimension == 768)

        let url = FileManager.default.temporaryDirectory.appendingPathComponent("lw-semantic-\(UUID().uuidString)/Semantic.sqlite3")
        let index = LensWorksSemanticIndex(url: url)
        try await index.adopt(LWSemanticIndexVersion(imageProvider: "clip_vit_l14", textProvider: "clip_vit_l14_text", space: probe.space, dimension: probe.dimension,
                                                     assets: ["openai/clip-vit-large-patch14@32bd64288804d66eefd0ccbe215aa642df71cc41"],
                                                     source: "catalog-preview-thumbnail-512", recipe: "test"))
        let candidates = try Self.fixtures.map { fixture -> LWSemanticCandidate in
            let image = try Self.swatch(fixture.rgb)
            return LWSemanticCandidate(id: fixture.id, stamp: "r1") { image }
        }
        let report = try await index.sync(candidates, embedder: embedder)
        #expect(report.embedded == Self.fixtures.count)
        for fixture in Self.fixtures {
            let matches = try await index.search(fixture.query, embedder: embedder)
            #expect(matches.first?.id == fixture.id, "\(fixture.query) → \(matches.map(\.id))")
        }
        // The same retrieval restricted by a catalog filter that admits only two photos.
        let filtered = try await index.search("a solid blue color", within: ["red", "blue"], embedder: embedder)
        #expect(filtered.map(\.id) == ["blue", "red"])
    }
}
