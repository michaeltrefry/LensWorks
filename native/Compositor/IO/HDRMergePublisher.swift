import Foundation
import CryptoKit

nonisolated struct HDRMergeSourceRecord: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
}

/// Provenance written beside the merged DNG; the catalog item for the DNG is linked to these sources.
nonisolated struct HDRMergeLinkRecord: Codable, Equatable, Sendable {
    let merged: String
    let sources: [HDRMergeSourceRecord]
    let deghost: Bool
    let align: Bool
}

nonisolated struct HDRMergePublication: Sendable {
    let dng: URL
    let link: URL
    let record: HDRMergeLinkRecord
    let destination: LWLinearMediaDestination
}

nonisolated enum HDRMergePublisher {
    static func sha256(_ url: URL) throws -> String {
        let lease = try LWFloatWorkingSet.sourceGraphs.reserve(4 * 1024 * 1024)
        defer { withExtendedLifetime(lease) {} }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { try Task.checkCancellation(); hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Compatibility for small mathematical controls; production retains planes.
    static func publish(_ result: HDRMergeResult, sources: [URL], into directory: URL, name: String,
                        options: HDRMergeOptions) throws -> HDRMergePublication {
        try LWFloatPlane.validateExtent(width: result.width, height: result.height)
        guard result.rgb.count == result.width * result.height * 3 else { throw HDRMergeError.invalidFrame }
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let builder = try workspace.makeBuilder(width: result.width, height: result.height)
        while let range = builder.nextRange {
            let bytes = try range.validate(frameWidth: result.width, frameHeight: result.height)
            let lease = try workspace.workingSet.reserve(bytes)
            var pixels = [SIMD4<Float>](); pixels.reserveCapacity(bytes / 16)
            for y in range.y..<(range.y + range.height) { for x in range.x..<(range.x + range.width) {
                let i = (y * result.width + x) * 3
                pixels.append(SIMD4(result.rgb[i], result.rgb[i + 1], result.rgb[i + 2], 1))
            } }
            try builder.append(LWLinearSurface(width: range.width, height: range.height, pixels: pixels, maximumBytes: bytes), at: range)
            withExtendedLifetime(lease) {}
        }
        return try publish(HDRPlaneMergeResult(plane: builder.finish(), referenceIndex: result.referenceIndex, shifts: result.shifts),
            sources: sources, into: directory, name: name, options: options)
    }

    /// Both data and provenance use the same physical media destination authority.
    /// A raced existing file is never replaced; interrupted partial files are removed.
    static func publish(_ result: HDRPlaneMergeResult, sources: [URL], expectedHashes: [String]? = nil,
                        into directory: URL, name: String, options: HDRMergeOptions) throws -> HDRMergePublication {
        guard !name.isEmpty, !name.contains("/"), !name.contains("\\"), !name.contains("\0"), name != ".", name != "..",
              expectedHashes == nil || expectedHashes?.count == sources.count else { throw HDRMergeError.invalidFrame }
        let destination = try LWLinearMediaDestination(output: directory, subdirectory: "HDR")
        let dng = destination.directory.appendingPathComponent(name).appendingPathExtension("dng")
        let link = dng.appendingPathExtension("sources.json")
        let paths = Set(sources.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        guard !paths.contains(dng.path), !paths.contains(link.path) else { throw HDRMergeError.destinationIsSource }
        let records = try sources.enumerated().map { index, url in
            let digest = try sha256(url)
            guard expectedHashes == nil || expectedHashes?[index] == digest else {
                throw LensWorksCatalogError.message("A bracketed original changed during the merge; no HDR was published.")
            }
            return HDRMergeSourceRecord(path: url.standardizedFileURL.path, sha256: digest)
        }
        let record = HDRMergeLinkRecord(merged: dng.lastPathComponent, sources: records, deghost: options.deghost, align: options.align)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let metadata = try encoder.encode(record)
        try LWLinearDNGWriter.writeDNG(result.plane, to: dng, destination: destination)
        do { try LWLinearDNGWriter.writeData(metadata, to: link, destination: destination) }
        catch {
            let primary = error
            do { try destination.removeUnimportedPublication(named: dng.lastPathComponent) }
            catch let failure as LWLinearMediaRecoveryError {
                throw LWLinearMediaRecoveryError(reason: primary.localizedDescription + " " + failure.reason,
                    recoveryPaths: ((primary as? LWLinearMediaRecoveryError)?.recoveryPaths ?? []) + failure.recoveryPaths)
            }
            throw primary
        }
        return HDRMergePublication(dng: dng, link: link, record: record, destination: destination)
    }
}
