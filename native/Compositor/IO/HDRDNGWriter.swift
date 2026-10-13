import Foundation

/// Where a merged HDR photo came from, embedded in the DNG's XMP packet so the record
/// of its sources travels with the file. The catalog keeps its own copy of the link
/// (LensWorksCatalogIndex.recordSources), which is what the app reads. The packet
/// names each source by file name only and names no catalog: the file is meant to
/// be shared, so it carries no local path.
nonisolated struct LWHDRMergeProvenance: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let catalogImageID: String
        let assetID: String
        let variantID: String
        /// The source's file name; never a path.
        let fileName: String
        let sha256: String
        /// Exposure relative to the reference frame, in stops.
        let relativeExposureEV: Double
        let offset: LWHDROffset
        /// The source's embedded color profile name, when it has one.
        let profile: String?
        var record: LWDerivedSourceRecord { LWDerivedSourceRecord(catalogImageID: catalogImageID, assetID: assetID, variantID: variantID, fileName: fileName, sha256: sha256) }
    }
    let documentID: String
    let deghost: Bool
    let referenceIndex: Int
    /// Stops a renderer adds to the stored (normalized) samples to reproduce the reference exposure.
    let baselineExposure: Double
    let sources: [Source]

    static let namespace = "https://lensworks.trefry.net/ns/hdr-merge/1.0/"

    func xmp(creatorTool: String = "LensWorks Merge to HDR", reference: [String: String] = [:]) -> String {
        LWDerivedXMP.packet(creatorTool: creatorTool, documentID: documentID, prefix: "lwhdr", namespace: Self.namespace,
            fields: [("deghost", String(deghost)), ("referenceIndex", String(referenceIndex)), ("baselineExposure", String(baselineExposure))],
            sources: sources.map { s in
                (s.record, [("relativeExposureEV", String(s.relativeExposureEV)), ("offsetX", String(s.offset.x)), ("offsetY", String(s.offset.y))] + (s.profile.map { [("profile", $0)] } ?? []))
            }, reference: reference)
    }

    static func parse(xmp: Data) throws -> Self {
        let parsed = try LWDerivedXMP.parse(xmp: xmp, namespace: namespace, marker: "referenceIndex")
        let records = try parsed.sources()
        let sources = try zip(records, parsed.items).map { record, item -> Source in
            guard let ev = parsed.field("relativeExposureEV", of: item).flatMap(Double.init), let x = parsed.field("offsetX", of: item).flatMap(Int.init),
                  let y = parsed.field("offsetY", of: item).flatMap(Int.init) else { throw LWLinearDNGError.missingProvenance }
            return Source(catalogImageID: record.catalogImageID, assetID: record.assetID, variantID: record.variantID, fileName: record.fileName, sha256: record.sha256,
                relativeExposureEV: ev, offset: LWHDROffset(x: x, y: y), profile: parsed.field("profile", of: item))
        }
        guard let deghost = parsed.field("deghost").flatMap(Bool.init), let reference = parsed.field("referenceIndex").flatMap(Int.init),
              let baseline = parsed.field("baselineExposure").flatMap(Double.init) else { throw LWLinearDNGError.missingProvenance }
        return Self(documentID: parsed.documentID, deghost: deghost, referenceIndex: reference, baselineExposure: baseline, sources: sources)
    }
}

typealias LWHDRDNGError = LWLinearDNGError

/// Writes an HDR merge through the shared linear float DNG writer (LinearDNG.swift). Samples are
/// normalized so the brightest channel is 1.0; BaselineExposure restores the reference exposure.
nonisolated enum LWHDRDNGWriter {
    static func normalization(_ result: LWHDRMergeResult) -> Float {
        var peak: Float = 0
        for value in result.samples { peak = max(peak, value) }
        return LWLinearDNGWriter.normalization(peak: peak)
    }
    private static func header(_ result: LWHDRMergeResult, _ provenance: LWHDRMergeProvenance, _ reference: [String: String]) -> LWLinearDNGWriter.Header {
        LWLinearDNGWriter.Header(width: result.width, height: result.height, software: "LensWorks Merge to HDR", model: "LensWorks HDR Merge",
            xmp: provenance.xmp(reference: reference), baselineExposure: provenance.baselineExposure)
    }
    private static func samples(_ result: LWHDRMergeResult) -> (Int, UnsafeMutableBufferPointer<Float>) throws -> Void {
        let scale = normalization(result)
        return { first, block in
            for index in block.indices {
                let value = result.samples[first + index]
                guard value.isFinite else { throw LWLinearDNGError.invalid }
                block[index] = max(0, value) * scale
            }
        }
    }

    /// The whole file in memory, for callers that want the bytes. Merge to HDR… uses `write`.
    static func encode(_ result: LWHDRMergeResult, provenance: LWHDRMergeProvenance, reference: [String: String] = [:]) throws -> Data {
        var file = Data()
        try LWLinearDNGWriter.serialize(header(result, provenance, reference), samples: samples(result)) { file.append($0.bindMemory(to: UInt8.self)) }
        return file
    }

    /// Streams the file to `url`, which must not exist; an existing file is never replaced.
    static func write(_ result: LWHDRMergeResult, provenance: LWHDRMergeProvenance, reference: [String: String] = [:], to url: URL) throws {
        try LWLinearDNGWriter.write(header(result, provenance, reference), to: url, samples: samples(result))
    }
}

nonisolated extension LWDNGInspection {
    func provenance() throws -> LWHDRMergeProvenance {
        guard let xmp else { throw LWLinearDNGError.missingProvenance }
        return try LWHDRMergeProvenance.parse(xmp: xmp)
    }
    /// The HDR merge record of the DNG at `url`, read without its samples.
    static func provenance(at url: URL) throws -> LWHDRMergeProvenance { try LWHDRMergeProvenance.parse(xmp: xmp(at: url)) }
}
