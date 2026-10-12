import Foundation
import CoreGraphics
import CoreImage

/// Destructive menu filters become ordered float graph operations. Display conversion
/// is a consumer boundary; no browse image supplies reference or exported pixels.
nonisolated enum LWFloatFilter {
    static func apply(_ filter: LWSourceRetainedFilter, node: LWLiveSourceNode, plane: LWFloatPlane,
        map: LWSourceSpatialMap, workspace: LWFloatWorkspace) throws -> LWFloatPlane {
        try filter.validate(source:node.id)
        let stage=filter.pixelStage,settings=filter.settings
        guard plane.width == stage.inputWidth,plane.height == stage.inputHeight,
            map.developedWidth == plane.width,map.developedHeight == plane.height else { throw ProjectError.invalid }
        let input=try padded(plane,stage:stage,workspace:workspace)
        let kernel=LWFloatKernelWorkspace(makeBuilder:{ try workspace.makeBuilder(width:$0,height:$1) },
            makeScratchDirectory:{ try workspace.makeScratchDirectory() },fileOwner:workspace)
        let made:LWFloatPlane
        if filter.kind.isAutomatic {
            guard let key=filter.retainedResultPlaneID else { throw ProjectError.invalid }
            made=try node.dependencyPlane(key,workspace:workspace)
            guard made.width == input.width,made.height == input.height else { throw ProjectError.invalid }
        } else if let adjustment=adjustment(filter) {
            // Adjustment layers and their destructive-menu counterpart share the
            // same continuous extended-sRGB/float kernel and global seed origin.
            made=try adjustment.apply(input,region:CGRect(x:0,y:0,width:input.width,height:input.height),scale:1,
                makeBuilder:{ try workspace.makeBuilder(width:$0,height:$1) },
                makeScratchDirectory:{ try workspace.makeScratchDirectory() },fileOwner:workspace)
        } else {
            switch filter.kind {
            case .gaussianBlur:
                made=try coreImage(input,workspace:workspace) { $0.applyingGaussianBlur(sigma:settings.radius) }
            case .motionBlur:
                let radius=settings.distance*PixelFilter.motionRadiusPerPixel
                made=try coreImage(input,workspace:workspace,apron:min(1024,Int(radius.rounded(.up))+16)) { $0.applyingFilter("CIMotionBlur",parameters:[
                    kCIInputRadiusKey:settings.distance*PixelFilter.motionRadiusPerPixel,
                    kCIInputAngleKey:settings.angle * .pi/180]) }
            case .bloomGlow:
                made=try coreImage(input,workspace:workspace) { $0.applyingFilter("CIBloom",parameters:[
                    kCIInputRadiusKey:settings.bloomRadius,kCIInputIntensityKey:settings.bloomAmount/50]) }
            case .tonalContrast:
                let blurred=try coreImage(input,workspace:workspace) { $0.applyingGaussianBlur(sigma:settings.tonalRadius) },base=blurred.sampler()
                made=try kernel.rgb(input) { linear,x,y in
                    let pixel=try base.pixel(x:x,y:y)
                    guard pixel.w>0 else { return linear }
                    typealias K=FloatImageAdjustmentPixels
                    let encoded=SIMD3(K.encode(linear.x),K.encode(linear.y),K.encode(linear.z))
                    let b=SIMD3(K.encode(Double(pixel.x)),K.encode(Double(pixel.y)),K.encode(Double(pixel.z)))
                    let lum=K.luminance(encoded),baseLum=K.luminance(b)
                    func smooth(_ low:Double,_ high:Double,_ value:Double)->Double { let t=K.unit((value-low)/(high-low));return t*t*(3-2*t) }
                    let shadows=1-smooth(0.15,0.5,baseLum),highlights=smooth(0.5,0.85,baseLum),midtones=1-shadows-highlights
                    let weight=(settings.tonalShadows*shadows+settings.tonalMidtones*midtones+settings.tonalHighlights*highlights)/100
                    // Tonal weights stay in their encoded-domain definition. The
                    // float extension retains out-of-range color instead of clipping it.
                    let delta=0.18*tanh((lum-baseLum)*6)*weight*(settings.tonalAmount/50)*(4*lum*(1-lum))
                    return SIMD3(K.decode(encoded.x+delta),K.decode(encoded.y+delta),K.decode(encoded.z+delta))
                }
            case .vignette:
                made=try kernel.rgb(input) { linear,x,y in
                    typealias K=FloatImageAdjustmentPixels
                    let nx=(Double(x)+0.5-Double(stage.offsetX)-Double(stage.inputWidth)/2)/(Double(stage.inputWidth)/2)
                    let ny=(Double(y)+0.5-Double(stage.offsetY)-Double(stage.inputHeight)/2)/(Double(stage.inputHeight)/2)
                    let circle=hypot(nx,ny)/sqrt(2),square=max(abs(nx),abs(ny))
                    let distance=circle+(square-circle)*(1-settings.vignetteRoundness/100)*0.5
                    let t=K.unit((distance-settings.vignetteMidpoint/100*0.85)/max(0.05,settings.vignetteFeather/100)),mask=t*t*(3-2*t)
                    let encoded=SIMD3(K.encode(linear.x),K.encode(linear.y),K.encode(linear.z))
                    let bright=K.unit((K.luminance(encoded)-0.45)/0.55)
                    let effect=settings.vignetteAmount/100*mask*(1-settings.vignetteHighlights/100*bright)
                    let color=settings.vignetteColor,target=SIMD3(color.red,color.green,color.blue)
                    let result=encoded+(target-encoded)*effect
                    return SIMD3(K.decode(result.x),K.decode(result.y),K.decode(result.z))
                }
            case .lensCorrection:
                let source=input.sampler()
                made=try kernel.map(input) { _,x,y,_ in
                    let point=try stage.optics.sourcePoint(for:CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5),width:input.width,height:input.height)
                    return try LWFloatKernelWorkspace.sample(source,width:input.width,height:input.height,x:Double(point.x)-0.5,y:Double(point.y)-0.5)
                }
            case .dither:
                made=try LWFloatDither.apply(settings.dither,plane:input,workspace:workspace)
            case .cameraRaw,.removeBackground,.contentAwareFill,.curves,.exposure,.gradientMap,.grain,.blackWhite,.colorBalance,.addNoise:
                throw ProjectError.invalid // the typed dispatch above owns these cases
            }
        }
        let selected: LWFloatPlane
        if let selectionID = filter.selectionPlaneID {
            let mask=try node.dependencyPlane(selectionID,workspace:workspace),coverage=mask.sampler(),changed=made.sampler()
            guard let frame=filter.selectionFrame,mask.width==frame.developedWidth,mask.height==frame.developedHeight else { throw ProjectError.invalid }
            var outputMap=map;outputMap.stages.append(stage)
            selected = try LWFloatCompositor.map(input,workspace:workspace) { old,x,y in
                guard let point=try outputMap.sourcePointIfInBounds(CGPoint(x:CGFloat(x)+0.5,y:CGFloat(y)+0.5)),
                    let captured=try frame.spatialMap.developedPointIfInBounds(point) else { return old }
                let amount=try coverage.pixel(x:Int(floor(captured.x)),y:Int(floor(captured.y))).w
                return interpolate(old,try changed.pixel(x:x,y:y),coverage:amount)
            }
        } else { selected = made }
        return try filter.crop.map { try cropped(selected,range:$0,workspace:workspace) } ?? selected
    }
    /// Scan the complete alpha plane once, with fixed tiles. Hidden RGB is not
    /// an alpha boundary; source RAW and historical generations remain untouched.
    static func alphaBounds(_ plane:LWFloatPlane,workspace:LWFloatWorkspace)throws->LWFloatRange? {
        var left=plane.width,top=plane.height,right=0,bottom=0
        try plane.forEachTile { range in
            try workspace.cancellation.check()
            let tile = try plane.read(range:range)
            for y in 0..<tile.range.height { for x in 0..<tile.range.width {
                if tile.surface.pixels[y*tile.range.width+x].w > 0 {
                    left=min(left,tile.range.x+x);top=min(top,tile.range.y+y)
                    right=max(right,tile.range.x+x+1);bottom=max(bottom,tile.range.y+y+1)
                }
            } }
        }
        guard left<right,top<bottom else { return nil }
        return LWFloatRange(x:left,y:top,width:right-left,height:bottom-top)
    }
    static func cropped(_ plane:LWFloatPlane,range:LWFloatRange,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        _ = try range.validate(frameWidth:plane.width,frameHeight:plane.height)
        if range==plane.globalExtent { return plane }
        let builder=try workspace.makeBuilder(width:range.width,height:range.height)
        while let output=builder.nextRange {
            try workspace.cancellation.check()
            let source=LWFloatRange(x:output.x+range.x,y:output.y+range.y,width:output.width,height:output.height)
            let read=try plane.read(range:source);try builder.append(read.surface,at:output)
        }
        return try builder.finish()
    }
    /// Selection blends associated colors, then returns straight float RGBA.
    static func interpolate(_ old:SIMD4<Float>,_ new:SIMD4<Float>,coverage:Float)->SIMD4<Float> {
        let t=min(1,max(0,coverage)),alpha=old.w*(1-t)+new.w*t
        guard alpha>0 else { return .zero }
        let rgb=(SIMD3(old.x,old.y,old.z)*old.w*(1-t)+SIMD3(new.x,new.y,new.z)*new.w*t)/alpha
        return SIMD4(rgb.x,rgb.y,rgb.z,alpha)
    }
    static func adjustment(_ filter:LWSourceRetainedFilter)->LayerAdjustment? {
        let s=filter.settings
        var value:LayerAdjustment
        switch filter.kind {
        case .curves: value=LayerAdjustment(kind:.curves);value.curves=s.curves
        case .exposure: value=LayerAdjustment(kind:.exposure);value.exposure=s.exposure
        case .gradientMap: value=LayerAdjustment(kind:.gradientMap);value.gradientMap=s.gradientMap
        case .grain: value=LayerAdjustment(kind:.grain);value.grain=s.grain
        case .blackWhite: value=LayerAdjustment(kind:.blackWhite);value.blackWhite=s.blackWhite
        case .colorBalance: value=LayerAdjustment(kind:.colorBalance);value.colorBalance=s.colorBalance
        case .addNoise: value=LayerAdjustment(kind:.addNoise);value.resolvedNoiseAmount=s.amount;value.resolvedNoiseGaussian=s.gaussian
            value.resolvedNoiseMonochromatic=s.monochromatic;value.noiseSeed=filter.seed
        default: return nil
        }
        return value
    }
    static func padded(_ plane:LWFloatPlane,stage:LWSourcePixelStage,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        if stage.outputWidth==plane.width,stage.outputHeight==plane.height,stage.offsetX==0,stage.offsetY==0 { return plane }
        let blank=try LWFloatCompositor.clearPlane(width:stage.outputWidth,height:stage.outputHeight,workspace:workspace),sampler=plane.sampler()
        return try LWFloatCompositor.map(blank,workspace:workspace) { _,x,y in try sampler.pixel(x:x-stage.offsetX,y:y-stage.offsetY) }
    }
    /// Retained full-source operator semantics with bounded provider/output storage.
    static func coreImage(_ source:LWFloatPlane,workspace:LWFloatWorkspace,apron:Int=0,
        operation:(CIImage)->CIImage)throws->LWFloatPlane {
        try LWFloatCoreImage.render(source,makeBuilder:{ try workspace.makeBuilder(width:$0,height:$1) },
            cancellation:workspace.cancellation,apron:apron,operation:operation)
    }

}
