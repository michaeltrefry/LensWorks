import Testing
import Foundation
import CoreGraphics
import CoreImage
@testable import Compositor

@MainActor struct FloatCoreImageProviderTests {
    private func tiledFixture(_ values:[SIMD4<Float>],width:Int,workspace:LWFloatWorkspace)throws->LWFloatPlane {
        let builder=try workspace.makeBuilder(width:width,height:values.count/width)
        while let range=builder.nextRange {
            let pixels=(range.y..<range.y+range.height).flatMap { y in (range.x..<range.x+range.width).map { values[y*width+$0] } }
            try builder.append(LWLinearSurface(width:range.width,height:range.height,pixels:pixels,maximumBytes:range.width*range.height*16),at:range)
        }
        return try builder.finish()
    }
    @Test(arguments:["gaussian","motion"])
    func fullLogicalCoreImageOperatorDoesNotRequireAWholeDependencyArray(_ kind:String) throws {
        let width=1025,height=1023,set=try LWFloatWorkingSet(limit:12*1024*1024)
        let workspace=try LWFloatWorkspace(workingSet:set),builder=try workspace.makeBuilder(width:width,height:height)
        while let range=builder.nextRange {
            let values=(0..<(range.width*range.height)).map { i -> SIMD4<Float> in
                let x=range.x+i%range.width,y=range.y+i/range.width
                return SIMD4(Float(x)/100,Float(y)/200,Float((x+y)%7)-2,1)
            }
            try builder.append(LWLinearSurface(width:range.width,height:range.height,pixels:values,maximumBytes:range.width*range.height*16),at:range)
        }
        let before=try builder.finish()
        #expect(throws:ProjectError.self) { _=try before.read(before.globalExtent) }
        func operation(_ image:CIImage)->CIImage {
            let edges=image.clampedToExtent()
            return kind == "gaussian" ? edges.applyingGaussianBlur(sigma:80):edges.applyingFilter("CIMotionBlur",parameters:[kCIInputRadiusKey:80,kCIInputAngleKey:0.3])
        }
        // Motion renders each tile inside the same apron the product uses (TiledFloatKernelWorkspace.coreImage).
        let actual=try LWFloatCoreImage.render(before,makeBuilder:{ try workspace.makeBuilder(width:$0,height:$1) },apron:kind == "motion" ? 96:0,operation:operation)
        let color=try #require(CGColorSpace(name:CGColorSpace.extendedLinearSRGB))
        let source=LWFloatPlaneImage(plane:before),image=try source.image()
        // Same official operator rendered whole as the deterministic reference.
        // The fixture's reference allocation is outside the deliberately tiny
        // working set; it does not grant a production cap or camera-color budget.
        let expected=try LWLinearSurface.render(operation(CIImage(cgImage:image,options:[.colorSpace:color])),
            width:width,height:height,maximumBytes:width*height*16)
        try source.check()
        // Within the declared Core Image blur tolerance (CoreImageBlurTolerance).
        var mismatches=0,worst:Float=0
        try actual.forEachTile { range in
            let tile=try actual.read(range:range)
            for (index,a) in tile.surface.pixels.enumerated() {
                let x=index%range.width,y=index/range.width
                let e=expected.pixels[(range.y+y)*width+range.x+x]
                for c in 0..<4 { worst=max(worst,abs(a[c]-e[c])/max(1,abs(e[c]))) }
                if !CoreImageBlurTolerance.agrees(a,e) { mismatches+=1 }
            }
        }
        #expect(mismatches==0,"\(kind): \(mismatches) samples exceed the declared tolerance; worst relative error \(worst)")
    }
    @Test func fullSourceCoreImageCallbackCancellationStopsBeforeOutputPublication() throws {
        let workspace=try LWFloatWorkspace(workingSet:LWFloatWorkingSet())
        let source=try tiledFixture([SIMD4(4,-1,2,1),SIMD4(2,3,4,1)],width:2,workspace:workspace)
        var builders=0
        #expect(throws:CancellationError.self) {
            _=try LWFloatCoreImage.render(source,makeBuilder:{ w,h in builders+=1;return try workspace.makeBuilder(width:w,height:h) },
                cancellation:workspace.cancellation,operation:{ image in workspace.cancellation.cancel();return image })
        }
        #expect(builders==0)
    }
}
