import AppKit
import Foundation
import Testing
@testable import Compositor

/// Hand-assembled WebAssembly modules for the sandbox tests.
enum WasmFixture {
    static func leb(_ value: Int) -> [UInt8] {
        var out: [UInt8] = [], rest = UInt32(value)
        repeat {
            var byte = UInt8(rest & 0x7F); rest >>= 7
            if rest != 0 { byte |= 0x80 }
            out.append(byte)
        } while rest != 0
        return out
    }
    static func sleb(_ value: Int) -> [UInt8] {
        var out: [UInt8] = [], rest = Int64(value), more = true
        while more {
            let byte = UInt8(rest & 0x7F); rest >>= 7
            if (rest == 0 && byte & 0x40 == 0) || (rest == -1 && byte & 0x40 != 0) { more = false; out.append(byte) } else { out.append(byte | 0x80) }
        }
        return out
    }
    static func name(_ text: String) -> [UInt8] { leb(text.utf8.count) + Array(text.utf8) }
    static func section(_ id: UInt8, _ body: [UInt8]) -> [UInt8] { [id] + leb(body.count) + body }
    static func vector(_ items: [[UInt8]]) -> [UInt8] { leb(items.count) + items.flatMap { $0 } }

    /// A module whose one function `filter(i32, i32)` runs `body` (with `locals` extra i32 locals).
    static func filterModule(locals: Int = 0, body: [UInt8], memoryMin: Int = 2, memoryMax: Int? = nil, imports: [(String, String)] = []) -> [UInt8] {
        var bytes: [UInt8] = [0x00, 0x61, 0x73, 0x6D, 0x01, 0x00, 0x00, 0x00]
        bytes += section(1, vector([[0x60, 0x02, 0x7F, 0x7F, 0x00], [0x60, 0x00, 0x01, 0x7F]]))
        if !imports.isEmpty {
            bytes += section(2, vector(imports.map { name($0.0) + name($0.1) + [0x00, 0x00] }))
        }
        bytes += section(3, vector([[0x00]]))
        bytes += section(5, vector([memoryMax.map { [0x01] + leb(memoryMin) + leb($0) } ?? [0x00] + leb(memoryMin)]))
        bytes += section(7, vector([name("filter") + [0x00, UInt8(imports.count)], name("memory") + [0x02, 0x00]]))
        let local = locals > 0 ? vector([leb(locals) + [0x7F]]) : leb(0)
        bytes += section(10, vector([leb(local.count + body.count + 1) + local + body + [0x0B]]))
        return bytes
    }

    /// Inverts R, G and B of every pixel and keeps alpha.
    static let invert = filterModule(locals: 1, body:
        [0x20, 0x00, 0x20, 0x01, 0x41, 0x02, 0x74, 0x6A, 0x21, 0x02,        // end = ptr + count * 4
         0x02, 0x40, 0x03, 0x40,                                          // block, loop
         0x20, 0x00, 0x20, 0x02, 0x4F, 0x0D, 0x01]                         // if ptr >= end break
        + (0..<3).flatMap { channel -> [UInt8] in
            [0x20, 0x00, 0x20, 0x00, 0x2D, 0x00, UInt8(channel), 0x41] + sleb(255) + [0x73, 0x3A, 0x00, UInt8(channel)]
        }
        + [0x20, 0x00, 0x41, 0x04, 0x6A, 0x21, 0x00, 0x0C, 0x00, 0x0B, 0x0B])
    /// Leaves every pixel as it is.
    static let identity = filterModule(body: [])
    /// Never returns.
    static let infiniteLoop = filterModule(body: [0x03, 0x40, 0x0C, 0x00, 0x0B])
    /// Tries to grow memory by 100 pages and traps unless the sandbox refused.
    static let growsPastLimit = filterModule(body: [0x41] + sleb(100) + [0x40, 0x00, 0x41, 0x7F, 0x47, 0x04, 0x40, 0x00, 0x0B])
}

struct WasmSandboxTests {
    private let pixels: [UInt8] = [10, 20, 30, 255, 0, 0, 0, 0, 255, 128, 1, 200]

    @Test func theInvertPluginInvertsColorAndKeepsAlpha() throws {
        let result = try WasmFilterRunner.run(WasmFixture.invert, pixels: pixels)
        #expect(result == [245, 235, 225, 255, 255, 255, 255, 0, 0, 127, 254, 200])
    }

    @Test func aLayerLargerThanOneChunkIsFilteredWhole() throws {
        let count = WasmFilterRunner.chunkPixels * 2 + 5
        let input = (0..<count * 4).map { UInt8($0 % 251) }
        let result = try WasmFilterRunner.run(WasmFixture.invert, pixels: input)
        #expect(result.count == input.count)
        for pixel in [0, count / 2, count - 1] {
            #expect(result[pixel * 4] == 255 ^ input[pixel * 4] && result[pixel * 4 + 3] == input[pixel * 4 + 3])
        }
    }

    @Test func aRunawayPluginStopsAtItsInstructionLimit() {
        var limits = WasmLimits.default
        limits.maxInstructions = 50_000
        #expect(throws: WasmError.outOfFuel) { try WasmFilterRunner.run(WasmFixture.infiniteLoop, pixels: pixels, limits: limits) }
    }

    @Test func aRunawayPluginStopsAtItsTimeLimit() {
        var limits = WasmLimits.default
        limits.maxSeconds = 0.2
        let started = Date()
        #expect(throws: WasmError.timeout) { try WasmFilterRunner.run(WasmFixture.infiniteLoop, pixels: pixels, limits: limits) }
        #expect(Date().timeIntervalSince(started) < 5)
    }

    @MainActor
    @Test func aRunawayPluginDoesNotBlockTheCaller() async {
        var limits = WasmLimits.default
        limits.maxSeconds = 1.5
        let input = pixels
        var finished = false
        let plugin = Task { @MainActor () -> WasmError? in
            defer { finished = true }
            do { _ = try await WasmFilterRunner.runIsolated(WasmFixture.infiniteLoop, pixels: input, limits: limits); return nil }
            catch { return error as? WasmError }
        }
        // The main actor keeps running while the plugin spins.
        var ticks = 0
        for _ in 0..<5 {
            try? await Task.sleep(nanoseconds: 50_000_000)
            ticks += 1
        }
        #expect(ticks == 5 && !finished, "main actor made progress while the plugin was still running")
        #expect(await plugin.value == .timeout)
    }

    @Test func memoryIsCappedAtTheLimit() throws {
        var limits = WasmLimits.default
        limits.maxMemoryPages = 4
        // The module asks for more than the limit up front: refused at load.
        #expect(throws: WasmError.memoryLimit) { try WasmFilterRunner.validate(WasmFixture.filterModule(body: [], memoryMin: 5), limits: limits) }
        // Growing past the limit fails (memory.grow returns -1) instead of allocating.
        _ = try WasmFilterRunner.run(WasmFixture.growsPastLimit, pixels: pixels, limits: limits)
        let instance = try WasmInstance(module: WasmFilterRunner.validate(WasmFixture.growsPastLimit, limits: limits), limits: limits)
        #expect(instance.memory.count <= 4 * WasmInstance.pageSize)
    }

    @Test func aPluginThatDeclaresAHostImportIsRejected() {
        let module = WasmFixture.filterModule(body: [], imports: [("env", "read_file")])
        #expect(throws: WasmError.hostImport("env.read_file")) { try WasmFilterRunner.validate(module) }
    }

    @Test func garbageAndMissingEntryPointsAreRefused() {
        #expect(throws: WasmError.self) { try WasmFilterRunner.validate([1, 2, 3, 4, 5]) }
        var module = WasmFixture.identity
        module.replaceSubrange(0..<4, with: [0, 0, 0, 0])
        #expect(throws: WasmError.self) { try WasmFilterRunner.validate(module) }
    }

    @Test func aTrappingPluginFailsWithAnErrorNotACrash() {
        let module = WasmFixture.filterModule(body: [0x00])
        #expect(throws: WasmError.trap("unreachable code was executed")) { try WasmFilterRunner.run(module, pixels: pixels) }
    }
}

struct WasmPluginStoreTests {
    private func makeStore() throws -> (LensWorksPluginStore, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WasmPluginTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LensWorksPluginStore(directory: root.appendingPathComponent("Plugins", isDirectory: true)), root)
    }
    private func write(_ bytes: [UInt8], _ name: String, in root: URL) throws -> URL {
        let url = root.appendingPathComponent(name)
        try Data(bytes).write(to: url)
        return url
    }

    @Test func installListRunAndRemove() throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        #expect(store.list().isEmpty)
        let plugin = try store.install(from: try write(WasmFixture.invert, "Invert.wasm", in: root))
        #expect(plugin.id == "invert" && plugin.name == "Invert" && store.list() == [plugin])
        let result = try WasmFilterRunner.run(try store.bytes("invert"), pixels: [1, 2, 3, 4])
        #expect(result == [254, 253, 252, 4])
        try store.remove("invert")
        #expect(store.list().isEmpty)
        #expect(throws: LensWorksPluginRefusal.self) { try store.bytes("invert") }
    }

    @Test func installRefusesAnImportingPluginAndADuplicate() throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let hostile = try write(WasmFixture.filterModule(body: [], imports: [("env", "open")]), "hostile.wasm", in: root)
        #expect(throws: WasmError.hostImport("env.open")) { try store.install(from: hostile) }
        #expect(store.list().isEmpty)
        let good = try write(WasmFixture.identity, "same.wasm", in: root)
        try store.install(from: good)
        #expect(throws: LensWorksPluginRefusal.self) { try store.install(from: good) }
        #expect(store.list().count == 1)
    }

    @Test func reloadUsesTheChangedBinary() throws {
        let (store, root) = try makeStore(); defer { try? FileManager.default.removeItem(at: root) }
        let url = try write(WasmFixture.identity, "tone.wasm", in: root)
        try store.install(from: url)
        #expect(try WasmFilterRunner.run(try store.bytes("tone"), pixels: [1, 2, 3, 4]) == [1, 2, 3, 4])
        try Data(WasmFixture.invert).write(to: url)
        // Until it is reloaded the installed copy keeps running.
        #expect(try WasmFilterRunner.run(try store.bytes("tone"), pixels: [1, 2, 3, 4]) == [1, 2, 3, 4])
        try store.reload("tone")
        #expect(try WasmFilterRunner.run(try store.bytes("tone"), pixels: [1, 2, 3, 4]) == [254, 253, 252, 4])
        // A file that no longer validates is refused and the installed code stays.
        try Data(WasmFixture.filterModule(body: [], imports: [("env", "x")])).write(to: url)
        #expect(throws: WasmError.self) { try store.reload("tone") }
        #expect(try WasmFilterRunner.run(try store.bytes("tone"), pixels: [1, 2, 3, 4]) == [254, 253, 252, 4])
    }
}

@MainActor
struct WasmPluginCommandTests {
    private func fixture() throws -> (LensWorksPluginLibrary, URL) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("WasmPluginCommandTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return (LensWorksPluginLibrary(store: LensWorksPluginStore(directory: root.appendingPathComponent("Plugins", isDirectory: true))), root)
    }
    private func pixel(_ session: EditorSession) async throws -> [Int] {
        let image = try await ImageExporter.shared.render(try #require(session.projectSnapshot())).image
        let context = try #require(CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
            bytesPerRow: image.width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue))
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        let bytes = try #require(context.data).assumingMemoryBound(to: UInt8.self)
        return (0..<4).map { Int(bytes[(20 * image.width + 50) * 4 + $0]) }
    }
    private func redSession() async throws -> EditorSession {
        let session = EditorSession()
        session.createDocument(width: 100, height: 40, emptyLayer: true)
        session.setPaletteColor(PaletteColor(red: 1, green: 0, blue: 0), background: false)
        await session.fillSelection(with: .foreground)
        return session
    }

    @Test func anInstalledPluginIsARegistryCommandThatInvertsTheActiveLayerAsOneUndo() async throws {
        let (library, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invert.wasm")
        try Data(WasmFixture.invert).write(to: url)
        try library.install(from: url)
        let descriptor = LensWorksCommandRegistry.descriptor(.runPlugin)
        #expect(descriptor.undoable && descriptor.menu == "Filter/Plugins" && descriptor.parameters.map(\.name) == ["plugin"])
        let session = try await redSession()
        #expect(session.menuReason(.runPlugin, argument: "invert", canStart: true) == nil)
        let before = session.history.undoCount
        await session.runPlugin("invert", library: library)
        #expect(session.history.undoCount == before + 1 && session.history.undoName == "invert")
        #expect(try await pixel(session) == [0, 255, 255, 255])
        session.undo()
        #expect(try await pixel(session) == [255, 0, 0, 255])
    }

    @Test func aRunawayPluginReportsAnErrorAndLeavesTheDocumentAlone() async throws {
        let (library, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        library.store.limits.maxSeconds = 0.3
        let url = root.appendingPathComponent("spin.wasm")
        try Data(WasmFixture.infiniteLoop).write(to: url)
        try library.install(from: url)
        let session = try await redSession()
        let before = session.history.undoCount
        await session.runPlugin("spin", library: library)
        #expect(session.brushError == WasmError.timeout.errorDescription)
        #expect(session.history.undoCount == before && !session.isProjectBusy)
        #expect(try await pixel(session) == [255, 0, 0, 255])
    }

    @Test func removingAPluginRemovesItsCommand() throws {
        let (library, root) = try fixture(); defer { try? FileManager.default.removeItem(at: root) }
        let url = root.appendingPathComponent("invert.wasm")
        try Data(WasmFixture.invert).write(to: url)
        try library.install(from: url)
        #expect(library.plugins.map(\.id) == ["invert"])
        try library.remove("invert")
        #expect(library.plugins.isEmpty)
    }
}
