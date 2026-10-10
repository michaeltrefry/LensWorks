import Foundation
import CoreGraphics

/// Transient overlays on the actual developed float plane. These are UI aids,
/// never persisted source pixels or photographic error-budget measurements.
nonisolated enum LWCameraRawDiagnostics {
    typealias K = FloatImageAdjustmentPixels
    static func preview(_ surface:LWLinearSurface,settings:CameraRawSettings,clipping:CameraRawClipping?,
                        shadows:Bool,highlights:Bool,point:Int,sharpenMask:Bool) throws -> LWLinearSurface {
        guard clipping != nil || shadows || highlights || point >= 0 || sharpenMask else { return surface }
        try settings.validateFloatControls()
        // Input, output, and one Double luma plane are simultaneously retained.
        let base=surface.byteLength.multipliedReportingOverflow(by:2)
        let lumaBytes=surface.pixels.count.multipliedReportingOverflow(by:MemoryLayout<Double>.stride)
        let total=base.partialValue.addingReportingOverflow(lumaBytes.partialValue)
        guard !base.overflow,!lumaBytes.overflow,!total.overflow,total.partialValue <= surface.maximumBytes else { throw ProjectError.tooLarge }
        let encodedBytes=surface.pixels.count.multipliedReportingOverflow(by:MemoryLayout<K.RGB>.stride)
        let aggregate=total.partialValue.addingReportingOverflow(encodedBytes.partialValue)
        guard !encodedBytes.overflow,!aggregate.overflow,aggregate.partialValue <= surface.maximumBytes else { throw ProjectError.tooLarge }
        let encoded=surface.pixels.map { p -> K.RGB in
            K.RGB(K.encode(Double(p.x)),K.encode(Double(p.y)),K.encode(Double(p.z)))
        }
        let luma=sharpenMask ? encoded.enumerated().map { surface.pixels[$0.offset].w > 0 ? K.luminance($0.element) : 0 } : []
        let detail=settings.detail
        let radius=max(1,Int((0.5+detail.sharpenRadius/100*2.5).rounded()))
        var pixels=surface.pixels
        for i in pixels.indices where pixels[i].w > 0 {
            var c=encoded[i]
            if let clipping {
                switch clipping {
                case .highlights: c=K.RGB(c.x >= 254.5/255 ? 1:0,c.y >= 254.5/255 ? 1:0,c.z >= 254.5/255 ? 1:0)
                case .shadows: c=K.RGB(c.x <= 0.5/255 ? 0:1,c.y <= 0.5/255 ? 0:1,c.z <= 0.5/255 ? 0:1)
                }
            } else if sharpenMask {
                let edge=K.edge(luma,width:surface.width,height:surface.height,x:i%surface.width,y:i/surface.width,radius:radius)
                let threshold=detail.sharpenMasking/100*0.35
                let value=K.unit((edge*(0.5+detail.sharpenDetail/100)-threshold)/max(0.04,0.35-threshold*0.5))
                c=K.RGB(repeating:value)
            } else {
                if settings.mixer.points.indices.contains(point) {
                    let target=settings.mixer.points[point],envelope=K.ColorEnvelope(c)
                    let hue=1-K.hueDistance(envelope.h,target.hue/360)/max(0.01,target.hueRange/360)
                    let sat=1-abs(envelope.s-target.saturation)/max(0.01,target.saturationRange)
                    let lum=1-abs(envelope.l-target.luminance)/max(0.01,target.luminanceRange)
                    if hue < 0 || sat < 0 || lum < 0 || hue*sat*lum <= 0.05 { c *= 0.35 }
                }
                if shadows && min(c.x,min(c.y,c.z)) <= 0.5/255 { c=c*0.35+K.RGB(0,0,0.65) }
                if highlights && max(c.x,max(c.y,c.z)) >= 254.5/255 { c=c*0.35+K.RGB(0.65,0,0) }
            }
            let rgb=K.RGB(K.decode(c.x),K.decode(c.y),K.decode(c.z))
            pixels[i]=SIMD4(Float(rgb.x),Float(rgb.y),Float(rgb.z),pixels[i].w)
        }
        return try LWLinearSurface(width:surface.width,height:surface.height,pixels:pixels,maximumBytes:surface.maximumBytes)
    }
}

nonisolated extension LWCameraRawDiagnostics {
    static func preview(_ plane:LWFloatPlane,settings:CameraRawSettings,clipping:CameraRawClipping?,
        shadows:Bool,highlights:Bool,point:Int,sharpenMask:Bool,workspace:LWFloatWorkspace) throws -> LWFloatPlane {
        guard clipping != nil || shadows || highlights || point>=0 || sharpenMask else { return plane }
        try settings.validateFloatControls()
        let kernels=LWFloatKernelWorkspace(makeBuilder:{ try workspace.makeBuilder(width:$0,height:$1) },
            makeScratchDirectory:{ try workspace.makeScratchDirectory() },fileOwner:workspace)
        let luma=sharpenMask ? try kernels.scalar(plane) { p in
            p.w>0 ? K.luminance(K.RGB(K.encode(Double(p.x)),K.encode(Double(p.y)),K.encode(Double(p.z)))) : 0
        }.reader() : nil
        let radius=max(1,Int((0.5+settings.detail.sharpenRadius/100*2.5).rounded()))
        return try kernels.map(plane) { p,x,y,_ in
            guard p.w>0 else { return p }
            var c=K.RGB(K.encode(Double(p.x)),K.encode(Double(p.y)),K.encode(Double(p.z)))
            if let clipping {
                switch clipping {
                case .highlights:c=K.RGB(c.x>=254.5/255 ? 1:0,c.y>=254.5/255 ? 1:0,c.z>=254.5/255 ? 1:0)
                case .shadows:c=K.RGB(c.x<=0.5/255 ? 0:1,c.y<=0.5/255 ? 0:1,c.z<=0.5/255 ? 0:1)
                }
            } else if sharpenMask,let luma {
                let center=try luma.value(x:x,y:y);var sum=0.0,count=0
                for dy in stride(from:-radius,through:radius,by:radius) { for dx in stride(from:-radius,through:radius,by:radius) where dx != 0 || dy != 0 {
                    let xx=x+dx,yy=y+dy
                    if xx>=0,yy>=0,xx<plane.width,yy<plane.height { sum += abs(try luma.value(x:xx,y:yy)-center);count+=1 }
                } }
                let edge=count==0 ? 0:sum/Double(count),detail=settings.detail,threshold=detail.sharpenMasking/100*0.35
                c=K.RGB(repeating:K.unit((edge*(0.5+detail.sharpenDetail/100)-threshold)/max(0.04,0.35-threshold*0.5)))
            } else {
                if settings.mixer.points.indices.contains(point) {
                    let target=settings.mixer.points[point],envelope=K.ColorEnvelope(c)
                    let hue=1-K.hueDistance(envelope.h,target.hue/360)/max(0.01,target.hueRange/360)
                    let sat=1-abs(envelope.s-target.saturation)/max(0.01,target.saturationRange)
                    let lum=1-abs(envelope.l-target.luminance)/max(0.01,target.luminanceRange)
                    if hue<0 || sat<0 || lum<0 || hue*sat*lum<=0.05 { c *= 0.35 }
                }
                if shadows && min(c.x,min(c.y,c.z))<=0.5/255 { c=c*0.35+K.RGB(0,0,0.65) }
                if highlights && max(c.x,max(c.y,c.z))>=254.5/255 { c=c*0.35+K.RGB(0.65,0,0) }
            }
            return SIMD4(Float(K.decode(c.x)),Float(K.decode(c.y)),Float(K.decode(c.z)),p.w)
        }
    }
}
