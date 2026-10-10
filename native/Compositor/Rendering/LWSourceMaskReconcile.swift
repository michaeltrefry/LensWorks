import Foundation
import CoreGraphics

nonisolated enum LWSourceMaskReconcile {
    static func reconcile(_ mask:LayerMask?, previous:LWLiveSourceNode,next:LWSourceSpatialMap,transform:LayerTransform) throws -> LayerMask? {
        guard let mask,mask.isLinked else { return mask }
        guard let local = mask.clipImage(placement:mask.placement,over:transform,width:previous.originalWidth,height:previous.originalHeight) else { throw ProjectError.invalid }
        let w=previous.originalWidth,h=previous.originalHeight
        let coverage=try GuidedMatte.levels(of:local,width:w,height:h)
        let old=LWSourceSpatialMap(geometry:previous.coordinateMap,optics:previous.settings.optics,width:w,height:h)
        var changed=[Float](repeating:0,count:coverage.count)
        for y in 0..<h { for x in 0..<w {
            let source=try next.sourcePoint(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5))
            let prior=try old.developedPoint(source)
            let xx=Int(floor(prior.x)),yy=Int(floor(prior.y))
            if xx>=0,xx<w,yy>=0,yy<h { changed[y*w+x]=coverage[yy*w+xx] }
        } }
        // This image is the intrinsic painted mask's storage, not source alpha.
        let asset=try LayerMask.asset(from:GuidedMatte.image(changed,width:w,height:h))
        var updated=mask.replacing(asset); updated.placement=nil
        return updated
    }
}

nonisolated extension LWSourceMaskReconcile {
    static func plane(_ asset:ImportedImage,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        guard LayerMask.isValid(asset.image) else { throw ProjectError.invalid }
        if let plane=asset.linearPlane { try asset.validatePlaneRead();return plane }
        let imported=try LWFloatCompositor.from(asset.image,workspace:workspace)
        let result=try LWFloatCompositor.map(imported,workspace:workspace) { p,_,_ in
            guard p.x.isFinite,(0...1).contains(p.x) else { throw ProjectError.invalid }
            return SIMD4(repeating:p.x)
        }
        try asset.validatePlaneRead();return result
    }
    /// Mask values are scalar coverage, not straight colors associated with their
    /// own coverage alpha. Use opaque float gray for the retained interpolation
    /// operator, then associate only its geometric boundary with the edge tone.
    static func projectCoverage(_ plane:LWFloatPlane,mapping:CGAffineTransform,width:Int,height:Int,
        background:Float=0,sampling:LayerSampling = .high,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        guard background.isFinite,(0...1).contains(background) else { throw ProjectError.invalid }
        let opaque=try LWFloatCompositor.map(plane,workspace:workspace) { p,_,_ in
            guard p.x == p.y,p.y == p.z,p.z == p.w,(0...1).contains(p.w) else { throw ProjectError.invalid }
            return SIMD4(p.w,p.w,p.w,1)
        }
        let placed=try LWFloatCompositor.project(opaque,mapping:mapping,width:width,height:height,workspace:workspace,sampling:sampling)
        return try LWFloatCompositor.map(placed,workspace:workspace) { p,_,_ in
            let value=p.x*p.w+background*(1-p.w)
            guard value.isFinite else { throw ProjectError.invalid }
            return SIMD4(repeating:min(1,max(0,value)))
        }
    }
    /// Same intrinsic grayscale placement and edge tone, built one admitted tile
    /// at a time instead of materializing LayerMask.clipImage's full local grid.
    static func coveragePlane(_ mask:LayerMask,over layer:LayerTransform,width:Int,height:Int,
        workspace:LWFloatWorkspace) throws -> LWFloatPlane {
        guard layer.isValid,mask.placement?.isValid ?? true,LayerMask.isValid(mask.asset.image) else { throw ProjectError.invalid }
        let image=mask.asset.image,placement=mask.placement ?? layer
        let mapping=BrushRaster.pixelToDocument(placement,width:image.width,height:image.height)
            .concatenating(BrushRaster.pixelToDocument(layer,width:width,height:height).inverted())
        let background=LayerMask.background(of:mask.asset.thumbnail)
        if let plane=mask.asset.linearPlane {
            let output=try projectCoverage(plane,mapping:mapping,width:width,height:height,background:Float(background),workspace:workspace)
            try mask.asset.validatePlaneRead();try workspace.cancellation.check();return output
        }
        let builder=try workspace.makeBuilder(width:width,height:height)
        while let range=builder.nextRange {
            try workspace.cancellation.check();try Task.checkCancellation()
            try autoreleasepool {
                let bytes=try range.validate(frameWidth:width,frameHeight:height),lease=try workspace.workingSet.reserve(bytes*3)
                let context=try BrushRaster.context(width:range.width,height:range.height,mask:true)
                context.setFillColor(gray:background,alpha:1);context.fill(CGRect(x:0,y:0,width:range.width,height:range.height))
                context.translateBy(x:-CGFloat(range.x),y:-CGFloat(range.y));context.concatenate(mapping)
                context.interpolationQuality = .high
                LayerMask.drawSmooth(image,in:CGRect(x:0,y:0,width:image.width,height:image.height),context:context)
                try mask.asset.validatePlaneRead();try workspace.cancellation.check()
                guard let data=context.data?.assumingMemoryBound(to:UInt8.self) else { throw ProjectError.invalid }
                var pixels=[SIMD4<Float>](repeating:.zero,count:range.width*range.height)
                for y in 0..<range.height { for x in 0..<range.width {
                    let value=Float(data[y*context.bytesPerRow+x])/255;pixels[y*range.width+x]=SIMD4(repeating:value)
                } }
                try builder.append(LWLinearSurface(width:range.width,height:range.height,pixels:pixels,maximumBytes:bytes),at:range)
                withExtendedLifetime(lease) {}
            }
        }
        try mask.asset.validatePlaneRead();return try builder.finish()
    }
    static func reconcilePlane(_ mask:LayerMask?,previous:LWLiveSourceNode,next:LWSourceSpatialMap,
        transform:LayerTransform,workspace:LWFloatWorkspace) throws -> LayerMask? {
        guard let mask,mask.isLinked else { return mask }
        let prior=try previous.currentSpatialMap
        let oldCoverage=try coveragePlane(mask,over:transform,width:prior.developedWidth,height:prior.developedHeight,workspace:workspace)
        let sampler=oldCoverage.sampler()
        let blank=try LWFloatCompositor.clearPlane(width:next.developedWidth,height:next.developedHeight,workspace:workspace)
        let made=try LWFloatCompositor.map(blank,workspace:workspace) { _,x,y in
            guard let source=try next.sourcePointIfInBounds(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),
                let old=try prior.developedPointIfInBounds(source) else { return .zero }
            let value=try sampler.pixel(x:Int(floor(old.x)),y:Int(floor(old.y))).x
            return SIMD4(repeating:value)
        }
        var result=mask.replacing(try ImportedImage(maskPlane:made,name:mask.asset.name));result.placement=nil;return result
    }
}
