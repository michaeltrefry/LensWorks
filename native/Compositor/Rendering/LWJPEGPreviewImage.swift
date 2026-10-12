import Foundation
import CoreGraphics

/// A decoded JPEG display image retains its exact private byte generation through
/// its provider, including independent CGImage aliases. ImageIO's admitted input
/// thumbnail is temporary; no second whole-frame native buffer is required.
nonisolated final class LWJPEGPreviewImage: @unchecked Sendable {
    static let failureNotification=Notification.Name("LensWorks.JPEGPreviewProviderFailure")
    let file:LWEncodedImageFile
    let width:Int
    let height:Int
    private let owner:LWFloatWorkingSet.Lease
    private let lock=NSLock()
    private var failure:Error?
    private init(file:LWEncodedImageFile,width:Int,height:Int,owner:LWFloatWorkingSet.Lease) {
        self.file=file;self.width=width;self.height=height;self.owner=owner
    }
    static func materialize(_ source:CGImage,workspace:LWFloatWorkspace,validate:()throws->Void) throws -> Self {
        guard (1...8192).contains(source.width),(1...8192).contains(source.height),
            let color=CGColorSpace(name:CGColorSpace.sRGB) else { throw ExportError.encode }
        try validate();try workspace.cancellation.check()
        let owner=try workspace.workingSet.reserve(1024)
        let file=try LWEncodedImageFile(workspace:workspace),stride=source.width*4
        for y in Swift.stride(from:0,to:source.height,by:64) {
            try workspace.cancellation.check()
            let height=min(64,source.height-y),bytes=stride*height
            let lease=try workspace.workingSet.reserve(bytes*3)
            var row=Data(count:bytes)
            try row.withUnsafeMutableBytes { raw in
                guard let pointer=raw.baseAddress,
                    let context=CGContext(data:pointer,width:source.width,height:height,bitsPerComponent:8,
                        bytesPerRow:stride,space:color,
                        bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue) else { throw ExportError.render }
                context.setBlendMode(.copy);context.interpolationQuality = .none
                // CGContext/CGImage lower-left coordinates: this chunk is the
                // exact top-to-bottom storage interval y..<y+height.
                context.translateBy(x:0,y:-CGFloat(source.height-y-height))
                context.draw(source,in:CGRect(x:0,y:0,width:source.width,height:source.height))
                try workspace.cancellation.check()
                try file.appendOwnedBytes(UnsafeRawBufferPointer(raw))
            }
            withExtendedLifetime(lease) {}
        }
        try file.finish(validate:validate)
        guard file.byteCount==stride*source.height else { throw ExportError.encode }
        return Self(file:file,width:source.width,height:source.height,owner:owner)
    }
    func check() throws {
        if let error=lock.withLock({failure}) { throw error }
        try file.check();withExtendedLifetime(owner) {}
    }
    private func fail(_ error:Error) {
        let first=lock.withLock { ()->Bool in guard failure==nil else { return false };failure=error;return true }
        // One bounded sticky event, never a per-row logger. The sheet observes
        // this on the main run loop and refuses Export; reference callers check.
        if first { NotificationCenter.default.post(name:Self.failureNotification,object:self) }
    }
    func image() throws -> CGImage {
        try check();let retained=Unmanaged.passRetained(self)
        var callbacks=CGDataProviderDirectCallbacks(version:0,getBytePointer:nil,releaseBytePointer:nil,
            getBytesAtPosition:{ info,output,position,count in
                guard let info else { return 0 }
                let owner=Unmanaged<LWJPEGPreviewImage>.fromOpaque(info).takeUnretainedValue()
                do { try owner.check();return try owner.file.copyOwnedBytes(into:output,position:position,count:count) }
                catch { owner.fail(error);return 0 }
            },releaseInfo:{ info in if let info { Unmanaged<LWJPEGPreviewImage>.fromOpaque(info).release() } })
        guard let provider=CGDataProvider(directInfo:retained.toOpaque(),size:off_t(width*height*4),callbacks:&callbacks) else {
            retained.release();throw ExportError.encode
        }
        guard let color=CGColorSpace(name:CGColorSpace.sRGB),
            let image=CGImage(width:width,height:height,bitsPerComponent:8,bitsPerPixel:32,bytesPerRow:width*4,
                space:color,bitmapInfo:CGBitmapInfo(rawValue:CGImageAlphaInfo.premultipliedLast.rawValue|CGBitmapInfo.byteOrder32Big.rawValue),
                provider:provider,decode:nil,shouldInterpolate:true,intent:.defaultIntent) else { throw ExportError.encode }
        return image
    }
}
