import Foundation
import Darwin

/// Source identity is published atomically with layers inside the native project package.
nonisolated struct LensWorksWorkingVersion: Codable, Sendable, Identifiable {
    var schema = 1
    let id: UUID
    let photoID: String
    let catalogPath: String
    let originalPath: String
    var projectPath: String
    var name: String
    var originalNativePath: LWCatalogNativePath? = nil
    var originalVariantKey: LWCatalogEditsVariantKey? = nil
    // Schema-1 records predating logical copies describe the retained master.
    var sourceVariantID: String { originalVariantKey?.variant_id ?? "master" }

    /// The same version (identity, photo, copy and project) at its original's relinked location.
    func relinked(originalPath: String, native: LWCatalogNativePath?) -> Self {
        LensWorksWorkingVersion(id: id, photoID: photoID, catalogPath: catalogPath, originalPath: originalPath, projectPath: projectPath,
            name: name, originalNativePath: native, originalVariantKey: originalVariantKey)
    }

    static func sidecar(for project: URL) -> URL {
        project.appendingPathExtension("lensworks.json")
    }

    func validateDestination(_ destination: URL) throws {
        let source = try (originalNativePath?.localFileURL() ?? URL(fileURLWithPath: originalPath)).resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        let catalog = URL(fileURLWithPath: catalogPath).resolvingSymlinksInPath().standardizedFileURL
        guard target.path != catalog.path, !target.path.hasPrefix(catalog.path + "/"), !catalog.path.hasPrefix(target.path + "/") else {
            throw LensWorksCatalogError.message("Choose a destination outside the catalog folder. Catalog databases and previews must remain separate from photos and working versions.")
        }
        // A package replacing a folder that contains the source would also destroy the original.
        guard source.path != target.path, !source.path.hasPrefix(target.path + "/") else {
            throw LensWorksCatalogError.message("Choose a different destination. The original photo must remain unchanged.")
        }
        if let sourceID = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
           let targetID = try? target.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
           sourceID == targetID {
            throw LensWorksCatalogError.message("This destination refers to the original photo. Choose a different file.")
        }
    }

    private static func admittedBytes(_ url: URL, limit: Int) throws -> Data {
        let descriptor = url.path.withCString { Darwin.open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard descriptor >= 0 else { throw LensWorksCatalogError.message("The working version record could not be admitted.") }
        let file = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? file.close() }
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_mode & S_IFMT == S_IFREG, info.st_size >= 0, info.st_size <= limit else {
            throw LensWorksCatalogError.message("The working version record is not a bounded regular file.")
        }
        let bytes = try file.read(upToCount: limit + 1) ?? Data()
        guard bytes.count <= limit else { throw ProjectError.tooLarge }
        return bytes
    }

    static func read(from project: URL) throws -> Self? {
        struct Header: Decodable { let workingVersionID: UUID? }
        let manifest = project.appendingPathComponent("manifest.json")
        let header = try JSONDecoder().decode(Header.self, from: admittedBytes(manifest, limit: 4 * 1024 * 1024))
        let embedded = project.appendingPathComponent("LensWorks.json")
        let metadata = header.workingVersionID != nil || FileManager.default.fileExists(atPath: embedded.path) ? embedded : sidecar(for: project)
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            guard header.workingVersionID == nil else {
                throw LensWorksCatalogError.message("The working version’s source record is missing. The project has not been opened.")
            }
            return nil
        }
        var record = try JSONDecoder().decode(Self.self, from: admittedBytes(metadata, limit: 64 * 1024))
        guard record.schema == 1, !record.photoID.isEmpty, !record.originalPath.isEmpty, !record.catalogPath.isEmpty,
              record.originalVariantKey == nil || (record.originalVariantKey?.asset_id == record.photoID && record.originalVariantKey?.variant_id.isEmpty == false),
              ![record.photoID, record.catalogPath, record.originalPath, record.originalVariantKey?.variant_id ?? ""].contains(where: { $0.utf8.contains(0) }),
              header.workingVersionID == nil || record.id == header.workingVersionID else {
            throw LensWorksCatalogError.message("The working version’s source record is invalid.")
        }
        record.projectPath = project.path
        try record.validateDestination(project)
        return record
    }

    func encoded() throws -> Data {
        guard schema == 1, !photoID.isEmpty, !originalPath.isEmpty, !catalogPath.isEmpty,
              originalVariantKey == nil || (originalVariantKey?.asset_id == photoID && originalVariantKey?.variant_id.isEmpty == false),
              ![photoID, catalogPath, originalPath, originalVariantKey?.variant_id ?? ""].contains(where: { $0.utf8.contains(0) }) else {
            throw LensWorksCatalogError.message("The working version’s source record is invalid.")
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        guard data.count <= 64 * 1024 else { throw ProjectError.tooLarge }
        return data
    }

}

nonisolated struct LensWorksVersionListing: Sendable {
    let versions: [LensWorksWorkingVersion]
    let errors: [String]
}

actor LensWorksVersionStore {
    static let shared = LensWorksVersionStore()
    func read(_ project: URL) throws -> LensWorksWorkingVersion? { try LensWorksWorkingVersion.read(from: project) }
    func readIfExists(_ project: URL) throws -> LensWorksWorkingVersion? {
        guard FileManager.default.fileExists(atPath: project.path) else { return nil }
        return try LensWorksWorkingVersion.read(from: project)
    }
    func canonicalPath(_ path: String, outside catalogPath: String?) throws -> String {
        let target = URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path
        if let catalogPath {
            let catalog = URL(fileURLWithPath: catalogPath).resolvingSymlinksInPath().standardizedFileURL.path
            guard target != catalog, !target.hasPrefix(catalog + "/") else {
                throw LensWorksCatalogError.message("Choose a working version folder outside the catalog database and preview folder.")
            }
        }
        return target
    }
    func sourceAvailable(_ path: String, native: LWCatalogNativePath? = nil) -> Bool {
        guard let url = try? native?.localFileURL() ?? URL(fileURLWithPath: path) else { return false }
        return (try? url.checkResourceIsReachable()) == true
    }
    func versionForDestination(_ version: LensWorksWorkingVersion?, destination: URL) throws -> LensWorksWorkingVersion? {
        guard let version else { return nil }
        try version.validateDestination(destination)
        let existing = URL(fileURLWithPath: version.projectPath).resolvingSymlinksInPath().standardizedFileURL.path
        let target = destination.resolvingSymlinksInPath().standardizedFileURL.path
        // FileWrapper can leave the held URL's directory bit stale after first publication.
        guard existing != target else { return version }
        return LensWorksWorkingVersion(id: UUID(), photoID: version.photoID, catalogPath: version.catalogPath,
            originalPath: version.originalPath, projectPath: destination.path, name: destination.deletingPathExtension().lastPathComponent, originalNativePath: version.originalNativePath, originalVariantKey: version.originalVariantKey)
    }
    func validate(_ version: LensWorksWorkingVersion?, destination: URL) throws { try version?.validateDestination(destination) }

    // MARK: Independent named versions

    /// A version's name as it is stored: trimmed, not empty, at most 1,024 UTF-8 bytes.
    nonisolated static func versionName(_ name: String) throws -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.utf8.count <= 1_024, !trimmed.utf8.contains(0) else {
            throw LensWorksCatalogError.message("A version needs a name of at most 1,024 bytes.")
        }
        return trimmed
    }
    /// Where a new version named `name` goes in `folder`: the name with the characters a file name cannot hold
    /// replaced, and the start of its identifier so two versions with one name never collide.
    /// A file name holds 255 UTF-8 bytes, not characters, so the name is cut to a byte budget (between
    /// characters, never inside one); a leading dot, which would hide the package in the Finder, is replaced too.
    nonisolated static let packageNameBytes = 120
    nonisolated static func packageURL(named name: String, id: UUID, in folder: URL) -> URL {
        var safe = "", bytes = 0
        for character in name {
            let kept: Character = "/:\u{0}".contains(character) || (safe.isEmpty && character == ".") ? "-" : character
            let size = String(kept).utf8.count
            guard bytes + size <= packageNameBytes else { break }
            safe.append(kept); bytes += size
        }
        return folder.appendingPathComponent("\(safe)-\(id.uuidString.prefix(8)).comp")
    }
    /// The version at `version.projectPath`, if the package there still is that version.
    private func current(_ version: LensWorksWorkingVersion) throws -> (record: LensWorksWorkingVersion, project: URL) {
        let project = URL(fileURLWithPath: version.projectPath)
        guard FileManager.default.fileExists(atPath: project.path), let record = try LensWorksWorkingVersion.read(from: project), record.id == version.id else {
            throw LensWorksCatalogError.message("“\(version.name)” is no longer at \(version.projectPath). Reconcile working versions and try again.")
        }
        return (record, project)
    }
    /// An independent copy of a saved version, beside it, under a new identity and name: every layer, mask, source
    /// link, checkpoint and undo step. The original package is only read. The copy is assembled out of sight and
    /// appears complete or not at all.
    func duplicate(_ version: LensWorksWorkingVersion, named name: String) throws -> LensWorksWorkingVersion {
        let name = try Self.versionName(name)
        let (record, source) = try current(version)
        let id = UUID(), folder = source.deletingLastPathComponent()
        let destination = Self.packageURL(named: name, id: id, in: folder)
        guard !FileManager.default.fileExists(atPath: destination.path) else { throw LensWorksCatalogError.message("A project named \(destination.lastPathComponent) already exists.") }
        let staged = folder.appendingPathComponent(".LensWorks-" + UUID().uuidString + ".comp", isDirectory: true)
        defer { if FileManager.default.fileExists(atPath: staged.path) { try? FileManager.default.removeItem(at: staged) } }
        // A coordinated read: a save of this version still writing in a tab (or anywhere else) finishes first, so
        // the copy is never taken from a package caught between two saves.
        var coordination: NSError?, copying: Error?
        NSFileCoordinator().coordinate(readingItemAt: source, options: .withoutChanges, error: &coordination) { current in
            do { try FileManager.default.copyItem(at: current, to: staged) } catch { copying = error }
        }
        if let error = coordination ?? copying as NSError? { throw error }
        // The manifest names the version it belongs to; only that one value changes, so nothing else is re-encoded.
        struct Header: Decodable { let workingVersionID: UUID? }
        let manifestURL = staged.appendingPathComponent("manifest.json")
        var manifest = try Data(contentsOf: manifestURL)
        if let old = try JSONDecoder().decode(Header.self, from: manifest).workingVersionID {
            guard let text = String(data: manifest, encoding: .utf8) else { throw ProjectError.invalid }
            let pattern = try NSRegularExpression(pattern: "(\"workingVersionID\"\\s*:\\s*\")" + NSRegularExpression.escapedPattern(for: old.uuidString) + "\"", options: [.caseInsensitive])
            let range = NSRange(text.startIndex..., in: text)
            guard pattern.numberOfMatches(in: text, range: range) == 1 else { throw ProjectError.invalid }
            manifest = Data(pattern.stringByReplacingMatches(in: text, range: range, withTemplate: "$1" + id.uuidString + "\"").utf8)
            try manifest.write(to: manifestURL)
        }
        let copy = LensWorksWorkingVersion(id: id, photoID: record.photoID, catalogPath: record.catalogPath, originalPath: record.originalPath,
            projectPath: destination.path, name: name, originalNativePath: record.originalNativePath, originalVariantKey: record.originalVariantKey)
        try copy.encoded().write(to: staged.appendingPathComponent("LensWorks.json"))
        try LWHistoryArchive.rebind(staged, manifestSHA256: LWHistoryArchive.digest(manifest))
        guard try LensWorksWorkingVersion.read(from: staged)?.id == id else { throw ProjectError.invalid }
        try FileManager.default.moveItem(at: staged, to: destination)
        return copy
    }
    /// Renames a saved version in place. Its identity, its file and everything in it stay as they are.
    func rename(_ version: LensWorksWorkingVersion, to name: String) throws -> LensWorksWorkingVersion {
        let name = try Self.versionName(name)
        var (record, project) = try current(version)
        record.name = name
        let embedded = project.appendingPathComponent("LensWorks.json")
        let target = FileManager.default.fileExists(atPath: embedded.path) ? embedded : LensWorksWorkingVersion.sidecar(for: project)
        try record.encoded().write(to: target, options: .atomic)
        return record
    }
    /// Takes a saved version's package out of its folder with `remove` (the Trash, unless a caller says otherwise).
    /// Callers ask the person first: see `LWLossConfirmation`.
    func delete(_ version: LensWorksWorkingVersion, confirmation: LWLossConfirmation, remove: @Sendable (URL) throws -> Void) throws {
        guard confirmation.subject == version.id else { throw LensWorksCatalogError.message("Deleting “\(version.name)” was not confirmed.") }
        let (_, project) = try current(version)
        let sidecar = LensWorksWorkingVersion.sidecar(for: project)
        try remove(project)
        if FileManager.default.fileExists(atPath: sidecar.path) { try remove(sidecar) }
    }
    func list(paths: [String], directory: String?) -> LensWorksVersionListing {
        var projects = Set(paths), errors: [String] = []
        if let directory {
            do {
                let entries = try FileManager.default.contentsOfDirectory(at: URL(fileURLWithPath: directory), includingPropertiesForKeys: nil)
                for entry in entries where entry.pathExtension == "comp" { projects.insert(entry.path) }
            } catch { errors.append("\(directory): \(error.localizedDescription)") }
        }
        var versions: [LensWorksWorkingVersion] = []
        for path in projects.sorted() {
            let project = URL(fileURLWithPath: path)
            guard FileManager.default.fileExists(atPath: path) else { continue }
            do {
                if let version = try LensWorksWorkingVersion.read(from: project) { versions.append(version) }
            } catch { errors.append("\(path): \(error.localizedDescription)") }
        }
        return LensWorksVersionListing(versions: versions, errors: errors)
    }
}
