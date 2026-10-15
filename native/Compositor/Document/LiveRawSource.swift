import Foundation
import CoreGraphics

nonisolated enum LWSourceWhiteBalance: Codable, Equatable, Sendable {
    case asShot
    case temperatureTint(kelvin: UInt32, tint: Float)
    var native: LWEditRecipeWhiteBalance {
        get throws {
            switch self {
            case .asShot: return .AsShot
            case .temperatureTint(let kelvin, let tint):
                guard (2000...50000).contains(kelvin), tint.isFinite, (-150...150).contains(tint) else { throw ProjectError.invalid }
                return .TemperatureTint(kelvin:kelvin, tint:try LWCatalogFloat32(tint))
            }
        }
    }
}

/// The immutable physical original, separate from mutable document development.
nonisolated struct LWLiveSourceNode: Codable, Equatable, Sendable {
    let schema: Int
    private(set) var id: UUID
    var revision: UUID
    var sourceLineage: [UUID]
    let original: LWCatalogNativePath
    let rawHint: Bool
    let originalRevision: Data
    let originalWidth: Int
    let originalHeight: Int
    let metadata: Data
    let provenance: Data
    let decoderSourceRevision: String
    /// Optional captured full native VariantKey/metadata revision/recipe CAS; never a UI selection handle.
    var catalogAuthority: Data?
    var whiteBalance: LWSourceWhiteBalance
    var settings: CameraRawSettings
    var grainSeed: UInt32
    var coordinateMap: LWSourceCoordinateMap
    var retouch: [LWSourceRetouchStroke]
    var selectedDevelopments: [LWSourceSelectedDevelopment]
    var sampleComposites: [LWSourceSampleComposite]
    /// Immutable range-backed dependencies. Codable stores only content identity;
    /// package hydration supplies private validated backing before graph evaluation.
    var planeAssets: [UUID: LWSourcePlaneAsset] = [:]
    var filters: [LWSourceRetainedFilter] = []
    var resamples: [LWSourceResample] = []
    var operations: [LWSourceOperation] = []
    var adjustments:[LWSourceRetainedAdjustment] = []
    /// Filter-plugin runs retained in order (project format 14). Written only when there are any, so a
    /// source without one stays readable by builds that know format 13.
    var plugins:[LWSourceRetainedPlugin] = []
    /// Runtime-only; shared by immutable value copies and retained history. An
    /// admitted mutation installs a fresh owner before any copy-on-write growth.
    var metadataStorage: LWSourceMetadataStorage? = nil
    var metadataWorkingSet:LWFloatWorkingSet { metadataStorage?.workingSet ?? .sourceGraphs }
    enum CodingKeys: String,CodingKey {
        case schema,id,revision,sourceLineage,original,rawHint,originalRevision,originalWidth,originalHeight,metadata,provenance,
            decoderSourceRevision,catalogAuthority,whiteBalance,settings,grainSeed,coordinateMap,retouch,selectedDevelopments,
            sampleComposites,planeAssets,filters,resamples,operations,adjustments,plugins
    }
    func encode(to encoder:any Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(schema,forKey:.schema);try c.encode(id,forKey:.id);try c.encode(revision,forKey:.revision)
        try c.encode(sourceLineage,forKey:.sourceLineage);try c.encode(original,forKey:.original);try c.encode(rawHint,forKey:.rawHint)
        try c.encode(originalRevision,forKey:.originalRevision);try c.encode(originalWidth,forKey:.originalWidth)
        try c.encode(originalHeight,forKey:.originalHeight);try c.encode(metadata,forKey:.metadata);try c.encode(provenance,forKey:.provenance)
        try c.encode(decoderSourceRevision,forKey:.decoderSourceRevision);try c.encodeIfPresent(catalogAuthority,forKey:.catalogAuthority)
        try c.encode(whiteBalance,forKey:.whiteBalance);try c.encode(settings,forKey:.settings);try c.encode(grainSeed,forKey:.grainSeed)
        try c.encode(coordinateMap,forKey:.coordinateMap);try c.encode(retouch,forKey:.retouch)
        try c.encode(selectedDevelopments,forKey:.selectedDevelopments);try c.encode(sampleComposites,forKey:.sampleComposites)
        try c.encode(planeAssets,forKey:.planeAssets);try c.encode(filters,forKey:.filters);try c.encode(resamples,forKey:.resamples)
        try c.encode(operations,forKey:.operations);try c.encode(adjustments,forKey:.adjustments)
        if !plugins.isEmpty { try c.encode(plugins,forKey:.plugins) }
    }
    /// Whether this source holds anything only project format 14 can express: a retained plugin step, or a
    /// retained Invert.
    var usesFormat14:Bool { !plugins.isEmpty || adjustments.contains { $0.settings.kind == .invert } }
    static func == (a:Self,b:Self)->Bool {
        a.schema==b.schema && a.id==b.id && a.revision==b.revision && a.sourceLineage==b.sourceLineage &&
        a.original==b.original && a.rawHint==b.rawHint && a.originalRevision==b.originalRevision && a.originalWidth==b.originalWidth &&
        a.originalHeight==b.originalHeight && a.metadata==b.metadata && a.provenance==b.provenance &&
        a.decoderSourceRevision==b.decoderSourceRevision && a.catalogAuthority==b.catalogAuthority &&
        a.whiteBalance==b.whiteBalance && a.settings==b.settings && a.grainSeed==b.grainSeed && a.coordinateMap==b.coordinateMap &&
        a.retouch==b.retouch && a.selectedDevelopments==b.selectedDevelopments && a.sampleComposites==b.sampleComposites &&
        a.planeAssets==b.planeAssets && a.filters==b.filters && a.resamples==b.resamples && a.operations==b.operations && a.adjustments==b.adjustments &&
        a.plugins==b.plugins
    }
    func metadataCopy(additionalBytes:Int = 0) throws -> Self {
        let owner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.sum(retainedPayloadBytes,additionalBytes),
            workingSet:metadataStorage?.workingSet ?? .sourceGraphs)
        var copy=self;copy.metadataStorage=owner;return copy
    }
    mutating func admitMetadataMutation(additionalBytes:Int) throws {
        self=try metadataCopy(additionalBytes:additionalBytes)
    }
    mutating func compactMetadataStorage() throws {
        metadataStorage=try LWSourceMetadataStorage(bytes:retainedPayloadBytes,workingSet:metadataStorage?.workingSet ?? .sourceGraphs)
    }
    func validateMetadataStorage() throws {
        guard let metadataStorage else { throw ProjectError.invalid }
        try metadataStorage.validate(bytes:retainedPayloadBytes)
    }
    init(original: LWCatalogNativePath, originalRevision: LWApplicationExportsDtoFileRevision,
        descriptor: LWManagedSourceFloatDescriptor, catalogAuthority: Data? = nil) throws {
        let admission=try LWSourceMetadataStorage(bytes:16*1024*1024)
        let actual=try LWSourceMetadataStorage.encode(descriptor.source_authority.original_revision,maximumBytes:1024*1024,catalogCodec:true)
        let expected=try LWSourceMetadataStorage.encode(originalRevision,maximumBytes:1024*1024,catalogCodec:true)
        guard descriptor.source_authority.original == original,actual.equals(expected) else { throw ProjectError.invalid }
        let metadata=try LWSourceMetadataStorage.encode(descriptor.metadata,maximumBytes:1024*1024,catalogCodec:true)
        let provenance=try LWSourceMetadataStorage.encode(descriptor.provenance,maximumBytes:1024*1024,catalogCodec:true)
        defer { withExtendedLifetime((actual,expected,metadata,provenance)) {} }
        try self.init(original: original, originalRevision: originalRevision, width: Int(descriptor.width), height: Int(descriptor.height),
            metadata:try metadata.copyData(ownedBy:admission),provenance:try provenance.copyData(ownedBy:admission),
            decoderSourceRevision: descriptor.source_revision, rawHint: descriptor.source_authority.raw_hint, catalogAuthority: catalogAuthority, admission:admission)
    }
    init(original: LWCatalogNativePath, originalRevision: LWApplicationExportsDtoFileRevision,
        descriptor: LWManagedSourcePlaneDescriptor, catalogAuthority: Data? = nil) throws {
        let admission=try LWSourceMetadataStorage(bytes:16*1024*1024)
        let actual=try LWSourceMetadataStorage.encode(descriptor.source_authority.original_revision,maximumBytes:1024*1024,catalogCodec:true)
        let expected=try LWSourceMetadataStorage.encode(originalRevision,maximumBytes:1024*1024,catalogCodec:true)
        guard descriptor.source_authority.original == original,actual.equals(expected) else { throw ProjectError.invalid }
        let metadata=try LWSourceMetadataStorage.encode(descriptor.metadata,maximumBytes:1024*1024,catalogCodec:true)
        let provenance=try LWSourceMetadataStorage.encode(descriptor.provenance,maximumBytes:1024*1024,catalogCodec:true)
        defer { withExtendedLifetime((actual,expected,metadata,provenance)) {} }
        try self.init(original: original, originalRevision: originalRevision, width: Int(descriptor.width), height: Int(descriptor.height),
            metadata:try metadata.copyData(ownedBy:admission),provenance:try provenance.copyData(ownedBy:admission),
            decoderSourceRevision: descriptor.source_revision, rawHint: descriptor.source_authority.raw_hint, catalogAuthority: catalogAuthority, admission:admission)
    }
    private init(original: LWCatalogNativePath, originalRevision: LWApplicationExportsDtoFileRevision,
        width: Int, height: Int, metadata: Data, provenance: Data, decoderSourceRevision: String, rawHint: Bool, catalogAuthority: Data?, admission:LWSourceMetadataStorage) throws {
        schema = 1; id = UUID(); revision = UUID(); sourceLineage = [revision]; self.original = original; self.rawHint = rawHint
        let encodedRevision=try LWSourceMetadataStorage.encode(originalRevision,maximumBytes:1024*1024,catalogCodec:true)
        defer { withExtendedLifetime(encodedRevision) {} }
        self.originalRevision=try encodedRevision.copyData(ownedBy:admission)
        originalWidth = width; originalHeight = height; self.metadata = metadata; self.provenance = provenance
        self.decoderSourceRevision = decoderSourceRevision; self.catalogAuthority = catalogAuthority
        whiteBalance = .asShot; settings = CameraRawSettings(); grainSeed = 0; coordinateMap = .identity
        retouch = []; selectedDevelopments = []; sampleComposites = [];metadataStorage=admission
        try validate();try compactMetadataStorage()
    }
    func validate() throws {
        try validateMetadataStorage()
        guard schema == 1, originalWidth > 0, originalHeight > 0, originalWidth <= DocumentLimits.maxSide,
            originalHeight <= DocumentLimits.maxSide, originalWidth <= DocumentLimits.maxSurfacePixels / originalHeight,
            sourceLineage.count <= 10000, sourceLineage.contains(revision), Set(sourceLineage).count == sourceLineage.count, settings.isValid, settings == settings.normalized, retouch.count <= 10000, selectedDevelopments.count <= 128, sampleComposites.count <= 10000,
            originalRevision.count <= 1024 * 1024, metadata.count <= 1024 * 1024, provenance.count <= 1024 * 1024,
            catalogAuthority.map({ $0.count <= 1024 * 1024 }) ?? true else { throw ProjectError.invalid }
        _ = try original.localFileURL(); _ = try whiteBalance.native
        let physical = try LWSourceMetadataStorage.withDecodeCharge(from:originalRevision,workingSet:metadataWorkingSet) { try LWCatalogCodec.decode(LWApplicationExportsDtoFileRevision.self, from:originalRevision) }
        guard physical.bytes.value > 0, physical.digest.count == 64,
            physical.digest.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw ProjectError.invalid }
        _ = try LWSourceMetadataStorage.withDecodeCharge(from:metadata,workingSet:metadataWorkingSet) { try LWCatalogCodec.decode(LWMediaMetadata.self, from:metadata) }
        _ = try LWSourceMetadataStorage.withDecodeCharge(from:provenance,workingSet:metadataWorkingSet) { try LWCatalogCodec.decode(LWMediaFullRenderProvenance.self, from:provenance) }
        guard decoderSourceRevision.count == 64 else { throw ProjectError.invalid }
        if let catalogAuthority { try LWSourceMetadataStorage.withDecodeCharge(from:catalogAuthority,workingSet:metadataWorkingSet) { try LWCatalogCodec.decode(LWSourceCatalogAuthority.self, from:catalogAuthority) }.validate() }
        var backingBytes = 0
        // Admit encoded ownership before decoding any backing; decode/evaluation has
        // an additional aggregate scratch admission at its production entry point.
        for step in selectedDevelopments {
            if let frame=step.coverageFrame { guard frame.width==originalWidth,frame.height==originalHeight else { throw ProjectError.invalid } }
            let (sum,overflow)=backingBytes.addingReportingOverflow(step.sourceCoverage.count)
            guard !overflow,sum<=LWSourceDeveloper.maximumResultBytes else { throw ProjectError.tooLarge };backingBytes=sum
        }
        for composite in sampleComposites {
            let (sum,overflow)=backingBytes.addingReportingOverflow(composite.byteLength)
            guard !overflow,sum<=LWSourceDeveloper.maximumResultBytes else { throw ProjectError.tooLarge };backingBytes=sum
        }
        for stroke in retouch {
            guard sourceLineage.contains(stroke.upstreamRevision) else { throw ProjectError.invalid }
            if let bytes=stroke.selectionSourceCoverage {
                guard bytes.count <= LWSourceDeveloper.maximumResultBytes-backingBytes else { throw ProjectError.tooLarge }
                backingBytes += bytes.count
            }
        }
        for step in selectedDevelopments { try step.validate() }
        for composite in sampleComposites {
            guard composite.sourceID == id,sourceLineage.contains(composite.upstreamRevision),!composite.payload.isEmpty else { throw ProjectError.invalid }
        }
        for stroke in retouch { try stroke.validate(source:id) }
        try validateOperationOrder()
        for operation in resamples {
            guard sourceLineage.contains(operation.upstreamRevision) else { throw ProjectError.invalid }
            try operation.validate(source:id)
        }
        for adjustment in adjustments {
            guard sourceLineage.contains(adjustment.upstreamRevision) else { throw ProjectError.invalid }
            try adjustment.validate(source:id)
        }
        for plugin in plugins {
            guard sourceLineage.contains(plugin.upstreamRevision) else { throw ProjectError.invalid }
            try plugin.validate(source:id)
        }
        for filter in filters {
            guard sourceLineage.contains(filter.upstreamRevision) else { throw ProjectError.invalid }
            try filter.validate(source: id)
        }
    }
    func request(id: UUID) throws -> LWDocumentSourceDevelopment {
        try validate()
        return LWDocumentSourceDevelopment(original:original,
            originalRevision:try LWSourceMetadataStorage.withDecodeCharge(from:originalRevision,workingSet:metadataWorkingSet) { try LWCatalogCodec.decode(LWApplicationExportsDtoFileRevision.self, from:originalRevision) },
            whiteBalance:try whiteBalance.native, requestID:id, rawHint:rawHint)
    }
}

nonisolated extension LWLiveSourceNode {
    /// The node for a copy of its layer: a new identity over the same original, with the same development, revision
    /// and lineage, and every retained operation bound to the new identity. The copy develops to the same pixels and
    /// is developed and edited on its own from then on.
    func forked() throws -> Self {
        var copy = try metadataCopy()
        let source = UUID()
        copy.id = source
        for i in copy.retouch.indices { copy.retouch[i].sourceID = source }
        for i in copy.sampleComposites.indices { copy.sampleComposites[i].sourceID = source }
        copy.adjustments = adjustments.map { $0.rebound(to: source) }
        copy.filters = filters.map { $0.rebound(to: source) }
        copy.resamples = resamples.map { $0.rebound(to: source) }
        try copy.validate()
        return copy
    }
}

/// Stroke points/radius are in the captured document frame. Current pixels map back
/// through the protected source to that frame; the original round tip is not approximated.
nonisolated struct LWSourceRetouchStroke: Codable, Equatable, Sendable {
    enum Kind: String, Codable, Sendable { case clone, heal, paint, erase, smear, blur, liquify }
    enum HealMode: Int, Codable, Sendable { case contentAware = 0, createTexture = 1, proximityMatch = 2 }
    fileprivate(set) var sourceID: UUID
    let upstreamRevision: UUID
    let captureFrame: LWSourceRetouchFrame
    let kind: Kind
    let seed: UInt32
    let healMode: HealMode
    let sampleAllLayers: Bool
    let aligned: Bool
    let sampleAllLayersCompositeRevision: UUID?
    let blurRadius: Double
    let radius: Double
    let hardness: Double
    let opacity: Double
    let points: [CGPoint]
    let sourceOffset: CGSize
    let color: [Float]
    var pointsAreDabs:Bool = false
    var selectionSourceCoverage:Data? = nil
    var selectionPlaneID:UUID? = nil
    /// New captures retain intrinsic selection in its actual developed grid,
    /// including owned padding. Legacy reference coverage remains source-frame.
    var selectionFrame:LWSourceRetouchFrame? = nil
    /// WarpStroke's first pointer position precedes its retained step dabs.
    var sourceStart:CGPoint? = nil
    func validate(source: UUID) throws {
        try captureFrame.validate()
        guard sourceID == source, sampleAllLayers == (sampleAllLayersCompositeRevision != nil),
            blurRadius.isFinite, blurRadius >= 0, blurRadius <= 250, radius.isFinite, radius > 0, radius <= Double(DocumentLimits.maxSide),
            hardness.isFinite, (0...1).contains(hardness), opacity.isFinite, (0...1).contains(opacity),
            !points.isEmpty, points.count <= 100000, points.allSatisfy({ $0.x.isFinite && $0.y.isFinite }),
            sourceOffset.width.isFinite, sourceOffset.height.isFinite,
            color.count == 4, color.allSatisfy(\.isFinite), (0...1).contains(color[3]) else { throw ProjectError.invalid }
        if let selectionFrame {
            try selectionFrame.validate()
            guard selectionPlaneID != nil || selectionSourceCoverage != nil else { throw ProjectError.invalid }
        }
        if let data=selectionSourceCoverage {
            let extent=try LWLinearSurface.packageExtent(data,maximumFileBytes:LWSourceDeveloper.maximumResultBytes)
            guard extent.width == (selectionFrame?.developedWidth ?? captureFrame.width),
                extent.height == (selectionFrame?.developedHeight ?? captureFrame.height) else { throw ProjectError.invalid }
        }
        if kind == .smear || kind == .liquify {
            guard let sourceStart,sourceStart.x.isFinite,sourceStart.y.isFinite,pointsAreDabs else { throw ProjectError.invalid }
        }
    }
}

nonisolated struct LWSourceCleanupFailure: LocalizedError {
    let operation: String?
    let cleanup: String
    var errorDescription: String? {
        (operation.map { $0 + "; " } ?? "") + "The source decoder owner remains retained for checked Close retry: " + cleanup
    }
}

actor LWSourceDeveloper {
    static let shared = LWSourceDeveloper()
    // Same retained session/result envelope; no new decode worker or unbounded pool.
    static let maximumResultBytes = 512 * 1024 * 1024
    static let maximumWorkerBytes: UInt64 = 4 * 1024 * 1024 * 1024
    private var owners: [ObjectIdentifier: LWManagedSession] = [:]
    private var failedOwners: Set<ObjectIdentifier> = []
    private var creatingOwners = 0
    private var drainingOwners = false
    private func session(original: LWCatalogNativePath) async throws -> LWManagedSession {
        guard !drainingOwners, failedOwners.isEmpty else {
            throw LensWorksManagedError.native(code: "draining", message: "A source decoder owner requires checked Close before another development.")
        }
        creatingOwners += 1; defer { creatingOwners -= 1 }
        let file = try original.localFileURL()
        var config = try LWManagedSessionConfig.installed(originalRoots:[try LWCatalogNativePath(fileURL:file.deletingLastPathComponent())])
        config.payload_bytes = LWCatalogU64(UInt64(Self.maximumResultBytes))
        config.worker_bytes = LWCatalogU64(Self.maximumWorkerBytes)
        let owner: LWManagedSession
        do { owner = try await LWManagedSession.createSourceOwner(config: config) }
        catch let refused as LWManagedSourceAdmissionFailure {
            owners[ObjectIdentifier(refused.owner)] = refused.owner
            failedOwners.insert(ObjectIdentifier(refused.owner))
            try await closeOwner(refused.owner, operation: refused.reason)
            throw refused.reason
        }
        owners[ObjectIdentifier(owner)] = owner
        guard !drainingOwners else {
            failedOwners.insert(ObjectIdentifier(owner))
            throw LWSourceCleanupFailure(operation: nil, cleanup: "Source admission completed while checked shutdown was in progress.")
        }
        return owner
    }
    private func closeOwner(_ owner: LWManagedSession, operation: Error? = nil) async throws {
        do {
            try await owner.close()
            owners.removeValue(forKey: ObjectIdentifier(owner)); failedOwners.remove(ObjectIdentifier(owner))
        } catch {
            // Keep a strong, named managed session across cancellation/deadline
            // failure. A detached deinit retry is not checked Close authority.
            failedOwners.insert(ObjectIdentifier(owner))
            throw LWSourceCleanupFailure(operation: operation?.localizedDescription, cleanup: error.localizedDescription)
        }
    }
    private func cleanupAfterFailure(_ owner: LWManagedSession, operation: Error) async throws {
        if let failure = operation as? LWSourceCleanupFailure { throw failure }
        try await closeOwner(owner, operation: operation)
    }
    /// Document Close drains failed owners only, so another document's active
    /// development is not canceled. Application/window Quit additionally joins
    /// all active/creating source owners under the existing 30-second Close bound.
    func drainRetainedSessions(includeActive: Bool = false, deadline suppliedDeadline: ContinuousClock.Instant? = nil) async throws {
        guard !drainingOwners else { throw LensWorksManagedError.native(code: "busy", message: "Source Close is already running.") }
        drainingOwners = true; defer { drainingOwners = false }
        let deadline = suppliedDeadline ?? ContinuousClock.now.advanced(by: .milliseconds(30000))
        while true {
            try Task.checkCancellation()
            guard ContinuousClock.now < deadline else {
                throw LWSourceCleanupFailure(operation:nil,cleanup:"Source Close deadline expired; ownership is retained for retry.")
            }
            let pending = owners.filter { includeActive || failedOwners.contains($0.key) }
            if pending.isEmpty, !includeActive || creatingOwners == 0 {
                try LWFloatWorkspace.retryRetainedCleanup(); return
            }
            guard ContinuousClock.now < deadline else {
                throw LWSourceCleanupFailure(operation: nil, cleanup: "Source Close timed out; ownership is retained for retry.")
            }
            for (identity, owner) in pending {
                let parts = ContinuousClock.now.duration(to: deadline).components
                let milliseconds = parts.seconds * 1000 + parts.attoseconds / 1_000_000_000_000_000
                do {
                    try await owner.close(timeoutMilliseconds: UInt32(clamping: max(0, milliseconds)))
                    owners.removeValue(forKey: identity); failedOwners.remove(identity)
                } catch {
                    failedOwners.insert(identity)
                    throw LWSourceCleanupFailure(operation: nil, cleanup: error.localizedDescription)
                }
            }
            if includeActive, creatingOwners != 0 { try await Task.sleep(for: .milliseconds(25)) }
        }
    }
    private var limits: LWApplicationExportsDtoDecodeLimits {
        .init(max_encoded_bytes:LWCatalogU64(Self.maximumWorkerBytes),
            max_intermediate_pixels:LWCatalogU64(UInt64(DocumentLimits.maxSurfacePixels)),
            max_allocation_bytes:LWCatalogU64(Self.maximumWorkerBytes))
    }
    func createPlane(original: LWCatalogNativePath, rawHint: Bool? = nil) async throws -> (LWLiveSourceNode, LWFloatPlane) {
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        return try await withTaskCancellationHandler {
            try await createPlane(original: original, rawHint: rawHint, workingSet: workspace.workingSet,
                makeBuilder: { try workspace.makeBuilder(width: $0, height: $1) })
        } onCancel: { workspace.cancellation.cancel() }
    }
    func createPlane(original: LWCatalogNativePath, rawHint: Bool? = nil, workingSet: LWFloatWorkingSet,
        makeBuilder: (Int, Int) throws -> LWFloatPlane.Builder) async throws -> (LWLiveSourceNode, LWFloatPlane) {
        let owner = try await session(original: original)
        do {
            let physical = try await owner.documentSourceRevision(original: original, maximumEncodedBytes: limits.max_encoded_bytes)
            let admittedRaw: Bool
            if let rawHint { admittedRaw = rawHint } else { admittedRaw = RawImporter.matches(try original.localFileURL()) }
            let request = LWDocumentSourceDevelopment(original: original, originalRevision: physical.original_revision,
                whiteBalance: .AsShot, requestID: UUID(), rawHint: admittedRaw)
            let (plane, descriptor) = try await LWSourceTileTransport.materialize(owner: owner, request: request,
                limits: limits, workerBytes: LWCatalogU64(Self.maximumWorkerBytes), workingSet: workingSet, makeBuilder: makeBuilder)
            let node = try LWLiveSourceNode(original: original, originalRevision: physical.original_revision, descriptor: descriptor)
            try await closeOwner(owner); return (node, plane)
        } catch { try await cleanupAfterFailure(owner, operation: error); throw error }
    }
    // Production source development exposes only the decode-once plane path.
    // Small mathematical kernels remain independent reference controls; they do
    // not provide a second managed full-buffer decoder or job-retirement path.
    func evaluatePlane(_ node: LWLiveSourceNode) async throws -> (surface: LWFloatPlane, map: LWSourceSpatialMap) {
        let made = try await evaluate(node, previewMaximumSide: nil)
        return (made.surface, made.map)
    }
    /// Completed full-resolution developments from the original (commit, export, quick look).
    /// Observable so tests can prove an export re-develops from source rather than reusing pixels.
    private(set) var fullResolutionDevelopments = 0
    /// The Camera Raw preview: the same decode and `CameraRawSettings.develop` graph evaluated on
    /// the decoded source reduced to at most `maximumSide` (exact area average), with pixel reach
    /// scaled to that grid. Returns the developed plane and its scale (evaluated px per original
    /// px). A node with selected developments or replayed operations (retouch, filters,
    /// adjustments, resamples) is evaluated at full resolution (scale 1): those operations are
    /// recorded on the full-resolution grid.
    func evaluatePreviewPlane(_ node: LWLiveSourceNode, maximumSide: Int) async throws -> (surface: LWFloatPlane, scale: Double) {
        guard maximumSide > 0 else { throw ProjectError.invalid }
        let made = try await evaluate(node, previewMaximumSide: maximumSide)
        return (made.surface, made.scale)
    }
    /// Reduced preview grid, sized exactly as `FilterEdit.prepared` sizes its preview copy.
    nonisolated static func previewExtent(width: Int, height: Int, maximumSide: Int) -> (width: Int, height: Int, scale: Double)? {
        let factor = min(1, CGFloat(maximumSide) / CGFloat(max(width, height)))
        guard factor < 1 else { return nil }
        return (max(1, Int(CGFloat(width) * factor)), max(1, Int(CGFloat(height) * factor)), Double(factor))
    }
    private func evaluate(_ node: LWLiveSourceNode, previewMaximumSide: Int?) async throws -> (surface: LWFloatPlane, map: LWSourceSpatialMap, scale: Double) {
        try node.validate(); try Task.checkCancellation()
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        return try await withTaskCancellationHandler {
            let owner = try await session(original: node.original)
            do {
                // Scope complete graph readers/cache before checked collection:
                // the published output is the only ordinary returned plane owner.
                func developGraph() async throws -> (surface:LWFloatPlane,map:LWSourceSpatialMap,scale:Double) {
                // A retained decode is reused for every same-WB development within
                // this graph evaluation. Tile requests never restart the codec.
                let inputOwner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.collectionBytes(
                    count:LWSourceMetadataStorage.sum(node.selectedDevelopments.count,1),
                    stride:MemoryLayout<LWSourceWhiteBalance>.stride+MemoryLayout<LWFloatPlane>.stride),workingSet:workspace.workingSet)
                defer { withExtendedLifetime(inputOwner) {} }
                var inputs: [(whiteBalance: LWSourceWhiteBalance, plane: LWFloatPlane)] = []
                func input(_ balance: LWSourceWhiteBalance) async throws -> LWFloatPlane {
                    if let existing = inputs.first(where: { $0.whiteBalance == balance }) { return existing.plane }
                    try workspace.cancellation.check(); try Task.checkCancellation()
                    let request = LWDocumentSourceDevelopment(original: node.original,
                        originalRevision: try LWSourceMetadataStorage.withDecodeCharge(from:node.originalRevision,workingSet:workspace.workingSet) {
                            try LWCatalogCodec.decode(LWApplicationExportsDtoFileRevision.self, from:node.originalRevision)
                        },
                        whiteBalance: try balance.native, requestID: UUID(), rawHint: node.rawHint)
                    let (plane, descriptor) = try await LWSourceTileTransport.materialize(owner: owner, request: request,
                        limits: limits, workerBytes: LWCatalogU64(Self.maximumWorkerBytes), workingSet: workspace.workingSet,
                        makeBuilder: { try workspace.makeBuilder(width: $0, height: $1) })
                    guard Int(descriptor.width) == node.originalWidth, Int(descriptor.height) == node.originalHeight,
                        descriptor.source_revision == node.decoderSourceRevision else { throw ProjectError.invalid }
                    inputs.append((balance, plane)); return plane
                }
                let original = try await input(node.whiteBalance)
                if let side = previewMaximumSide, node.selectedDevelopments.isEmpty, node.retouch.isEmpty, node.filters.isEmpty,
                    node.resamples.isEmpty, node.adjustments.isEmpty, node.plugins.isEmpty,
                    let reduced = Self.previewExtent(width: original.width, height: original.height, maximumSide: side) {
                    let small = try LWFloatCompositor.downscale(original, width: reduced.width, height: reduced.height, workspace: workspace)
                    let developed = try node.settings.develop(small, seed: node.grainSeed, scale: reduced.scale,
                        makeBuilder: { try workspace.makeBuilder(width: $0, height: $1) }, makeScratchDirectory: { try workspace.makeScratchDirectory() }, fileOwner: workspace)
                    try await closeOwner(owner)
                    try workspace.cancellation.check(); try Task.checkCancellation()
                    return (developed.surface, LWSourceSpatialMap(geometry: developed.map, optics: node.settings.optics, width: small.width, height: small.height), reduced.scale)
                }
                let developed = try node.settings.develop(original, seed: node.grainSeed,
                    makeBuilder: { try workspace.makeBuilder(width: $0, height: $1) }, makeScratchDirectory: { try workspace.makeScratchDirectory() }, fileOwner: workspace)
                let map = LWSourceSpatialMap(geometry: developed.map, optics: node.settings.optics, width: original.width, height: original.height)
                var combined = developed.surface
                for step in node.selectedDevelopments {
                    try workspace.cancellation.check(); try Task.checkCancellation()
                    let raw = try await input(step.whiteBalance)
                    let made = try step.settings.develop(raw, seed: step.seed,
                        makeBuilder: { try workspace.makeBuilder(width: $0, height: $1) }, makeScratchDirectory: { try workspace.makeScratchDirectory() }, fileOwner: workspace)
                    let mask = try node.developmentSelectionPlane(step, workspace: workspace)
                    // The selection belongs to the recorded source frame. A new
                    // selected geometry changes pixels, never the selection's owner.
                    combined = try LWSourceSelectedDevelopmentBlend.apply(original: combined,
                        adjusted: made.surface, sourceCoverage: mask, currentMap: map, adjustedMap: LWSourceSpatialMap(geometry:made.map,optics:step.settings.optics,width:raw.width,height:raw.height), coverageFrame:step.coverageFrame, workspace: workspace)
                }
                // Checked worker cleanup precedes local replay; failure cannot be
                // hidden by publishing a partially developed result.
                try await closeOwner(owner)
                let output = try LWSourceOperationReplay.evaluate(node, developed: combined, map: map, workspace: workspace)
                try workspace.cancellation.check(); try Task.checkCancellation(); return (output.surface, output.map, 1)
                }
                let output=try await developGraph()
                // All temporary decodes, samplers and kernel stages have released
                // their strong tokens. Retire only exact registered zero-owner
                // generations; an unknown member/identity remains a failure.
                try workspace.retireReleasedGenerations()
                try workspace.cancellation.check();try Task.checkCancellation()
                if output.scale == 1 { fullResolutionDevelopments += 1 }
                return output
            } catch {
                workspace.cancellation.cancel()
                try await cleanupAfterFailure(owner, operation: error); throw error
            }
        } onCancel: { workspace.cancellation.cancel() }
    }

}

nonisolated struct LWSourceCatalogAuthority: Codable, Sendable {
    let key: LWCatalogEditsVariantKey
    let metadataRevision: Int64
    let variant: LWApplicationDtoVariant
    func validate() throws {
        guard key.asset_id == variant.key.asset_id, key.variant_id == variant.key.variant_id,
            metadataRevision >= 0, !variant.recipe_digest.isEmpty else { throw ProjectError.invalid }
    }
}

/// Geometry and radial optics are composed in the same order as the pixels.
/// A folded radial transform has no unique inverse; the optics helper refuses it.
nonisolated struct LWSourceSpatialMap: Sendable {
    let geometry: LWSourceCoordinateMap
    let optics: CameraRawOpticsSettings
    let width: Int
    let height: Int
    var stages: [LWSourcePixelStage] = []
    var metadataStorage:LWSourceMetadataStorage? = nil
    var developedWidth: Int { stages.last?.outputWidth ?? width }
    var developedHeight: Int { stages.last?.outputHeight ?? height }
    func validateStages() throws {
        guard stages.count <= 20000 else { throw ProjectError.invalid }
        var w = width, h = height
        for stage in stages { try stage.validate(); guard stage.inputWidth == w, stage.inputHeight == h else { throw ProjectError.invalid }; w = stage.outputWidth; h = stage.outputHeight }
    }
    /// The shared green/luminance radial equation extends to owned padding.
    /// Chromatic aberration is channel-specific and is not a fictitious shared
    /// offset. The same monotone radial branch is used in both directions.
    private func radialSourcePoint(_ point:CGPoint) throws -> CGPoint {
        guard optics == optics.normalized,point.x.isFinite,point.y.isFinite else { throw ProjectError.invalid }
        let cx=Double(width)*0.5,cy=Double(height)*0.5,k=optics.distortionK(profileStrength:PixelFilter.lensStrength)
        let dx=Double(point.x)-cx,dy=Double(point.y)-cy,q=(dx*dx+dy*dy)/(cx*cx+cy*cy)
        guard k.isFinite,k < 1.0/3,q.isFinite,1-3*k*q > 0 else { throw ProjectError.invalid }
        let result=CGPoint(x:cx+dx*(1-k*q),y:cy+dy*(1-k*q))
        guard result.x.isFinite,result.y.isFinite else { throw ProjectError.invalid };return result
    }
    private func radialDevelopedPoint(_ point:CGPoint) throws -> CGPoint {
        guard optics == optics.normalized,point.x.isFinite,point.y.isFinite else { throw ProjectError.invalid }
        let cx=Double(width)*0.5,cy=Double(height)*0.5,diagonal=cx*cx+cy*cy
        let dx=Double(point.x)-cx,dy=Double(point.y)-cy,target=hypot(dx,dy)
        let k=optics.distortionK(profileStrength:PixelFilter.lensStrength)
        guard k.isFinite,k < 1.0/3,target.isFinite else { throw ProjectError.invalid }
        if target == 0 || k == 0 { return point }
        // Negative distortion is globally monotone. Positive distortion has
        // one monotone branch; never select a second inverse beyond its fold.
        var low=0.0,high=k > 0 ? (diagonal/(3*k)).squareRoot():max(diagonal.squareRoot(),target)
        let ceiling=high*(1-k*high*high/diagonal)
        guard high.isFinite,ceiling.isFinite,target < ceiling || (k < 0 && target == ceiling) else { throw ProjectError.invalid }
        for _ in 0..<64 {
            let mid=(low+high)/2,mapped=mid*(1-k*mid*mid/diagonal)
            guard mapped.isFinite else { throw ProjectError.invalid }
            if mapped < target { low=mid } else { high=mid }
        }
        let radius=(low+high)/2,mapped=radius*(1-k*radius*radius/diagonal)
        guard abs(mapped-target) <= 64*Double.ulpOfOne*max(1,max(target,radius)),1-3*k*radius*radius/diagonal > 0 else { throw ProjectError.invalid }
        let result=CGPoint(x:cx+dx*radius/target,y:cy+dy*radius/target)
        guard result.x.isFinite,result.y.isFinite else { throw ProjectError.invalid };return result
    }
    func developedPoint(_ source: CGPoint) throws -> CGPoint {
        try LWFloatPlane.validateExtent(width:width,height:height);try validateStages()
        var point=try radialDevelopedPoint(geometry.map(source))
        for stage in stages { point=try stage.developedPoint(point) }
        return point
    }
    func sourcePoint(_ developed: CGPoint) throws -> CGPoint {
        try LWFloatPlane.validateExtent(width:width,height:height);try validateStages()
        var point=developed
        for stage in stages.reversed() { point=try stage.sourcePoint(point) }
        return try geometry.inverse().map(radialSourcePoint(point))
    }
    func sourcePointIfInBounds(_ developed:CGPoint) throws -> CGPoint? {
        try LWFloatPlane.validateExtent(width:width,height:height);try validateStages()
        guard optics == optics.normalized,developed.x.isFinite,developed.y.isFinite,
            optics.distortionK(profileStrength:PixelFilter.lensStrength) < 1.0/3 else { throw ProjectError.invalid }
        _ = try geometry.inverse()
        guard developed.x >= 0,developed.y >= 0,developed.x < CGFloat(developedWidth),developed.y < CGFloat(developedHeight) else { return nil }
        return try sourcePoint(developed)
    }
    /// Ordinary final-grid absence is nil; malformed or nonunique inversion is
    /// an error. Owned padding remains in the same virtual source frame.
    func developedPointIfInBounds(_ source:CGPoint) throws -> CGPoint? {
        try LWFloatPlane.validateExtent(width:width,height:height);try validateStages()
        _ = try geometry.inverse()
        var point=try radialDevelopedPoint(geometry.map(source))
        for stage in stages { guard let next=try stage.developedPointIfInBounds(point) else { return nil };point=next }
        return point.x >= 0 && point.y >= 0 && point.x < CGFloat(developedWidth) && point.y < CGFloat(developedHeight) ? point:nil
    }

}

nonisolated struct LWSourceSelectedDevelopment: Codable, Equatable, Sendable {
    let settings: CameraRawSettings
    let whiteBalance: LWSourceWhiteBalance
    let seed: UInt32
    let sourceCoverage: Data
    var sourceCoveragePlaneID: UUID? = nil
    /// Nil only for legacy source-grid coverage. New selected captures preserve the
    /// full developed grid/map in which their coverage was recorded.
    var coverageFrame: LWSourceRetouchFrame? = nil
    func validate() throws {
        guard settings.isValid, settings == settings.normalized else { throw ProjectError.invalid }
        _ = try whiteBalance.native
        try coverageFrame?.validate()
        if sourceCoveragePlaneID != nil { guard sourceCoverage.isEmpty else { throw ProjectError.invalid } }
        else { _ = try LWLinearSurface.packageExtent(sourceCoverage,maximumFileBytes:LWSourceDeveloper.maximumResultBytes) }
    }
}
nonisolated extension LWLiveSourceNode {
    func applyingDevelopment(settings:CameraRawSettings,whiteBalance:LWSourceWhiteBalance,seed:UInt32,selection:SelectionClip?,mapping:CGAffineTransform) throws -> Self {
        var next=try metadataCopy(additionalBytes:LWSourceMetadataStorage.sum(settings.retainedMetadataBytes,4096)); next.revision=UUID(); next.sourceLineage.append(next.revision)
        if let selection {
            let w=originalWidth,h=originalHeight
            let coverage=try PixelAdjust.coverage(selection,width:w,height:h,pixelToDocument:mapping)
            let values=try GuidedMatte.levels(of:coverage,width:w,height:h)
            let old=LWSourceSpatialMap(geometry:coordinateMap,optics:self.settings.optics,width:w,height:h)
            var mask=try LWFloatCompositor.clear(w,h)
            for y in 0..<h { for x in 0..<w {
                let point=try old.developedPoint(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
                let xx=Int(floor(point.x)),yy=Int(floor(point.y))
                if xx>=0,xx<w,yy>=0,yy<h { mask.pixels[y*w+x].w=values[yy*w+xx] }
            } }
            try next.admitMetadataMutation(additionalBytes:LWSourceMetadataStorage.sum(settings.retainedMetadataBytes,LWSourceMetadataStorage.product(mask.byteLength+4096,2)))
            next.selectedDevelopments.append(.init(settings:settings,whiteBalance:whiteBalance,seed:seed,sourceCoverage:try mask.packageData(maximumFileBytes:LWSourceDeveloper.maximumResultBytes)))
        } else { next.settings=settings;next.whiteBalance=whiteBalance;next.grainSeed=seed }
        try next.validate();return next
    }
}

/// The composite captures other layers once and substitutes the current developed
/// upstream source at its original position. No retouched output is a dependency.
nonisolated struct LWSourceSampleComposite: Codable, Equatable, Sendable {
    let revision: UUID
    fileprivate(set) var sourceID: UUID
    let upstreamRevision: UUID
    let payload: Data
    var metadataStorage:LWSourceMetadataStorage? = nil
    enum CodingKeys:String,CodingKey { case revision,sourceID,upstreamRevision,payload }
    static func ==(a:Self,b:Self)->Bool { a.revision==b.revision && a.sourceID==b.sourceID && a.upstreamRevision==b.upstreamRevision && a.payload==b.payload }
    var byteLength:Int { payload.count }
    struct Backing: Codable, Sendable {
        let documentID: UUID
        let width:Int
        let height:Int
        let sourceLayerID:UUID
        let layers:[ProjectLayerRecord]
        let images:[UUID:Data]
        let masks:[UUID:Data]
        var imagePlanes: [UUID:UUID] = [:]
        var maskPlanes: [UUID:UUID] = [:]
        var metadataStorage:LWSourceMetadataStorage? = nil
        enum CodingKeys:String,CodingKey { case documentID,width,height,sourceLayerID,layers,images,masks,imagePlanes,maskPlanes }
    }
    func decodedBacking(workingSet supplied:LWFloatWorkingSet?=nil) throws -> Backing {
        let selected=supplied ?? metadataStorage?.workingSet ?? .sourceGraphs
        // Reserve in the caller's actual shared owner before any typed backing
        // is decoded. A smaller workspace must not borrow the global budget.
        let owner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.decodingBytes(payload),workingSet:selected)
        var value=try LWCatalogCodec.decode(Backing.self,from:payload);value.metadataStorage=owner
        try Task.checkCancellation();return value
    }
    func validate(source:UUID,workingSet:LWFloatWorkingSet?=nil) throws {
        guard sourceID==source,payload.count<=LWSourceDeveloper.maximumResultBytes else { throw ProjectError.invalid }
        let backing=try decodedBacking(workingSet:workingSet)
        try backing.validate()
    }
    static func capture(_ snapshot:ProjectSnapshot,sourceLayer:UUID,node:LWLiveSourceNode) throws -> Self {
        var records=snapshot.manifest.layers,images:[UUID:Data]=[:],masks:[UUID:Data]=[:]
        guard records.contains(where:{$0.id==sourceLayer && $0.liveSource?.id==node.id}) else { throw ProjectError.invalid }
        for i in records.indices {
            records[i].liveSource=nil;records[i].liveSourceFile=nil
            if records[i].id != sourceLayer,let asset=snapshot.images[records[i].id] {
                let surface=try asset.linear ?? LWLinearSurface.read(asset.image,maximumBytes:LWSourceDeveloper.maximumResultBytes)
                images[records[i].id]=try surface.packageData(maximumFileBytes:LWSourceDeveloper.maximumResultBytes)
            }
            if let asset=snapshot.masks[records[i].id] {
                let surface=try LWLinearSurface.read(asset.image,maximumBytes:LWSourceDeveloper.maximumResultBytes)
                masks[records[i].id]=try surface.packageData(maximumFileBytes:LWSourceDeveloper.maximumResultBytes)
            }
        }
        let payload=try LWCatalogCodec.encode(Backing(documentID:snapshot.manifest.documentID,width:snapshot.manifest.width,height:snapshot.manifest.height,sourceLayerID:sourceLayer,layers:records,images:images,masks:masks))
        let result=Self(revision:UUID(),sourceID:node.id,upstreamRevision:node.revision,payload:payload)
        try result.validate(source:node.id,workingSet:node.metadataWorkingSet);return result
    }
}

nonisolated struct LWSourceRetouchFrame: Codable, Equatable, Sendable {
    let geometry:LWSourceCoordinateMap
    let optics:CameraRawOpticsSettings
    let width:Int
    let height:Int
    let layerTransform:LayerTransform
    var stages: [LWSourcePixelStage] = []
    var metadataStorage:LWSourceMetadataStorage? = nil
    enum CodingKeys:String,CodingKey { case geometry,optics,width,height,layerTransform,stages }
    static func ==(lhs:Self,rhs:Self)->Bool {
        lhs.geometry==rhs.geometry && lhs.optics==rhs.optics && lhs.width==rhs.width && lhs.height==rhs.height &&
        lhs.layerTransform==rhs.layerTransform && lhs.stages==rhs.stages
    }
    var spatialMap: LWSourceSpatialMap { LWSourceSpatialMap(geometry:geometry,optics:optics,width:width,height:height,stages:stages,metadataStorage:metadataStorage) }
    var developedWidth: Int { spatialMap.developedWidth }
    var developedHeight: Int { spatialMap.developedHeight }
    func validate() throws {
        try LWFloatPlane.validateExtent(width:width,height:height)
        try spatialMap.validateStages()
        guard layerTransform.isValid,optics == optics.normalized else { throw ProjectError.invalid }
    }
    /// Sigma in the captured developed layer pixel grid, exactly BlurTool's
    /// sourceRect grid; it is not a scalar approximation to a radial source map.
    func retainedBlurSigma(blurRadius:Double) throws -> Double {
        try validate();guard blurRadius.isFinite else { throw ProjectError.invalid }
        let affine=BrushRaster.pixelToDocument(layerTransform,width:developedWidth,height:developedHeight)
        let perPixel=max(1e-6,abs(Double(affine.a*affine.d-affine.b*affine.c)).squareRoot())
        return min(min(50,max(0.5,blurRadius))/perPixel,Double(max(developedWidth,developedHeight))/2)
    }
    func developedPixelToDocument(_ pixel:CGPoint) throws -> CGPoint {
        try validate();guard pixel.x.isFinite,pixel.y.isFinite else { throw ProjectError.invalid }
        let point=pixel.applying(BrushRaster.pixelToDocument(layerTransform,width:developedWidth,height:developedHeight))
        guard point.x.isFinite,point.y.isFinite else { throw ProjectError.invalid };return point
    }
    func documentToDevelopedPixel(_ document:CGPoint) throws -> CGPoint {
        try validate();guard document.x.isFinite,document.y.isFinite else { throw ProjectError.invalid }
        let point=document.applying(BrushRaster.pixelToDocument(layerTransform,width:developedWidth,height:developedHeight).inverted())
        guard point.x.isFinite,point.y.isFinite else { throw ProjectError.invalid };return point
    }
    func documentPoint(_ source:CGPoint) throws -> CGPoint {
        let pixel=try spatialMap.developedPoint(source)
        let result=pixel.applying(BrushRaster.pixelToDocument(layerTransform,width:developedWidth,height:developedHeight))
        guard result.x.isFinite,result.y.isFinite else { throw ProjectError.invalid };return result
    }
    func sourcePoint(_ document:CGPoint) throws -> CGPoint {
        let pixel=document.applying(BrushRaster.pixelToDocument(layerTransform,width:developedWidth,height:developedHeight).inverted())
        return try spatialMap.sourcePoint(pixel)
    }
    /// Off-canvas capture samples are absent, while malformed/folded mappings refuse.
    /// Warp edge sampling clamps only in the captured developed pixel grid.
    /// Malformed or folded geometry is never converted to a regular edge sample.
    func sourcePointClamped(_ document:CGPoint) throws -> CGPoint {
        try validate()
        guard document.x.isFinite,document.y.isFinite,
              optics.distortionK(profileStrength:PixelFilter.lensStrength) < 1.0/3 else { throw ProjectError.invalid }
        _ = try geometry.inverse()
        let pixel=try documentToDevelopedPixel(document)
        let clamped=CGPoint(x:min(CGFloat(developedWidth)-0.5,max(0.5,pixel.x)),
                            y:min(CGFloat(developedHeight)-0.5,max(0.5,pixel.y)))
        return try spatialMap.sourcePoint(clamped)
    }
    func documentPointIfInBounds(_ source:CGPoint) throws -> CGPoint? {
        try validate()
        let map=spatialMap
        guard let pixel=try map.developedPointIfInBounds(source) else { return nil }
        let result=pixel.applying(BrushRaster.pixelToDocument(layerTransform,width:developedWidth,height:developedHeight))
        guard result.x.isFinite,result.y.isFinite else { throw ProjectError.invalid };return result
    }
    func sourcePointIfInBounds(_ document:CGPoint) throws -> CGPoint? {
        try validate()
        guard document.x.isFinite,document.y.isFinite,
              optics.distortionK(profileStrength:PixelFilter.lensStrength) < 1.0/3 else { throw ProjectError.invalid }
        // Validate the homography independently of edge classification.
        _ = try geometry.inverse()
        let pixel=document.applying(BrushRaster.pixelToDocument(layerTransform,width:developedWidth,height:developedHeight).inverted())
        guard pixel.x.isFinite,pixel.y.isFinite else { throw ProjectError.invalid }
        guard pixel.x >= 0,pixel.y >= 0,pixel.x < CGFloat(developedWidth),pixel.y < CGFloat(developedHeight) else { return nil }
        let result=try spatialMap.sourcePoint(pixel)
        return result
    }
}

nonisolated extension LWSourceRetouchStroke {
    /// Decode once per retained operation; evaluator samples alpha in source space.
    var liquifyStrength:Double { min(1,max(0.01,opacity)) }
    var smudgeDabs:[CGPoint] { get throws { try warpDabs } }
    func admittedReplayPointCount() throws -> Int {
        guard points.count <= 100000 else { throw ProjectError.tooLarge }
        if kind == .smear || kind == .liquify {
            guard pointsAreDabs,let sourceStart,sourceStart.x.isFinite,sourceStart.y.isFinite else { throw ProjectError.invalid }
            let (count,overflow)=points.count.addingReportingOverflow(1)
            guard !overflow else { throw ProjectError.tooLarge };return count
        }
        return points.count
    }
    var warpDabs:[CGPoint] {
        get throws {
            guard pointsAreDabs,let sourceStart,sourceStart.x.isFinite,sourceStart.y.isFinite else { throw ProjectError.invalid }
            return [sourceStart]+points
        }
    }
    func selectionMask(admission:LWSourceRetouchAdmission) throws -> LWLinearSurface? {
        guard let data=selectionSourceCoverage else { return nil }
        guard data.count <= admission.selectionBytes,data.count <= admission.encodedBackingBytes else { throw ProjectError.tooLarge }
        return try selectionMask()
    }
    func selectionMask() throws -> LWLinearSurface? {
        guard let data=selectionSourceCoverage else { return nil }
        let mask=try LWLinearSurface.package(data,maximumFileBytes:LWSourceDeveloper.maximumResultBytes)
        guard mask.width == captureFrame.width,mask.height == captureFrame.height else { throw ProjectError.invalid }
        return mask
    }
}
nonisolated extension LWLiveSourceNode {
    func sourceCoverage(_ selection:SelectionClip?,mapping:CGAffineTransform) throws -> Data? {
        guard let selection else { return nil }
        let w=originalWidth,h=originalHeight
        let coverage=try PixelAdjust.coverage(selection,width:w,height:h,pixelToDocument:mapping)
        let values=try GuidedMatte.levels(of:coverage,width:w,height:h)
        let map=LWSourceSpatialMap(geometry:coordinateMap,optics:settings.optics,width:w,height:h)
        var surface=try LWFloatCompositor.clear(w,h)
        for y in 0..<h { for x in 0..<w {
            let p=try map.developedPoint(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
            let xx=Int(floor(p.x)),yy=Int(floor(p.y))
            if xx>=0,xx<w,yy>=0,yy<h { surface.pixels[y*w+x].w=values[yy*w+xx] }
        } }
        return try surface.packageData(maximumFileBytes:LWSourceDeveloper.maximumResultBytes)
    }
}

/// Conservative aggregate admission for encoded dependency ownership plus decoding,
/// surface snapshots, operation scratch and captured dab/carry coordinates. This is
/// the existing result envelope, not a raised process quota or a timing claim.
nonisolated struct LWSourceRetouchAdmission: Sendable {
    let encodedBackingBytes:Int
    let selectionBytes:Int
    let compositeBytes:Int
    let maximumDabs:Int
    let surfaceBytes:Int
    let operationScratchBytes:Int
    var lease: LWFloatWorkingSet.Lease? = nil
    var admittedPlaneID:UUID? = nil
    var admittedSourceID:UUID? = nil
    var admittedRevision:UUID? = nil
    var admittedWorkingSet:LWFloatWorkingSet? = nil
    func validate(node:LWLiveSourceNode,workspace:LWFloatWorkspace,plane:LWFloatPlane? = nil) throws {
        guard lease != nil,admittedSourceID == node.id,admittedRevision == node.revision,
            admittedWorkingSet === workspace.workingSet,admittedPlaneID != nil else { throw ProjectError.invalid }
        if let plane { guard admittedPlaneID == plane.manifest.id,plane.workingSet === workspace.workingSet else { throw ProjectError.invalid } }
        try workspace.cancellation.check()
    }
}
nonisolated extension LWLiveSourceNode {
    /// Operation-wide resident admission. Virtual full-plane/disk capacity is not
    /// confused with resident surface bytes: all later tile/state leases still
    /// draw from this same owner while this metadata/working reservation is held.
    func retouchAdmission(plane: LWFloatPlane, workspace: LWFloatWorkspace,
        operationScratchBytes: Int) throws -> LWSourceRetouchAdmission {
        let current = try currentSpatialMap
        guard plane.width == current.developedWidth, plane.height == current.developedHeight,
            plane.workingSet === workspace.workingSet, operationScratchBytes >= 0 else { throw ProjectError.invalid }
        try current.validateStages()
        try validate(); try workspace.cancellation.check()
        let limit = workspace.workingSet.limit
        var selections = 0, composites = 0, dabs = 0, metadata = retainedPayloadBytes
        func add(_ amount: Int, _ total: inout Int) throws {
            let (value, overflow) = total.addingReportingOverflow(amount)
            guard amount >= 0, !overflow, value <= limit else { throw ProjectError.tooLarge }; total = value
        }
        for stroke in retouch { try add(stroke.selectionSourceCoverage?.count ?? 0, &selections); try add(stroke.admittedReplayPointCount(), &dabs) }
        for step in selectedDevelopments { try add(step.sourceCoverage.count, &selections) }
        for composite in sampleComposites { try add(composite.payload.count, &composites) }
        var encoded = selections; try add(composites, &encoded)
        let (copies, copyOverflow) = encoded.multipliedReportingOverflow(by: 8)
        let (coordinates, pointOverflow) = dabs.multipliedReportingOverflow(by: MemoryLayout<CGPoint>.stride * 4)
        guard !copyOverflow, !pointOverflow, metadata >= 0 else { throw ProjectError.tooLarge }
        try add(copies, &metadata); try add(coordinates, &metadata); try add(operationScratchBytes, &metadata)
        let lease = try workspace.workingSet.reserve(metadata)
        // Pixel caches/builders/readbacks are charged by their concrete owners,
        // not prepaid unbounded full-frame copies hidden in this receipt.
        let tileBytes = min(plane.width, LWFloatPlane.tileSide) * min(plane.height, LWFloatPlane.tileSide) * 16
        return .init(encodedBackingBytes: encoded, selectionBytes: selections, compositeBytes: composites,
            maximumDabs:dabs,surfaceBytes:tileBytes,operationScratchBytes:operationScratchBytes,lease:lease,
            admittedPlaneID:plane.manifest.id,admittedSourceID:id,admittedRevision:revision,admittedWorkingSet:workspace.workingSet)
    }
    func retouchAdmission(surface:LWLinearSurface,operationScratchBytes:Int=0) throws -> LWSourceRetouchAdmission {
        try retouchAdmission(width:surface.width,height:surface.height,maximumBytes:surface.maximumBytes,operationScratchBytes:operationScratchBytes)
    }
    func retouchAdmission(width:Int,height:Int,maximumBytes:Int,operationScratchBytes:Int=0) throws -> LWSourceRetouchAdmission {
        let count=try LWLinearSurface.extent(width:width,height:height,maximumBytes:maximumBytes)
        guard retouch.count <= 10000,sampleComposites.count <= 10000,selectedDevelopments.count <= 128 else { throw ProjectError.tooLarge }
        var selectionBytes=0,compositeBytes=0,encodedBytes=0,dabs=0
        func add(_ amount:Int,_ total:inout Int) throws {
            guard amount >= 0,amount <= maximumBytes-total else { throw ProjectError.tooLarge };total += amount
        }
        for step in selectedDevelopments { try add(step.sourceCoverage.count,&selectionBytes) }
        for stroke in retouch {
            guard !stroke.points.isEmpty,stroke.points.count <= 100000,stroke.points.allSatisfy({$0.x.isFinite && $0.y.isFinite}),
                  stroke.radius.isFinite,stroke.radius > 0,stroke.radius <= Double(DocumentLimits.maxSide) else { throw ProjectError.invalid }
            try add(stroke.selectionSourceCoverage?.count ?? 0,&selectionBytes)
            try add(stroke.admittedReplayPointCount(),&dabs)
        }
        for composite in sampleComposites { try add(composite.payload.count,&compositeBytes) }
        try add(selectionBytes,&encodedBytes);try add(compositeBytes,&encodedBytes)
        func multiplied(_ value:Int,_ factor:Int) throws -> Int {
            let (result,overflow)=value.multipliedReportingOverflow(by:factor)
            guard !overflow,result <= maximumBytes else { throw ProjectError.tooLarge };return result
        }
        // 8 full surfaces + 3 Float coverage arrays agree with the evaluator's
        // retained scratch, while dependency bytes reserve eight decode/copy
        // equivalents (JSON/base64, Data, float arrays, provider and composite).
        var required=try multiplied(count,16*8+4*3)
        try add(try multiplied(encodedBytes,8),&required)
        try add(try multiplied(dabs,MemoryLayout<CGPoint>.stride*4),&required)
        try add(operationScratchBytes,&required)
        guard required <= maximumBytes else { throw ProjectError.tooLarge }
        return .init(encodedBackingBytes:encodedBytes,selectionBytes:selectionBytes,compositeBytes:compositeBytes,maximumDabs:dabs,surfaceBytes:count*MemoryLayout<SIMD4<Float>>.stride,operationScratchBytes:operationScratchBytes)
    }
}

nonisolated extension LWLiveSourceNode {
    /// Full package validation occurs under the same predecode aggregate admission;
    /// operation metadata validation itself never decodes a selection twice.
    func validateBackingAssets() throws {
        try validate()
        for asset in planeAssets.values {
            try asset.reference.validate()
            guard let plane = asset.plane,asset.reference == (try LWFloatPlaneArchive.reference(plane)) else { throw ProjectError.missingImage }
            try plane.checkCancellation()
        }
        for step in selectedDevelopments {
            // New coverage is retained in its own captured developed grid. Only
            // legacy no-frame records use the original source extent.
            let width=step.coverageFrame?.developedWidth ?? originalWidth
            let height=step.coverageFrame?.developedHeight ?? originalHeight
            if let key = step.sourceCoveragePlaneID {
                guard let asset = planeAssets[key],asset.reference.width == width,asset.reference.height == height else { throw ProjectError.invalid }
            } else {
                let extent=try LWLinearSurface.packageExtent(step.sourceCoverage,maximumFileBytes:LWSourceDeveloper.maximumResultBytes)
                guard extent.width == width,extent.height == height else { throw ProjectError.invalid }
            }
        }
        for stroke in retouch {
            if let key = stroke.selectionPlaneID {
                guard stroke.selectionSourceCoverage == nil,let asset = planeAssets[key],
                    asset.reference.width == (stroke.selectionFrame?.developedWidth ?? stroke.captureFrame.width),
                    asset.reference.height == (stroke.selectionFrame?.developedHeight ?? stroke.captureFrame.height) else { throw ProjectError.invalid }
            }
        }
        for adjustment in adjustments {
            if let key=adjustment.selectionPlaneID {
                guard let asset=planeAssets[key],asset.reference.width == adjustment.captureFrame.developedWidth,
                    asset.reference.height == adjustment.captureFrame.developedHeight else { throw ProjectError.invalid }
            }
        }
        for plugin in plugins {
            if let key=plugin.selectionPlaneID {
                guard let asset=planeAssets[key],asset.reference.width == plugin.captureFrame.developedWidth,
                    asset.reference.height == plugin.captureFrame.developedHeight else { throw ProjectError.invalid }
            }
        }
        for filter in filters {
            if let key = filter.selectionPlaneID {
                guard let frame = filter.selectionFrame, let asset = planeAssets[key],
                    asset.reference.width == frame.developedWidth, asset.reference.height == frame.developedHeight else { throw ProjectError.invalid }
            }
            if let key = filter.retainedResultPlaneID {
                guard let asset = planeAssets[key], asset.reference.width == filter.pixelStage.outputWidth,
                    asset.reference.height == filter.pixelStage.outputHeight else { throw ProjectError.invalid }
            }
        }
        for composite in sampleComposites { try composite.validate(source:id,workingSet:metadataWorkingSet) }
    }
}

nonisolated extension LWLiveSourceNode {
    /// Retained ownership charge, in addition to the existing CGImage backing.
    /// Includes encoded dependencies and typed array contents; it is not RSS.
    var retainedPayloadBytes:Int {
        var bytes=MemoryLayout<Self>.stride
        func add(_ amount:Int) { let sum=bytes.addingReportingOverflow(amount);bytes=sum.overflow ? Int.max:sum.partialValue }
        func array(_ count:Int,_ stride:Int) { add((try? LWSourceMetadataStorage.collectionBytes(count:count,stride:stride)) ?? Int.max) }
        func data(_ count:Int) { add((try? LWSourceMetadataStorage.sum(256,LWSourceMetadataStorage.product(count,2))) ?? Int.max) }
        func development(_ value:CameraRawSettings) {
            for points in [value.curve.rgb,value.curve.red,value.curve.green,value.curve.blue] { array(points.count,MemoryLayout<CurvePoint>.stride) }
            for values in [value.mixer.hue,value.mixer.saturation,value.mixer.luminance] { array(values.count,MemoryLayout<Double>.stride) }
            array(value.mixer.points.count,MemoryLayout<CameraRawPointColor>.stride)
            array(value.geometry.guides.count,MemoryLayout<CameraRawGeometryGuide>.stride)
        }
        func stage(_ value:LWSourcePixelStage) { array(value.homography?.values.count ?? 0,MemoryLayout<Double>.stride) }
        func frame(_ value:LWSourceRetouchFrame) {
            array(value.geometry.values.count,MemoryLayout<Double>.stride)
            array(value.stages.count,MemoryLayout<LWSourcePixelStage>.stride)
            for value in value.stages { stage(value) }
        }
        array(coordinateMap.values.count,MemoryLayout<Double>.stride)
        add((try? original.localFileURL().path.utf8.count) ?? Int.max)
        data(originalRevision.count);data(metadata.count);data(provenance.count);data(catalogAuthority?.count ?? 0);data(decoderSourceRevision.utf8.count)
        array(sourceLineage.count,MemoryLayout<UUID>.stride);development(settings)
        array(selectedDevelopments.count,MemoryLayout<LWSourceSelectedDevelopment>.stride)
        for selected in selectedDevelopments { if let captured=selected.coverageFrame { frame(captured) } }
        for step in selectedDevelopments { data(step.sourceCoverage.count);development(step.settings) }
        array(planeAssets.count,MemoryLayout<UUID>.stride + MemoryLayout<LWSourcePlaneAsset>.stride + 128)
        array(sampleComposites.count,MemoryLayout<LWSourceSampleComposite>.stride)
        for sample in sampleComposites { data(sample.payload.count) }
        array(retouch.count,MemoryLayout<LWSourceRetouchStroke>.stride)
        for stroke in retouch {
            array(stroke.points.count,MemoryLayout<CGPoint>.stride);array(stroke.color.count,MemoryLayout<Float>.stride)
            data(stroke.selectionSourceCoverage?.count ?? 0);frame(stroke.captureFrame)
            if let selection=stroke.selectionFrame { frame(selection) }
        }
        array(operations.count,MemoryLayout<LWSourceOperation>.stride)
        array(resamples.count,MemoryLayout<LWSourceResample>.stride)
        for operation in resamples { stage(operation.stage) }
        array(adjustments.count,MemoryLayout<LWSourceRetainedAdjustment>.stride)
        for value in adjustments { add(value.retainedMetadataBytes) }
        array(plugins.count,MemoryLayout<LWSourceRetainedPlugin>.stride)
        for value in plugins { add(value.retainedMetadataBytes) }
        array(filters.count,MemoryLayout<LWSourceRetainedFilter>.stride)
        for filter in filters { frame(filter.captureFrame);stage(filter.pixelStage)
            if let selection=filter.selectionFrame { frame(selection) }
            development(filter.settings.cameraRaw); add(filter.settings.dither.characters.utf8.count)
            for channel in filter.settings.curves.channels { array(channel.count,MemoryLayout<CurvePoint>.stride) } }
        return bytes
    }
}

/// Encoded document state binds content; a hydrated private plane owns the pixels.
/// Equality ignores its in-memory locator and compares the complete content identity.
nonisolated struct LWSourcePlaneAsset: Codable, Equatable, @unchecked Sendable {
    let reference: LWFloatPlaneArchive.Reference
    var plane: LWFloatPlane?
    init(_ plane: LWFloatPlane) throws { reference = try LWFloatPlaneArchive.reference(plane); self.plane = plane }
    enum CodingKeys: String, CodingKey { case reference }
    init(from decoder: Decoder) throws {
        let keys = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        guard Set(keys.allKeys.map(\.stringValue)) == ["reference"] else { throw ProjectError.invalid }
        let values = try decoder.container(keyedBy: CodingKeys.self)
        reference = try values.decode(LWFloatPlaneArchive.Reference.self, forKey: .reference); try reference.validate(); plane = nil
    }
    func encode(to encoder: Encoder) throws {
        try reference.validate(); var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(reference, forKey: .reference)
    }
    static func == (lhs: Self, rhs: Self) -> Bool { lhs.reference == rhs.reference }
    func resolved(in workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        try reference.validate()
        guard let plane, plane.workingSet === workspace.workingSet,
            reference == (try LWFloatPlaneArchive.reference(plane)) else { throw ProjectError.invalid }
        try plane.checkCancellation(); return plane
    }
}
nonisolated extension LWLiveSourceNode {
    func dependencyPlane(_ id: UUID, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        guard let asset = planeAssets[id] else { throw ProjectError.missingImage }
        return try asset.resolved(in: workspace)
    }
    func developmentSelectionPlane(_ step: LWSourceSelectedDevelopment, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let plane: LWFloatPlane
        if let id = step.sourceCoveragePlaneID {
            guard step.sourceCoverage.isEmpty else { throw ProjectError.invalid }; plane = try dependencyPlane(id, workspace: workspace)
        } else {
            // Legacy small owned coverage is decoded once, then tiled. New captures
            // always carry plane identities and do not enter this compatibility path.
            plane = try LWFloatCompositor.fromEncodedSurface(step.sourceCoverage,
                maximumFileBytes:LWSourceDeveloper.maximumResultBytes,workspace:workspace)
        }
        guard plane.width == (step.coverageFrame?.developedWidth ?? originalWidth),
              plane.height == (step.coverageFrame?.developedHeight ?? originalHeight) else { throw ProjectError.invalid }; return plane
    }
    func selectionPlane(for stroke: LWSourceRetouchStroke, admission: LWSourceRetouchAdmission,
        workspace: LWFloatWorkspace) throws -> LWFloatPlane? {
        try admission.validate(node:self,workspace:workspace)
        try stroke.validate(source:id)
        guard sourceLineage.contains(stroke.upstreamRevision) else { throw ProjectError.invalid }
        let result:LWFloatPlane
        if let selected = stroke.selectionPlaneID {
            guard stroke.selectionSourceCoverage == nil else { throw ProjectError.invalid }
            result = try dependencyPlane(selected, workspace: workspace)
        } else if let data = stroke.selectionSourceCoverage {
            guard data.count <= admission.selectionBytes else { throw ProjectError.tooLarge }
            result = try LWFloatCompositor.fromEncodedSurface(data,
                maximumFileBytes:LWSourceDeveloper.maximumResultBytes,workspace:workspace)
        } else { return nil }
        guard result.width == (stroke.selectionFrame?.developedWidth ?? stroke.captureFrame.width),
            result.height == (stroke.selectionFrame?.developedHeight ?? stroke.captureFrame.height) else { throw ProjectError.invalid }
        return result
    }
    func selectionSampler(for stroke: LWSourceRetouchStroke, plane: LWFloatPlane?) throws -> LWSourceSelectionSampler? {
        try stroke.validate(source:id)
        guard sourceLineage.contains(stroke.upstreamRevision) else { throw ProjectError.invalid }
        guard let plane else {
            guard stroke.selectionPlaneID == nil, stroke.selectionSourceCoverage == nil, stroke.selectionFrame == nil else { throw ProjectError.invalid }
            return nil
        }
        if let key = stroke.selectionPlaneID {
            guard let recorded = planeAssets[key], recorded.reference == (try LWFloatPlaneArchive.reference(plane)) else { throw ProjectError.invalid }
        } else { guard stroke.selectionSourceCoverage != nil else { throw ProjectError.invalid } }
        guard sourceLineage.contains(stroke.upstreamRevision),
            plane.width == (stroke.selectionFrame?.developedWidth ?? stroke.captureFrame.width),
            plane.height == (stroke.selectionFrame?.developedHeight ?? stroke.captureFrame.height) else { throw ProjectError.invalid }
        return LWSourceSelectionSampler(plane:plane,frame:stroke.selectionFrame)
    }
    func sampleAllCompositePlane(for stroke: LWSourceRetouchStroke, before: LWFloatPlane,
        admission: LWSourceRetouchAdmission, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        try admission.validate(node:self,workspace:workspace,plane:before)
        let spatial=try currentSpatialMap
        guard before.width == spatial.developedWidth,before.height == spatial.developedHeight,
            stroke.sourceID == id,sourceLineage.contains(stroke.upstreamRevision),stroke.sampleAllLayers,
            let revision = stroke.sampleAllLayersCompositeRevision,
            let captured = sampleComposites.first(where: { $0.revision == revision }),
            captured.sourceID == id, captured.upstreamRevision == stroke.upstreamRevision,
            captured.payload.count <= admission.compositeBytes else { throw ProjectError.invalid }
        let backing=try captured.decodedBacking(workingSet:workspace.workingSet)
        try backing.validate()
        guard backing.layers.filter({ $0.id == backing.sourceLayerID }).count == 1,
            backing.images[backing.sourceLayerID] == nil, backing.imagePlanes[backing.sourceLayerID] == nil,
            backing.layers.allSatisfy({ $0.liveSource == nil && $0.liveSourceFile == nil }) else { throw ProjectError.invalid }
        var images: [UUID: ImportedImage] = [:], masks: [UUID: ImportedImage] = [:]
        for (layer, assetID) in backing.imagePlanes { images[layer] = try ImportedImage(plane: dependencyPlane(assetID, workspace: workspace), name: "Retained sampling dependency") }
        for (layer, assetID) in backing.maskPlanes { masks[layer] = try ImportedImage(maskPlane: dependencyPlane(assetID, workspace: workspace), name: "Retained mask dependency") }
        // Historical small encoded dependencies remain lawful inputs. Resolve
        // them under the operation-wide encoded/copy lease, without silently
        // dropping a retained layer or substituting the current mutable document.
        for (layer,data) in backing.images {
            let plane=try LWFloatCompositor.fromEncodedSurface(data,maximumFileBytes:admission.encodedBackingBytes,workspace:workspace)
            images[layer]=try ImportedImage(plane:plane,name:"Retained encoded sampling dependency")
        }
        for (layer,data) in backing.masks {
            let plane=try LWFloatCompositor.fromEncodedSurface(data,maximumFileBytes:admission.encodedBackingBytes,workspace:workspace)
            let coverage=try LWFloatCompositor.map(plane,workspace:workspace) { p,_,_ in
                guard p.x.isFinite,(0...1).contains(p.x) else { throw ProjectError.invalid };return SIMD4(repeating:p.x)
            }
            masks[layer]=try ImportedImage(maskPlane:coverage,name:"Retained encoded mask dependency")
        }
        // Immediately-pre-operation input occupies its captured stack position.
        // The live node's retouched output cannot be captured in other dependencies.
        images[backing.sourceLayerID] = try ImportedImage(plane: before, name: "Immutable pre-operation source")
        let manifest = ProjectManifest(documentID: backing.documentID, width: backing.width, height: backing.height,
            activeLayerID: backing.sourceLayerID, layers: backing.layers)
        let composite = try LWFloatCompositor.renderPlane(ProjectSnapshot(manifest: manifest, images: images, masks: masks), workspace: workspace)
        guard let sourceRecord = backing.layers.first(where: { $0.id == backing.sourceLayerID }) else { throw ProjectError.invalid }
        return try LWFloatCompositor.project(composite,
            mapping: BrushRaster.pixelToDocument(sourceRecord.transform, width: before.width, height: before.height).inverted(),
            width: before.width, height: before.height, workspace: workspace)
    }
}

nonisolated extension LWSourceSampleComposite {
    static func capturePlane(_ snapshot: ProjectSnapshot, sourceLayer: UUID, node: LWLiveSourceNode,
        workspace: LWFloatWorkspace) throws -> (composite: Self, assets: [UUID:LWSourcePlaneAsset]) {
        let entries=try LWSourceMetadataStorage.product(snapshot.manifest.layers.count,4)
        let topology=try LWSourceMetadataStorage.collectionBytes(count:entries,stride:MemoryLayout<LWSourcePlaneAsset>.stride+128)
        let chargedManifest=try snapshot.manifest.metadataCopy(additionalBytes:topology,workingSet:workspace.workingSet)
        defer { withExtendedLifetime(chargedManifest.metadataStorage) {} }
        var records = chargedManifest.layers, images: [UUID:UUID] = [:], masks: [UUID:UUID] = [:], assets: [UUID:LWSourcePlaneAsset] = [:]
        guard records.contains(where: { $0.id == sourceLayer && $0.liveSource?.id == node.id }) else { throw ProjectError.invalid }
        for i in records.indices {
            try Task.checkCancellation()
            records[i].liveSource = nil; records[i].liveSourceFile = nil
            if records[i].id != sourceLayer, let asset = snapshot.images[records[i].id] {
                let plane = try asset.linearPlane ?? LWFloatCompositor.from(asset.image, workspace: workspace)
                let id = UUID(); assets[id] = try LWSourcePlaneAsset(plane); images[records[i].id] = id
                try asset.validatePlaneRead()
            }
            if let asset = snapshot.masks[records[i].id] {
                let plane = try LWSourceMaskReconcile.plane(asset,workspace:workspace)
                let id = UUID(); assets[id] = try LWSourcePlaneAsset(plane); masks[records[i].id] = id
                try asset.validatePlaneRead()
            }
        }
        let encoded=try LWSourceMetadataStorage.encode(Backing(documentID:snapshot.manifest.documentID,
            width:snapshot.manifest.width,height:snapshot.manifest.height,sourceLayerID:sourceLayer,
            layers:records,images:[:],masks:[:],imagePlanes:images,maskPlanes:masks),
            maximumBytes:4*1024*1024,workingSet:workspace.workingSet,catalogCodec:true)
        defer { withExtendedLifetime(encoded) {} }
        let retained=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.sum(LWSourceMetadataStorage.sum(LWSourceMetadataStorage.product(encoded.count,2),4096),topology),workingSet:workspace.workingSet,decodedPayload:true)
        let payload=try encoded.copyData(ownedBy:retained)
        var result = Self(revision: UUID(), sourceID: node.id, upstreamRevision: node.revision, payload: payload)
        result.metadataStorage=retained
        try result.validate(source: node.id,workingSet:workspace.workingSet); return (result, assets)
    }
}
nonisolated extension LWLiveSourceNode {
    func sourceCoveragePlane(_ selection: SelectionClip?, mapping: CGAffineTransform,
        workspace: LWFloatWorkspace, capturedDevelopment:Bool=false) throws -> LWSourcePlaneAsset? {
        guard let selection else { return nil }
        guard [mapping.a,mapping.b,mapping.c,mapping.d,mapping.tx,mapping.ty].allSatisfy(\.isFinite),
            mapping.a * mapping.d - mapping.b * mapping.c != 0 else { throw ProjectError.invalid }
        let borrowedBytes:Int
        if let coverage=selection.coverage {
            let bytes=coverage.bytesPerRow.multipliedReportingOverflow(by:coverage.height)
            guard !bytes.overflow,bytes.partialValue >= 0 else { throw ProjectError.tooLarge }
            borrowedBytes=bytes.partialValue
        } else { borrowedBytes=0 }
        let borrowed = try workspace.workingSet.reserve(borrowedBytes)
        let oldMap = try currentSpatialMap, developedWidth = oldMap.developedWidth, developedHeight = oldMap.developedHeight
        let builder = try workspace.makeBuilder(width: developedWidth, height: developedHeight)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            try autoreleasepool {
                let bytes = try range.validate(frameWidth: developedWidth, frameHeight: developedHeight)
                let lease = try workspace.workingSet.reserve(bytes * 6)
                // Intrinsic selection remains the existing grayscale coverage,
                // including its exact public empty-selection behavior.
                let context = try BrushRaster.context(width: range.width, height: range.height, mask: true)
                context.translateBy(x: -CGFloat(range.x), y: -CGFloat(range.y))
                context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0,y: 0,width: developedWidth,height: developedHeight))
                context.concatenate(mapping.inverted()); selection.apply(to: context)
                context.setFillColor(gray: 1, alpha: 1); context.fill(selection.rect)
                guard let image = context.makeImage() else { throw ExportError.render }
                try builder.append(LWLinearSurface.read(image, maximumBytes: bytes), at: range)
                withExtendedLifetime(lease) {}
            }
        }
        let developed = try builder.finish()
        if capturedDevelopment {
            let mask=try LWFloatCompositor.map(developed,workspace:workspace) { p,_,_ in SIMD4(repeating:p.x) }
            withExtendedLifetime(borrowed) {};return try LWSourcePlaneAsset(mask)
        }
        let coverage = developed.sampler()
        let blank = try LWFloatCompositor.clearPlane(width:originalWidth,height:originalHeight,workspace:workspace)
        let source = try LWFloatCompositor.map(blank, workspace: workspace) { _, x, y in
            guard let point = try oldMap.developedPointIfInBounds(CGPoint(x: CGFloat(x)+0.5,y: CGFloat(y)+0.5)) else { return .zero }
            let value = try coverage.pixel(x: Int(floor(point.x)),y: Int(floor(point.y))).x
            return SIMD4(value, value, value, value)
        }
        withExtendedLifetime(borrowed) {}; return try LWSourcePlaneAsset(source)
    }
    func applyingDevelopment(settings: CameraRawSettings, whiteBalance: LWSourceWhiteBalance, seed: UInt32,
        selection: SelectionClip?, mapping: CGAffineTransform, workspace: LWFloatWorkspace) throws -> Self {
        let capture=try currentSpatialMap
        let frame=LWSourceRetouchFrame(geometry:capture.geometry,optics:capture.optics,width:capture.width,height:capture.height,
            layerTransform:LayerTransform(origin:.zero,size:CGSize(width:capture.developedWidth,height:capture.developedHeight)),stages:capture.stages)
        let additional=try LWSourceMetadataStorage.sum(settings.retainedMetadataBytes,
            LWSourceMetadataStorage.sum(selection == nil ? 0:frame.retainedMetadataBytes,8192))
        var next = try metadataCopy(additionalBytes:additional); next.revision = UUID(); next.sourceLineage.append(next.revision)
        if let coverage = try sourceCoveragePlane(selection,mapping: mapping,workspace: workspace,capturedDevelopment:true) {
            let key = UUID(); next.planeAssets[key] = coverage
            next.selectedDevelopments.append(.init(settings: settings,whiteBalance: whiteBalance,seed: seed,
                sourceCoverage: Data(),sourceCoveragePlaneID: key,coverageFrame:frame))
        } else { next.settings = settings; next.whiteBalance = whiteBalance; next.grainSeed = seed }
        try next.validate(); return next
    }
}


nonisolated extension LWLiveSourceNode {
    init(from decoder: any Decoder) throws {
        guard let admission=decoder.userInfo[LWSourceMetadataStorage.decoderKey] as? LWSourceMetadataStorage else { throw ProjectError.invalid }
        metadataStorage=admission
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let required: Set<String> = ["schema","id","revision","sourceLineage","original","rawHint","originalRevision",
            "originalWidth","originalHeight","metadata","provenance","decoderSourceRevision","whiteBalance",
            "settings","grainSeed","coordinateMap","retouch","selectedDevelopments","sampleComposites"]
        let allowed = required.union(["catalogAuthority","planeAssets","filters","resamples","operations","adjustments","plugins"])
        let actual = Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of: actual), actual.isSubset(of: allowed) else { throw ProjectError.invalid }
        schema = try c.decode(Int.self, forKey: .init("schema"))
        id = try c.decode(UUID.self, forKey: .init("id")); revision = try c.decode(UUID.self, forKey: .init("revision"))
        sourceLineage = try c.decode([UUID].self, forKey: .init("sourceLineage"))
        original = try c.decode(LWCatalogNativePath.self, forKey: .init("original"))
        rawHint = try c.decode(Bool.self, forKey: .init("rawHint"))
        originalRevision = try c.decode(Data.self, forKey: .init("originalRevision"))
        originalWidth = try c.decode(Int.self, forKey: .init("originalWidth")); originalHeight = try c.decode(Int.self, forKey: .init("originalHeight"))
        metadata = try c.decode(Data.self, forKey: .init("metadata")); provenance = try c.decode(Data.self, forKey: .init("provenance"))
        decoderSourceRevision = try c.decode(String.self, forKey: .init("decoderSourceRevision"))
        catalogAuthority = try c.decodeIfPresent(Data.self, forKey: .init("catalogAuthority"))
        whiteBalance = try c.decode(LWSourceWhiteBalance.self, forKey: .init("whiteBalance"))
        settings = try c.decode(CameraRawSettings.self, forKey: .init("settings"))
        grainSeed = try c.decode(UInt32.self, forKey: .init("grainSeed"))
        coordinateMap = try c.decode(LWSourceCoordinateMap.self, forKey: .init("coordinateMap"))
        retouch = try c.decode([LWSourceRetouchStroke].self, forKey: .init("retouch"))
        selectedDevelopments = try c.decode([LWSourceSelectedDevelopment].self, forKey: .init("selectedDevelopments"))
        sampleComposites = try c.decode([LWSourceSampleComposite].self, forKey: .init("sampleComposites"))
        // Reference-only pre-plane source records may omit these arrays. Unknown
        // mechanisms are refused, not silently discarded during a save/reopen.
        planeAssets = try c.decodeIfPresent([UUID: LWSourcePlaneAsset].self, forKey: .init("planeAssets")) ?? [:]
        filters = try c.decodeIfPresent([LWSourceRetainedFilter].self, forKey: .init("filters")) ?? []
        resamples = try c.decodeIfPresent([LWSourceResample].self, forKey: .init("resamples")) ?? []
        operations = try c.decodeIfPresent([LWSourceOperation].self, forKey: .init("operations")) ?? []
        adjustments=try c.decodeIfPresent([LWSourceRetainedAdjustment].self,forKey:.init("adjustments")) ?? []
        plugins=try c.decodeIfPresent([LWSourceRetainedPlugin].self,forKey:.init("plugins")) ?? []
        // The archive deliberately externalizes backing bytes before encoding
        // this record. Decode checks schema/metadata here; hydrate validates all
        // required backing, identities and semantic state before publication.
        guard schema == 1, sourceLineage.count <= 10000, retouch.count <= 10000,
            selectedDevelopments.count <= 128, sampleComposites.count <= 10000,
            settings.isValid, settings == settings.normalized else { throw ProjectError.invalid }
        try LWFloatPlane.validateExtent(width: originalWidth, height: originalHeight)
        _ = try coordinateMap.inverse(); try validateOperationOrder();try validateMetadataStorage()
    }
}


/// Samples one already-resolved immutable mask. A recorded selection is never
/// replaced with full coverage because mapping or decoding failed.
nonisolated final class LWSourceSelectionSampler {
    private let sampler: LWFloatPlane.Sampler
    private let frame: LWSourceRetouchFrame?
    init(plane: LWFloatPlane, frame: LWSourceRetouchFrame?) { sampler=plane.sampler();self.frame=frame }
    func sample(_ source:CGPoint) throws -> SIMD4<Float> {
        guard source.x.isFinite,source.y.isFinite else { throw ProjectError.invalid }
        if let frame {
            guard let pixel=try frame.spatialMap.developedPointIfInBounds(source) else { return .zero }
            return try sampler.sample(pixel)
        }
        return try sampler.sample(source)
    }
}

nonisolated extension LWSourceRetouchFrame {
    init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:LWCatalogCodingKey.self)
        let required:Set<String>=["geometry","optics","width","height","layerTransform"]
        let actual=Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of:actual),actual.isSubset(of:required.union(["stages"])) else { throw ProjectError.invalid }
        geometry=try c.decode(LWSourceCoordinateMap.self,forKey:.init("geometry"));optics=try c.decode(CameraRawOpticsSettings.self,forKey:.init("optics"))
        width=try c.decode(Int.self,forKey:.init("width"));height=try c.decode(Int.self,forKey:.init("height"))
        layerTransform=try c.decode(LayerTransform.self,forKey:.init("layerTransform"))
        stages=try c.decodeIfPresent([LWSourcePixelStage].self,forKey:.init("stages")) ?? []
        metadataStorage=decoder.userInfo[LWSourceMetadataStorage.decoderKey] as? LWSourceMetadataStorage
        try validate()
    }
}

nonisolated extension LWSourceRetouchStroke {
    init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:LWCatalogCodingKey.self)
        let required:Set<String>=["sourceID","upstreamRevision","captureFrame","kind","seed","healMode","sampleAllLayers","aligned","blurRadius","radius","hardness","opacity","points","sourceOffset","color"]
        let actual=Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of:actual),actual.isSubset(of:required.union(["sampleAllLayersCompositeRevision","selectionSourceCoverage","selectionPlaneID","selectionFrame","sourceStart","pointsAreDabs"])) else { throw ProjectError.invalid }
        sourceID=try c.decode(UUID.self,forKey:.init("sourceID"))
        upstreamRevision=try c.decode(UUID.self,forKey:.init("upstreamRevision"))
        captureFrame=try c.decode(LWSourceRetouchFrame.self,forKey:.init("captureFrame"))
        kind=try c.decode(Kind.self,forKey:.init("kind"))
        seed=try c.decode(UInt32.self,forKey:.init("seed"))
        healMode=try c.decode(HealMode.self,forKey:.init("healMode"))
        sampleAllLayers=try c.decode(Bool.self,forKey:.init("sampleAllLayers"))
        aligned=try c.decode(Bool.self,forKey:.init("aligned"))
        blurRadius=try c.decode(Double.self,forKey:.init("blurRadius"))
        radius=try c.decode(Double.self,forKey:.init("radius"))
        hardness=try c.decode(Double.self,forKey:.init("hardness"))
        opacity=try c.decode(Double.self,forKey:.init("opacity"))
        points=try c.decode([CGPoint].self,forKey:.init("points"))
        sourceOffset=try c.decode(CGSize.self,forKey:.init("sourceOffset"))
        color=try c.decode([Float].self,forKey:.init("color"))
        sampleAllLayersCompositeRevision=try c.decodeIfPresent(UUID.self,forKey:.init("sampleAllLayersCompositeRevision"))
        selectionSourceCoverage=try c.decodeIfPresent(Data.self,forKey:.init("selectionSourceCoverage"))
        selectionPlaneID=try c.decodeIfPresent(UUID.self,forKey:.init("selectionPlaneID"))
        selectionFrame=try c.decodeIfPresent(LWSourceRetouchFrame.self,forKey:.init("selectionFrame"))
        sourceStart=try c.decodeIfPresent(CGPoint.self,forKey:.init("sourceStart"))
        pointsAreDabs=try c.decodeIfPresent(Bool.self,forKey:.init("pointsAreDabs")) ?? false
        try validate(source:sourceID)
    }
}


nonisolated extension LWSourceSampleComposite.Backing {
    init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:LWCatalogCodingKey.self)
        let required:Set<String>=["documentID","width","height","sourceLayerID","layers","images","masks"]
        let actual=Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of:actual),actual.isSubset(of:required.union(["imagePlanes","maskPlanes"])) else { throw ProjectError.invalid }
        documentID=try c.decode(UUID.self,forKey:.init("documentID"));width=try c.decode(Int.self,forKey:.init("width"))
        height=try c.decode(Int.self,forKey:.init("height"));sourceLayerID=try c.decode(UUID.self,forKey:.init("sourceLayerID"))
        layers=try c.decode([ProjectLayerRecord].self,forKey:.init("layers"))
        images=try c.decode([UUID:Data].self,forKey:.init("images"));masks=try c.decode([UUID:Data].self,forKey:.init("masks"))
        imagePlanes=try c.decodeIfPresent([UUID:UUID].self,forKey:.init("imagePlanes")) ?? [:]
        maskPlanes=try c.decodeIfPresent([UUID:UUID].self,forKey:.init("maskPlanes")) ?? [:]
        guard (1...DocumentLimits.maxSide).contains(width),(1...DocumentLimits.maxSide).contains(height),layers.count <= 10000,
            images.count <= layers.count,masks.count <= layers.count,imagePlanes.count <= layers.count,maskPlanes.count <= layers.count else { throw ProjectError.invalid }
    }
}

nonisolated extension LWSourceSampleComposite.Backing {
    func validate() throws {
        try LayerHierarchy.validate(layers);try LiveMaskGraph.validate(layers)
        guard layers.filter({$0.id==sourceLayerID}).count==1,
            images[sourceLayerID]==nil,imagePlanes[sourceLayerID]==nil,
            layers.allSatisfy({$0.liveSource==nil && $0.liveSourceFile==nil}),
            (1...DocumentLimits.maxSide).contains(width),(1...DocumentLimits.maxSide).contains(height) else { throw ProjectError.invalid }
        let imageIDs=Set(layers.filter { $0.imageFile != nil && $0.id != sourceLayerID }.map(\.id))
        let maskIDs=Set(layers.filter { $0.maskFile != nil }.map(\.id))
        guard Set(images.keys).isDisjoint(with:Set(imagePlanes.keys)),
            Set(masks.keys).isDisjoint(with:Set(maskPlanes.keys)),
            Set(images.keys).union(imagePlanes.keys) == imageIDs,
            Set(masks.keys).union(maskPlanes.keys) == maskIDs else { throw ProjectError.invalid }
        for record in layers where record.imageFile != nil && record.id != sourceLayerID {
            if let data=images[record.id] { _=try LWLinearSurface.packageExtent(data,maximumFileBytes:LWSourceDeveloper.maximumResultBytes) }
            else { guard imagePlanes[record.id] != nil else { throw ProjectError.missingImage } }
        }
        for record in layers where record.maskFile != nil {
            if let data=masks[record.id] { _=try LWLinearSurface.packageExtent(data,maximumFileBytes:LWSourceDeveloper.maximumResultBytes) }
            else { guard maskPlanes[record.id] != nil else { throw ProjectError.missingImage } }
        }
    }
}

nonisolated extension LWSourceSampleComposite {
    init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:LWCatalogCodingKey.self)
        guard Set(c.allKeys.map(\.stringValue)) == Set(["revision","sourceID","upstreamRevision","payload"]) else { throw ProjectError.invalid }
        revision=try c.decode(UUID.self,forKey:.init("revision"));sourceID=try c.decode(UUID.self,forKey:.init("sourceID"))
        upstreamRevision=try c.decode(UUID.self,forKey:.init("upstreamRevision"));payload=try c.decode(Data.self,forKey:.init("payload"))
        metadataStorage=decoder.userInfo[LWSourceMetadataStorage.decoderKey] as? LWSourceMetadataStorage
    }
}


/// Coverage stays in its recorded developed frame. A current output sample maps
/// through the immutable source into the selected development's own effective
/// geometry/optics before sampling. Partial coverage combines premultiplied color
/// and alpha; selected geometry never substitutes same-index source pixels.
nonisolated enum LWSourceSelectedDevelopmentBlend {
    static func apply(original: LWFloatPlane, adjusted: LWFloatPlane,
                      sourceCoverage: LWFloatPlane, currentMap: LWSourceSpatialMap,
                      adjustedMap:LWSourceSpatialMap?=nil,coverageFrame:LWSourceRetouchFrame?=nil,workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        guard original.workingSet === workspace.workingSet,
              adjusted.workingSet === workspace.workingSet,
              sourceCoverage.workingSet === workspace.workingSet,
              original.width == adjusted.width, original.height == adjusted.height,
              sourceCoverage.width == (coverageFrame?.developedWidth ?? currentMap.width),
              sourceCoverage.height == (coverageFrame?.developedHeight ?? currentMap.height) else { throw ProjectError.invalid }
        let selectedMap=adjustedMap ?? currentMap
        try selectedMap.validateStages();try coverageFrame?.validate()
        guard selectedMap.width==currentMap.width,selectedMap.height==currentMap.height else { throw ProjectError.invalid }
        let coverage = sourceCoverage.sampler(), pixels = adjusted.sampler()
        return try LWFloatCompositor.map(original, workspace: workspace) { old, x, y in
            try workspace.cancellation.check()
            guard let source = try currentMap.sourcePointIfInBounds(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)) else { return old }
            guard let selected=try selectedMap.developedPointIfInBounds(source) else { return old }
            let captured:CGPoint
            if let frame=coverageFrame {
                guard let value=try frame.spatialMap.developedPointIfInBounds(source) else { return old };captured=value
            } else { captured=source }
            let amount = try coverage.sample(captured).w
            guard amount > 0 else { return old }
            let new = try pixels.sample(selected)
            if amount == 1 { return new }
            let alpha = old.w * (1-amount) + new.w * amount
            guard alpha > 0 else { return .zero }
            return SIMD4((old.x*old.w*(1-amount)+new.x*new.w*amount)/alpha,
                         (old.y*old.w*(1-amount)+new.y*new.w*amount)/alpha,
                         (old.z*old.w*(1-amount)+new.z*new.w*amount)/alpha,alpha)
        }
    }
}

