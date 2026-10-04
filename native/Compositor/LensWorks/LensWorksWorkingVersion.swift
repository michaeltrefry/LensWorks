import Foundation

/// Source identity is published atomically with layers inside the native project package.
nonisolated struct LensWorksWorkingVersion: Codable, Sendable, Identifiable {
    var schema = 1
    let id: UUID
    let photoID: String
    let catalogPath: String
    let originalPath: String
    var projectPath: String
    var name: String

    static func sidecar(for project: URL) -> URL {
        project.appendingPathExtension("lensworks.json")
    }

    func validateDestination(_ destination: URL) throws {
        let source = URL(fileURLWithPath: originalPath).resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        let catalog = URL(fileURLWithPath: catalogPath).resolvingSymlinksInPath().standardizedFileURL
        guard target != catalog, !target.path.hasPrefix(catalog.path + "/"), !catalog.path.hasPrefix(target.path + "/") else {
            throw LensWorksCatalogError.message("Choose a destination outside the catalog folder. Catalog databases and previews must remain separate from photos and working versions.")
        }
        // A package replacing a folder that contains the source would also destroy the original.
        guard source != target, !source.path.hasPrefix(target.path + "/") else {
            throw LensWorksCatalogError.message("Choose a different destination. The original photo must remain unchanged.")
        }
        if let sourceID = try? source.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
           let targetID = try? target.resourceValues(forKeys: [.fileResourceIdentifierKey]).fileResourceIdentifier as? NSObject,
           sourceID == targetID {
            throw LensWorksCatalogError.message("This destination refers to the original photo. Choose a different file.")
        }
    }

    static func read(from project: URL) throws -> Self? {
        struct Header: Decodable { let workingVersionID: UUID? }
        let manifest = project.appendingPathComponent("manifest.json")
        let manifestValues = try manifest.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard manifestValues.isRegularFile == true, manifestValues.isSymbolicLink != true,
              let manifestSize = manifestValues.fileSize, manifestSize <= 4 * 1024 * 1024 else { throw ProjectError.invalid }
        let header = try JSONDecoder().decode(Header.self, from: Data(contentsOf: manifest))
        let embedded = project.appendingPathComponent("LensWorks.json")
        let metadata = header.workingVersionID != nil || FileManager.default.fileExists(atPath: embedded.path) ? embedded : sidecar(for: project)
        guard FileManager.default.fileExists(atPath: metadata.path) else {
            guard header.workingVersionID == nil else {
                throw LensWorksCatalogError.message("The working version’s source record is missing. The project has not been opened.")
            }
            return nil
        }
        let values = try metadata.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, let size = values.fileSize, size <= 64 * 1024 else {
            throw LensWorksCatalogError.message("The working version’s source record is invalid.")
        }
        var record = try JSONDecoder().decode(Self.self, from: Data(contentsOf: metadata))
        guard record.schema == 1, !record.photoID.isEmpty, !record.originalPath.isEmpty,
              header.workingVersionID == nil || record.id == header.workingVersionID else {
            throw LensWorksCatalogError.message("The working version’s source record is invalid.")
        }
        record.projectPath = project.path
        try record.validateDestination(project)
        return record
    }

    func encoded() throws -> Data {
        guard schema == 1, !photoID.isEmpty, !originalPath.isEmpty, !catalogPath.isEmpty else {
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
    func sourceAvailable(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    func versionForDestination(_ version: LensWorksWorkingVersion?, destination: URL) throws -> LensWorksWorkingVersion? {
        guard let version else { return nil }
        try version.validateDestination(destination)
        let existing = URL(fileURLWithPath: version.projectPath).resolvingSymlinksInPath().standardizedFileURL
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        guard existing != target else { return version }
        return LensWorksWorkingVersion(id: UUID(), photoID: version.photoID, catalogPath: version.catalogPath,
            originalPath: version.originalPath, projectPath: destination.path, name: destination.deletingPathExtension().lastPathComponent)
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
