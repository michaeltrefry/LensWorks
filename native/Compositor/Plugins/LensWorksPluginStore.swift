import Foundation
import Observation

/// The filter plugins the person installed. A package is a folder holding `plugin.json` and `filter.wasm`; installing
/// one checks the manifest and the module (every import, export and limit), copies both into LensWorks's own
/// Application Support folder and records their SHA-256 hashes. Every run reads the installed copy again, checks it
/// is still the bytes that were installed and validates it again, so a file changed behind LensWorks's back never
/// runs. Installing, removing and reloading are the person's decisions: no agent command reaches this type's
/// mutating functions.
@MainActor @Observable final class LensWorksPluginStore {
    /// The person's plugins, under the one accessor for their Application Support folder (a per-process stand-in
    /// under XCTest).
    static let shared = LensWorksPluginStore(directory: LensWorksUserState.applicationSupport.appendingPathComponent("Plugins", isDirectory: true))
    static let recordName = "installed.json"
    /// The most plugins that can be installed at once.
    static let maximumPlugins = 64

    struct Installed: Identifiable, Equatable, Sendable {
        let manifest: LensWorksPluginManifest
        /// SHA-256 of the installed `filter.wasm` and `plugin.json`.
        let moduleHash: String
        let manifestHash: String
        /// The package folder it was installed from, which Reload reads again.
        let source: String
        var id: String { manifest.id }
    }
    /// A folder in the plugins directory that is not a usable plugin; it can only be removed.
    struct Damaged: Identifiable, Equatable, Sendable {
        let id: String
        let problem: String
    }
    enum Outcome: Equatable, Sendable {
        case installed(Installed)
        case replaced(Installed, previousHash: String)
        case unchanged(Installed)
        var plugin: Installed { switch self { case .installed(let plugin), .replaced(let plugin, _), .unchanged(let plugin): plugin } }
        /// What to tell the person, with the plugin's id and both hashes.
        var message: String {
            switch self {
            case .installed(let plugin): "Installed \(plugin.manifest.name) (\(plugin.id)) \(plugin.manifest.version), SHA-256 \(plugin.moduleHash)."
            case .replaced(let plugin, let previous):
                "Replaced \(plugin.manifest.name) (\(plugin.id)): it is now version \(plugin.manifest.version), SHA-256 \(plugin.moduleHash) (was \(previous))."
            case .unchanged(let plugin): "\(plugin.manifest.name) (\(plugin.id)) is unchanged: SHA-256 \(plugin.moduleHash)."
            }
        }
    }

    let directory: URL
    private(set) var plugins: [Installed] = []
    private(set) var damaged: [Damaged] = []
    /// The result of the last install, remove or reload, for the settings pane.
    var lastMessage: String?
    var lastError: String?

    init(directory: URL) {
        self.directory = directory
        refresh()
    }

    func plugin(_ id: String) -> Installed? { plugins.first { $0.id == id } }

    private func folder(_ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }

    /// A regular file's bytes, refused when it is a link, not a file, or over `limit` bytes.
    private static func read(_ url: URL, limit: Int, what: String) throws -> Data {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LensWorksPluginFailure("The package has no \(what) file.")
        }
        guard let size = values.fileSize, size <= limit else { throw LensWorksPluginFailure("The package’s \(what) is over the \(limit)-byte limit.") }
        guard let data = try? Data(contentsOf: url), data.count <= limit else { throw LensWorksPluginFailure("The package’s \(what) could not be read.") }
        return data
    }

    /// Reads and fully checks a package folder: the manifest, then the module against the filter interface.
    static func check(package: URL) throws -> (manifest: LensWorksPluginManifest, manifestData: Data, module: Data) {
        let read = try read(package: package)
        do { try LensWorksPluginSandbox.validate(read.module) }
        catch { throw LensWorksPluginFailure("The plugin’s module was refused. " + error.localizedDescription) }
        return read
    }
    /// Reads a package folder's two files within their size limits and checks the manifest. The module is not
    /// compiled here: `check` does that at install, and the sandbox does it again every time the plugin is run.
    static func read(package: URL) throws -> (manifest: LensWorksPluginManifest, manifestData: Data, module: Data) {
        guard let values = try? package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else {
            throw LensWorksPluginFailure("Choose a plugin package: a folder holding \(LensWorksPluginManifest.fileName) and \(LensWorksPluginManifest.moduleName).")
        }
        let manifestData = try read(package.appendingPathComponent(LensWorksPluginManifest.fileName), limit: LensWorksPluginManifest.maximumBytes, what: LensWorksPluginManifest.fileName)
        let manifest = try LensWorksPluginManifest(data: manifestData)
        let module = try read(package.appendingPathComponent(LensWorksPluginManifest.moduleName), limit: Int(LensWorksPluginSandbox.limits.module_bytes), what: LensWorksPluginManifest.moduleName)
        return (manifest, manifestData, module)
    }

    /// Installs the package at `package`, or replaces the installed plugin of the same id when its bytes differ.
    @discardableResult func install(from package: URL) throws -> Outcome {
        let checked = try Self.check(package: package)
        let manifest = checked.manifest
        let installed = Installed(manifest: manifest, moduleHash: LensWorksPluginManifest.sha256(checked.module),
                                  manifestHash: LensWorksPluginManifest.sha256(checked.manifestData), source: package.standardizedFileURL.path)
        let previous = plugin(manifest.id)
        if let previous, previous.moduleHash == installed.moduleHash, previous.manifestHash == installed.manifestHash, (try? load(manifest.id)) != nil {
            return .unchanged(previous)
        }
        if previous == nil, !damaged.contains(where: { $0.id == manifest.id }), plugins.count + damaged.count >= Self.maximumPlugins {
            throw LensWorksPluginFailure("At most \(Self.maximumPlugins) plugins can be installed. Remove one first.")
        }
        // Another installed plugin may not show the same name: the id alongside tells them apart, the name should too.
        if let twin = plugins.first(where: { $0.id != manifest.id && $0.manifest.name.lowercased() == manifest.name.lowercased() }) {
            throw LensWorksPluginFailure("The plugin’s manifest was refused: “name” is already the name of the installed plugin \(twin.id).")
        }
        let files = FileManager.default
        do {
            try files.createDirectory(at: directory, withIntermediateDirectories: true)
            // Written whole beside its place, then moved over it, so a failure never leaves half a plugin installed.
            let staging = directory.appendingPathComponent(".installing-" + UUID().uuidString, isDirectory: true)
            try files.createDirectory(at: staging, withIntermediateDirectories: false)
            defer { try? files.removeItem(at: staging) }
            try checked.manifestData.write(to: staging.appendingPathComponent(LensWorksPluginManifest.fileName))
            try checked.module.write(to: staging.appendingPathComponent(LensWorksPluginManifest.moduleName))
            let record: [String: Any] = ["schema": 1, "id": manifest.id, "moduleSHA256": installed.moduleHash, "manifestSHA256": installed.manifestHash, "source": installed.source]
            try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]).write(to: staging.appendingPathComponent(Self.recordName))
            let destination = folder(manifest.id)
            if files.fileExists(atPath: destination.path) { try files.removeItem(at: destination) }
            try files.moveItem(at: staging, to: destination)
        } catch { refresh(); throw LensWorksPluginFailure("The plugin could not be installed: " + error.localizedDescription) }
        refresh()
        guard let now = plugin(manifest.id) else { throw LensWorksPluginFailure("The plugin could not be installed.") }
        return previous.map { .replaced(now, previousHash: $0.moduleHash) } ?? .installed(now)
    }

    /// Removes an installed (or damaged) plugin: its command is gone from the menus and from agents at once.
    func remove(_ id: String) throws {
        guard LensWorksPluginManifest.isIdentifier(id), plugins.contains(where: { $0.id == id }) || damaged.contains(where: { $0.id == id }) else {
            throw LensWorksPluginFailure("That plugin is not installed.")
        }
        do { try FileManager.default.removeItem(at: folder(id)) }
        catch { refresh(); throw LensWorksPluginFailure("The plugin could not be removed: " + error.localizedDescription) }
        refresh()
    }

    /// Reads the plugin's package again from the folder it was installed from, and replaces the installed copy when
    /// the bytes changed. The package must still be the same plugin.
    @discardableResult func reload(_ id: String) throws -> Outcome {
        guard let current = plugin(id) else { throw LensWorksPluginFailure("That plugin is not installed.") }
        let package = URL(fileURLWithPath: current.source, isDirectory: true)
        let checked = try Self.check(package: package)
        guard checked.manifest.id == id else {
            throw LensWorksPluginFailure("The package at \(current.source) is now the plugin \(checked.manifest.id), not \(id). Install it as a new plugin instead.")
        }
        return try install(from: package)
    }

    /// The installed plugin and its module, read from LensWorks's own copy: the bytes must still hash to what was
    /// installed, and the module is validated again by the sandbox when it is instantiated.
    func load(_ id: String) throws -> (plugin: Installed, module: Data) {
        guard let installed = plugin(id) else {
            throw LensWorksPluginFailure(damaged.first { $0.id == id }.map { "The plugin \(id) cannot run. " + $0.problem } ?? "The plugin \(id) is not installed.")
        }
        let location = folder(id)
        let manifestData = try Self.read(location.appendingPathComponent(LensWorksPluginManifest.fileName), limit: LensWorksPluginManifest.maximumBytes, what: LensWorksPluginManifest.fileName)
        let module = try Self.read(location.appendingPathComponent(LensWorksPluginManifest.moduleName), limit: Int(LensWorksPluginSandbox.limits.module_bytes), what: LensWorksPluginManifest.moduleName)
        guard LensWorksPluginManifest.sha256(module) == installed.moduleHash, LensWorksPluginManifest.sha256(manifestData) == installed.manifestHash else {
            refresh()
            throw LensWorksPluginFailure("The plugin \(id) cannot run. " + Self.changedProblem)
        }
        return (installed, module)
    }
    static let changedProblem = "Its installed files are no longer the ones that were installed. Remove it and install it again."

    /// Reads the plugins directory again. A folder that is not a whole plugin with a readable manifest and exactly
    /// the bytes that were installed is listed as damaged. Nothing is compiled here (this runs at launch): a
    /// module is validated when it is installed and again, by the sandbox, every time it is run.
    func refresh() {
        var found: [Installed] = [], broken: [Damaged] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { LensWorksPluginManifest.isIdentifier($0) }.sorted()
        for name in names.prefix(Self.maximumPlugins * 2) {
            let location = folder(name)
            do {
                let recordData = try Self.read(location.appendingPathComponent(Self.recordName), limit: LensWorksPluginManifest.maximumBytes, what: Self.recordName)
                guard let record = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any], record["schema"] as? Int == 1, record["id"] as? String == name,
                      let moduleHash = record["moduleSHA256"] as? String, let manifestHash = record["manifestSHA256"] as? String, let source = record["source"] as? String else {
                    throw LensWorksPluginFailure("Its install record cannot be read. Remove it and install it again.")
                }
                let checked = try Self.read(package: location)
                guard checked.manifest.id == name, LensWorksPluginManifest.sha256(checked.module) == moduleHash, LensWorksPluginManifest.sha256(checked.manifestData) == manifestHash else {
                    throw LensWorksPluginFailure(Self.changedProblem)
                }
                found.append(.init(manifest: checked.manifest, moduleHash: moduleHash, manifestHash: manifestHash, source: source))
            } catch { broken.append(.init(id: name, problem: error.localizedDescription)) }
        }
        plugins = found; damaged = broken
    }
}
