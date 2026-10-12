import AppKit

/// Whole-image adjustment dialogs retain ordered float operations beneath layers.
/// FilterKind stays the existing public seventeen-kind menu contract.
nonisolated struct LWSourceRetainedAdjustment: Codable, Equatable, Sendable {
    let id:UUID
    let sourceID:UUID
    let upstreamRevision:UUID
    let settings:LayerAdjustment
    let captureFrame:LWSourceRetouchFrame
    let selectionPlaneID:UUID?
    func validate(source:UUID) throws {
        guard sourceID == source,settings.isValid,settings.kind == .hsv || settings.kind == .levels else { throw ProjectError.invalid }
        try captureFrame.validate()
    }
    var retainedMetadataBytes:Int {
        var bytes=MemoryLayout<Self>.stride
        for value in [captureFrame.retainedMetadataBytes,
            (try? LWSourceMetadataStorage.collectionBytes(count:settings.resolvedHSV.adjustments.count,stride:MemoryLayout<ColorRange>.stride+MemoryLayout<RangeAdjustment>.stride+128)) ?? Int.max,
            (try? LWSourceMetadataStorage.collectionBytes(count:settings.resolvedHSV.bands.count,stride:MemoryLayout<ColorRange>.stride+MemoryLayout<HueBand>.stride+128)) ?? Int.max,
            (try? LWSourceMetadataStorage.collectionBytes(count:settings.levels.ranges.count,stride:MemoryLayout<LevelRange>.stride)) ?? Int.max] {
            bytes=(try? LWSourceMetadataStorage.sum(bytes,value)) ?? Int.max
        }
        return bytes
    }
    init(id:UUID,sourceID:UUID,upstreamRevision:UUID,settings:LayerAdjustment,captureFrame:LWSourceRetouchFrame,selectionPlaneID:UUID?) {
        self.id=id;self.sourceID=sourceID;self.upstreamRevision=upstreamRevision;self.settings=settings
        self.captureFrame=captureFrame;self.selectionPlaneID=selectionPlaneID
    }
    init(from decoder:any Decoder) throws {
        let c=try decoder.container(keyedBy:LWCatalogCodingKey.self)
        let required:Set<String>=["id","sourceID","upstreamRevision","settings","captureFrame"]
        let keys=Set(c.allKeys.map(\.stringValue))
        guard required.isSubset(of:keys),keys.isSubset(of:required.union(["selectionPlaneID"])) else { throw ProjectError.invalid }
        id=try c.decode(UUID.self,forKey:.init("id"));sourceID=try c.decode(UUID.self,forKey:.init("sourceID"))
        upstreamRevision=try c.decode(UUID.self,forKey:.init("upstreamRevision"));settings=try c.decode(LayerAdjustment.self,forKey:.init("settings"))
        captureFrame=try c.decode(LWSourceRetouchFrame.self,forKey:.init("captureFrame"));selectionPlaneID=try c.decodeIfPresent(UUID.self,forKey:.init("selectionPlaneID"))
        try validate(source:sourceID)
    }
    static func apply(_ operation:Self,node:LWLiveSourceNode,plane:LWFloatPlane,map:LWSourceSpatialMap,
        workspace:LWFloatWorkspace) throws -> LWFloatPlane {
        try operation.validate(source:node.id)
        guard node.sourceLineage.contains(operation.upstreamRevision),plane.workingSet === workspace.workingSet,
            plane.width == map.developedWidth,plane.height == map.developedHeight else { throw ProjectError.invalid }
        let changed=try operation.settings.apply(plane,makeBuilder:{ try workspace.makeBuilder(width:$0,height:$1) },
            makeScratchDirectory:{ try workspace.makeScratchDirectory() },fileOwner:workspace)
        guard let key=operation.selectionPlaneID else { return changed }
        guard let asset=node.planeAssets[key],let mask=asset.plane,mask.workingSet === workspace.workingSet,
            mask.width == operation.captureFrame.developedWidth,mask.height == operation.captureFrame.developedHeight else { throw ProjectError.invalid }
        let coverage=mask.sampler(),pixels=changed.sampler()
        return try LWFloatCompositor.map(plane,workspace:workspace) { old,x,y in
            try workspace.cancellation.check()
            guard let source=try map.sourcePointIfInBounds(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),
                let document=try operation.captureFrame.documentPointIfInBounds(source) else { return old }
            let captured=try operation.captureFrame.documentToDevelopedPixel(document)
            let amount=try coverage.sample(captured).w
            guard amount.isFinite,(0...1).contains(amount) else { throw ProjectError.invalid }
            let new=try pixels.pixel(x:x,y:y)
            if amount == 0 { return old };if amount == 1 { return new }
            let alpha=old.w*(1-amount)+new.w*amount
            guard alpha > 0 else { return .zero }
            return SIMD4((old.x*old.w*(1-amount)+new.x*new.w*amount)/alpha,
                (old.y*old.w*(1-amount)+new.y*new.w*amount)/alpha,
                (old.z*old.w*(1-amount)+new.z*new.w*amount)/alpha,alpha)
        }
    }
}

nonisolated extension LWLiveSourceNode {
    mutating func appendAdjustment(_ value:LWSourceRetainedAdjustment) throws {
        try admitMetadataMutation(additionalBytes:LWSourceMetadataStorage.sum(value.retainedMetadataBytes,
            LWSourceMetadataStorage.sum(4096,LWSourceMetadataStorage.collectionBytes(count:retouch.count,stride:MemoryLayout<LWSourceOperation>.stride))))
        if operations.isEmpty && filters.isEmpty && resamples.isEmpty && adjustments.isEmpty { operations=retouch.indices.map(LWSourceOperation.retouch) }
        try value.validate(source:id)
        adjustments.append(value);operations.append(.adjustment(value.id));try validateOperationOrder()
    }
}

nonisolated enum LWSourceAdjustmentPreparation {
    struct Result:Sendable { let node:LWLiveSourceNode;let plane:LWFloatPlane }
    static func prepare(_ source:LWLiveSourceNode,settings:LayerAdjustment,selection:SelectionClip?,
        transform:LayerTransform,workspace:LWFloatWorkspace) async throws -> Result {
        try await withTaskCancellationHandler {
            let before=try await LWSourceDeveloper.shared.evaluatePlane(source)
            return try prepare(source,before:before.surface,map:before.map,settings:settings,selection:selection,
                transform:transform,workspace:workspace)
        } onCancel: { workspace.cancellation.cancel() }
    }
    /// Same production body accepts the resolved immutable upstream. Controls need
    /// no fake worker or camera claim to exercise append, selection and float replay.
    static func prepare(_ source:LWLiveSourceNode,before:LWFloatPlane,map:LWSourceSpatialMap,
        settings:LayerAdjustment,selection:SelectionClip?,transform:LayerTransform,workspace:LWFloatWorkspace) throws -> Result {
        try source.validate();try workspace.cancellation.check()
        guard transform.isValid,settings.isValid,settings.kind == .hsv || settings.kind == .levels else { throw ProjectError.invalid }
        let frame=try source.capturedFrame(transform:transform)
        let coverage=try LWSourceSelectionPlane.capture(selection,mapping:BrushRaster.pixelToDocument(transform,width:before.width,height:before.height),
            width:before.width,height:before.height,workspace:workspace)
        var node=try source.metadataCopy(additionalBytes:16*1024)
        let key=coverage.map { _ in UUID() }
        if let key,let coverage { node.planeAssets[key]=try LWSourcePlaneAsset(coverage) }
        let operation=LWSourceRetainedAdjustment(id:UUID(),sourceID:source.id,upstreamRevision:source.revision,
            settings:settings,captureFrame:frame,selectionPlaneID:key)
        let plane=try LWSourceRetainedAdjustment.apply(operation,node:node,plane:before,map:map,workspace:workspace)
        node.revision=UUID();node.sourceLineage.append(node.revision);try node.appendAdjustment(operation)
        try node.validate();try workspace.cancellation.check()
        return Result(node:node,plane:plane)
    }
}

/// Display histogram only. Binning encodes/clamps for the existing 256 display
/// bins; reference/developed plane samples are never replaced by these values.
nonisolated enum LWSourceLevelsHistogram {
    struct Result:Sendable { let bins:[[Double]];let charge:LWFloatWorkingSet.Lease }
    static func make(_ plane:LWFloatPlane,selection:SelectionClip?,transform:LayerTransform,
        workspace:LWFloatWorkspace) throws -> Result {
        guard plane.workingSet === workspace.workingSet,transform.isValid else { throw ProjectError.invalid }
        let charge=try workspace.workingSet.reserve(1024*8*3+4096)
        var bins=Array(repeating:0.0,count:1024)
        let coverage=try LWSourceSelectionPlane.capture(selection,mapping:BrushRaster.pixelToDocument(transform,width:plane.width,height:plane.height),
            width:plane.width,height:plane.height,workspace:workspace)
        let sample=coverage?.sampler()
        func bin(_ value:Float) throws -> Int {
            guard value.isFinite else { throw ProjectError.invalid }
            let x=Double(value),encoded=x <= 0.0031308 ? x*12.92:1.055*pow(x,1/2.4)-0.055
            return Int((min(1,max(0,encoded))*255).rounded())
        }
        try plane.forEachTile { (range:LWFloatRange) in
            try workspace.cancellation.check()
            let tile=try plane.read(range)
            for y in 0..<range.height { for x in 0..<range.width {
                try workspace.cancellation.check()
                let pixel=tile.surface.pixels[y*range.width+x]
                let weight=Double(pixel.w*(try sample?.pixel(x:range.x+x,y:range.y+y).w ?? 1))
                guard weight.isFinite,(0...1).contains(weight) else { throw ProjectError.invalid }
                for channel in 0..<3 { bins[(channel+1)*256+(try bin(pixel[channel]))]+=weight }
            } }
        }
        for index in 0..<256 { bins[index]=(bins[256+index]+bins[512+index]+bins[768+index])/3 }
        return Result(bins:(0..<4).map { Array(bins[$0*256..<($0+1)*256]) },charge:charge)
    }
}

extension EditorSession {
    func validateSourceAdjustmentAdmission(_ admission:LWDocumentEditAdmission,layerID:UUID,node:LWLiveSourceNode,
        original:ImportedImage,transform:LayerTransform,mask:LayerMask?) throws {
        guard !sourceClosePending,let current=activeLayer,current.id == layerID,current.liveSource == node,
            current.asset?.image === original.image,current.transform == transform,current.mask == mask else { throw ProjectError.invalid }
        try validateDocumentEditAdmission(admission);try current.asset?.validatePlaneRead()
    }
    func publishSourceAdjustment(_ result:LWSourceAdjustmentPreparation.Result,admission:LWDocumentEditAdmission,
        layerID:UUID,node:LWLiveSourceNode,original:ImportedImage,transform:LayerTransform,mask:LayerMask?,actionName:String) throws {
        try validateSourceAdjustmentAdmission(admission,layerID:layerID,node:node,original:original,transform:transform,mask:mask)
        guard result.node.id == node.id,result.node.original == node.original,result.node.originalRevision == node.originalRevision,
            result.node.sourceLineage.contains(node.revision),result.node.revision != node.revision,
            let index=document?.layers.firstIndex(where:{$0.id == layerID}),let current=document?.layers[index] else { throw ProjectError.invalid }
        try result.node.validateBackingAssets();try result.plane.checkCancellation()
        let asset=try ImportedImage(plane:result.plane,name:original.name)
        var changed=current;changed.asset=asset;changed.liveSource=result.node
        guard beginEdit(actionName) else { throw ProjectError.invalid }
        document?.layers[index]=changed;endEdit()
    }
    func commitSourceAdjustment(admission:LWDocumentEditAdmission,layerID:UUID,node:LWLiveSourceNode,
        original:ImportedImage,transform:LayerTransform,mask:LayerMask?,settings:LayerAdjustment,selection:SelectionClip?) async throws {
        try validateSourceAdjustmentAdmission(admission,layerID:layerID,node:node,original:original,transform:transform,mask:mask)
        let workspace=try LWFloatWorkspace(workingSet:.sourceGraphs)
        try await withTaskCancellationHandler {
            let result=try await LWSourceAdjustmentPreparation.prepare(node,settings:settings,selection:selection,transform:transform,workspace:workspace)
            try Task.checkCancellation();try validateSourceAdjustmentAdmission(admission,layerID:layerID,node:node,original:original,transform:transform,mask:mask)
            try publishSourceAdjustment(result,admission:admission,layerID:layerID,node:node,original:original,
                transform:transform,mask:mask,actionName:settings.kind.rawValue)
        } onCancel: { workspace.cancellation.cancel() }
    }
}
