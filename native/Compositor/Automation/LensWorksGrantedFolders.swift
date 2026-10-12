import Foundation
import Observation

/// The folders the person granted to automation (Settings › Automation). None by default. An agent's command may
/// name a file only inside one of them: every path argument is resolved to the real file it reaches (through `..`,
/// symbolic links and standardisation) and must still lie inside a granted folder, or the command is refused before
/// anything is read or written.
@Observable
final class LensWorksGrantedFolders {
    static let defaultsKey = "LensWorksAutomationGrantedFolders"
    static let rule = "Agents read and write files only inside folders granted to automation (LensWorks › Settings › Automation › Granted Folders)."
    /// The longest path an argument may carry.
    static let pathLimit = 4096

    struct Grant: Identifiable, Equatable, Codable {
        let id: UUID
        /// The folder's real path when it was granted, with symbolic links resolved.
        let path: String
        /// A bookmark that reopens the folder in a later launch (security-scoped where the sandbox requires one).
        var bookmark: Data?
    }

    private(set) var grants: [Grant]
    @ObservationIgnored private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        grants = (defaults.data(forKey: Self.defaultsKey)).flatMap { try? JSONDecoder().decode([Grant].self, from: $0) } ?? []
    }

    private func persist() {
        if grants.isEmpty { defaults.removeObject(forKey: Self.defaultsKey) }
        else if let data = try? JSONEncoder().encode(grants) { defaults.set(data, forKey: Self.defaultsKey) }
    }

    /// Grants `folder` (an existing directory) to automation. Granting a folder twice keeps one grant.
    @discardableResult func grant(_ folder: URL) throws -> Grant {
        let real = try Self.realPath(folder.path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: real, isDirectory: &isDirectory), isDirectory.boolValue else {
            throw LensWorksCommandRefusal(reason: "Only an existing folder can be granted to automation.")
        }
        guard real != "/" else { throw LensWorksCommandRefusal(reason: "The whole disk cannot be granted to automation; choose a folder.") }
        if let existing = grants.first(where: { $0.path == real }) { return existing }
        let url = URL(fileURLWithPath: real, isDirectory: true)
        let bookmark = (try? url.bookmarkData(options: .withSecurityScope, includingResourceValuesForKeys: nil, relativeTo: nil))
            ?? (try? url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil))
        let grant = Grant(id: UUID(), path: real, bookmark: bookmark)
        grants.append(grant); persist()
        return grant
    }

    /// Takes a grant back: from now on every path inside it is refused.
    func revoke(_ id: UUID) {
        grants.removeAll { $0.id == id }; persist()
    }

    /// The real path `path` reaches: absolute, standardised (no `.` or `..`), with every symbolic link in its longest
    /// existing prefix resolved. What does not exist yet (a file about to be written) keeps its literal name.
    static func realPath(_ path: String) throws -> String {
        guard !path.isEmpty, path.utf8.count <= pathLimit, !path.contains("\0") else {
            throw LensWorksCommandRefusal(reason: "A path must be 1 to \(pathLimit) bytes with no NUL.")
        }
        guard path.hasPrefix("/") else { throw LensWorksCommandRefusal(reason: "A path must be absolute (start with “/”). " + rule) }
        // Standardise lexically first, so `..` can never be read against a symbolic link's target.
        var parts: [String] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(part))
        }
        var existing = parts, missing: [String] = []
        while true {
            let candidate = "/" + existing.joined(separator: "/")
            var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
            if realpath(candidate, &buffer) != nil {
                let resolved = String(cString: buffer)
                return missing.isEmpty ? resolved : (resolved == "/" ? "" : resolved) + "/" + missing.reversed().joined(separator: "/")
            }
            // A dangling symbolic link is not "missing": it names a place outside what was checked.
            var info = stat()
            if lstat(candidate, &info) == 0, (info.st_mode & S_IFMT) == S_IFLNK {
                throw LensWorksCommandRefusal(reason: "The path goes through a symbolic link that cannot be resolved. " + rule)
            }
            guard let last = existing.popLast() else { throw LensWorksCommandRefusal(reason: "The path cannot be resolved. " + rule) }
            missing.append(last)
        }
    }

    /// Whether `real` (a resolved path) is `folder` or lies inside it.
    static func contains(_ folder: String, _ real: String) -> Bool {
        real == folder || real.hasPrefix(folder.hasSuffix("/") ? folder : folder + "/")
    }

    /// The grant a resolved path lies inside, or nil.
    func grant(containing real: String) -> Grant? {
        grants.first { grant in
            // The granted folder must still be the directory that was granted: one since replaced by a link to
            // somewhere else resolves away from the granted path and admits nothing.
            guard Self.contains(grant.path, real), (try? Self.realPath(grant.path)) == grant.path else { return false }
            var isDirectory: ObjCBool = false
            return FileManager.default.fileExists(atPath: grant.path, isDirectory: &isDirectory) && isDirectory.boolValue
        }
    }

    /// Admits a path an agent named: the file URL of the real location it reaches, when that lies inside a granted
    /// folder. Throws the granted-folder refusal otherwise; nothing is read or written.
    func admit(_ path: String) throws -> URL {
        guard !grants.isEmpty else { throw LensWorksCommandRefusal(reason: "No folders are granted to automation, so no file can be named. " + Self.rule) }
        let real = try Self.realPath(path)
        guard grant(containing: real) != nil else {
            throw LensWorksCommandRefusal(reason: "“\(path.prefix(256))” is outside every folder granted to automation. " + Self.rule)
        }
        return URL(fileURLWithPath: real)
    }

    /// Runs `body` with access to the granted folder holding `url` (a no-op outside the sandbox).
    func withAccess<T>(to url: URL, _ body: () async throws -> T) async throws -> T {
        var scoped: URL?
        if let bookmark = grant(containing: url.path)?.bookmark {
            var stale = false
            if let folder = try? URL(resolvingBookmarkData: bookmark, options: .withSecurityScope, relativeTo: nil, bookmarkDataIsStale: &stale),
               folder.startAccessingSecurityScopedResource() { scoped = folder }
        }
        defer { scoped?.stopAccessingSecurityScopedResource() }
        return try await body()
    }
}
