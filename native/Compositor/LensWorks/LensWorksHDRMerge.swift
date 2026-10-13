import Foundation
import SwiftUI

nonisolated struct LensWorksHDRMergeOutcome: Sendable {
    let dng: URL
    let provenance: LWHDRMergeProvenance
    let asset: LensWorksCatalogAsset
    let result: LWHDRMergeResult
}

/// A file the caller's `admit` check refused while rebuilding a merge link: passed through, never read as offline.
nonisolated struct LensWorksHDRSourceRefusal: Error {
    let error: Error
}

/// Merge to HDR… on the catalog. The catalog side it shares with Merge to Panorama… is in
/// LensWorksDerivedMerge.swift.
extension LensWorksCatalog {
    var isMergingHDR: Bool { merge?.kind == .hdr }
    private static let hdrTooFew = "Select two or more bracketed photos."
    private static var hdrTooMany: String { "Select at most \(LWHDRMerger.maximumFrames) bracketed photos." }
    /// Why Merge to HDR… is unavailable now, or nil when the selection can be merged.
    func hdrMergeAvailability() -> String? {
        mergeAvailability(.hdr, frames: 2...LWHDRMerger.maximumFrames, tooFew: Self.hdrTooFew, tooMany: Self.hdrTooMany)
    }
    /// Why the running merge cannot be cancelled now, or nil when it can.
    var hdrMergeCancelReason: String? { mergeCancelReason(.hdr) }
    /// Cancels the running merge: nothing is written beside the photos or added to the catalog.
    func cancelHDRMerge() { cancelMerge(.hdr) }

    /// Develops one original for an HDR merge. `frames` is the size of the bracket it belongs to:
    /// the merge's memory budget is checked as soon as the dimensions are known.
    nonisolated static func developHDRFrame(original: LWCatalogNativePath, url: URL, frames: Int = 1, budget: Int = LWHDRMerger.budgetBytes) async throws -> LWHDRFrame {
        try await developMergeFrame(original: original, url: url) { width, height in
            try LWHDRMerger.admit(frames: frames, width: width, height: height, budget: budget)
        }
    }

    /// Merges the selected bracket into a new linear floating-point DNG beside the first source,
    /// imports that one file into this catalog, records its sources against it and selects it.
    /// Sources are only read; their bytes are re-verified before the DNG is put in place.
    /// Cancelling (the Cancel command, the calling task, or the catalog scope ending) stops the
    /// merge and leaves no file. `admitted` is what an agent's request was checked against (each source original's
    /// path, in selection order): with it, nothing is read or written unless the selection still reaches exactly those.
    func mergeSelectionToHDR(deghost: Bool = true, admitted: [String]? = nil) async throws -> LensWorksHDRMergeOutcome {
        try await runMerge(.hdr, availability: hdrMergeAvailability()) { scope in
            let output = try await self.performMerge(.hdr, scope: scope, frames: 2...LWHDRMerger.maximumFrames, tooFew: Self.hdrTooFew, tooMany: Self.hdrTooMany, checked: admitted) { originals in
                let count = originals.count
                var frames = try await self.developMergeFrames(originals, kind: .hdr, scope: scope) { width, height in
                    try LWHDRMerger.admit(frames: count, width: width, height: height)
                }
                self.status = "Merging \(frames.count) photos to HDR…"
                let result = try await Self.detached { [frames] in try LWHDRMerger.merge(frames, options: LWHDRMergeOptions(deghost: deghost)) }
                frames = []  // Not needed for the write.
                let reference = originals[result.referenceIndex].url
                let provenance = LWHDRMergeProvenance(documentID: UUID().uuidString, deghost: deghost, referenceIndex: result.referenceIndex,
                    baselineExposure: Double(-log2(LWHDRDNGWriter.normalization(result))), sources: originals.indices.map { index in
                        LWHDRMergeProvenance.Source(catalogImageID: originals[index].row.imageID, assetID: originals[index].row.key.asset_id,
                            variantID: originals[index].row.key.variant_id, fileName: originals[index].url.lastPathComponent, sha256: originals[index].sha256,
                            relativeExposureEV: log2(result.exposures[index]), offset: result.offsets[index], profile: Self.profileName(originals[index].url))
                    })
                return LensWorksMergePlan(product: (result, provenance), stem: reference.deletingPathExtension().lastPathComponent + LensWorksDerivedKind.hdr.suffix) { temporary in
                    try LWHDRDNGWriter.write(result, provenance: provenance, reference: Self.referenceMetadata(reference), to: temporary)
                }
            }
            return LensWorksHDRMergeOutcome(dng: output.dng, provenance: output.product.1, asset: output.asset, result: output.product.0)
        }
    }
}

/// The catalog toolbar's registered Merge to HDR… command; its sheet asks about deghosting.
struct LensWorksHDRMergeButton: View {
    let catalog: LensWorksCatalog
    let workspace: ProjectWorkspace
    @State private var confirming = false
    @State private var deghost = true
    var body: some View {
        LensWorksMergeButton(kind: .hdr, catalog: catalog, availability: catalog.hdrMergeAvailability(), confirming: $confirming) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Merge \(catalog.selectionCount) Photos to HDR").font(.headline)
                Text("Creates a new linear floating-point DNG beside the first photo and adds it to the catalog. The originals are not changed.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                Toggle("Deghost moving subjects", isOn: $deghost).accessibilityIdentifier("LensWorks.hdrDeghost")
                LensWorksMergeSheetButtons(confirming: $confirming, confirmIdentifier: "LensWorks.hdrMergeConfirm") {
                    let deghost = deghost
                    Task {
                        let scope = catalog.captureScope()
                        do {
                            _ = try await catalog.mergeSelectionToHDR(deghost: deghost)
                            try catalog.checkScope(scope)
                            await catalog.createWorkingVersion(workspace: workspace)
                        } catch { if !(error is CancellationError), catalog.scopeIsCurrent(scope) { catalog.error = error.localizedDescription } }
                    }
                }
            }
        }
    }
}
