import Foundation
import simd

/// Where a stitched panorama came from, embedded in the DNG's XMP packet so the record of its
/// sources travels with the file. The catalog keeps its own copy of the link
/// (LensWorksCatalogIndex.recordSources). The packet names each source by file name only.
nonisolated struct LWPanoramaProvenance: Equatable, Sendable {
    struct Source: Equatable, Sendable {
        let record: LWDerivedSourceRecord
        /// Camera-to-world rotation as a unit quaternion (x, y, z, w).
        let rotation: SIMD4<Double>
        /// Exposure relative to the set's mean, in stops (green channel).
        let relativeExposureEV: Double
        /// The source's embedded color profile name, when it has one.
        let profile: String?
    }
    let documentID: String
    let projection: LWPanoramaProjection
    let boundary: LWPanoramaBoundary
    /// The shared focal length the alignment solved, in source pixels.
    let focalPixels: Double
    /// Stops a renderer adds to the stored (normalized) samples to reproduce the merged exposure.
    let baselineExposure: Double
    let sources: [Source]

    static let namespace = "https://lensworks.trefry.net/ns/panorama-merge/1.0/"

    func xmp(creatorTool: String = "LensWorks Merge to Panorama", reference: [String: String] = [:]) -> String {
        LWDerivedXMP.packet(creatorTool: creatorTool, documentID: documentID, prefix: "lwpano", namespace: Self.namespace,
            fields: [("projection", projection.rawValue), ("boundary", boundary.rawValue), ("focalPixels", String(focalPixels)), ("baselineExposure", String(baselineExposure))],
            sources: sources.map { s in
                (s.record, [("rotationX", String(s.rotation.x)), ("rotationY", String(s.rotation.y)), ("rotationZ", String(s.rotation.z)), ("rotationW", String(s.rotation.w)),
                            ("relativeExposureEV", String(s.relativeExposureEV))] + (s.profile.map { [("profile", $0)] } ?? []))
            }, reference: reference)
    }

    static func parse(xmp: Data) throws -> Self {
        let parsed = try LWDerivedXMP.parse(xmp: xmp, namespace: namespace, marker: "projection")
        let records = try parsed.sources()
        let sources = try zip(records, parsed.items).map { record, item -> Source in
            func number(_ name: String) throws -> Double {
                guard let value = parsed.field(name, of: item).flatMap(Double.init) else { throw LWLinearDNGError.missingProvenance }
                return value
            }
            return Source(record: record, rotation: SIMD4(try number("rotationX"), try number("rotationY"), try number("rotationZ"), try number("rotationW")),
                relativeExposureEV: try number("relativeExposureEV"), profile: parsed.field("profile", of: item))
        }
        guard let projection = parsed.field("projection").flatMap(LWPanoramaProjection.init), let boundary = parsed.field("boundary").flatMap(LWPanoramaBoundary.init),
              let focal = parsed.field("focalPixels").flatMap(Double.init), let baseline = parsed.field("baselineExposure").flatMap(Double.init) else { throw LWLinearDNGError.missingProvenance }
        return Self(documentID: parsed.documentID, projection: projection, boundary: boundary, focalPixels: focal, baselineExposure: baseline, sources: sources)
    }
}

/// Writes a stitched panorama through the shared linear float DNG writer (LinearDNG.swift).
nonisolated enum LWPanoramaDNGWriter {
    static func normalization(_ result: LWPanoramaResult) -> Float {
        var peak: Float = 0
        result.samples.withUnsafeBufferPointer { samples in for value in samples { peak = max(peak, Float(value)) } }
        return LWLinearDNGWriter.normalization(peak: peak)
    }
    private static func header(_ result: LWPanoramaResult, _ provenance: LWPanoramaProvenance, _ reference: [String: String]) -> LWLinearDNGWriter.Header {
        LWLinearDNGWriter.Header(width: result.width, height: result.height, software: "LensWorks Merge to Panorama", model: "LensWorks Panorama Merge",
            xmp: provenance.xmp(reference: reference), baselineExposure: provenance.baselineExposure)
    }
    private static func samples(_ result: LWPanoramaResult) -> (Int, UnsafeMutableBufferPointer<Float>) throws -> Void {
        let scale = normalization(result)
        return { first, block in
            try result.samples.withUnsafeBufferPointer { source in
                for index in block.indices {
                    let value = Float(source[first + index])
                    guard value.isFinite else { throw LWLinearDNGError.invalid }
                    block[index] = max(0, value) * scale
                }
            }
        }
    }
    static func encode(_ result: LWPanoramaResult, provenance: LWPanoramaProvenance, reference: [String: String] = [:]) throws -> Data {
        var file = Data()
        try LWLinearDNGWriter.serialize(header(result, provenance, reference), samples: samples(result)) { file.append($0.bindMemory(to: UInt8.self)) }
        return file
    }
    /// Streams the file to `url`, which must not exist; an existing file is never replaced.
    static func write(_ result: LWPanoramaResult, provenance: LWPanoramaProvenance, reference: [String: String] = [:], to url: URL) throws {
        try LWLinearDNGWriter.write(header(result, provenance, reference), to: url, samples: samples(result))
    }
}

nonisolated extension LWDNGInspection {
    func panoramaProvenance() throws -> LWPanoramaProvenance {
        guard let xmp else { throw LWLinearDNGError.missingProvenance }
        return try LWPanoramaProvenance.parse(xmp: xmp)
    }
}
