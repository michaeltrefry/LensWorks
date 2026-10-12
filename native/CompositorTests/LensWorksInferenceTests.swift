import CoreGraphics
import Foundation
import Security
import Testing
@testable import Compositor

private nonisolated let inferenceLibrary = ProcessInfo.processInfo.environment["LW_INFERENCE_LIBRARY"]
private nonisolated let hasLibrary = inferenceLibrary.map { FileManager.default.fileExists(atPath: $0) } ?? false

/// `LW_INFERENCE_SANA_SPRINT_DIR`, else the SceneWorks Hugging Face cache snapshot. The cache
/// may live on another volume (here ~/.cache/huggingface is a link to /Volumes/Models), where
/// macOS privacy consent can block the test host's first read; resolution therefore runs off
/// the test thread with a deadline and reports that case instead of hanging the runner.
private nonisolated func resolveSanaSprintQ4(timeout: TimeInterval = 20) -> Result<URL, LWInferenceError> {
    if let dir = ProcessInfo.processInfo.environment["LW_INFERENCE_SANA_SPRINT_DIR"], !dir.isEmpty {
        return .success(URL(fileURLWithPath: dir))
    }
    final class Box: @unchecked Sendable { var url: URL? }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    DispatchQueue.global(qos: .userInitiated).async {
        let snapshots = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".cache/huggingface/hub/models--SceneWorks--Sana_Sprint_1.6B_1024px_mlx/snapshots")
        let candidates = (try? FileManager.default.contentsOfDirectory(at: snapshots, includingPropertiesForKeys: nil)) ?? []
        box.url = candidates.map { $0.appendingPathComponent("q4") }.first { FileManager.default.fileExists(atPath: $0.path) }
        done.signal()
    }
    guard done.wait(timeout: .now() + timeout) == .success else {
        return .failure(.libraryUnavailable("Reading the model cache timed out; grant the test host access to the model volume or set LW_INFERENCE_SANA_SPRINT_DIR."))
    }
    guard let url = box.url else { return .failure(.libraryUnavailable("Sana Sprint q4 weights are not in the SceneWorks model cache.")) }
    return .success(url)
}

/// Opens `file` and reads its first 4 KB on a background thread with a deadline. Returns nil when
/// readable, else why not. A model volume that macOS privacy consent withholds from the (ad-hoc
/// signed, rebuilt) test host answers EPERM, or blocks `open` instead of failing; the blocked
/// thread is abandoned, never joined.
nonisolated func probeWeightFile(_ file: URL, timeout: TimeInterval) -> String? {
    final class Box: @unchecked Sendable { var failure: String? = "no answer" }
    let box = Box()
    let done = DispatchSemaphore(value: 0)
    let thread = Thread {
        let fd = open(file.path, O_RDONLY | O_CLOEXEC)
        if fd < 0 {
            let code = errno
            box.failure = code == EPERM || code == EACCES ? "access denied (\(String(cString: strerror(code))))" : String(cString: strerror(code))
        } else {
            var buffer = [UInt8](repeating: 0, count: 4096)
            let count = read(fd, &buffer, buffer.count)
            box.failure = count > 0 ? nil : "read failed (\(count < 0 ? String(cString: strerror(errno)) : "empty file"))"
            close(fd)
        }
        done.signal()
    }
    thread.start()
    guard done.wait(timeout: .now() + timeout) == .success else {
        return "no answer within \(String(format: "%g", timeout)) s (blocked, typically by macOS privacy consent)"
    }
    return box.failure
}

/// The in-host gate for real-weight tests. The runner script resolves the weights outside the
/// test host, but the test host itself may still be denied (or blocked) by macOS privacy consent
/// for the model volume: that is a skip with a warning, unless LW_REQUIRE_REAL=1 makes it a failure.
nonisolated enum RealWeightGate: Equatable {
    case run
    case skip(String)
    case fail(String)

    var shouldRun: Bool { if case .skip = self { return false }; return true }

    static func evaluate(_ files: [URL], require: Bool, timeout: TimeInterval = 20) -> RealWeightGate {
        for file in files {
            guard let failure = probeWeightFile(file, timeout: timeout) else { continue }
            let reason = "The test host cannot read \(file.path): \(failure). If the model cache is on another volume, grant the LensWorks development build access to it in Privacy & Security."
            return require ? .fail("LW_REQUIRE_REAL=1: \(reason)") : .skip(reason)
        }
        return .run
    }
}

private nonisolated let requireRealWeights = ProcessInfo.processInfo.environment["LW_REQUIRE_REAL"] == "1"

/// Resolved once per test run: the Sana Sprint q4 directory and whether this host may read it.
private nonisolated let sanaSprintGate: (URL?, RealWeightGate) = {
    guard runRealWeights else { return (nil, .skip("LW_INFERENCE_REAL_WEIGHTS is not set")) }
    switch resolveSanaSprintQ4() {
    case .failure(let error):
        let reason = "\(error)"
        if requireRealWeights { return (nil, .fail("LW_REQUIRE_REAL=1: \(reason)")) }
        print("::warning::Real-weight test skipped. \(reason)")
        return (nil, .skip(reason))
    case .success(let weights):
        let files = ["text_encoder/gemma-2-2b-it.safetensors", "transformer/diffusion_pytorch_model.safetensors", "vae/diffusion_pytorch_model.safetensors"]
            .map { weights.appendingPathComponent($0) }
        let gate = RealWeightGate.evaluate(files, require: requireRealWeights)
        if case .skip(let reason) = gate { print("::warning::Real-weight test skipped. \(reason)") }
        return (weights, gate)
    }
}()

/// The app bundle layout build-native.sh produces: the dylib in `Contents/Helpers`, the
/// metallib in `Contents/Resources` (sealed by the app signature).
private nonisolated func bundledMetallib(for library: URL) -> URL {
    library.deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/mlx.metallib")
}

private nonisolated let runRealWeights = hasLibrary && ProcessInfo.processInfo.environment["LW_INFERENCE_REAL_WEIGHTS"] == "1"

/// The real-weight gate itself, on files this test creates (no weights or adapter needed).
@Suite nonisolated struct LensWorksRealWeightGateTests {
    @Test func readableDeniedAndBlockedWeightFilesRunSkipOrFail() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lw-gate-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let readable = dir.appendingPathComponent("readable.safetensors")
        try Data(repeating: 7, count: 8192).write(to: readable)
        #expect(RealWeightGate.evaluate([readable], require: false, timeout: 2) == .run)

        let denied = dir.appendingPathComponent("denied.safetensors")
        try Data(repeating: 7, count: 8192).write(to: denied)
        #expect(chmod(denied.path, 0o000) == 0)
        defer { _ = chmod(denied.path, 0o600) }
        guard case .skip(let reason) = RealWeightGate.evaluate([readable, denied], require: false, timeout: 2) else {
            Issue.record("a denied weight file skips"); return
        }
        #expect(reason.contains("access denied") && reason.contains(denied.path))
        guard case .fail(let required) = RealWeightGate.evaluate([denied], require: true, timeout: 2) else {
            Issue.record("LW_REQUIRE_REAL=1 turns the skip into a failure"); return
        }
        #expect(required.hasPrefix("LW_REQUIRE_REAL=1"))

        // open(O_RDONLY) on a FIFO blocks in the kernel like a privacy-withheld volume.
        let blocked = dir.appendingPathComponent("blocked.fifo")
        #expect(mkfifo(blocked.path, 0o600) == 0)
        let started = Date()
        guard case .skip(let timedOut) = RealWeightGate.evaluate([blocked], require: false, timeout: 0.5) else {
            Issue.record("a blocked read skips at the deadline"); return
        }
        #expect(Date().timeIntervalSince(started) < 3 && timedOut.contains("no answer"))
        // Release the abandoned probe thread.
        let writer = open(blocked.path, O_WRONLY | O_NONBLOCK)
        if writer >= 0 { close(writer) }
    }
}

/// Pixel, alpha and colour-space conversion at the Swift side of the boundary (no adapter needed).
@Suite nonisolated struct LensWorksInferenceBufferTests {
    @Test func cgImageInputIsColorManagedIntoSRGBPremultiplied() throws {
        // Pure Display P3 green is outside sRGB; conversion must clip into sRGB, not reinterpret bytes.
        let p3 = CGColorSpace(name: CGColorSpace.displayP3)!
        let context = CGContext(data: nil, width: 2, height: 1, bitsPerComponent: 8, bytesPerRow: 8, space: p3,
                                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        context.setFillColor(CGColor(colorSpace: p3, components: [0, 1, 0, 1])!)
        context.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        context.setFillColor(CGColor(colorSpace: p3, components: [1, 1, 1, 0.5])!)
        context.fill(CGRect(x: 1, y: 0, width: 1, height: 1))
        let image = try LWInferenceImage(cgImage: context.makeImage()!)
        #expect(image.alpha == .premultiplied && image.channels == 4 && image.width == 2)
        let p = [UInt8](image.pixels)
        #expect(p[0] < 10 && p[1] > 245 && p[2] < 10 && p[3] == 255, "P3 green clipped to sRGB green: \(p[0..<4])")
        #expect(p[7] >= 126 && p[7] <= 129 && abs(Int(p[4]) - Int(p[7])) <= 2, "white at 50% stays premultiplied: \(p[4..<8])")
        let straight = image.straightened()
        #expect(straight.alpha == .straight)
        let s = [UInt8](straight.pixels)
        #expect(s[4] >= 253 && s[7] == p[7], "straight white restores full colour: \(s[4..<8])")
    }

    @Test func straightAndPremultipliedConvertBothWaysAndTagSRGB() throws {
        let straight = try LWInferenceImage(width: 2, height: 1, channels: 4, alpha: .straight, pixels: Data([200, 100, 50, 255, 200, 100, 50, 64]))
        let pre = straight.premultiplied()
        #expect([UInt8](pre.pixels) == [200, 100, 50, 255, 50, 25, 13, 64])
        let back = pre.straightened()
        for (a, b) in zip([UInt8](back.pixels), [UInt8](straight.pixels)) { #expect(abs(Int(a) - Int(b)) <= 2) }
        let cg = try #require(straight.cgImage())
        #expect(cg.alphaInfo == .last, "straight alpha is declared non-premultiplied")
        #expect(cg.colorSpace?.name == CGColorSpace.sRGB)
        #expect(try #require(pre.cgImage()).alphaInfo == .premultipliedLast)
        let rgb = try LWInferenceImage(width: 1, height: 1, channels: 3, alpha: .none, pixels: Data([1, 2, 3]))
        #expect(try #require(rgb.cgImage()).alphaInfo == .none)
        let mask = try LWInferenceImage.mask(width: 2, height: 1, values: Data([0, 255]))
        #expect(try #require(mask.cgImage()).colorSpace?.model == .monochrome)
    }

    @Test func stridedBuffersArePackedAndInvalidLayoutsRejected() throws {
        let strided = try LWInferenceImage(width: 1, height: 2, channels: 4, rowBytes: 8, alpha: .premultiplied,
                                           pixels: Data([10, 10, 10, 128, 9, 9, 9, 9, 20, 20, 20, 255]))
        let packed = strided.straightened()
        #expect(packed.rowBytes == 4 && [UInt8](packed.pixels) == [20, 20, 20, 128, 20, 20, 20, 255])
        #expect(throws: LWInferenceError.self) { try LWInferenceImage(width: 2, height: 2, channels: 4, alpha: .none, pixels: Data(count: 16)) }
        #expect(throws: LWInferenceError.self) { try LWInferenceImage(width: 2, height: 2, channels: 3, alpha: .none, pixels: Data(count: 5)) }
        #expect(throws: LWInferenceError.self) { try LWInferenceImage(width: 1, height: 1, channels: 2, alpha: .none, pixels: Data(count: 2)) }
    }

    @Test func typedRequestsEncodeTheVersionedContract() throws {
        let request = LWInferenceRequest.generate(
            provider: "sana_sprint_1600m", weights: .dir(URL(fileURLWithPath: "/m/q4")), load: .init(residency: .keepLoaded),
            LWGenerateParams(prompt: "fox", width: 512, height: 512, negativePrompt: "blur", steps: 2, conditioning: [.mask(input: 0), .reference(input: 1, strength: 0.5)]))
        let object = try #require(try JSONSerialization.jsonObject(with: request.json) as? [String: Any])
        #expect(object["version"] as? Int == 1 && object["task"] as? String == "generate")
        #expect((object["weights"] as? [String: String]) == ["dir": "/m/q4"])
        #expect((object["load"] as? [String: String])?["residency"] == "keep_loaded")
        let params = try #require(object["params"] as? [String: Any])
        #expect(params["negative_prompt"] as? String == "blur" && params["alpha_output"] as? Bool == false && params["seed"] == nil)
        let conditioning = try #require(params["conditioning"] as? [[String: Any]])
        #expect(conditioning[0]["kind"] as? String == "mask" && conditioning[1]["kind"] as? String == "reference")
        let sam = LWInferenceRequest.segmentSam3Concept(weights: URL(fileURLWithPath: "/s/model.safetensors"), tokenizer: URL(fileURLWithPath: "/s/tokenizer.json"),
                                                        LWSam3ConceptParams(input: 0, concept: "dog"))
        let samObject = try #require(try JSONSerialization.jsonObject(with: sam.json) as? [String: Any])
        #expect(samObject["provider"] as? String == "sam3" && samObject["tokenizer"] as? String == "/s/tokenizer.json")
    }
}

/// The real adapter dylib, loaded at runtime exactly as the app loads it.
@Suite(.serialized, .enabled(if: hasLibrary, "Set TEST_RUNNER_LW_INFERENCE_LIBRARY to liblensworks_inference.dylib"))
nonisolated struct LensWorksInferenceRuntimeTests {
    func runtime() throws -> LWInferenceRuntime { try LWInferenceRuntime.installed() }

    @Test func capabilitiesEnumerateEveryRouteWithUnsupportedReasons() async throws {
        let caps = try await runtime().capabilities()
        #expect(caps.abiVersion == LWInferenceRuntime.expectedABI && caps.platform == "macos" && caps.backend == "mlx")
        #expect(caps.inferenceRevision.count == 40)
        // The bundle's sealed metallib is pinned strictly (no fallback).
        let bundled = bundledMetallib(for: URL(fileURLWithPath: try #require(inferenceLibrary)))
        if FileManager.default.fileExists(atPath: bundled.path) {
            #expect(caps.execution.metallib == bundled.path)
        } else {
            #expect(caps.execution.metallib == "mlx_search_order")
        }
        let generators = try #require(caps.routes["generate"])
        #expect(generators.count > 30)
        #expect(generators.contains { $0.id == "sana_sprint_1600m" && $0.isSupported })
        for route in generators where !route.isSupported { #expect(route.reason?.isEmpty == false) }
        for route in generators { for (name, control) in route.controls ?? [:] where !control.supported { #expect(control.reason?.isEmpty == false, "\(route.id).\(name)") } }
        #expect(caps.routes["caption"]?.isEmpty == false && caps.routes["embed_image"]?.isEmpty == false && caps.routes["embed_text"]?.isEmpty == false)
        let segmentTasks: Set<String> = Set((caps.routes["segment"] ?? []).compactMap(\.task))
        #expect(segmentTasks == ["segment_sam2_box", "segment_sam3_concept", "segment_sam3_box"])
        #expect(caps.notRouted.contains { $0.surface == "trainers" })
    }

    /// The shipped model manifest is compatible with the bundled runtime: same inference
    /// revision, every route served, every licence row present with the qualified declaration.
    @Test func shippedModelManifestMatchesTheRuntime() async throws {
        let caps = try await runtime().capabilities()
        let facts = LWModelRuntimeFacts(capabilities: caps)
        let manifest = try LWModelManifest.bundled()
        #expect(manifest.inferenceRevision == facts.inferenceRevision)
        #expect(facts.licenses["sam3"]?.familyName.isEmpty == false && facts.licenses["sam3"]?.gated == true)
        for model in manifest.models {
            for route in model.routes { #expect(facts.routes.contains(route.key), "\(model.id): \(route.key)") }
            for license in model.licenseComponents {
                #expect(facts.licenses[license.key]?.declared == license.declared, "\(model.id): \(license.key)")
            }
            #expect(model.memory.peakBytes != nil, "\(model.id) has a measured memory need")
        }
    }

    @Test func malformedRequestsAreRejectedSynchronously() async throws {
        let runtime = try runtime()
        await #expect(throws: LWInferenceError.self) { try await runtime.start(LWInferenceRequest(json: Data("{".utf8))) }
        let bad = LWInferenceRequest.caption(provider: "x", weights: .dir(URL(fileURLWithPath: "/m")), LWCaptionParams(input: 3))
        do {
            _ = try await runtime.start(bad, inputs: [try LWInferenceImage(width: 1, height: 1, channels: 3, alpha: .none, pixels: Data([1, 2, 3]))])
            Issue.record("expected rejection")
        } catch let LWInferenceError.rejected(kind, message) {
            #expect(kind == "invalid_request" && message.contains("out of range"))
        }
    }

    @Test func failuresAndUnsupportedControlsArriveTypedOffTheMainThread() async throws {
        let runtime = try runtime()
        let missing = LWInferenceRequest.generate(provider: "sana_sprint_1600m", weights: .dir(URL(fileURLWithPath: "/nonexistent/lensworks/sana")),
                                                  LWGenerateParams(prompt: "x", width: 512, height: 512, steps: 2))
        let job = try await runtime.start(missing)
        let events = await job.collect()
        guard case .failed(let failure)? = events.last else { Issue.record("expected failure: \(events)"); return }
        #expect(failure.kind == "load")
        #expect(!job.deliveredOnMainThread)
        job.release()

        let unsupported = LWInferenceRequest.generate(provider: "sana_sprint_1600m", weights: .dir(URL(fileURLWithPath: "/nonexistent/lensworks/sana")),
                                                      LWGenerateParams(prompt: "x", width: 512, height: 512, negativePrompt: "blur", alphaOutput: true))
        let rejected = await (try await runtime.start(unsupported)).collect()
        guard case .failed(let f)? = rejected.last else { Issue.record("expected unsupported"); return }
        #expect(f.kind == "unsupported")
        let controls: Set<String> = Set((f.unsupported ?? []).map(\.control))
        #expect(controls.isSuperset(of: ["negative_prompt", "alpha_output"]))
        #expect(!rejected.contains { if case .progress = $0 { true } else { false } }, "rejected before any load")
    }

    /// The dylib exactly as the signed app ships it: weights-free GPU kernels run on the
    /// executor thread against the metallib sealed in the bundle's Resources.
    @Test func bundledRuntimePassesTheGPUSelfTest() async throws {
        let runtime = try runtime()
        let library = runtime.libraryURL.standardizedFileURL
        #expect(library.path.hasSuffix(".app/Contents/Helpers/liblensworks_inference.dylib"), "\(library.path)")
        let app = library.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        var code: SecStaticCode?
        #expect(SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess)
        let status = SecStaticCodeCheckValidity(try #require(code), SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckNestedCode), nil)
        #expect(status == errSecSuccess, "the app signature (which seals Resources/mlx.metallib) is valid: \(status)")
        let report = try await runtime.selfTest()
        #expect(report.ok, "\(report)")
        #expect(report.thread == "lensworks-inference-executor")
        #expect(report.metallib == bundledMetallib(for: library).path, "MLX loaded the bundled metallib: \(report.metallib ?? "nil")")
        #expect(report.metallibResolution == report.metallib)
        #expect(report.ops.map(\.op) == ["steel_gemm_f32", "quantized_matmul_q4"])
        #expect(report.ops.allSatisfy { $0.ok && ($0.maxRelError ?? .infinity) <= ($0.tolerance ?? 0) })
    }

    @Test func releaseTearsDownTheCallbackContextWithoutLeaks() async throws {
        let runtime = try runtime()
        weak var weakBox: LWInferenceCallbackBox?
        do {
            let job = try await runtime.start(.embedText(provider: "clip_vit_l14_text", weights: .dir(URL(fileURLWithPath: "/nonexistent/lensworks/clip")),
                                                   LWEmbedTextParams(texts: ["a"])))
            weakBox = job.callbackBox
            job.release()
            job.release() // idempotent
            let events = await job.collect() // the stream is finished by release
            #expect(events.count <= 3)
        }
        #expect(weakBox == nil, "the adapter released its context reference and the job freed the box")
        // A job that completes and is dropped without an explicit release also frees everything.
        weak var weakBox2: LWInferenceCallbackBox?
        do {
            let job = try await runtime.start(.embedText(provider: "no_such_embedder", weights: .dir(URL(fileURLWithPath: "/m")), LWEmbedTextParams(texts: ["a"])))
            weakBox2 = job.callbackBox
            guard case .failed(let f)? = await job.collect().last else { Issue.record("expected failure"); return }
            #expect(f.kind == "unknown_provider")
        }
        #expect(weakBox2 == nil)
        #expect(await runtime.releaseModels() == 0)
    }
}

/// One real image job through Swift: typed progress, output, cancellation and failure.
@Suite(.serialized, .enabled(if: runRealWeights, "Set LW_INFERENCE_REAL_WEIGHTS=1 on a machine with the SceneWorks Sana Sprint q4 weights"))
nonisolated struct LensWorksInferenceRealWeightTests {
    @Test(.enabled("The test host cannot read the Sana Sprint q4 weights (see the warning); LW_REQUIRE_REAL=1 makes this a failure") {
        sanaSprintGate.1.shouldRun
    })
    func realImageJobProgressOutputCancelAndFailure() async throws {
        if case .fail(let reason) = sanaSprintGate.1 { Issue.record("\(reason)"); return }
        let weights = try #require(sanaSprintGate.0)
        let runtime = try LWInferenceRuntime.installed()
        func request(_ prompt: String, steps: Int) -> LWInferenceRequest {
            .generate(provider: "sana_sprint_1600m", weights: .dir(weights), load: .init(residency: .keepLoaded),
                      LWGenerateParams(prompt: prompt, width: 512, height: 512, seed: 7, steps: steps))
        }
        let job = try await runtime.start(request("a red apple on a white table", steps: 2))
        let events = await job.collect()
        #expect(!job.deliveredOnMainThread)
        let steps = events.compactMap { if case .progress(let p) = $0, p.phase == "step" { (p.current ?? 0, p.total ?? 0) } else { nil } }
        #expect(steps.map(\.0) == [1, 2] && steps.allSatisfy { $0.1 == 2 })
        let images = events.compactMap { if case .image(let image, _) = $0 { image } else { nil } }
        let image = try #require(images.first)
        #expect(images.count == 1 && image.width == 512 && image.height == 512 && image.channels == 3)
        let cg = try #require(image.cgImage())
        #expect(cg.colorSpace?.name == CGColorSpace.sRGB && cg.width == 512)
        guard case .completed(let result)? = events.last else { Issue.record("expected completion: \(events.last as Any)"); return }
        #expect(result.provider == "sana_sprint_1600m" && result.images == 1 && result.inferenceRevision.count == 40)
        #expect((result.memory?.peakBytes ?? 0) > 0 && (result.memory?.activeBytes ?? 0) > 0, "the job reports its measured memory")
        #expect(result.metallib == bundledMetallib(for: runtime.libraryURL).path,
                "the real job ran on the bundled metallib")

        let cancelling = try await runtime.start(request("a lighthouse at dusk", steps: 4))
        var seen: [LWInferenceEvent] = []
        for await event in cancelling.events {
            seen.append(event)
            if case .progress(let p) = event, p.phase == "step" { cancelling.cancel() }
        }
        #expect(seen.last == .cancelled, "\(seen.last as Any)")
        #expect(!seen.contains { if case .image = $0 { true } else { false } })
        cancelling.release()
        #expect(await runtime.releaseModels() == 1)

        let empty = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: empty, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: empty) }
        let failing = try await runtime.start(.generate(provider: "sana_sprint_1600m", weights: .dir(empty), LWGenerateParams(prompt: "x", width: 512, height: 512, steps: 2)))
        guard case .failed(let failure)? = await failing.collect().last else { Issue.record("expected failure"); return }
        #expect(failure.kind == "load")
    }
}
