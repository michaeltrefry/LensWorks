import Foundation
import CoreGraphics
import CoreImage

/// Exact working samples. Conversion to a display/output profile happens at the boundary.
nonisolated struct LWLinearSurface: Sendable {
    let width: Int
    let height: Int
    var pixels: [SIMD4<Float>]
    let maximumBytes: Int
    var byteLength: Int { pixels.count * MemoryLayout<SIMD4<Float>>.stride }
    init(width: Int, height: Int, pixels: [SIMD4<Float>], maximumBytes: Int) throws {
        self.width = width; self.height = height; self.pixels = pixels; self.maximumBytes = maximumBytes
        try validate(maximumBytes: maximumBytes)
    }
    /// Mutable Array surfaces are reference-kernel fixtures. Production compatibility
    /// results use immutable owned storage so an escaped collection/slice keeps its lease.
    static func admitted(width: Int, height: Int, maximumBytes: Int,
                         workingSet: LWFloatWorkingSet,
                         pixels: (Int) throws -> SIMD4<Float>) throws -> LWSourceOwnedLinearSurface {
        try LWSourceOwnedLinearSurface(width:width,height:height,maximumBytes:maximumBytes,
            workingSet:workingSet,pixels:pixels)
    }
    static func extent(width: Int, height: Int, maximumBytes: Int) throws -> Int {
        let (count, countOverflow) = width.multipliedReportingOverflow(by: height)
        let (bytes, byteOverflow) = count.multipliedReportingOverflow(by: MemoryLayout<SIMD4<Float>>.stride)
        guard width > 0, height > 0, width <= DocumentLimits.maxSide, height <= DocumentLimits.maxSide,
            !countOverflow, !byteOverflow, count <= DocumentLimits.maxSurfacePixels,
            maximumBytes > 0, bytes <= maximumBytes else { throw ProjectError.tooLarge }
        return count
    }
    func validate(maximumBytes: Int) throws {
        guard pixels.count == (try Self.extent(width:width, height:height, maximumBytes:maximumBytes)),
            pixels.allSatisfy({ $0.x.isFinite && $0.y.isFinite && $0.z.isFinite && $0.w.isFinite && (0...1).contains($0.w) }) else {
            throw ProjectError.invalid
        }
    }
    /// Premultiplied float transport for Core Image operators. CIMotionBlur does not premultiply a
    /// straight-alpha float CGImage: it blurs the stored RGB, so hidden RGB under zero alpha leaks
    /// into visible pixels. Range-backed planes already reach Core Image premultiplied
    /// (LWFloatPlaneImage); whole-surface operators use this so both paths read the same samples.
    func premultipliedCGImage() throws -> CGImage {
        try validate(maximumBytes: maximumBytes)
        let premultiplied = pixels.map { SIMD4($0.x * $0.w, $0.y * $0.w, $0.z * $0.w, $0.w) }
        let data = premultiplied.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
            let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
            let image = CGImage(width:width, height:height, bitsPerComponent:32, bitsPerPixel:128,
                bytesPerRow:width * 16, space:color,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue).union(.floatComponents).union(.byteOrder32Little),
                provider:provider, decode:nil, shouldInterpolate:false, intent:.relativeColorimetric) else { throw ProjectError.encode }
        return image
    }
    func cgImage() throws -> CGImage {
        try validate(maximumBytes: maximumBytes)
        let data = pixels.withUnsafeBytes { Data($0) }
        guard let provider = CGDataProvider(data: data as CFData),
            let color = CGColorSpace(name: CGColorSpace.extendedLinearSRGB),
            let image = CGImage(width:width, height:height, bitsPerComponent:32, bitsPerPixel:128,
                bytesPerRow:width * 16, space:color,
                bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue).union(.floatComponents).union(.byteOrder32Little),
                provider:provider, decode:nil, shouldInterpolate:false, intent:.relativeColorimetric) else { throw ProjectError.encode }
        return image
    }
    static func render(_ image: CIImage, width: Int, height: Int, maximumBytes: Int) throws -> Self {
        let count = try extent(width:width, height:height, maximumBytes:maximumBytes)
        guard let color = CGColorSpace(name:CGColorSpace.extendedLinearSRGB) else { throw ProjectError.invalid }
        var pixels = [SIMD4<Float>](repeating:.zero, count:count)
        let context = CIContext(options:[.workingColorSpace:color, .outputColorSpace:color,
            .workingFormat:CIFormat.RGBAf.rawValue, .cacheIntermediates:false])
        pixels.withUnsafeMutableBytes { raw in
            context.render(image, toBitmap:raw.baseAddress!, rowBytes:width * 16,
                bounds:CGRect(x:0,y:0,width:width,height:height), format:.RGBAf, colorSpace:color)
        }
        // Core Image returns premultiplied RGBA. Only this explicit boundary unpremultiplies.
        // Convolutions (motion/Gaussian blur over opaque input) sum many weighted alphas in float
        // and can land a few ulps above one; that rounding is clamped, a real excess still refuses.
        for index in pixels.indices {
            let alpha = pixels[index].w
            if alpha > 0 {
                pixels[index].x /= alpha; pixels[index].y /= alpha; pixels[index].z /= alpha
                if alpha > 1, alpha <= 1 + 1e-4 { pixels[index].w = 1 }
            }
            else { pixels[index] = .zero }
        }
        return try Self(width:width, height:height, pixels:pixels, maximumBytes:maximumBytes)
    }
}

/// Persisted source→developed transform used by geometry, retouch and mask coordinates.
nonisolated struct LWSourceCoordinateMap: Codable, Equatable, Sendable {
    let values: [Double]
    static let identity = try! Self([1,0,0,0,1,0,0,0,1])
    init(_ values: [Double]) throws {
        guard values.count == 9, values.allSatisfy(\.isFinite) else { throw ProjectError.invalid }
        self.values = values
        guard determinant.isFinite, determinant != 0 else { throw ProjectError.invalid }
    }
    init(from decoder: any Decoder) throws { try self.init(decoder.singleValueContainer().decode([Double].self)) }
    func encode(to encoder: any Encoder) throws { var c = encoder.singleValueContainer(); try c.encode(values) }
    private var determinant: Double {
        let a = values
        return a[0]*(a[4]*a[8]-a[5]*a[7])-a[1]*(a[3]*a[8]-a[5]*a[6])+a[2]*(a[3]*a[7]-a[4]*a[6])
    }
    func map(_ point: CGPoint) throws -> CGPoint {
        let a = values, x = Double(point.x), y = Double(point.y)
        let denominator = a[6]*x+a[7]*y+a[8]
        guard x.isFinite, y.isFinite, denominator.isFinite, denominator != 0 else { throw ProjectError.invalid }
        let result = CGPoint(x:(a[0]*x+a[1]*y+a[2])/denominator, y:(a[3]*x+a[4]*y+a[5])/denominator)
        guard result.x.isFinite, result.y.isFinite else { throw ProjectError.invalid }
        return result
    }
    func inverse() throws -> Self {
        let a = values, d = determinant
        return try Self([(a[4]*a[8]-a[5]*a[7])/d,(a[2]*a[7]-a[1]*a[8])/d,(a[1]*a[5]-a[2]*a[4])/d,
            (a[5]*a[6]-a[3]*a[8])/d,(a[0]*a[8]-a[2]*a[6])/d,(a[2]*a[3]-a[0]*a[5])/d,
            (a[3]*a[7]-a[4]*a[6])/d,(a[1]*a[6]-a[0]*a[7])/d,(a[0]*a[4]-a[1]*a[3])/d])
    }
}

nonisolated extension LWLinearSurface {
    /// Package-owned exact samples; this is never a browse image or source original.
    func packageData(maximumFileBytes: Int) throws -> Data {
        try validate(maximumBytes:maximumFileBytes - 24)
        var data = Data("LWRA32F1".utf8)
        func word<T:FixedWidthInteger>(_ value:T) { var v = value.littleEndian; withUnsafeBytes(of:&v) { data.append(contentsOf:$0) } }
        word(UInt32(width)); word(UInt32(height)); word(UInt64(byteLength))
        for pixel in pixels { for channel in 0..<4 { word(pixel[channel].bitPattern) } }
        guard data.count <= maximumFileBytes else { throw ProjectError.tooLarge }
        return data
    }
    static func package(_ data:Data, maximumFileBytes:Int) throws -> Self {
        guard data.count >= 24, data.count <= maximumFileBytes, data.prefix(8) == Data("LWRA32F1".utf8) else { throw ProjectError.invalid }
        func word(_ offset:Int,_ count:Int) -> UInt64 { (0..<count).reduce(0) { $0 | UInt64(data[offset+$1]) << (8*$1) } }
        let width = Int(word(8,4)), height = Int(word(12,4)), bytes = word(16,8)
        let count = try extent(width:width,height:height,maximumBytes:maximumFileBytes - 24)
        guard bytes == UInt64(count * 16), bytes == UInt64(data.count - 24) else { throw ProjectError.invalid }
        var pixels = [SIMD4<Float>](); pixels.reserveCapacity(count)
        for offset in stride(from:24,to:data.count,by:16) {
            pixels.append(SIMD4(Float(bitPattern:UInt32(word(offset,4))),Float(bitPattern:UInt32(word(offset+4,4))),
                Float(bitPattern:UInt32(word(offset+8,4))),Float(bitPattern:UInt32(word(offset+12,4)))))
        }
        return try Self(width:width,height:height,pixels:pixels,maximumBytes:maximumFileBytes-24)
    }
}
nonisolated extension ImportedImage {
    init(linear:LWLinearSurface, name:String) throws {
        let image = try linear.cgImage()
        self.init(image:image,thumbnail:try PixelAdjust.thumbnail(of:image),name:name,linear:linear)
    }
}

nonisolated extension LWLinearSurface {
    static func context(width:Int, height:Int, maximumBytes:Int) throws -> CGContext {
        _ = try extent(width:width,height:height,maximumBytes:maximumBytes)
        guard let color = CGColorSpace(name:CGColorSpace.extendedLinearSRGB),
            let context = CGContext(data:nil,width:width,height:height,bitsPerComponent:32,bytesPerRow:width*16,
                space:color,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { throw ExportError.render }
        return context
    }
    static func read(_ image:CGImage, maximumBytes:Int) throws -> Self {
        try render(CIImage(cgImage:image),width:image.width,height:image.height,maximumBytes:maximumBytes)
    }
    static func blend(_ adjusted:Self, over original:Self, selection:SelectionClip, mapping:CGAffineTransform) throws -> Self {
        guard adjusted.width == original.width, adjusted.height == original.height else { throw ProjectError.invalid }
        let mask = try PixelAdjust.coverage(selection,width:adjusted.width,height:adjusted.height,pixelToDocument:mapping)
        let image = CIImage(cgImage:try adjusted.cgImage()).applyingFilter("CIBlendWithMask",parameters:[
            kCIInputBackgroundImageKey:CIImage(cgImage:try original.cgImage()),kCIInputMaskImageKey:CIImage(cgImage:mask)])
        return try render(image,width:adjusted.width,height:adjusted.height,maximumBytes:adjusted.maximumBytes)
    }
}

nonisolated extension LWLinearSurface {
    /// Integer codecs cannot carry scene-linear HDR. Clipping/quantization occurs
    /// only at this named output boundary; working/document samples stay exact.
    func integerOutput(bits:Int,colorSpace:CGColorSpace) throws -> CGImage {
        guard bits == 8 || bits == 16 else { throw ProjectError.invalid }
        try validate(maximumBytes:maximumBytes)
        let outputBytes=width*height*4*(bits/8)
        guard outputBytes <= maximumBytes-byteLength else { throw ProjectError.tooLarge }
        guard let context=CGContext(data:nil,width:width,height:height,bitsPerComponent:bits,
              bytesPerRow:width*4*(bits/8),space:colorSpace,
              bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue | (bits == 16 ? CGBitmapInfo.byteOrder16Little.rawValue : 0)) else { throw ExportError.render }
        context.draw(try cgImage(),in:CGRect(x:0,y:0,width:width,height:height))
        guard let output=context.makeImage() else { throw ExportError.render };return output
    }
}

nonisolated extension LWLinearSurface {
    /// Header/extent validation without allocating or decoding a pixel array.
    static func packageExtent(_ data:Data,maximumFileBytes:Int) throws -> (width:Int,height:Int) {
        guard data.count >= 24,data.count <= maximumFileBytes,data.prefix(8) == Data("LWRA32F1".utf8) else { throw ProjectError.invalid }
        func word(_ offset:Int,_ count:Int)->UInt64 { (0..<count).reduce(0) { $0 | UInt64(data[offset+$1]) << (8*$1) } }
        let width=Int(word(8,4)),height=Int(word(12,4))
        let count=try extent(width:width,height:height,maximumBytes:maximumFileBytes-24)
        guard word(16,8) == UInt64(count*16),data.count-24 == count*16 else { throw ProjectError.invalid }
        // Every packaged sample is finite straight RGBA with alpha in 0...1.
        for offset in stride(from:24,to:data.count,by:16) {
            let pixel=SIMD4(Float(bitPattern:UInt32(word(offset,4))),Float(bitPattern:UInt32(word(offset+4,4))),
                Float(bitPattern:UInt32(word(offset+8,4))),Float(bitPattern:UInt32(word(offset+12,4))))
            guard pixel.x.isFinite,pixel.y.isFinite,pixel.z.isFinite,pixel.w.isFinite,(0...1).contains(pixel.w) else { throw ProjectError.invalid }
        }
        return (width,height)
    }
}

nonisolated extension LWLinearSurface {
    static func readColor(red:Double,green:Double,blue:Double) throws -> SIMD3<Float> {
        let lease=try LWFloatWorkingSet.sourceGraphs.reserve(128)
        guard let space=CGColorSpace(name:CGColorSpace.sRGB),let context=CGContext(data:nil,width:1,height:1,bitsPerComponent:32,bytesPerRow:16,
            space:space,bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.floatComponents.rawValue|CGBitmapInfo.byteOrder32Little.rawValue) else { throw ProjectError.invalid }
        context.setFillColor(CGColor(colorSpace:space,components:[CGFloat(red),CGFloat(green),CGFloat(blue),1])!)
        context.fill(CGRect(x:0,y:0,width:1,height:1))
        guard let image=context.makeImage() else { throw ProjectError.invalid }
        let p=try read(image,maximumBytes:64).pixels[0];withExtendedLifetime(lease) {}
        return SIMD3(p.x,p.y,p.z)
    }
}


/// An immutable resident compatibility boundary, separate from mutable reference
/// kernels. There is no naked Array getter, mutable subscript, or uncharged COW path.
/// Every collection value and Slice retains the actual private allocation owner.
nonisolated struct LWSourceOwnedLinearSurface: Sendable {
    fileprivate final class Storage: @unchecked Sendable {
        private let buffer:UnsafeMutablePointer<SIMD4<Float>>
        let count:Int
        let charge:LWFloatWorkingSet.Lease
        private init(buffer:UnsafeMutablePointer<SIMD4<Float>>,count:Int,charge:LWFloatWorkingSet.Lease) {
            self.buffer=buffer;self.count=count;self.charge=charge
        }
        static func make(count:Int,charge:LWFloatWorkingSet.Lease,pixel:(Int)throws->SIMD4<Float>) throws -> Storage {
            let buffer=UnsafeMutablePointer<SIMD4<Float>>.allocate(capacity:count)
            var initialized=0
            do {
                for index in 0..<count {
                    try Task.checkCancellation()
                    let value=try pixel(index)
                    guard value.x.isFinite,value.y.isFinite,value.z.isFinite,value.w.isFinite,(0...1).contains(value.w) else { throw ProjectError.invalid }
                    buffer.advanced(by:index).initialize(to:value);initialized+=1
                }
                return Storage(buffer:buffer,count:count,charge:charge)
            } catch { buffer.deinitialize(count:initialized);buffer.deallocate();throw error }
        }
        subscript(index:Int)->SIMD4<Float> { precondition((0..<count).contains(index));return buffer[index] }
        func provider() throws -> CGDataProvider {
            let retained=Unmanaged.passRetained(self).toOpaque()
            guard let provider=CGDataProvider(dataInfo:retained,data:buffer,size:count*16,releaseData:{ info,_,_ in
                if let info { Unmanaged<Storage>.fromOpaque(info).release() }
            }) else { Unmanaged<Storage>.fromOpaque(retained).release();throw ProjectError.encode }
            return provider
        }
        deinit { buffer.deinitialize(count:count);buffer.deallocate() }
    }
    struct Pixels: RandomAccessCollection, Sendable, Equatable {
        typealias Index=Int
        fileprivate let storage:Storage
        var startIndex:Int { 0 }
        var endIndex:Int { storage.count }
        func index(after index:Int)->Int { index+1 }
        func index(before index:Int)->Int { index-1 }
        subscript(index:Int)->SIMD4<Float> { storage[index] }
        static func ==(lhs:Self,rhs:Self)->Bool { lhs.elementsEqual(rhs) }
        static func ==(lhs:Self,rhs:[SIMD4<Float>])->Bool { lhs.elementsEqual(rhs) }
        static func ==(lhs:[SIMD4<Float>],rhs:Self)->Bool { lhs.elementsEqual(rhs) }
        static func !=(lhs:Self,rhs:[SIMD4<Float>])->Bool { !(lhs == rhs) }
        static func !=(lhs:[SIMD4<Float>],rhs:Self)->Bool { !(lhs == rhs) }
    }
    let width:Int
    let height:Int
    let maximumBytes:Int
    let workingSet:LWFloatWorkingSet
    let pixels:Pixels
    var byteLength:Int { pixels.count*MemoryLayout<SIMD4<Float>>.stride }
    fileprivate init(width:Int,height:Int,maximumBytes:Int,workingSet:LWFloatWorkingSet,
        pixels:(Int)throws->SIMD4<Float>) throws {
        let count=try LWLinearSurface.extent(width:width,height:height,maximumBytes:maximumBytes)
        let charge=try workingSet.reserve(count*MemoryLayout<SIMD4<Float>>.stride)
        let storage=try Storage.make(count:count,charge:charge,pixel:pixels)
        self.width=width;self.height=height;self.maximumBytes=maximumBytes;self.workingSet=workingSet
        self.pixels=Pixels(storage:storage)
    }
    func validate(maximumBytes:Int) throws {
        guard maximumBytes > 0,byteLength <= maximumBytes,
            pixels.count == (try LWLinearSurface.extent(width:width,height:height,maximumBytes:maximumBytes)) else { throw ProjectError.tooLarge }
    }
    /// A mutation is a separately charged immutable successor, never COW growth
    /// under the predecessor lease. Reservation precedes every transform callback.
    func replacingPixels(_ transform:(Int,SIMD4<Float>)throws->SIMD4<Float>) throws -> Self {
        try Self(width:width,height:height,maximumBytes:maximumBytes,workingSet:workingSet) { try transform($0,pixels[$0]) }
    }
    /// The direct provider retains the exact allocation/lease until the framework
    /// releases its last image/provider alias; no naked Data copy escapes ownership.
    func cgImage() throws -> CGImage {
        try validate(maximumBytes:maximumBytes)
        guard let color=CGColorSpace(name:CGColorSpace.extendedLinearSRGB),
            let image=CGImage(width:width,height:height,bitsPerComponent:32,bitsPerPixel:128,bytesPerRow:width*16,
                space:color,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.last.rawValue).union(.floatComponents).union(.byteOrder32Little),
                provider:try pixels.storage.provider(),decode:nil,shouldInterpolate:false,intent:.relativeColorimetric) else { throw ProjectError.encode }
        return image
    }
    /// Build bounded rows from immutable values. The copy lease exists before each
    /// Array allocation and survives append; the returned plane owns its own backing.
    func plane(workspace:LWFloatWorkspace) throws -> LWFloatPlane {
        guard workspace.workingSet === workingSet else { throw ProjectError.invalid }
        try validate(maximumBytes:maximumBytes)
        let builder=try workspace.makeBuilder(width:width,height:height)
        while let range=builder.nextRange {
            try workspace.cancellation.check()
            let bytes=try range.validate(frameWidth:width,frameHeight:height)
            let charge=try workingSet.reserve(bytes)
            var copied=[SIMD4<Float>]();copied.reserveCapacity(bytes/16)
            for y in range.y..<(range.y+range.height) {
                for x in range.x..<(range.x+range.width) { copied.append(pixels[y*width+x]) }
            }
            try builder.append(LWLinearSurface(width:range.width,height:range.height,pixels:copied,maximumBytes:bytes),at:range)
            withExtendedLifetime(charge) {}
        }
        return try builder.finish()
    }
}
