import Foundation
import CoreGraphics

/// Persisted order is separate from edit history: upstream RAW development changes
/// replay this same ordered graph; automatic pixels remain explicit retained inputs.
nonisolated enum LWSourceOperation: Codable, Equatable, Sendable {
    case retouch(Int)
    case filter(UUID)
    case resample(UUID)
    case adjustment(UUID)
    /// A filter plugin's run (project format 14): the plugin, its code's hash and its parameter values.
    case plugin(UUID)
}
nonisolated struct LWSourceRetainedFilter: Codable, Equatable, Sendable {
    let id: UUID
    private(set) var sourceID: UUID
    func rebound(to source: UUID) -> Self { var copy = self; copy.sourceID = source; return copy }
    let upstreamRevision: UUID
    let kind: FilterKind
    let settings: FilterSettings
    let seed: UInt32
    let captureFrame: LWSourceRetouchFrame
    var selectionPlaneID: UUID?
    var selectionFrame: LWSourceRetouchFrame? = nil
    var retainedResultPlaneID: UUID?
    let pixelStage: LWSourcePixelStage
    var crop: LWFloatRange? = nil
    var spatialStages: [LWSourcePixelStage] {
        guard let crop else { return [pixelStage] }
        return [pixelStage,LWSourcePixelStage(inputWidth:pixelStage.outputWidth,inputHeight:pixelStage.outputHeight,
            outputWidth:crop.width,outputHeight:crop.height,offsetX:-crop.x,offsetY:-crop.y,distortion:0)]
    }
    var outputWidth: Int { crop?.width ?? pixelStage.outputWidth }
    var outputHeight: Int { crop?.height ?? pixelStage.outputHeight }
    func validate(source: UUID) throws {
        guard sourceID == source, settings == settings.normalized,
            kind != .cameraRaw else { throw ProjectError.invalid }
        try captureFrame.validate(); try pixelStage.validate()
        if let crop { _ = try crop.validate(frameWidth:pixelStage.outputWidth,frameHeight:pixelStage.outputHeight) }
        guard (selectionPlaneID == nil) == (selectionFrame == nil) else { throw ProjectError.invalid }
        try selectionFrame?.validate()
        guard pixelStage.inputWidth == captureFrame.developedWidth,
            pixelStage.inputHeight == captureFrame.developedHeight else { throw ProjectError.invalid }
        // An automatic operation has retained actual pixels. Never run a model or
        // synthesis during RAW recipe invalidation, preview, reopen, or export.
        guard kind.isAutomatic == (retainedResultPlaneID != nil) else { throw ProjectError.invalid }
    }
}
nonisolated extension LWLiveSourceNode {
    var orderedOperations: [LWSourceOperation] {
        operations.isEmpty && filters.isEmpty && resamples.isEmpty && adjustments.isEmpty && plugins.isEmpty ? retouch.indices.map(LWSourceOperation.retouch) : operations
    }
    /// Production validation/map/replay traverses compatibility order without
    /// constructing an unowned retouch-index projection array.
    func forEachOrderedOperation(_ body:(LWSourceOperation)throws->Void) throws {
        if operations.isEmpty && filters.isEmpty && resamples.isEmpty && adjustments.isEmpty && plugins.isEmpty {
            for index in retouch.indices { try body(.retouch(index)) }
        } else { for operation in operations { try body(operation) } }
    }
    /// The input plane already includes all preceding operations. Keep their
    /// spatial order as metadata, while the evaluator applies just this stroke.
    func previewingRetouch(_ stroke: LWSourceRetouchStroke) throws -> Self {
        try validateOperationOrder(); try stroke.validate(source:id)
        let count=try LWSourceMetadataStorage.sum(operations.count,1)
        var result=try metadataCopy(additionalBytes:LWSourceMetadataStorage.sum(stroke.retainedMetadataBytes,
            LWSourceMetadataStorage.collectionBytes(count:count,stride:MemoryLayout<LWSourceOperation>.stride)))
        result.retouch=[stroke];result.operations=[];result.operations.reserveCapacity(count)
        try forEachOrderedOperation { operation in
            if case .retouch = operation { return };result.operations.append(operation)
        }
        result.operations.append(.retouch(0))
        try result.validateOperationOrder()
        return result
    }
    func validateOperationOrder() throws {
        guard retouch.count <= 10000,filters.count <= 10000,resamples.count <= 10000,operations.count <= 20000,adjustments.count <= 10000,plugins.count <= 10000 else { throw ProjectError.invalid }
        let count=try LWSourceMetadataStorage.sum(plugins.count,LWSourceMetadataStorage.sum(retouch.count,LWSourceMetadataStorage.sum(filters.count,LWSourceMetadataStorage.sum(resamples.count,adjustments.count))))
        let allowance=try LWSourceMetadataStorage.collectionBytes(count:count,stride:MemoryLayout<LWSourceOperation>.stride+MemoryLayout<UUID>.stride+128)
        let charge=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.product(allowance,4),workingSet:metadataStorage?.workingSet ?? .sourceGraphs)
        defer { withExtendedLifetime(charge) {} }
        var filterIDs=Set<UUID>(),resampleIDs=Set<UUID>(),adjustmentIDs=Set<UUID>()
        for value in filters { guard filterIDs.insert(value.id).inserted else { throw ProjectError.invalid } }
        for value in resamples { guard resampleIDs.insert(value.id).inserted else { throw ProjectError.invalid } }
        for value in adjustments { guard adjustmentIDs.insert(value.id).inserted else { throw ProjectError.invalid } }
        var pluginIDs=Set<UUID>(),external=Set<UUID>()
        for value in plugins { guard pluginIDs.insert(value.id).inserted else { throw ProjectError.invalid } }
        var strokes = Set<Int>(), effects = Set<UUID>(), spatial = Set<UUID>(), tonal = Set<UUID>()
        try forEachOrderedOperation { operation in
            switch operation {
            case .retouch(let index):
                guard retouch.indices.contains(index), strokes.insert(index).inserted else { throw ProjectError.invalid }
            case .filter(let id):
                guard filters.contains(where: { $0.id == id }), effects.insert(id).inserted else { throw ProjectError.invalid }
            case .resample(let id):
                guard resamples.contains(where: { $0.id == id }), spatial.insert(id).inserted else { throw ProjectError.invalid }
            case .adjustment(let id):
                guard adjustments.contains(where:{$0.id == id}),tonal.insert(id).inserted else { throw ProjectError.invalid }
            case .plugin(let id):
                guard plugins.contains(where:{$0.id == id}),external.insert(id).inserted else { throw ProjectError.invalid }
            }
        }
        guard strokes.count == retouch.count,effects == filterIDs,spatial == resampleIDs,tonal == adjustmentIDs,external == pluginIDs else { throw ProjectError.invalid }
    }
    mutating func appendRetouch(_ stroke: LWSourceRetouchStroke) throws {
        try admitMetadataMutation(additionalBytes:LWSourceMetadataStorage.sum(stroke.retainedMetadataBytes,
            LWSourceMetadataStorage.sum(4096,LWSourceMetadataStorage.collectionBytes(count:retouch.count,stride:MemoryLayout<LWSourceOperation>.stride))))
        if operations.isEmpty && filters.isEmpty && resamples.isEmpty && adjustments.isEmpty && plugins.isEmpty { operations = retouch.indices.map(LWSourceOperation.retouch) }
        try stroke.validate(source: id)
        operations.append(.retouch(retouch.count)); retouch.append(stroke)
        try validateOperationOrder()
    }
    mutating func appendFilter(_ filter: LWSourceRetainedFilter) throws {
        try admitMetadataMutation(additionalBytes:LWSourceMetadataStorage.sum(filter.retainedMetadataBytes,
            LWSourceMetadataStorage.sum(4096,LWSourceMetadataStorage.collectionBytes(count:retouch.count,stride:MemoryLayout<LWSourceOperation>.stride))))
        if operations.isEmpty && filters.isEmpty && resamples.isEmpty && adjustments.isEmpty && plugins.isEmpty { operations = retouch.indices.map(LWSourceOperation.retouch) }
        try filter.validate(source: id)
        filters.append(filter); operations.append(.filter(filter.id))
        try validateOperationOrder()
    }
}
nonisolated enum LWSourceOperationReplay {
    static func evaluate(_ node: LWLiveSourceNode, developed: LWFloatPlane,
        map inputMap: LWSourceSpatialMap, workspace: LWFloatWorkspace) throws -> (surface: LWFloatPlane, map: LWSourceSpatialMap) {
        try node.validateOperationOrder()
        let replayCount=try LWSourceMetadataStorage.sum(node.plugins.count,LWSourceMetadataStorage.sum(node.retouch.count,LWSourceMetadataStorage.sum(node.filters.count,LWSourceMetadataStorage.sum(node.resamples.count,node.adjustments.count))))
        let replayOwner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.sum(4096,
            LWSourceMetadataStorage.collectionBytes(count:replayCount,
                stride:MemoryLayout<LWSourceRetainedFilter>.stride+MemoryLayout<LWSourceResample>.stride+MemoryLayout<LWSourceOperation>.stride+MemoryLayout<LWSourcePixelStage>.stride+MemoryLayout<LWSourceRetainedAdjustment>.stride+MemoryLayout<LWSourceRetainedPlugin>.stride)),
            workingSet:workspace.workingSet,payloadOwners:inputMap.metadataStorage.map { [$0] } ?? [])
        var result = developed, map = inputMap
        map.metadataStorage=replayOwner
        var precedingFilters: [LWSourceRetainedFilter] = []
        var precedingResamples: [LWSourceResample] = [], precedingAdjustments:[LWSourceRetainedAdjustment]=[], precedingOperations: [LWSourceOperation] = []
        var precedingPlugins:[LWSourceRetainedPlugin]=[]
        try node.forEachOrderedOperation { operation in
            try workspace.cancellation.check(); try Task.checkCancellation()
            let next: LWFloatPlane
            switch operation {
            case .retouch(let index):
                // The evaluator receives the immediately-prior immutable plane.
                // Other operations and old output planes are never sample sources.
                var step = try node.metadataCopy(additionalBytes:4096)
                step.retouch = [node.retouch[index]]; step.filters = precedingFilters; step.resamples = precedingResamples;step.adjustments=precedingAdjustments
                step.plugins=precedingPlugins
                step.operations = precedingOperations + [.retouch(0)]
                next = try LWSourceRetouch.evaluate(step, developed: result, map: map, workspace: workspace)
            case .filter(let id):
                guard let filter = node.filters.first(where: { $0.id == id }) else { throw ProjectError.invalid }
                next = try LWFloatFilter.apply(filter, node: node, plane: result, map: map, workspace: workspace)
                map.stages.append(contentsOf:filter.spatialStages); try map.validateStages()
                precedingFilters.append(filter); precedingOperations.append(operation)
            case .adjustment(let id):
                guard let adjustment=node.adjustments.first(where:{$0.id == id}) else { throw ProjectError.invalid }
                next=try LWSourceRetainedAdjustment.apply(adjustment,node:node,plane:result,map:map,workspace:workspace)
                precedingAdjustments.append(adjustment);precedingOperations.append(operation)
            case .plugin(let id):
                // The plugin installed now must be the code that made the step: anything else throws with the
                // reason, and the caller keeps the pixels it had.
                guard let step=node.plugins.first(where:{$0.id == id}) else { throw ProjectError.invalid }
                next=try LWSourceRetainedPlugin.apply(step,node:node,plane:result,map:map,workspace:workspace)
                precedingPlugins.append(step);precedingOperations.append(operation)
            case .resample(let id):
                guard let operation = node.resamples.first(where: { $0.id == id }) else { throw ProjectError.invalid }
                try operation.validate(source: node.id)
                next = try LWSourceResample.apply(operation, plane: result, workspace: workspace)
                map.stages.append(operation.stage); try map.validateStages()
                precedingResamples.append(operation); precedingOperations.append(.resample(id))
            }
            var old: LWFloatPlane? = result
            result = next
            // Same-plane identity results still retain the old backing and refuse
            // retirement. External retained references also prevent removal.
            _ = try workspace.retireOwnedPlane(&old)
            old = nil
            try workspace.retireReleasedGenerations()
        }
        return (result, map)
    }
}

/// Each output grid records its exact relation to the preceding developed grid.
/// Translation is padding; distortion is the retained Lens Correction radial map.
nonisolated struct LWSourcePixelStage: Codable, Equatable, Sendable {
    let inputWidth: Int
    let inputHeight: Int
    let outputWidth: Int
    let outputHeight: Int
    let offsetX: Int
    let offsetY: Int
    let distortion: Double
    var homography: LWSourceCoordinateMap? = nil
    func validate() throws {
        try LWFloatPlane.validateExtent(width:inputWidth,height:inputHeight)
        try LWFloatPlane.validateExtent(width:outputWidth,height:outputHeight)
        if let homography {
            guard offsetX == 0, offsetY == 0, distortion == 0,
                homography.values[6] == 0, homography.values[7] == 0, homography.values[8] == 1 else { throw ProjectError.invalid }
            _ = try homography.inverse(); return
        }
        let right=offsetX.addingReportingOverflow(inputWidth),bottom=offsetY.addingReportingOverflow(inputHeight)
        // One stage is either padding or an exact contained crop, never an
        // arbitrary reinterpretation of dimensions or an overflowed offset.
        let pads = offsetX >= 0 && offsetY >= 0 && right.partialValue <= outputWidth && bottom.partialValue <= outputHeight
        let crops = offsetX <= 0 && offsetY <= 0 && offsetX >= -inputWidth && offsetY >= -inputHeight &&
            outputWidth <= right.partialValue && outputHeight <= bottom.partialValue && distortion == 0
        guard !right.overflow,!bottom.overflow,(pads || crops),
            distortion.isFinite,(-100...100).contains(distortion) else { throw ProjectError.invalid }
    }
    var optics: CameraRawOpticsSettings {
        var value=CameraRawOpticsSettings();value.distortion=distortion;return value
    }
    func sourcePoint(_ output:CGPoint) throws -> CGPoint {
        try validate()
        if let homography { return try homography.inverse().map(output) }
        let point=CGPoint(x:output.x-CGFloat(offsetX),y:output.y-CGFloat(offsetY))
        return distortion == 0 ? point:try LWSourceSpatialMap(geometry:.identity,optics:optics,width:inputWidth,height:inputHeight).sourcePoint(point)
    }
    func developedPoint(_ input:CGPoint) throws -> CGPoint {
        try validate()
        if let homography { return try homography.map(input) }
        let point=distortion == 0 ? input:try LWSourceSpatialMap(geometry:.identity,optics:optics,width:inputWidth,height:inputHeight).developedPoint(input)
        return CGPoint(x:point.x+CGFloat(offsetX),y:point.y+CGFloat(offsetY))
    }
    func developedPointIfInBounds(_ input:CGPoint) throws -> CGPoint? {
        try validate()
        if let homography {
            let result = try homography.map(input)
            return result.x >= 0 && result.y >= 0 && result.x < CGFloat(outputWidth) && result.y < CGFloat(outputHeight) ? result : nil
        }
        if distortion == 0 {
            guard input.x.isFinite,input.y.isFinite else { throw ProjectError.invalid }
            let result=CGPoint(x:input.x+CGFloat(offsetX),y:input.y+CGFloat(offsetY))
            return result.x >= 0 && result.y >= 0 && result.x < CGFloat(outputWidth) && result.y < CGFloat(outputHeight) ? result:nil
        }
        let identity=LWSourceSpatialMap(geometry:.identity,optics:optics,width:inputWidth,height:inputHeight)
        let point=try identity.developedPoint(input)
        let result=CGPoint(x:point.x+CGFloat(offsetX),y:point.y+CGFloat(offsetY))
        return result.x >= 0 && result.y >= 0 && result.x < CGFloat(outputWidth) && result.y < CGFloat(outputHeight) ? result:nil
    }
}
nonisolated extension LWLiveSourceNode {
    var currentSpatialMap: LWSourceSpatialMap {
        get throws {
            try validateOperationOrder()
            var count=0,bytes=try LWSourceMetadataStorage.collectionBytes(count:coordinateMap.values.count,stride:MemoryLayout<Double>.stride)
            try forEachOrderedOperation { operation in
                switch operation {
                case .filter(let id):
                    guard let value=filters.first(where:{$0.id==id}) else { throw ProjectError.invalid }
                    // Each filter exposes at most its pixel stage and optional crop.
                    count=try LWSourceMetadataStorage.sum(count,value.crop == nil ? 1:2)
                    bytes=try LWSourceMetadataStorage.sum(bytes,value.pixelStage.retainedMetadataBytes)
                case .resample(let id):
                    guard let value=resamples.first(where:{$0.id==id}) else { throw ProjectError.invalid }
                    count=try LWSourceMetadataStorage.sum(count,1);bytes=try LWSourceMetadataStorage.sum(bytes,value.stage.retainedMetadataBytes)
                case .retouch,.adjustment,.plugin: break
                }
            }
            guard count <= 20000 else { throw ProjectError.invalid }
            bytes=try LWSourceMetadataStorage.sum(bytes,LWSourceMetadataStorage.collectionBytes(count:count,stride:MemoryLayout<LWSourcePixelStage>.stride))
            let owner=try LWSourceMetadataStorage(bytes:bytes,workingSet:metadataStorage?.workingSet ?? .sourceGraphs)
            var stages:[LWSourcePixelStage]=[];stages.reserveCapacity(count)
            try forEachOrderedOperation { operation in
                switch operation {
                case .filter(let id): guard let value=filters.first(where:{$0.id==id}) else { throw ProjectError.invalid };stages.append(contentsOf:value.spatialStages)
                case .resample(let id): guard let value=resamples.first(where:{$0.id==id}) else { throw ProjectError.invalid };stages.append(value.stage)
                case .retouch,.adjustment,.plugin: break
                }
            }
            let result=LWSourceSpatialMap(geometry:coordinateMap,optics:settings.optics,width:originalWidth,height:originalHeight,stages:stages,metadataStorage:owner)
            try result.validateStages();return result
        }
    }
    func capturedFrame(transform:LayerTransform) throws -> LWSourceRetouchFrame {
        let map=try currentSpatialMap
        return LWSourceRetouchFrame(geometry:coordinateMap,optics:settings.optics,width:originalWidth,height:originalHeight,
            layerTransform:transform,stages:map.stages,metadataStorage:map.metadataStorage)
    }
}


nonisolated extension LWSourceRetainedFilter {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let required: Set<String> = ["id","sourceID","upstreamRevision","kind","settings","seed","captureFrame","pixelStage"]
        let actual = Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of: actual), actual.isSubset(of: required.union(["selectionPlaneID","selectionFrame","retainedResultPlaneID","crop"])) else { throw ProjectError.invalid }
        id = try c.decode(UUID.self, forKey: .init("id")); sourceID = try c.decode(UUID.self, forKey: .init("sourceID"))
        upstreamRevision = try c.decode(UUID.self, forKey: .init("upstreamRevision"))
        kind = try c.decode(FilterKind.self, forKey: .init("kind")); settings = try c.decode(FilterSettings.self, forKey: .init("settings"))
        seed = try c.decode(UInt32.self, forKey: .init("seed")); captureFrame = try c.decode(LWSourceRetouchFrame.self, forKey: .init("captureFrame"))
        selectionPlaneID = try c.decodeIfPresent(UUID.self, forKey: .init("selectionPlaneID"))
        selectionFrame = try c.decodeIfPresent(LWSourceRetouchFrame.self, forKey: .init("selectionFrame"))
        retainedResultPlaneID = try c.decodeIfPresent(UUID.self, forKey: .init("retainedResultPlaneID"))
        pixelStage = try c.decode(LWSourcePixelStage.self, forKey: .init("pixelStage"))
        crop = try c.decodeIfPresent(LWFloatRange.self, forKey:.init("crop")); try validate(source: sourceID)
    }
}
nonisolated extension LWSourcePixelStage {
    init(from decoder: any Decoder) throws {
        let c = try decoder.container(keyedBy: LWCatalogCodingKey.self)
        let required: Set<String> = ["inputWidth","inputHeight","outputWidth","outputHeight","offsetX","offsetY","distortion"]
        let keys = Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of: keys), keys.isSubset(of: required.union(["homography"])) else { throw ProjectError.invalid }
        inputWidth = try c.decode(Int.self, forKey: .init("inputWidth")); inputHeight = try c.decode(Int.self, forKey: .init("inputHeight"))
        outputWidth = try c.decode(Int.self, forKey: .init("outputWidth")); outputHeight = try c.decode(Int.self, forKey: .init("outputHeight"))
        offsetX = try c.decode(Int.self, forKey: .init("offsetX")); offsetY = try c.decode(Int.self, forKey: .init("offsetY"))
        distortion = try c.decode(Double.self, forKey: .init("distortion"))
        homography = try c.decodeIfPresent(LWSourceCoordinateMap.self, forKey: .init("homography")); try validate()
    }
}


/// Ordered document resize, retaining source authority and its exact affine
/// relation. It is distinct from Camera Raw geometry and destructive filters.
nonisolated struct LWSourceResample: Codable, Equatable, Sendable {
    let id: UUID
    private(set) var sourceID: UUID
    func rebound(to source: UUID) -> Self { var copy = self; copy.sourceID = source; return copy }
    let upstreamRevision: UUID
    let stage: LWSourcePixelStage
    let sampling: LayerSampling
    func validate(source: UUID) throws {
        guard sourceID == source, stage.homography != nil else { throw ProjectError.invalid }
        try stage.validate()
    }
    static func apply(_ operation: Self, plane: LWFloatPlane, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        let stage = operation.stage
        guard plane.width == stage.inputWidth, plane.height == stage.inputHeight, let h = stage.homography else { throw ProjectError.invalid }
        try stage.validate()
        let v = h.values, affine = CGAffineTransform(a:v[0],b:v[3],c:v[1],d:v[4],tx:v[2],ty:v[5])
        return try LWFloatCompositor.project(plane,mapping:affine,width:stage.outputWidth,height:stage.outputHeight,
            workspace:workspace,sampling:operation.sampling)
    }
}
nonisolated extension LWLiveSourceNode {
    mutating func appendResample(_ operation: LWSourceResample) throws {
        try admitMetadataMutation(additionalBytes:LWSourceMetadataStorage.sum(operation.stage.retainedMetadataBytes,
            LWSourceMetadataStorage.sum(4096,LWSourceMetadataStorage.collectionBytes(count:retouch.count,stride:MemoryLayout<LWSourceOperation>.stride))))
        if operations.isEmpty && filters.isEmpty && resamples.isEmpty && adjustments.isEmpty && plugins.isEmpty { operations = retouch.indices.map(LWSourceOperation.retouch) }
        try operation.validate(source:id)
        resamples.append(operation); operations.append(.resample(operation.id)); try validateOperationOrder()
    }
}

nonisolated extension LWSourceResample {
    init(from decoder: any Decoder) throws {
        let c=try decoder.container(keyedBy:LWCatalogCodingKey.self)
        guard Set(c.allKeys.map(\.stringValue)) == ["id","sourceID","upstreamRevision","stage","sampling"] else { throw ProjectError.invalid }
        id=try c.decode(UUID.self,forKey:.init("id"));sourceID=try c.decode(UUID.self,forKey:.init("sourceID"))
        upstreamRevision=try c.decode(UUID.self,forKey:.init("upstreamRevision"))
        stage=try c.decode(LWSourcePixelStage.self,forKey:.init("stage"));sampling=try c.decode(LayerSampling.self,forKey:.init("sampling"))
        try validate(source:sourceID)
    }
}
