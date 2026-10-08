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
