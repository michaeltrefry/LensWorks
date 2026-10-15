import Foundation
import Observation

/// The plugin files on disk, read and written off the main actor: reading a package, compiling its module to check
/// it, hashing installed modules and moving folders are all work the window never waits for.
nonisolated enum LensWorksPluginFiles {
    static let recordName = "installed.json"
    static let changedProblem = "Its installed files are no longer the ones that were installed. Remove it and install it again."

    struct Checked: Sendable {
        let manifest: LensWorksPluginManifest
        let manifestData: Data
        let module: Data
        var moduleHash: String { LensWorksPluginManifest.sha256(module) }
        var manifestHash: String { LensWorksPluginManifest.sha256(manifestData) }
    }

    static func folder(_ directory: URL, _ id: String) -> URL { directory.appendingPathComponent(id, isDirectory: true) }

    /// A regular file's bytes, refused when it is a link, not a file, or over `limit` bytes.
    static func read(_ url: URL, limit: Int, what: String) throws -> Data {
        guard let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]),
              values.isRegularFile == true, values.isSymbolicLink != true else {
            throw LensWorksPluginFailure("The package has no \(what) file.")
        }
        guard let size = values.fileSize, size <= limit else { throw LensWorksPluginFailure("The package’s \(what) is over the \(limit)-byte limit.") }
        guard let data = try? Data(contentsOf: url), data.count <= limit else { throw LensWorksPluginFailure("The package’s \(what) could not be read.") }
        return data
    }

    /// Reads and fully checks a package folder: the manifest, then the module against the filter interface.
    static func check(package: URL) throws -> Checked {
        let read = try read(package: package)
        do { try LensWorksPluginSandbox.validate(read.module) }
        catch { throw LensWorksPluginFailure("The plugin’s module was refused. " + error.localizedDescription) }
        return read
    }
    /// Reads a package folder's two files within their size limits and checks the manifest. The module is not
    /// compiled here: `check` does that at install, and the sandbox does it again every time the plugin is run.
    static func read(package: URL) throws -> Checked {
        guard let values = try? package.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey]), values.isDirectory == true, values.isSymbolicLink != true else {
            throw LensWorksPluginFailure("Choose a plugin package: a folder holding \(LensWorksPluginManifest.fileName) and \(LensWorksPluginManifest.moduleName).")
        }
        let manifestData = try read(package.appendingPathComponent(LensWorksPluginManifest.fileName), limit: LensWorksPluginManifest.maximumBytes, what: LensWorksPluginManifest.fileName)
        let manifest = try LensWorksPluginManifest(data: manifestData)
        let module = try read(package.appendingPathComponent(LensWorksPluginManifest.moduleName), limit: Int(LensWorksPluginSandbox.limits.module_bytes), what: LensWorksPluginManifest.moduleName)
        return Checked(manifest: manifest, manifestData: manifestData, module: module)
    }

    /// One installed folder, read whole and held to its install record: the manifest must be this plugin's and
    /// both files must still hash to what was installed.
    static func installed(_ directory: URL, _ name: String) throws -> (plugin: LensWorksPluginStore.Installed, module: Data) {
        let location = folder(directory, name)
        let recordData = try read(location.appendingPathComponent(recordName), limit: LensWorksPluginManifest.maximumBytes, what: recordName)
        guard let record = try? JSONSerialization.jsonObject(with: recordData) as? [String: Any], record["schema"] as? Int == 1, record["id"] as? String == name,
              let moduleHash = record["moduleSHA256"] as? String, let manifestHash = record["manifestSHA256"] as? String, let source = record["source"] as? String else {
            throw LensWorksPluginFailure("Its install record cannot be read. Remove it and install it again.")
        }
        let checked = try read(package: location)
        guard checked.manifest.id == name, checked.moduleHash == moduleHash, checked.manifestHash == manifestHash else { throw LensWorksPluginFailure(changedProblem) }
        return (.init(manifest: checked.manifest, moduleHash: moduleHash, manifestHash: manifestHash, source: source), checked.module)
    }

    /// Every folder in the plugins directory: the whole plugins, and those that are not (listed as damaged).
    /// Nothing is compiled here: a module is validated when it is installed and again, by the sandbox, every time
    /// it is run.
    static func scan(_ directory: URL) -> (plugins: [LensWorksPluginStore.Installed], damaged: [LensWorksPluginStore.Damaged]) {
        var found: [LensWorksPluginStore.Installed] = [], broken: [LensWorksPluginStore.Damaged] = []
        let names = ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []).filter { LensWorksPluginManifest.isIdentifier($0) }.sorted()
        for name in names.prefix(LensWorksPluginStore.maximumPlugins * 2) {
            do { found.append(try installed(directory, name).plugin) }
            catch { broken.append(.init(id: name, problem: error.localizedDescription)) }
        }
        return (found, broken)
    }

    /// Writes a checked package whole into a staging folder beside its place and puts it there with `place`. A
    /// failure at any point leaves what was installed before exactly as it was, and no staging folder behind.
    static func write(_ checked: Checked, source: String, into directory: URL, place: (_ staged: URL, _ destination: URL) throws -> Void) throws {
        let files = FileManager.default
        try files.createDirectory(at: directory, withIntermediateDirectories: true)
        let staging = directory.appendingPathComponent(".installing-" + UUID().uuidString, isDirectory: true)
        try files.createDirectory(at: staging, withIntermediateDirectories: false)
        defer { try? files.removeItem(at: staging) }
        try checked.manifestData.write(to: staging.appendingPathComponent(LensWorksPluginManifest.fileName))
        try checked.module.write(to: staging.appendingPathComponent(LensWorksPluginManifest.moduleName))
        let record: [String: Any] = ["schema": 1, "id": checked.manifest.id, "moduleSHA256": checked.moduleHash, "manifestSHA256": checked.manifestHash, "source": source]
        try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys, .prettyPrinted]).write(to: staging.appendingPathComponent(recordName))
        try place(staging, folder(directory, checked.manifest.id))
    }

    /// Puts the staged folder at `destination`. Over an installed plugin this is one atomic replacement: the old
    /// folder stays in place until the new one has taken it, so a failure never leaves the plugin uninstalled.
    static func place(staged: URL, destination: URL) throws {
        let files = FileManager.default
        if files.fileExists(atPath: destination.path) { _ = try files.replaceItemAt(destination, withItemAt: staged) }
        else { try files.moveItem(at: staged, to: destination) }
    }
}

/// The filter plugins the person installed. A package is a folder holding `plugin.json` and `filter.wasm`; installing
/// one checks the manifest and the module (every import, export and limit), copies both into LensWorks's own
/// Application Support folder and records their SHA-256 hashes. Every run reads the installed copy again, checks it
/// is still the bytes that were installed and validates it again, so a file changed behind LensWorks's back never
/// runs. Installing, removing and reloading are the person's decisions: no agent command reaches this type's
/// mutating functions. The store's lists live on the main actor; reading, hashing, compiling and moving files
/// happen off it (`LensWorksPluginFiles`), one change at a time.
@MainActor @Observable final class LensWorksPluginStore {
    /// The person's plugins, under the one accessor for their Application Support folder (a per-process stand-in
    /// under XCTest).
    static let shared = LensWorksPluginStore(directory: sharedDirectory)
    nonisolated static let sharedDirectory = LensWorksUserState.applicationSupport.appendingPathComponent("Plugins", isDirectory: true)
    nonisolated static let recordName = LensWorksPluginFiles.recordName
    nonisolated static let changedProblem = LensWorksPluginFiles.changedProblem
    /// The most plugins that can be installed at once.
    nonisolated static let maximumPlugins = 64

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

    nonisolated let directory: URL
    private(set) var plugins: [Installed] = []
    private(set) var damaged: [Damaged] = []
    /// The result of the last install, remove or reload, for the settings pane.
    var lastMessage: String?
    var lastError: String?
    /// How a staged folder is put in its place: `LensWorksPluginFiles.place`, or a test's stand-in that fails.
    @ObservationIgnored var place: @Sendable (_ staged: URL, _ destination: URL) throws -> Void = { try LensWorksPluginFiles.place(staged: $0, destination: $1) }
    /// Told what file work is starting, on the thread doing it: how a test sees that none of it holds the main actor.
    @ObservationIgnored var observer: (@Sendable (_ work: String) -> Void)?
    /// The last change or reading queued: each waits for the one before it, so two never interleave.
    @ObservationIgnored private var last: Task<Void, Never>

    /// The folder is read (every installed module hashed) off the main actor; `plugins` fills in when that is done,
    /// and every later call waits for it.
    init(directory: URL) {
        self.directory = directory
        last = Task {}
        last = Task { [weak self] in await self?.rescan() }
    }

    /// Runs `body` after everything queued before it, so the lists it reads are current and stay so until it ends.
    private func serialized<T: Sendable>(_ body: @escaping @MainActor () async throws -> T) async throws -> T {
        let previous = last
        let task = Task { @MainActor in await previous.value; return try await body() }
        last = Task { _ = await task.result }
        return try await task.value
    }
    /// Work on the plugin files, off the main actor.
    private func files<T: Sendable>(_ work: String, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        let observer = observer
        return try await Task.detached(priority: .userInitiated) { observer?(work); return try body() }.value
    }
    /// Reads the folder — every installed module, hashed — and takes what it found.
    private func rescan() async {
        let directory = directory
        guard let scanned = try? await files("scan", { LensWorksPluginFiles.scan(directory) }) else { return }
        plugins = scanned.plugins; damaged = scanned.damaged
    }

    /// Returns once the folder has been read and every change queued so far has finished.
    func loaded() async { await last.value }

    func plugin(_ id: String) -> Installed? { plugins.first { $0.id == id } }

    /// Installs the package at `package`, or replaces the installed plugin of the same id when its bytes differ.
    @discardableResult func install(from package: URL) async throws -> Outcome {
        try await serialized { try await self.installNow(from: package, expecting: nil) }
    }
    private func installNow(from package: URL, expecting id: String?) async throws -> Outcome {
        let directory = directory, place = place
        // Reading the package, parsing its manifest and compiling its module to check it: off the main actor.
        let checked = try await files("check") { try LensWorksPluginFiles.check(package: package) }
        let manifest = checked.manifest
        if let id, manifest.id != id {
            throw LensWorksPluginFailure("The package at \(package.path) is now the plugin \(manifest.id), not \(id). Install it as a new plugin instead.")
        }
        let installed = Installed(manifest: manifest, moduleHash: checked.moduleHash, manifestHash: checked.manifestHash, source: package.standardizedFileURL.path)
        let previous = plugin(manifest.id)
        if let previous, previous.moduleHash == installed.moduleHash, previous.manifestHash == installed.manifestHash,
           (try? await files("read", { try LensWorksPluginFiles.installed(directory, manifest.id) })) != nil {
            return .unchanged(previous)
        }
        if previous == nil, !damaged.contains(where: { $0.id == manifest.id }), plugins.count + damaged.count >= Self.maximumPlugins {
            throw LensWorksPluginFailure("At most \(Self.maximumPlugins) plugins can be installed. Remove one first.")
        }
        // Another installed plugin may not show the same name: the id alongside tells them apart, the name should too.
        if let twin = plugins.first(where: { $0.id != manifest.id && $0.manifest.name.lowercased() == manifest.name.lowercased() }) {
            throw LensWorksPluginFailure("The plugin’s manifest was refused: “name” is already the name of the installed plugin \(twin.id).")
        }
        do { try await files("write") { try LensWorksPluginFiles.write(checked, source: installed.source, into: directory, place: place) } }
        catch { await rescan(); throw LensWorksPluginFailure("The plugin could not be installed: " + error.localizedDescription) }
        await rescan()
        guard let now = plugin(manifest.id) else { throw LensWorksPluginFailure("The plugin could not be installed.") }
        return previous.map { .replaced(now, previousHash: $0.moduleHash) } ?? .installed(now)
    }

    /// Removes an installed (or damaged) plugin: its command is gone from the menus and from agents at once.
    func remove(_ id: String) async throws {
        try await serialized {
            guard LensWorksPluginManifest.isIdentifier(id), self.plugins.contains(where: { $0.id == id }) || self.damaged.contains(where: { $0.id == id }) else {
                throw LensWorksPluginFailure("That plugin is not installed.")
            }
            let location = LensWorksPluginFiles.folder(self.directory, id)
            do { try await self.files("remove") { try FileManager.default.removeItem(at: location) } }
            catch { await self.rescan(); throw LensWorksPluginFailure("The plugin could not be removed: " + error.localizedDescription) }
            await self.rescan()
        }
    }

    /// Reads the plugin's package again from the folder it was installed from, and replaces the installed copy when
    /// the bytes changed. The package must still be the same plugin.
    @discardableResult func reload(_ id: String) async throws -> Outcome {
        try await serialized {
            guard let current = self.plugin(id) else { throw LensWorksPluginFailure("That plugin is not installed.") }
            return try await self.installNow(from: URL(fileURLWithPath: current.source, isDirectory: true), expecting: id)
        }
    }

    /// The installed plugin and its module, read from LensWorks's own copy: the bytes must still hash to what was
    /// installed, and the module is validated again by the sandbox when it is instantiated.
    func load(_ id: String) async throws -> (plugin: Installed, module: Data) {
        try await serialized {
            guard let installed = self.plugin(id) else {
                throw LensWorksPluginFailure(self.damaged.first { $0.id == id }.map { "The plugin \(id) cannot run. " + $0.problem } ?? "The plugin \(id) is not installed.")
            }
            let directory = self.directory
            let changed = LensWorksPluginFailure(Self.changedProblem)
            do {
                let read = try await self.files("read") { try LensWorksPluginFiles.installed(directory, id) }
                guard read.plugin == installed else { throw changed }
                return read
            } catch let failure as LensWorksPluginFailure where failure == changed {
                await self.rescan()
                throw LensWorksPluginFailure("The plugin \(id) cannot run. " + Self.changedProblem)
            }
        }
    }

    /// Reads the plugins directory again. A folder that is not a whole plugin with a readable manifest and exactly
    /// the bytes that were installed is listed as damaged.
    func refresh() async {
        _ = try? await serialized { await self.rescan() }
    }
}
