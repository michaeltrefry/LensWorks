import Foundation
import Darwin

/// Current and retained Undo/Redo originals remain immutable even when an ordinary
/// RAW import has no catalog working-version record. Path metadata stays charged
/// through coordinated publication; no file is adopted or modified by this guard.
nonisolated final class LWSourceDestinationAuthority: @unchecked Sendable {
    private struct Original { let url:URL;let device:UInt64;let inode:UInt64 }
    private let originals: [Original]
    private let leases: [LWFloatWorkingSet.Lease]
    init(_ snapshot: ProjectSnapshot, workingSet: LWFloatWorkingSet = .sourceGraphs) throws {
        var values: [Original] = [], owners: [LWFloatWorkingSet.Lease] = [], seen: Set<String> = []
        func collect(_ project: ProjectSnapshot) throws {
            for layer in project.manifest.layers {
                try Task.checkCancellation()
                guard let source = layer.liveSource else { continue }
                let original = try source.original.localFileURL().resolvingSymlinksInPath().standardizedFileURL
                guard original.isFileURL else { throw ProjectError.invalid }
                let revision=try LWSourceMetadataStorage.withDecodeCharge(from:source.originalRevision) {
                    try LWCatalogCodec.decode(LWApplicationExportsDtoFileRevision.self,from:source.originalRevision)
                }
                let bytes = try LWSourceMetadataStorage.sum(768, LWSourceMetadataStorage.product(original.path.utf8.count, 6))
                // Reserve before the compound key/array growth. Multiple captured
                // identities at the same pathname remain distinct history guards.
                let lease = try workingSet.reserve(bytes)
                let key=original.path+":"+String(revision.identity.first.value)+":"+String(revision.identity.second.value)
                if seen.contains(key) { continue }
                seen.insert(key);values.append(Original(url:original,device:revision.identity.first.value,inode:revision.identity.second.value));owners.append(lease)
            }
        }
        try collect(snapshot)
        originals = values; leases = owners
    }
    func validate(_ destination: URL) throws {
        guard destination.isFileURL else { throw ProjectError.invalid }
        let target = destination.resolvingSymlinksInPath().standardizedFileURL
        for original in originals {
            guard target.path != original.url.path, !original.url.path.hasPrefix(target.path + "/") else { throw ProjectError.invalid }
            var source = stat(), output = stat()
            let sourceExists = original.url.path.withCString { lstat($0, &source) } == 0
            let targetExists = target.path.withCString { lstat($0, &output) } == 0
            if targetExists {
                // Captured Unix (dev,ino) is authoritative even if the original
                // name was removed/replaced after the source/history was captured.
                if UInt64(exactly:output.st_dev)==original.device && UInt64(exactly:output.st_ino)==original.inode { throw ProjectError.invalid }
                if sourceExists && source.st_dev == output.st_dev && source.st_ino == output.st_ino { throw ProjectError.invalid }
            }
        }
        withExtendedLifetime(leases) {}
    }
}
