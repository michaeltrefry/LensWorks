import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

/// A filter plugin installed in LensWorks's Application Support folder.
nonisolated struct InstalledPlugin: Codable, Equatable, Identifiable, Sendable {
    /// Stable identity and registry argument: the lowercased file name without its extension.
    let id: String
    let name: String
    /// Where the binary was installed from; Reload reads it again.
    let sourcePath: String
}

nonisolated struct LensWorksPluginRefusal: LocalizedError, Equatable {
    let reason: String
    var errorDescription: String? { reason }
}

/// Installed plugins on disk: one validated copy of each binary plus an index. Every run reads the stored copy, so a
/// reload that replaces it is the code the next run uses.
nonisolated final class LensWorksPluginStore {
    static let maxBinaryBytes = 8 << 20
    let directory: URL
    var limits: WasmLimits

    init(directory: URL, limits: WasmLimits = .default) {
        self.directory = directory
        self.limits = limits
    }

    private var indexURL: URL { directory.appendingPathComponent("plugins.json") }
    private func binaryURL(_ id: String) -> URL { directory.appendingPathComponent(id + ".wasm") }

    func list() -> [InstalledPlugin] {
        guard let data = try? Data(contentsOf: indexURL), let plugins = try? JSONDecoder().decode([InstalledPlugin].self, from: data) else { return [] }
        return plugins.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }
    private func save(_ plugins: [InstalledPlugin]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try JSONEncoder().encode(plugins).write(to: indexURL, options: .atomic)
    }
    private func binary(at url: URL) throws -> Data {
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= Self.maxBinaryBytes else { throw LensWorksPluginRefusal(reason: "The plugin file is larger than \(Self.maxBinaryBytes >> 20) MiB.") }
        let data = try Data(contentsOf: url)
        try WasmFilterRunner.validate([UInt8](data), limits: limits)
        return data
    }

    /// Installs the plugin at `url` after checking it loads in the sandbox (and so declares no import).
    @discardableResult func install(from url: URL) throws -> InstalledPlugin {
        let base = url.deletingPathExtension().lastPathComponent
        let id = String(base.lowercased().map { $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" ? $0 : "-" })
        guard !id.isEmpty else { throw LensWorksPluginRefusal(reason: "Name the plugin file before installing it.") }
        var plugins = list()
        guard !plugins.contains(where: { $0.id == id }) else { throw LensWorksPluginRefusal(reason: "A plugin named “\(id)” is already installed. Reload it to use a changed file.") }
        let data = try binary(at: url)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: binaryURL(id), options: .atomic)
        let plugin = InstalledPlugin(id: id, name: base, sourcePath: url.path)
        plugins.append(plugin)
        try save(plugins)
        return plugin
    }

    /// Replaces the stored binary with its source file as it is now. A file that no longer validates leaves the installed copy as it was.
    @discardableResult func reload(_ id: String) throws -> InstalledPlugin {
        guard let plugin = list().first(where: { $0.id == id }) else { throw LensWorksPluginRefusal(reason: "That plugin is not installed.") }
        let data = try binary(at: URL(fileURLWithPath: plugin.sourcePath))
        try data.write(to: binaryURL(id), options: .atomic)
        return plugin
    }

    func remove(_ id: String) throws {
        let plugins = list()
        guard plugins.contains(where: { $0.id == id }) else { throw LensWorksPluginRefusal(reason: "That plugin is not installed.") }
        try? FileManager.default.removeItem(at: binaryURL(id))
        try save(plugins.filter { $0.id != id })
    }

    func bytes(_ id: String) throws -> [UInt8] {
        guard list().contains(where: { $0.id == id }) else { throw LensWorksPluginRefusal(reason: "That plugin is not installed.") }
        return [UInt8](try Data(contentsOf: binaryURL(id)))
    }
}

/// The plugins the Filter menu offers. Each installed plugin is a `plugin.run` registry command whose argument is its id.
@MainActor @Observable final class LensWorksPluginLibrary {
    static let shared = LensWorksPluginLibrary(store: LensWorksPluginStore(directory: LensWorksUserState.applicationSupport.appendingPathComponent("Plugins", isDirectory: true)))
    let store: LensWorksPluginStore
    private(set) var plugins: [InstalledPlugin]
    init(store: LensWorksPluginStore) { self.store = store; plugins = store.list() }

    @discardableResult func install(from url: URL) throws -> InstalledPlugin {
        defer { plugins = store.list() }
        return try store.install(from: url)
    }
    @discardableResult func reload(_ id: String) throws -> InstalledPlugin {
        defer { plugins = store.list() }
        return try store.reload(id)
    }
    func remove(_ id: String) throws {
        defer { plugins = store.list() }
        try store.remove(id)
    }

    /// File › Filter › Plugins › Install Plugin…: asks for a .wasm file and reports why one is refused.
    func chooseAndInstall(window: NSWindow?) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "wasm") ?? .data]
        panel.message = "Choose a WebAssembly filter plugin. It runs in a sandbox with no file, network or system access."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        perform { try install(from: url) }
    }
    func perform(_ action: () throws -> Void) {
        do { try action() } catch {
            let alert = NSAlert()
            alert.messageText = "The plugin could not be installed"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }
}

/// Moves a layer's pixels through a plugin: premultiplied RGBA8 out to straight alpha, filtered in the sandbox, and back.
nonisolated enum PluginPixels {
    struct Box: @unchecked Sendable { let image: CGImage }

    static func apply(_ wasm: [UInt8], to image: CGImage, limits: WasmLimits) async throws -> CGImage {
        let width = image.width, height = image.height
        let source = Box(image: image)
        let straight = try await Task.detached(priority: .userInitiated) { try unpremultiplied(source.image) }.value
        let filtered = try await WasmFilterRunner.runIsolated(wasm, pixels: straight, limits: limits)
        return try await Task.detached(priority: .userInitiated) { Box(image: try premultipliedImage(filtered, width: width, height: height)) }.value.image
    }

    static func unpremultiplied(_ image: CGImage) throws -> [UInt8] {
        let width = image.width, height = image.height
        let context = try PixelAdjust.bitmap(width: width, height: height, mask: false)
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
        guard let data = context.data else { throw ExportError.render }
        var bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: width * height * 4))
        for pixel in stride(from: 0, to: bytes.count, by: 4) {
            let alpha = Int(bytes[pixel + 3])
            guard alpha != 0, alpha != 255 else { if alpha == 0 { bytes[pixel] = 0; bytes[pixel + 1] = 0; bytes[pixel + 2] = 0 }; continue }
            for channel in 0..<3 { bytes[pixel + channel] = UInt8(min(255, (Int(bytes[pixel + channel]) * 255 + alpha / 2) / alpha)) }
        }
        return bytes
    }

    static func premultipliedImage(_ straight: [UInt8], width: Int, height: Int) throws -> CGImage {
        guard straight.count == width * height * 4 else { throw ExportError.render }
        let context = try PixelAdjust.bitmap(width: width, height: height, mask: false)
        guard let data = context.data else { throw ExportError.render }
        let target = data.assumingMemoryBound(to: UInt8.self)
        for pixel in stride(from: 0, to: straight.count, by: 4) {
            let alpha = Int(straight[pixel + 3])
            for channel in 0..<3 { target[pixel + channel] = UInt8((Int(straight[pixel + channel]) * alpha + 127) / 255) }
            target[pixel + 3] = UInt8(alpha)
        }
        guard let image = context.makeImage() else { throw ExportError.render }
        return image
    }
}

extension EditorSession {
    /// Runs the installed plugin `id` on the active layer's pixels (inside the selection, when there is one) as one undo step.
    /// A plugin that fails or is stopped at a limit leaves the document untouched and reports why.
    func runPlugin(_ id: String, library: LensWorksPluginLibrary) async {
        guard canAdjustColors else { return }
        commitTransform()
        guard canAdjustColors, let document, let layer = activeLayer, let image = layer.asset?.image,
              let index = document.layers.firstIndex(where: { $0.id == layer.id }) else { return }
        let name = library.plugins.first { $0.id == id }?.name ?? id
        let wasm: [UInt8]
        do { wasm = try library.store.bytes(id) } catch { brushError = error.localizedDescription; return }
        finishOpacityEdit()
        isProjectBusy = true
        defer { isProjectBusy = false }
        do {
            guard image.width * image.height <= DocumentLimits.maxSurfacePixels else { throw ProjectError.tooLarge }
            let clip = try selection?.clip(canvas: document.size)
            var result = try await PluginPixels.apply(wasm, to: image, limits: library.store.limits)
            if let clip {
                result = try PixelAdjust.blend(result, over: image, through: clip,
                    pixelToDocument: BrushRaster.pixelToDocument(layer.transform, width: image.width, height: image.height), isMask: false)
            }
            let asset = ImportedImage(image: result, thumbnail: try PixelInvert.thumbnail(of: result), name: layer.name)
            guard let layers = self.document?.layers, layers.indices.contains(index), case let current = layers[index], current.id == layer.id, current.asset?.image === layer.asset?.image else { return }
            guard beginEdit(name) else { return }
            self.document?.layers[index] = ImageLayer(id: current.id, asset: asset, name: current.name,
                isVisible: current.isVisible, transform: current.transform, parentID: current.parentID, isGroup: false,
                opacity: current.opacity, blendMode: current.blendMode, mask: current.mask, maskSourceID: current.maskSourceID)
            endEdit()
            brushRevision += 1
        } catch { brushError = error.localizedDescription }
    }
}
