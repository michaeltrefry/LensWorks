import Foundation
import SwiftUI
import ImageIO
import simd

nonisolated struct LensWorksPanoramaOutcome: Sendable {
    let dng: URL
    let provenance: LWPanoramaProvenance
    let asset: LensWorksCatalogAsset
    let result: LWPanoramaResult
}

/// Merge to Panorama… on the catalog. The catalog side it shares with Merge to HDR… is in
/// LensWorksDerivedMerge.swift.
extension LensWorksCatalog {
    var isMergingPanorama: Bool { merge?.kind == .panorama }
    private static let panoramaTooFew = "Select two or more overlapping photos."
    private static var panoramaTooMany: String { "Select at most \(LWPanoramaStitcher.maximumFrames) photos." }
    /// Why Merge to Panorama… is unavailable now, or nil when the selection can be merged.
    func panoramaMergeAvailability() -> String? {
        mergeAvailability(.panorama, frames: 2...LWPanoramaStitcher.maximumFrames, tooFew: Self.panoramaTooFew, tooMany: Self.panoramaTooMany)
    }
    /// Why the running panorama merge cannot be cancelled now, or nil when it can.
    var panoramaMergeCancelReason: String? { mergeCancelReason(.panorama) }
    /// Cancels the running panorama merge: nothing is written beside the photos or added to the catalog.
    func cancelPanoramaMerge() { cancelMerge(.panorama) }

    /// Develops one original for a panorama of `frames` photos; the panorama's memory budget is
    /// checked as soon as the dimensions are known, before the frame is loaded.
    nonisolated static func developPanoramaFrame(original: LWCatalogNativePath, url: URL, frames: Int = 2, budget: Int = LWMergeBudget.bytes) async throws -> LWMergeFrame {
        try await developMergeFrame(original: original, url: url) { width, height in
            try LWPanoramaStitcher.admit(frames: frames, width: width, height: height, budget: budget)
        }
    }

    /// The focal length the photo's metadata implies, in pixels of the developed frame: the
    /// 35 mm-equivalent focal length against the 43.27 mm diagonal of that format.
    nonisolated static func focalHint(_ url: URL, width: Int, height: Int) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = properties[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let equivalent = (exif[kCGImagePropertyExifFocalLenIn35mmFilm] as? NSNumber)?.doubleValue, equivalent > 0 else { return nil }
        return equivalent / 43.27 * (Double(width * width + height * height)).squareRoot()
    }

    /// Stitches the selected photos into a new linear floating-point DNG beside the first source,
    /// imports that one file into this catalog, records its sources against it and selects it.
    /// Sources are only read; their bytes are re-verified before the DNG is put in place.
    /// Cancelling (the Cancel command, the calling task, or the catalog scope ending) stops the
    /// merge and leaves no file.
    func mergeSelectionToPanorama(projection: LWPanoramaProjection = .spherical, boundary: LWPanoramaBoundary = .autoCrop) async throws -> LensWorksPanoramaOutcome {
        try await runMerge(.panorama, availability: panoramaMergeAvailability()) { scope in
            let options = LWPanoramaOptions(projection: projection, boundary: boundary)
            let output = try await self.performMerge(.panorama, scope: scope, frames: 2...LWPanoramaStitcher.maximumFrames, tooFew: Self.panoramaTooFew, tooMany: Self.panoramaTooMany) { originals in
                let count = originals.count, names = originals.map(\.url.lastPathComponent)
                do {
                    var frames = try await self.developMergeFrames(originals, kind: .panorama, scope: scope) { width, height in
                        try LWPanoramaStitcher.admit(frames: count, width: width, height: height)
                    }
                    let first = originals[0].url, hint = Self.focalHint(first, width: frames[0].width, height: frames[0].height)
                    self.status = "Aligning \(count) photos…"
                    let aligned = try await Self.detached { [frames] in try LWPanoramaStitcher.align(frames, focalHint: hint) }
                    try self.checkScope(scope)
                    self.status = "Blending \(count) photos into a panorama…"
                    let result = try await Self.detached { [frames] in try LWPanoramaStitcher.compose(frames, alignment: aligned.alignment, works: aligned.works, options: options) }
                    frames = []  // Not needed for the write.
                    let alignment = result.alignment
                    let provenance = LWPanoramaProvenance(documentID: UUID().uuidString, projection: projection, boundary: boundary, focalPixels: alignment.focal,
                        baselineExposure: Double(-log2(LWPanoramaDNGWriter.normalization(result))), sources: originals.indices.map { index in
                            LWPanoramaProvenance.Source(record: originals[index].record, rotation: simd_quatd(alignment.rotations[index]).vector,
                                relativeExposureEV: Double(log2(alignment.gains[index].y)), profile: Self.profileName(originals[index].url))
                        })
                    return LensWorksMergePlan(product: (result, provenance), stem: first.deletingPathExtension().lastPathComponent + LensWorksDerivedKind.panorama.suffix) { temporary in
                        try LWPanoramaDNGWriter.write(result, provenance: provenance, reference: Self.referenceMetadata(first), to: temporary)
                    }
                } catch let error as LWPanoramaError {
                    // The stitcher knows frames by number; a person knows them by file name.
                    throw LensWorksCatalogError.message(error.message(names: names))
                }
            }
            return LensWorksPanoramaOutcome(dng: output.dng, provenance: output.product.1, asset: output.asset, result: output.product.0)
        }
    }
}

/// The catalog toolbar's registered Merge to Panorama… command; its sheet asks for the
/// projection and what to do with the uncovered border.
struct LensWorksPanoramaMergeButton: View {
    let catalog: LensWorksCatalog
    let workspace: ProjectWorkspace
    @State private var confirming = false
    @State private var projection = LWPanoramaProjection.spherical
    @State private var boundary = LWPanoramaBoundary.autoCrop
    var body: some View {
        LensWorksMergeButton(kind: .panorama, catalog: catalog, availability: catalog.panoramaMergeAvailability(), confirming: $confirming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Merge \(catalog.selectionCount) Photos to a Panorama").font(.headline)
                Text("Creates a new linear floating-point DNG beside the first photo and adds it to the catalog. The originals are not changed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Picker("Projection", selection: $projection) {
                    ForEach(LWPanoramaProjection.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("LensWorks.panoramaProjection")
                Picker("Edges", selection: $boundary) {
                    ForEach(LWPanoramaBoundary.allCases, id: \.self) { Text($0.title).tag($0) }
                }.accessibilityIdentifier("LensWorks.panoramaBoundary")
                LensWorksMergeSheetButtons(confirming: $confirming, confirmIdentifier: "LensWorks.panoramaMergeConfirm") {
                    let projection = projection, boundary = boundary
                    Task {
                        let scope = catalog.captureScope()
                        do {
                            _ = try await catalog.mergeSelectionToPanorama(projection: projection, boundary: boundary)
                            try catalog.checkScope(scope)
                            await catalog.createWorkingVersion(workspace: workspace)
                        } catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
                    }
                }
            }
        }
    }
}
