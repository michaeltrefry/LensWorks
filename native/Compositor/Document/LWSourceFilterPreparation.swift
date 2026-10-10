import Foundation
import CoreGraphics

/// One explicit user operation samples its immediately-prior immutable graph.
/// Automatic pixels are retained actual inputs; subsequent RAW replay never runs
/// Vision or Content Fill again. Remove Background keeps RAW and edits its mask.
nonisolated enum LWSourceFilterPreparation {
    struct Result: Sendable {
        let node: LWLiveSourceNode
        let surface: LWFloatPlane
        let map: LWSourceSpatialMap
        let mask: LWFloatPlane?
        let transform: LayerTransform
    }
    static func combineSubject(_ subject: LWFloatPlane, under: LWFloatPlane?, selection: LWFloatPlane?,
        workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        guard [under,selection].compactMap({ $0 }).allSatisfy({ $0.width == subject.width && $0.height == subject.height }) else { throw ProjectError.invalid }
        let sample = subject.sampler(), previous = under?.sampler(), selected = selection?.sampler()
        return try LWFloatCompositor.map(subject, workspace: workspace) { _, x, y in
            let old = try previous?.pixel(x: x, y: y).x ?? 1
            let changed = old * (try sample.pixel(x: x, y: y).x)
            let amount = try selected?.pixel(x: x, y: y).w ?? 1
            guard old.isFinite,changed.isFinite,amount.isFinite,(0...1).contains(old),(0...1).contains(changed),(0...1).contains(amount) else { throw ProjectError.invalid }
            return SIMD4(repeating: old * (1 - amount) + changed * amount)
        }
    }
    static func prepare(_ original: LWLiveSourceNode, kind: FilterKind, settings: FilterSettings,
        seed: UInt32, selection: SelectionClip?, inputTransform: LayerTransform, transform: LayerTransform, stage: LWSourcePixelStage,
        existingMask: LayerMask?, workspace: LWFloatWorkspace) async throws -> Result {
        try await withTaskCancellationHandler {
            try workspace.cancellation.check(); try original.validate(); try stage.validate()
            guard kind != .cameraRaw, settings == settings.normalized, inputTransform.isValid, transform.isValid else { throw ProjectError.invalid }
            let before = try await LWSourceDeveloper.shared.evaluatePlane(original)
            try workspace.cancellation.check(); try Task.checkCancellation()
            guard before.surface.width == stage.inputWidth, before.surface.height == stage.inputHeight else { throw ProjectError.invalid }
            let input = try LWFloatFilter.padded(before.surface, stage: stage, workspace: workspace)
            let mapping = BrushRaster.pixelToDocument(transform, width: input.width, height: input.height)
            let coverage = try LWSourceSelectionPlane.capture(selection, mapping: mapping,
                width: input.width, height: input.height, workspace: workspace)
            if kind == .removeBackground {
                guard stage.offsetX == 0, stage.offsetY == 0, input.width == before.surface.width,
                    input.height == before.surface.height else { throw ProjectError.invalid }
                let subject = try LWFloatSubjectMask.run(input, settings: settings, workspace: workspace)
                let under = try existingMask.map { try LWSourceMaskReconcile.coveragePlane($0, over: transform,
                    width: input.width, height: input.height, workspace: workspace) }
                let mask = try combineSubject(subject, under: under, selection: coverage, workspace: workspace)
                return Result(node: original, surface: before.surface, map: before.map, mask: mask, transform: transform)
            }
            var node = try original.metadataCopy(additionalBytes:8192)
            let selectedID = coverage.map { _ in UUID() }
            if let selectedID, let coverage { node.planeAssets[selectedID] = try LWSourcePlaneAsset(coverage) }
            var outputMap = before.map; outputMap.stages.append(stage); try outputMap.validateStages()
            let captured = LWSourceRetouchFrame(geometry: outputMap.geometry, optics: outputMap.optics,
                width: original.originalWidth, height: original.originalHeight, layerTransform: transform,
                stages: outputMap.stages)
            var resultID: UUID?
            if kind == .contentAwareFill {
                guard let coverage else { throw ProjectError.invalid }
                let result = try LWFloatContentFill.run(input, coverage: coverage, workspace: workspace)
                let key = UUID(); node.planeAssets[key] = try LWSourcePlaneAsset(result); resultID = key
            }
            var filter = LWSourceRetainedFilter(id: UUID(), sourceID: node.id, upstreamRevision: original.revision,
                kind: kind, settings: settings, seed: seed,
                captureFrame: LWSourceRetouchFrame(geometry:before.map.geometry,optics:before.map.optics,
                    width:original.originalWidth,height:original.originalHeight,layerTransform:inputTransform,stages:before.map.stages),
                selectionPlaneID: selectedID, selectionFrame: selectedID == nil ? nil : captured,
                retainedResultPlaneID: resultID, pixelStage: stage)
            var surface = try LWFloatFilter.apply(filter, node: node, plane: before.surface,
                map: before.map, workspace: workspace)
            var placed = transform
            if [.gaussianBlur,.motionBlur,.bloomGlow].contains(kind),
                let crop = try LWFloatFilter.alphaBounds(surface, workspace:workspace), crop != surface.globalExtent {
                let pixelToDocument = BrushRaster.pixelToDocument(transform,width:surface.width,height:surface.height)
                let middle = CGPoint(x:CGFloat(crop.x)+CGFloat(crop.width)/2,y:CGFloat(crop.y)+CGFloat(crop.height)/2).applying(pixelToDocument)
                placed.size = CGSize(width:CGFloat(crop.width)*transform.size.width/CGFloat(surface.width),
                    height:CGFloat(crop.height)*transform.size.height/CGFloat(surface.height))
                placed.origin = CGPoint(x:middle.x-placed.size.width/2,y:middle.y-placed.size.height/2)
                surface = try LWFloatFilter.cropped(surface,range:crop,workspace:workspace)
                filter.crop = crop
                outputMap.stages = before.map.stages + filter.spatialStages;try outputMap.validateStages()
            }
            node.revision = UUID(); node.sourceLineage.append(node.revision)
            try node.appendFilter(filter); try node.validate(); try workspace.cancellation.check()
            return Result(node: node, surface: surface, map: outputMap, mask: nil, transform: placed)
        } onCancel: { workspace.cancellation.cancel() }
    }
}

nonisolated enum LWSourceSelectionPlane {
    static func capture(_ selection: SelectionClip?, mapping: CGAffineTransform,
        width: Int, height: Int, workspace: LWFloatWorkspace) throws -> LWFloatPlane? {
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
        let builder = try workspace.makeBuilder(width: width, height: height)
        while let range = builder.nextRange {
            try workspace.cancellation.check(); try Task.checkCancellation()
            try autoreleasepool {
                let bytes = try range.validate(frameWidth: width, frameHeight: height)
                let lease = try workspace.workingSet.reserve(bytes * 6)
                let context = try BrushRaster.context(width: range.width, height: range.height, mask: true)
                context.translateBy(x: -CGFloat(range.x), y: -CGFloat(range.y))
                context.setFillColor(gray: 0, alpha: 1); context.fill(CGRect(x: 0, y: 0, width: width, height: height))
                context.concatenate(mapping.inverted()); selection.apply(to: context)
                context.setFillColor(gray: 1, alpha: 1); context.fill(selection.rect)
                guard let image = context.makeImage() else { throw ExportError.render }
                // Grayscale rasterization is a coverage boundary, not reference RGB.
                let read = try LWLinearSurface.read(image, maximumBytes: bytes)
                let coverage = try LWLinearSurface(width: read.width, height: read.height, pixels: read.pixels.map { SIMD4(repeating: $0.x) }, maximumBytes: bytes)
                try builder.append(coverage, at: range); withExtendedLifetime(lease) {}
            }
        }
        withExtendedLifetime(borrowed) {}; return try builder.finish()
    }
}
