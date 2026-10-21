import AppKit
import CoreGraphics
import Foundation
import ImageIO

/// Decodes a catalog photo into a linear frame and the exposure it was taken at.
nonisolated enum HDRFrameLoader {
    /// Capture exposure only from the physical original; a missing/invalid field
    /// is a refusal, never an assumed ISO/aperture or a browse-preview substitute.
    static func exposureValue(_ url: URL) -> Double? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any],
              let time = (exif[kCGImagePropertyExifExposureTime] as? NSNumber)?.doubleValue,
              let iso = (exif[kCGImagePropertyExifISOSpeedRatings] as? [NSNumber])?.first?.doubleValue,
              let aperture = (exif[kCGImagePropertyExifFNumber] as? NSNumber)?.doubleValue,
              time.isFinite, iso.isFinite, aperture.isFinite, time > 0, iso > 0, aperture > 0 else { return nil }
        let value = log2(time) + log2(iso / 100) - 2 * log2(aperture)
        return value.isFinite ? value : nil
    }

    static func frames(_ urls: [URL]) async throws -> [HDRPlaneFrame] {
        guard urls.count >= 2 else { throw HDRMergeError.tooFewFrames }
        var loaded: [(LWFloatPlane, Double, URL, String)] = []
        for url in urls {
            try Task.checkCancellation()
            let before = try HDRMergePublisher.sha256(url)
            guard let exposure = exposureValue(url) else {
                throw LensWorksCatalogError.message("Every bracketed photo needs recorded exposure time, ISO and aperture to be merged.")
            }
            let (_, plane) = try await LWSourceDeveloper.shared.createPlane(original: LWCatalogNativePath(fileURL: url), rawHint: RawImporter.matches(url))
            guard try HDRMergePublisher.sha256(url) == before else {
                throw LensWorksCatalogError.message("A bracketed original changed while it was being read; no HDR was published.")
            }
            loaded.append((plane, exposure, url, before))
        }
        let middle = loaded.map { $0.1 }.sorted()[loaded.count / 2]
        return loaded.map { HDRPlaneFrame(plane: $0.0, exposureStops: Float($0.1 - middle), original: $0.2, sha256: $0.3) }
    }

}

/// Only the HDR task's registration flow may enter its reserved catalog lane.
nonisolated enum LensWorksHDROperationOwner {
    @TaskLocal static var current: LensWorksHDROperationLease?
}

/// An inherited task-local is not authority after its owning operation ends.
/// The lease binds one catalog incarnation and captured disk-backed selection;
/// only the native-confirmed merged row may join its source-link write set.
nonisolated final class LensWorksHDROperationLease: @unchecked Sendable {
    private struct Row: Hashable {
        let image: String, asset: String, variant: String
        init(_ row: LensWorksSelectedRow) { image = row.imageID; asset = row.key.asset_id; variant = row.key.variant_id }
    }
    private let catalog: ObjectIdentifier
    private let operation: UUID
    private let scope: LensWorksCatalogScope
    private let selectionOwner: String
    private let lock = NSLock()
    private var active = true
    private var rows: Set<Row>
    private var ownership: LWFloatWorkingSet.Lease?
    init(catalog: LensWorksCatalog, operation: UUID, admission: LensWorksHDRMergeAdmission) {
        self.catalog = ObjectIdentifier(catalog); self.operation = operation; scope = admission.scope
        selectionOwner = admission.selectionOwner; rows = Set(admission.rows.map(Row.init)); ownership = admission.ownership
    }
    func allows(catalog: ObjectIdentifier, operation: UUID?, scope: LensWorksCatalogScope, selectionOwner: String) -> Bool {
        lock.withLock {
            active && self.catalog == catalog && self.operation == operation && self.selectionOwner == selectionOwner &&
                self.scope.epoch == scope.epoch && self.scope.token == scope.token && self.scope.path == scope.path
        }
    }
    func permits(_ requested: [LensWorksSelectedRow]) -> Bool {
        lock.withLock { active && requested.allSatisfy { rows.contains(Row($0)) } }
    }
    fileprivate func includeMerged(_ row: LensWorksSelectedRow) throws {
        try lock.withLock {
            guard active else { throw CancellationError() }
            rows.insert(Row(row))
        }
    }
    func close() {
        lock.withLock { active = false; rows.removeAll(); ownership = nil }
    }
}

/// Stable catalog/selection/output authority captured before any original is read.
nonisolated struct LensWorksHDRMergeAdmission: Sendable {
    let scope: LensWorksCatalogScope
    let selectionOwner: String
    let selectionEpoch: UInt64
    let queryOwner: String
    let outputEpoch: UInt64
    let output: URL?
    let ownership: LWFloatWorkingSet.Lease
    var rows: [LensWorksSelectedRow] = []
    var originals: [URL] = []
}

/// Import and links use full native keys, independently of the person's current
/// browse filter/page; a displayed filename never authorizes filesystem access.
@MainActor
struct LensWorksHDRMergeRegistrar {
    let catalog: LensWorksCatalog
    let sources: [LensWorksSelectedRow]
    var origin = LensWorksCommandOrigin.user
    var authorize: @MainActor () throws -> Void = {}

    func registerMerged(_ publication: HDRMergePublication) async throws {
        let scope = catalog.captureScope()
        let current: @MainActor () throws -> Void = {
            try catalog.checkScope(scope); try authorize()
            try publication.destination.validatePublication(named: publication.dng.lastPathComponent)
            try publication.destination.validatePublication(named: publication.link.lastPathComponent)
        }
        try current()
        let previous = catalog.importProgress?.id
        do {
            try await catalog.startImport(publication.destination.directory.path, authorize: current)
            #if DEBUG
            await catalog.continuationFixture?(.hdrImportStarted)
            #endif
            try current(); try catalog.checkScope(scope)
            try await catalog.waitImport(terminal: true, authorize: current)
        } catch {
            let primary = error
            if catalog.scopeIsCurrent(scope), catalog.isImporting, catalog.importProgress?.id != previous {
                do { try await catalog.cancelImport() }
                catch {
                    if let recovery = primary as? LWLinearMediaRecoveryError {
                        throw LWLinearMediaRecoveryError(reason: recovery.reason + " The HDR import is still retiring: " + error.localizedDescription,
                            recoveryPaths: recovery.recoveryPaths)
                    }
                    throw LensWorksCatalogError.message(primary.localizedDescription + " The HDR import is still retiring: " + error.localizedDescription)
                }
            }
            throw primary
        }
        try catalog.checkScope(scope); try current()
        let options = LWApplicationBrowseOptions(text: publication.dng.lastPathComponent, keyword: nil, keyword_direct: false,
            folder: nil, folder_recursive: true, collection: nil, date_from: nil, date_until: nil,
            camera_make: nil, camera: nil, lens: nil, format: nil, rating: nil, flag: nil, label: nil,
            only_conflicted: false, sort: .Sequence, direction: .Ascending)
        var cursor: String?, merged: LensWorksSelectedRow?
        while merged == nil {
            try current()
            let page = try await catalog.service.browse(options: options, cursor: cursor)
            try catalog.checkScope(scope); try current()
            for row in page.rows where row.filename == publication.dng.lastPathComponent {
                let unresolved = LensWorksCatalogAsset(sequence: row.sequence.value, id: row.image_id,
                    originalPath: row.filename, state: row.state, previewPath: nil, key: row.key)
                try current()
                let resolved = try await catalog.service.resolve(unresolved)
                try catalog.checkScope(scope); try current()
                if let actual = try resolved.originalURL.physicalFileURL, let expected = publication.dng.physicalFileURL, actual == expected {
                    merged = LensWorksSelectedRow(imageID: row.image_id, key: row.key); break
                }
            }
            if !page.hasMore { break }
            guard let next = page.next, next != cursor else { throw ProjectError.invalid }
            cursor = next
        }
        guard let merged else {
            throw LensWorksCatalogError.message("The HDR files were published, but catalog registration could not be confirmed. Add the HDR folder to the catalog before trying again.")
        }
        try LensWorksHDROperationOwner.current?.includeMerged(merged)
        let title = "HDR Merge " + publication.dng.deletingPathExtension().lastPathComponent
        try current()
        let groupID = try await catalog.createGroupReturningID(title, authorize: current)
        try catalog.checkScope(scope); try current()
        try await catalog.organize(.addCollection(groupID), rows: sources + [merged], origin: origin, authorize: current)
        try catalog.checkScope(scope); try current()
    }
}

extension LensWorksCatalog {
    var hdrMergeUnavailableReason: String? {
        if catalogPath == nil { return "Open a catalog first." }
        if isBusy || isImporting || isHDRMerging || closingRequested { return "Finish the current catalog operation first." }
        if selectionCount < 2 { return "Select two or more bracketed photos first." }
        return nil
    }

    func promptMergeSelectionToHDR() async {
        guard hdrMergeUnavailableReason == nil else { return }
        let alert = NSAlert()
        alert.messageText = "Merge to HDR"
        alert.informativeText = "Selected bracketed originals will be aligned at full resolution and merged into a new linear DNG."
        alert.addButton(withTitle: "Merge"); alert.addButton(withTitle: "Cancel")
        let deghost = NSButton(checkboxWithTitle: "Deghost moving subjects", target: nil, action: nil)
        alert.accessoryView = deghost
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        var options = HDRMergeOptions(); options.deghost = deghost.state == .on
        await mergeSelectionToHDR(options: options)
    }

    func mergeSelectionToHDR(options: HDRMergeOptions = HDRMergeOptions()) async {
        let scope = captureScope()
        do {
            let admission = try await admitHDRMerge()
            _ = try await performHDRMerge(admission, options: options)
        }
        catch {
            if error is LWLinearMediaRecoveryError || (!(error is CancellationError) && scopeIsCurrent(scope)) { self.error = error.localizedDescription }
        }
    }

    /// The common UI/agent execution path. Source decoding, hashes, merge and
    /// publication run off the main actor; only catalog registration returns here.
    @discardableResult
    func performHDRMerge(_ admission: LensWorksHDRMergeAdmission, options: HDRMergeOptions,
                         origin: LensWorksCommandOrigin = .user,
                         authorize: @escaping @MainActor @Sendable () throws -> Void = {}) async throws -> HDRMergePublication {
        try validateHDRMerge(admission); try authorize()
        if let reason = hdrMergeUnavailableReason { throw LensWorksCommandRefusal(reason: reason) }
        guard admission.rows.count >= 2, admission.rows.count == admission.originals.count else { throw HDRMergeError.tooFewFrames }
        guard !isHDRMerging else { throw LensWorksCommandRefusal(reason: "An HDR merge is already running.") }
        let operation = UUID()
        hdrMergeOperation = operation; isHDRMerging = true; error = nil
        var publication: HDRMergePublication?, registrationStarted = false
        var lease: LensWorksHDROperationLease?
        defer {
            lease?.close()
            if hdrMergeOperation == operation { hdrMergeTask = nil; hdrMergeOperation = nil; isHDRMerging = false }
        }
        #if DEBUG
        await continuationFixture?(.hdrInputsAdmitted)
        #endif
        try validateHDRMerge(admission); try authorize()
        let sources = admission.originals
        let output = admission.output ?? sources[0].deletingLastPathComponent()
        let name = "HDR-" + UUID().uuidString
        status = "Merging \(sources.count) originals to HDR…"
        let work = Task.detached(priority: .userInitiated) {
            try await authorize()
            let frames = try await HDRFrameLoader.frames(sources)
            let result = try HDRMerge.merge(frames, options: options)
            try Task.checkCancellation(); try await authorize()
            return try HDRMergePublisher.publish(result, sources: sources, expectedHashes: frames.map(\.sha256), into: output, name: name, options: options)
        }
        hdrMergeTask = work
        let watch = Task { @MainActor in
            while !Task.isCancelled {
                do { try await Task.sleep(for: .milliseconds(50)); try authorize()
                    if registrationStarted { try self.checkScope(admission.scope) }
                    else { try self.validateHDRMerge(admission) } }
                catch { work.cancel(); return }
            }
        }
        defer { watch.cancel() }
        do {
            let made = try await withTaskCancellationHandler { try await work.value } onCancel: { work.cancel() }
            publication = made
            #if DEBUG
            await continuationFixture?(.hdrPublicationReady)
            #endif
            try validateHDRMerge(admission); try authorize()
            registrationStarted = true // Import may have written even if its reply is lost: retain its media.
            let registration = LensWorksHDROperationLease(catalog: self, operation: operation, admission: admission)
            lease = registration
            try await LensWorksHDROperationOwner.$current.withValue(registration) {
                try await LensWorksHDRMergeRegistrar(catalog: self, sources: admission.rows, origin: origin, authorize: authorize).registerMerged(made)
            }
            status = "Merged \(sources.count) frames into \(made.dng.lastPathComponent)."
            return made
        } catch {
            let primary = error
            if !registrationStarted, let publication {
                var recovery: [URL] = [], reasons: [String] = []
                for name in [publication.link.lastPathComponent, publication.dng.lastPathComponent] {
                    do { try publication.destination.removeUnimportedPublication(named: name) }
                    catch let failure as LWLinearMediaRecoveryError { recovery += failure.recoveryPaths; reasons.append(failure.reason) }
                    catch { recovery.append(publication.destination.directory.appendingPathComponent(name)); reasons.append(error.localizedDescription) }
                }
                if !recovery.isEmpty {
                    let failure = LWLinearMediaRecoveryError(reason: primary.localizedDescription + " " + reasons.joined(separator: " "), recoveryPaths: recovery)
                    reportMediaRecovery(failure)
                    throw failure
                }
            }
            if let recovery = primary as? LWLinearMediaRecoveryError { reportMediaRecovery(recovery) }
            throw primary
        }
    }
}
