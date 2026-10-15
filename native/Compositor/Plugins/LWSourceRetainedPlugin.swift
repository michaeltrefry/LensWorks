import CoreGraphics
import Foundation

/// A filter plugin's run on a live RAW source, retained in the source's ordered operations (project format 14):
/// which plugin, the SHA-256 of the module that ran, the filter interface it ran under and the parameter values it
/// was given. Developing the RAW again runs the same step again on the new development — and only with the code
/// that made it: if that plugin is no longer installed, or the installed module's hash is not the recorded one, the
/// development fails with the reason and the layer keeps the pixels and the source it had.
nonisolated struct LWSourceRetainedPlugin: Codable, Equatable, Sendable {
    let id: UUID
    let sourceID: UUID
    let upstreamRevision: UUID
    /// The plugin's id, and the name its manifest gave when the step was recorded (for messages and the list).
    let plugin: String
    let name: String
    /// SHA-256 of the `filter.wasm` that ran, as the installed store records it.
    let moduleHash: String
    let interface: Int
    /// The values the plugin's `param(index)` answered, in its manifest's order.
    let parameters: [Double]
    let captureFrame: LWSourceRetouchFrame
    let selectionPlaneID: UUID?

    /// The history entry of the edit that removes or re-runs this step, and how it is listed.
    var title: String { "Plugin: " + name }

    func validate(source: UUID) throws {
        guard sourceID == source, LensWorksPluginManifest.isIdentifier(plugin), LensWorksPluginManifest.isDisplayText(name),
              moduleHash.utf8.count == 64, moduleHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
              interface >= 1, interface <= Int(Int32.max), parameters.count <= Int(LensWorksPluginSandbox.limits.parameters),
              parameters.allSatisfy(\.isFinite) else { throw ProjectError.invalid }
        try captureFrame.validate()
    }
    var retainedMetadataBytes: Int {
        var bytes = MemoryLayout<Self>.stride
        for value in [captureFrame.retainedMetadataBytes, plugin.utf8.count, name.utf8.count, moduleHash.utf8.count,
                      (try? LWSourceMetadataStorage.collectionBytes(count: parameters.count, stride: MemoryLayout<Double>.stride)) ?? Int.max] {
            bytes = (try? LWSourceMetadataStorage.sum(bytes, value)) ?? Int.max
        }
        return bytes
    }
    init(id: UUID, sourceID: UUID, upstreamRevision: UUID, plugin: String, name: String, moduleHash: String, interface: Int,
         parameters: [Double], captureFrame: LWSourceRetouchFrame, selectionPlaneID: UUID?) {
        self.id = id; self.sourceID = sourceID; self.upstreamRevision = upstreamRevision; self.plugin = plugin; self.name = name
        self.moduleHash = moduleHash; self.interface = interface; self.parameters = parameters
        self.captureFrame = captureFrame; self.selectionPlaneID = selectionPlaneID
    }
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let required: Set<String> = ["id", "sourceID", "upstreamRevision", "plugin", "name", "moduleHash", "interface", "parameters", "captureFrame"]
        let keys = Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(["selectionPlaneID"])) else { throw ProjectError.invalid }
        id = try c.decode(UUID.self, forKey: .init("id")); sourceID = try c.decode(UUID.self, forKey: .init("sourceID"))
        upstreamRevision = try c.decode(UUID.self, forKey: .init("upstreamRevision"))
        plugin = try c.decode(String.self, forKey: .init("plugin")); name = try c.decode(String.self, forKey: .init("name"))
        moduleHash = try c.decode(String.self, forKey: .init("moduleHash")); interface = try c.decode(Int.self, forKey: .init("interface"))
        parameters = try c.decode([Double].self, forKey: .init("parameters"))
        captureFrame = try c.decode(LWSourceRetouchFrame.self, forKey: .init("captureFrame"))
        selectionPlaneID = try c.decodeIfPresent(UUID.self, forKey: .init("selectionPlaneID"))
        try validate(source: sourceID)
    }

    /// The step re-bound to the plugin as it is installed now: the same place in the order, the same selection,
    /// the installed module's hash and interface, and `parameters`.
    func rebound(to installed: LensWorksPluginStore.Installed, parameters: [Double]) -> Self {
        Self(id: id, sourceID: sourceID, upstreamRevision: upstreamRevision, plugin: plugin, name: installed.manifest.name,
             moduleHash: installed.moduleHash, interface: installed.manifest.interface, parameters: parameters,
             captureFrame: captureFrame, selectionPlaneID: selectionPlaneID)
    }

    /// Runs `module` over `plane` under this step's parameters and lays the result over `plane` through the
    /// step's selection. Thrown errors are the sandbox's own; nothing is written to `plane`.
    func run(module: Data, node: LWLiveSourceNode, plane: LWFloatPlane, map: LWSourceSpatialMap, workspace: LWFloatWorkspace,
             runFuel: UInt64 = LensWorksPluginSandbox.limits.fuel_run, progress: @Sendable (Double) -> Void = { _ in }) throws -> LWFloatPlane {
        try validate(source: node.id)
        guard node.sourceLineage.contains(upstreamRevision), plane.workingSet === workspace.workingSet,
              plane.width == map.developedWidth, plane.height == map.developedHeight else { throw ProjectError.invalid }
        let sandbox = try LensWorksPluginSandbox(wasm: module, parameters: parameters, runFuel: runFuel)
        let changed = try LensWorksPluginRunner.filtered(plane, sandbox: sandbox, workspace: workspace,
                                                         check: { try workspace.cancellation.check(); try Task.checkCancellation() }, progress: progress)
        return try LWSourceRetainedAdjustment.blend(changed, over: plane, selectionPlaneID: selectionPlaneID, captureFrame: captureFrame,
                                                    node: node, map: map, workspace: workspace)
    }

    /// The step applied again while its source is developed: the installed plugin must be the code that made it.
    static func apply(_ step: Self, node: LWLiveSourceNode, plane: LWFloatPlane, map: LWSourceSpatialMap, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let module = try LensWorksRetainedPlugins.module(for: step)
        do { return try step.run(module: module, node: node, plane: plane, map: map, workspace: workspace) }
        catch let failure as LensWorksPluginFailure { throw LWSourceRetainedPluginProblem(step, .failed(failure.reason)) }
    }
}

/// Why a retained plugin step could not be applied again. The layer it is on keeps its source and its pixels; the
/// person re-runs the step with the plugin installed now, or removes it (Filter › Plugins › Retained Plugin Steps…).
nonisolated struct LWSourceRetainedPluginProblem: LocalizedError, Equatable, Sendable {
    enum Kind: Equatable, Sendable {
        case notInstalled
        case damaged(String)
        case changed(installed: String)
        case interface
        case failed(String)
    }
    let step: UUID
    let plugin: String
    let name: String
    let recordedHash: String
    let recordedInterface: Int
    let kind: Kind
    init(_ step: LWSourceRetainedPlugin, _ kind: Kind) {
        self.step = step.id; plugin = step.plugin; name = step.name; recordedHash = step.moduleHash; recordedInterface = step.interface; self.kind = kind
    }
    /// What is wrong, without what to do about it.
    var reason: String {
        switch kind {
        case .notInstalled: "The plugin is not installed."
        case .damaged(let problem): "The plugin cannot run. " + problem
        case .changed(let installed):
            "The installed plugin is not the code that made this step: its module’s SHA-256 is \(installed), and the step recorded \(recordedHash)."
        case .interface: "The step was recorded with filter interface \(recordedInterface), and this LensWorks provides \(LensWorksPluginSandbox.limits.interface_version)."
        case .failed(let message): "The plugin failed. " + message
        }
    }
    /// What the person (or an agent, by the step's id) does about it.
    var remedy: String {
        "Choose Filter › Plugins › Retained Plugin Steps… to re-run the step with the plugin installed now, or to remove it (an agent: plugin.step.rerun or plugin.step.remove with step \(step.uuidString))."
    }
    var errorDescription: String? {
        "The retained plugin step \(name) (\(plugin)) on this layer could not be applied again, so the layer was not changed. \(reason) \(remedy)"
    }
}

/// Where a development finds the plugins its retained steps name: the person's installed plugins, or the store of
/// the session that started the work.
nonisolated enum LensWorksRetainedPlugins {
    @TaskLocal static var directory: URL = LensWorksPluginStore.sharedDirectory

    /// The module that made `step`, read from the installed copy and held to the step's recorded hash.
    static func module(for step: LWSourceRetainedPlugin) throws -> Data {
        try check(step, installed: installed(step.plugin)).module
    }
    /// What is installed under a step's plugin id, or why nothing usable is.
    static func installed(_ plugin: String) -> Result<(plugin: LensWorksPluginStore.Installed, module: Data), LensWorksPluginFailure>? {
        let location = LensWorksPluginFiles.folder(directory, plugin)
        guard LensWorksPluginManifest.isIdentifier(plugin), FileManager.default.fileExists(atPath: location.path) else { return nil }
        do { return .success(try LensWorksPluginFiles.installed(directory, plugin)) }
        catch { return .failure(LensWorksPluginFailure(error.localizedDescription)) }
    }
    /// Holds what is installed to what the step recorded.
    static func check(_ step: LWSourceRetainedPlugin, installed: Result<(plugin: LensWorksPluginStore.Installed, module: Data), LensWorksPluginFailure>?) throws
        -> (plugin: LensWorksPluginStore.Installed, module: Data) {
        guard let installed else { throw LWSourceRetainedPluginProblem(step, .notInstalled) }
        switch installed {
        case .failure(let failure): throw LWSourceRetainedPluginProblem(step, .damaged(failure.reason))
        case .success(let found):
            guard step.interface == Int(LensWorksPluginSandbox.limits.interface_version) else { throw LWSourceRetainedPluginProblem(step, .interface) }
            guard found.plugin.moduleHash == step.moduleHash else { throw LWSourceRetainedPluginProblem(step, .changed(installed: found.plugin.moduleHash)) }
            return found
        }
    }
    /// The state of `step` against what is installed now: nil when it can be applied again as recorded.
    static func problem(_ step: LWSourceRetainedPlugin) -> LWSourceRetainedPluginProblem? {
        do { _ = try check(step, installed: installed(step.plugin)); return nil }
        catch let problem as LWSourceRetainedPluginProblem { return problem }
        catch { return LWSourceRetainedPluginProblem(step, .damaged(error.localizedDescription)) }
    }
}

nonisolated extension LWLiveSourceNode {
    mutating func appendPlugin(_ value: LWSourceRetainedPlugin) throws {
        try admitMetadataMutation(additionalBytes: LWSourceMetadataStorage.sum(value.retainedMetadataBytes,
            LWSourceMetadataStorage.sum(4096, LWSourceMetadataStorage.collectionBytes(count: retouch.count, stride: MemoryLayout<LWSourceOperation>.stride))))
        if operations.isEmpty && filters.isEmpty && resamples.isEmpty && adjustments.isEmpty && plugins.isEmpty { operations = retouch.indices.map(LWSourceOperation.retouch) }
        try value.validate(source: id)
        plugins.append(value); operations.append(.plugin(value.id)); try validateOperationOrder()
    }
    /// This source without the retained plugin step `step`, as a new revision of it.
    func removingPlugin(_ step: UUID) throws -> Self {
        guard let removed = plugins.first(where: { $0.id == step }) else { throw ProjectError.invalid }
        var node = try metadataCopy(additionalBytes: 4096)
        node.plugins.removeAll { $0.id == step }
        node.operations.removeAll { $0 == .plugin(step) }
        // The step's selection goes with it, unless something else on the source still uses that plane.
        if let key = removed.selectionPlaneID, !node.plugins.contains(where: { $0.selectionPlaneID == key }),
           !node.adjustments.contains(where: { $0.selectionPlaneID == key }), !node.filters.contains(where: { $0.selectionPlaneID == key || $0.retainedResultPlaneID == key }),
           !node.retouch.contains(where: { $0.selectionPlaneID == key }), !node.selectedDevelopments.contains(where: { $0.sourceCoveragePlaneID == key }) {
            node.planeAssets[key] = nil
        }
        node.revision = UUID(); node.sourceLineage.append(node.revision)
        try node.validate(); return node
    }
    /// This source with the retained plugin step `step` replaced by `replacement`, as a new revision of it.
    func replacingPlugin(_ replacement: LWSourceRetainedPlugin) throws -> Self {
        guard let index = plugins.firstIndex(where: { $0.id == replacement.id }) else { throw ProjectError.invalid }
        var node = try metadataCopy(additionalBytes: LWSourceMetadataStorage.sum(4096, replacement.retainedMetadataBytes))
        node.plugins[index] = replacement
        node.revision = UUID(); node.sourceLineage.append(node.revision)
        try node.validate(); return node
    }
}

/// A plugin run on a live source, made the way a development will make it again: the step is recorded and applied
/// by the same function a later development calls.
nonisolated enum LWSourcePluginPreparation {
    struct Result: Sendable { let node: LWLiveSourceNode; let plane: LWFloatPlane }
    static func prepare(_ source: LWLiveSourceNode, before: LWFloatPlane, map: LWSourceSpatialMap, plugin: LensWorksPluginStore.Installed, module: Data,
                        parameters: [Double], selection: SelectionClip?, transform: LayerTransform, workspace: LWFloatWorkspace,
                        runFuel: UInt64 = LensWorksPluginSandbox.limits.fuel_run, progress: @Sendable (Double) -> Void = { _ in }) throws -> Result {
        try source.validate(); try workspace.cancellation.check()
        guard transform.isValid, plugin.manifest.admits(parameters), LensWorksPluginManifest.sha256(module) == plugin.moduleHash else { throw ProjectError.invalid }
        let frame = try source.capturedFrame(transform: transform)
        let coverage = try LWSourceSelectionPlane.capture(selection, mapping: BrushRaster.pixelToDocument(transform, width: before.width, height: before.height),
                                                          width: before.width, height: before.height, workspace: workspace)
        var node = try source.metadataCopy(additionalBytes: 16 * 1024)
        let key = coverage.map { _ in UUID() }
        if let key, let coverage { node.planeAssets[key] = try LWSourcePlaneAsset(coverage) }
        let step = LWSourceRetainedPlugin(id: UUID(), sourceID: source.id, upstreamRevision: source.revision, plugin: plugin.id, name: plugin.manifest.name,
                                          moduleHash: plugin.moduleHash, interface: plugin.manifest.interface, parameters: parameters,
                                          captureFrame: frame, selectionPlaneID: key)
        let plane = try step.run(module: module, node: node, plane: before, map: map, workspace: workspace, runFuel: runFuel, progress: progress)
        node.revision = UUID(); node.sourceLineage.append(node.revision); try node.appendPlugin(step)
        try node.validate(); try workspace.cancellation.check()
        return Result(node: node, plane: plane)
    }
}
