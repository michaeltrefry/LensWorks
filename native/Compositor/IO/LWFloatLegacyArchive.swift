import Foundation
import CryptoKit
import Darwin

/// The compact LWRA32F1 compatibility backing is read through the same bounded
/// tile ownership as current planes. Neither its encoded file nor a whole f32
/// array is retained in native memory. Originals are never changed or retired.
nonisolated enum LWFloatLegacyArchive {
    static func read(from file:URL,maximumFileBytes:Int,workspace:LWFloatWorkspace,
        makeBuilder:((Int,Int)throws->LWFloatPlane.Builder)? = nil)throws->LWFloatPlane {
        guard file.isFileURL,file.hasNormalizedPath,file.isUnaliasedFilePath,
            maximumFileBytes > 24,maximumFileBytes <= LWSourceDeveloper.maximumResultBytes else { throw ProjectError.invalid }
        let parent=try LWFloatDirectoryChain(file.deletingLastPathComponent())
        let fd=openat(parent.fd,file.lastPathComponent,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else { throw ProjectError.invalid };defer{close(fd)}
        func identity()throws->stat {
            try parent.check();try workspace.cancellation.check();try Task.checkCancellation()
            var held=stat(),named=stat()
            guard fstat(fd,&held)==0,fstatat(parent.fd,file.lastPathComponent,&named,AT_SYMLINK_NOFOLLOW)==0,
                held.st_dev==named.st_dev,held.st_ino==named.st_ino,(held.st_mode&S_IFMT)==S_IFREG,
                held.st_uid==getuid(),held.st_nlink==1,held.st_size>=24,held.st_size<=off_t(maximumFileBytes),
                held.st_size==named.st_size,held.st_mode==named.st_mode,
                held.st_mtimespec.tv_sec==named.st_mtimespec.tv_sec,held.st_mtimespec.tv_nsec==named.st_mtimespec.tv_nsec,
                held.st_ctimespec.tv_sec==named.st_ctimespec.tv_sec,held.st_ctimespec.tv_nsec==named.st_ctimespec.tv_nsec else { throw ProjectError.invalid }
            return held
        }
        func same(_ a:stat,_ b:stat)->Bool {
            a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size && a.st_mode==b.st_mode &&
            a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec&&a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec
        }
        func fill(_ data:inout Data,at offset:Int)throws {
            try data.withUnsafeMutableBytes { raw in
                var copied=0
                while copied<raw.count {
                    try workspace.cancellation.check();try Task.checkCancellation()
                    let n=pread(fd,raw.baseAddress!.advanced(by:copied),raw.count-copied,off_t(offset+copied))
                    if n<0&&errno==EINTR{continue};guard n>0 else {throw ProjectError.invalid};copied += n
                }
            }
        }
        let before=try identity()
        func wholeHash()throws->SHA256.Digest {
            let lease=try workspace.workingSet.reserve(1024*1024)
            var data=Data(count:1024*1024),hash=SHA256(),position=0
            while position<Int(before.st_size){
                let amount=min(data.count,Int(before.st_size)-position)
                // A fixed reusable buffer; the final short read hashes no stale tail.
                try data.withUnsafeMutableBytes { raw in
                    var copied=0;while copied<amount {
                        try workspace.cancellation.check();try Task.checkCancellation()
                        let n=pread(fd,raw.baseAddress!.advanced(by:copied),amount-copied,off_t(position+copied))
                        if n<0&&errno==EINTR{continue};guard n>0 else {throw ProjectError.invalid};copied += n
                    }
                    hash.update(bufferPointer:UnsafeRawBufferPointer(start:raw.baseAddress,count:amount))
                };position += amount
            }
            var extra:UInt8=0;guard pread(fd,&extra,1,before.st_size)==0,same(before,try identity()) else {throw ProjectError.invalid}
            withExtendedLifetime(lease) {};return hash.finalize()
        }
        let originalHash=try wholeHash(),headerLease=try workspace.workingSet.reserve(24)
        var header=Data(count:24);try fill(&header,at:0)
        guard header.prefix(8)==Data("LWRA32F1".utf8) else {throw ProjectError.invalid}
        func word(_ position:Int,_ count:Int)->UInt64{(0..<count).reduce(0){$0|UInt64(header[position+$1])<<(8*$1)}}
        let width=Int(word(8,4)),height=Int(word(12,4)),length=word(16,8)
        try LWFloatPlane.validateExtent(width:width,height:height)
        let pixels=width.multipliedReportingOverflow(by:height),bytes=pixels.partialValue.multipliedReportingOverflow(by:16)
        guard !pixels.overflow,!bytes.overflow,length==UInt64(bytes.partialValue),
            before.st_size==off_t(bytes.partialValue+24) else {throw ProjectError.invalid}
        let builder=try makeBuilder?(width,height) ?? workspace.makeBuilder(width:width,height:height)
        guard builder.width==width,builder.height==height,builder.workingSet===workspace.workingSet else {throw ProjectError.invalid}
        while let range=builder.nextRange {
            guard same(before,try identity()) else {throw ProjectError.invalid}
            let bytes=try range.validate(frameWidth:width,frameHeight:height)
            let lease=try workspace.workingSet.reserve(bytes*2)
            var data=Data(count:bytes),samples=[SIMD4<Float>]();samples.reserveCapacity(bytes/16)
            for row in 0..<range.height {
                try workspace.cancellation.check();try Task.checkCancellation()
                let offset=24+((range.y+row)*width+range.x)*16,rowBytes=range.width*16
                try data.withUnsafeMutableBytes { raw in
                    var copied=0;while copied<rowBytes {
                        try workspace.cancellation.check();try Task.checkCancellation()
                        let n=pread(fd,raw.baseAddress!.advanced(by:row*rowBytes+copied),rowBytes-copied,off_t(offset+copied))
                        if n<0&&errno==EINTR{continue};guard n>0 else {throw ProjectError.invalid};copied += n
                    }
                }
            }
            try data.withUnsafeBytes { raw in
                for i in stride(from:0,to:bytes,by:16) {
                    if i % 65536 == 0 { try workspace.cancellation.check();try Task.checkCancellation() }
                    func value(_ channel:Int)->Float{Float(bitPattern:UInt32(littleEndian:raw.loadUnaligned(fromByteOffset:i+channel*4,as:UInt32.self)))}
                    samples.append(SIMD4(value(0),value(1),value(2),value(3)))
                }
            }
            try builder.append(LWLinearSurface(width:range.width,height:range.height,pixels:samples,maximumBytes:bytes),at:range)
            withExtendedLifetime(lease) {}
        }
        guard originalHash==((try wholeHash())),same(before,try identity()) else {throw ProjectError.invalid}
        let plane=try builder.finish();withExtendedLifetime(headerLease) {};return plane
    }
}
