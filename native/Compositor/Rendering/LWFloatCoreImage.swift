import Foundation
import CoreGraphics
import CoreImage

/// Exact full-logical-source operators receive range-backed pixels. Dependency
/// rectangles never become whole native arrays merely because the operator has a
/// large radius. The provider reads fixed admitted ranges; output is a fixed tile.
/// Core Image's opaque allocations/process RSS remain an actual measurement gate.
nonisolated enum LWFloatCoreImage {
    static func render(_ source:LWFloatPlane,makeBuilder:(Int,Int)throws->LWFloatPlane.Builder,
        cancellation:LWFloatCancellation? = nil,operation:(CIImage)->CIImage)throws->LWFloatPlane {
        try source.checkCancellation();try cancellation?.check()
        guard let color=CGColorSpace(name:CGColorSpace.extendedLinearSRGB) else { throw ProjectError.invalid }
        let topology=try source.workingSet.reserve(4096)
        let provider=LWFloatPlaneImage(plane:source,cancellation:cancellation)
        let image=try provider.image(),input=CIImage(cgImage:image,options:[.colorSpace:color])
        let extent=CGRect(x:0,y:0,width:source.width,height:source.height)
        let filtered=operation(input).cropped(to:extent)
        // Framework callbacks and an operator may cancel while building the graph.
        // Refuse before the first output owner is created.
        try provider.check();try source.checkCancellation();try cancellation?.check();try Task.checkCancellation()
        let builder=try makeBuilder(source.width,source.height)
        guard builder.workingSet === source.workingSet else { throw ProjectError.invalid }
        while let range=builder.nextRange {
            try source.checkCancellation();try cancellation?.check();try Task.checkCancellation()
            try autoreleasepool {
                let bytes=try range.validate(frameWidth:source.width,frameHeight:source.height)
                // Output samples, context/bitmap conversion and builder encoding.
                // Input tiles/unaligned provider scratch own separate shared leases.
                let charge=try source.workingSet.reserve(bytes*4)
                let output=CGRect(x:range.x,y:source.height-range.y-range.height,width:range.width,height:range.height)
                let local=filtered.cropped(to:output).transformed(by:CGAffineTransform(translationX:-output.minX,y:-output.minY))
                let surface=try LWLinearSurface.render(local,width:range.width,height:range.height,maximumBytes:bytes)
                try provider.check();try source.checkCancellation();try cancellation?.check()
                try builder.append(surface,at:range);withExtendedLifetime(charge) {}
            }
        }
        try provider.check();try cancellation?.check()
        let result=try builder.finish();withExtendedLifetime(topology) {};return result
    }
}
