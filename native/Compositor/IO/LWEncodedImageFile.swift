import Foundation
import CoreGraphics
import CryptoKit
import Darwin

/// A streamed codec result, owned by one private graph workspace. The codec's
/// callback writes the held exclusive file; no whole encoded image Data is built.
nonisolated final class LWEncodedImageFile: @unchecked Sendable {
    let sourceProtection: LWSourceDestinationAuthority?
    let workspace: LWFloatWorkspace
    let directory: URL
    let url: URL
    private let chain: LWFloatDirectoryChain
    private let descriptor: Int32
    private let lifetime: LWFloatWorkspace.ChildLifetime
    private let name = "encoded-image"
    private let lock = NSLock()
    private var failure: Error?
    private var sealed: stat?
    private(set) var byteCount = 0
    private(set) var sha256 = ""

    init(workspace: LWFloatWorkspace, sourceProtection: LWSourceDestinationAuthority? = nil) throws {
        self.sourceProtection=sourceProtection; self.workspace=workspace; directory=try workspace.makeScratchDirectory()
        lifetime = try workspace.retainChild(directory)
        url=directory.appendingPathComponent(name);chain=try LWFloatDirectoryChain(directory)
        descriptor=openat(chain.fd,name,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard descriptor >= 0 else { throw ExportError.encode }
        do { try workspace.registerCreatedFile(directory:directory,name:name,descriptor:descriptor) }
        catch { close(descriptor);throw error }
    }
    deinit {
        // A failed codec still leaves only a registered, held partial member.
        if sealed == nil { try? workspace.captureWrittenFile(directory:directory,name:name,descriptor:descriptor) }
        close(descriptor)
    }
    func consumer() throws -> CGDataConsumer {
        let retained=Unmanaged.passRetained(self)
        var callbacks=CGDataConsumerCallbacks(putBytes:{ info,bytes,count in
            guard let info else { return 0 }
            let owner=Unmanaged<LWEncodedImageFile>.fromOpaque(info).takeUnretainedValue()
            do { return try owner.accept(bytes,count:count) }
            catch { owner.lock.withLock { if owner.failure == nil { owner.failure=error } };return 0 }
        },releaseConsumer:{ info in if let info { Unmanaged<LWEncodedImageFile>.fromOpaque(info).release() } })
        guard let result=CGDataConsumer(info:retained.toOpaque(),cbks:&callbacks) else { retained.release();throw ExportError.encode }
        return result
    }
    private func accept(_ bytes:UnsafeRawPointer,count:Int) throws -> Int {
        try workspace.cancellation.check()
        return try lock.withLock {
            guard sealed == nil,failure == nil,count >= 0 else { throw ExportError.encode }
            var offset=0
            while offset<count {
                try workspace.cancellation.check()
                let n=Darwin.write(descriptor,bytes.advanced(by:offset),count-offset)
                if n<0 && errno == EINTR { continue }
                guard n>0 else { throw ExportError.encode };offset+=n
            }
            return offset
        }
    }
    /// Same held exclusive writer for bounded decoded display rows. This does
    /// not expose the file descriptor or allow writes after finish.
    func appendOwnedBytes(_ bytes:UnsafeRawBufferPointer) throws {
        guard bytes.count <= 8192*64*4,let pointer=bytes.baseAddress else { throw ExportError.encode }
        guard try accept(pointer,count:bytes.count)==bytes.count else { throw ExportError.encode }
    }
    /// The final provider borrows its caller-owned output buffer. Read in bounded
    /// ranges and recheck held/named identity; no whole-file Data allocation.
    func copyOwnedBytes(into output:UnsafeMutableRawPointer,position:off_t,count:Int) throws -> Int {
        try workspace.cancellation.check()
        guard let expected=sealed,unchanged(expected,try identity()),position>=0,
            let start=Int(exactly:position),start<=byteCount,count>=0 else { throw ExportError.encode }
        let requested=min(count,byteCount-start)
        var offset=0
        while offset<requested {
            try workspace.cancellation.check()
            let n=pread(descriptor,output.advanced(by:offset),min(64*1024,requested-offset),position+off_t(offset))
            if n<0 && errno==EINTR { continue };guard n>0 else { throw ExportError.encode };offset+=n
        }
        guard unchanged(expected,try identity()) else { throw ExportError.encode }
        try workspace.cancellation.check();return offset
    }
    private func identity() throws -> stat {
        try chain.check()
        var held=stat(),named=stat()
        guard fstat(descriptor,&held)==0,fstatat(chain.fd,name,&named,AT_SYMLINK_NOFOLLOW)==0,
            (held.st_mode&S_IFMT)==S_IFREG,held.st_uid==getuid(),held.st_nlink==1,
            held.st_dev==named.st_dev,held.st_ino==named.st_ino,held.st_size==named.st_size,
            held.st_mode==named.st_mode,held.st_size>=0,
            held.st_mtimespec.tv_sec==named.st_mtimespec.tv_sec,held.st_mtimespec.tv_nsec==named.st_mtimespec.tv_nsec,
            held.st_ctimespec.tv_sec==named.st_ctimespec.tv_sec,held.st_ctimespec.tv_nsec==named.st_ctimespec.tv_nsec else { throw ExportError.encode }
        return held
    }
    private func unchanged(_ a:stat,_ b:stat) -> Bool {
        a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_mode==b.st_mode && a.st_size==b.st_size &&
            a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec &&
            a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec
    }
    @discardableResult func finish(validate:() throws -> Void) throws -> LWEncodedImageFile {
        try validate();try workspace.cancellation.check()
        if let failure=lock.withLock({failure}) { throw failure }
        guard sealed == nil,fsync(descriptor)==0,fchmod(descriptor,0o444)==0,fsync(descriptor)==0,fsync(chain.fd)==0 else { throw ExportError.encode }
        let before=try identity();guard before.st_size>0,let count=Int(exactly:before.st_size) else { throw ExportError.encode }
        let digest=try readChunks { _ in }
        guard unchanged(before,try identity()) else { throw ExportError.encode }
        try workspace.captureWrittenFile(directory:directory,name:name,descriptor:descriptor)
        sealed=before;byteCount=count;sha256=digest;return self
    }
    private func readChunks(_ consume:(UnsafeRawBufferPointer) throws -> Void) throws -> String {
        let before=try identity(),lease=try workspace.workingSet.reserve(64*1024)
        var buffer=Data(count:64*1024),offset:off_t=0,hash=SHA256()
        while offset<before.st_size {
            try workspace.cancellation.check();try Task.checkCancellation()
            let request=min(buffer.count,Int(before.st_size-offset))
            let n=buffer.withUnsafeMutableBytes { pread(descriptor,$0.baseAddress!,request,offset) }
            if n<0 && errno==EINTR { continue }
            guard n>0 else { throw ExportError.encode }
            try buffer.withUnsafeBytes { raw in
                let chunk=UnsafeRawBufferPointer(start:raw.baseAddress,count:n)
                hash.update(bufferPointer:chunk);try consume(chunk)
            }
            offset+=off_t(n)
        }
        var extra:UInt8=0;guard pread(descriptor,&extra,1,offset)==0,unchanged(before,try identity()) else { throw ExportError.encode }
        withExtendedLifetime(lease) {}
        return hash.finalize().map { String(format:"%02x",$0) }.joined()
    }
    func check() throws {
        try workspace.cancellation.check()
        guard let expected=sealed,unchanged(expected,try identity()),try readChunks({ _ in })==sha256 else { throw ExportError.encode }
    }
    /// Bounded reference/test API only. The allocation lease travels with Data's
    /// custom deallocator; public full-resolution exports use publish instead.
    func data() throws -> Data {
        try check();let lease=try workspace.workingSet.reserve(byteCount)
        let pointer=UnsafeMutableRawPointer.allocate(byteCount:byteCount,alignment:16)
        do {
            var offset=0
            let digest=try readChunks { chunk in
                pointer.advanced(by:offset).copyMemory(from:chunk.baseAddress!,byteCount:chunk.count);offset+=chunk.count
            }
            guard offset==byteCount,digest==sha256 else { throw ExportError.encode }
            return Data(bytesNoCopy:pointer,count:byteCount,deallocator:.custom { pointer,_ in pointer.deallocate();withExtendedLifetime(lease) {} })
        } catch { pointer.deallocate();throw error }
    }
    func publish(to destination:URL,workingVersion:LensWorksWorkingVersion?) throws {
        try sourceProtection?.validate(destination);try workingVersion?.validateDestination(destination);try check()
        var coordinationError:NSError?,writeError:Error?
        NSFileCoordinator().coordinate(writingItemAt:destination,options:.forReplacing,error:&coordinationError) { target in
            do {
                try sourceProtection?.validate(target);try workingVersion?.validateDestination(target)
                let parent=target.deletingLastPathComponent().resolvingSymlinksInPath().standardizedFileURL
                let parentChain=try LWFloatDirectoryChain(parent)
                let targetName=target.lastPathComponent
                guard !targetName.isEmpty,targetName != ".",targetName != ".." else { throw ProjectError.invalid }
                var prior=stat();errno=0
                let exists=fstatat(parentChain.fd,targetName,&prior,AT_SYMLINK_NOFOLLOW)==0
                guard exists ? (prior.st_mode&S_IFMT)==S_IFREG : errno==ENOENT else { throw ProjectError.invalid }
                let stage=".LensWorks-export-"+UUID().uuidString.lowercased()
                let output=openat(parentChain.fd,stage,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
                guard output>=0 else { throw ExportError.encode }
                var birth=stat();guard fstat(output,&birth)==0 else { close(output);throw ExportError.encode }
                var published=false
                defer {
                    if !published {
                        var held=stat(),named=stat()
                        if fstat(output,&held)==0,fstatat(parentChain.fd,stage,&named,AT_SYMLINK_NOFOLLOW)==0,
                            held.st_dev==birth.st_dev,held.st_ino==birth.st_ino,named.st_dev==held.st_dev,named.st_ino==held.st_ino,held.st_nlink==1 {
                            _=unlinkat(parentChain.fd,stage,0)
                        }
                    }
                    close(output)
                }
                let digest=try readChunks { raw in
                    var offset=0
                    while offset<raw.count {
                        try workspace.cancellation.check()
                        let n=Darwin.write(output,raw.baseAddress!.advanced(by:offset),raw.count-offset)
                        if n<0 && errno==EINTR { continue };guard n>0 else { throw ExportError.encode };offset+=n
                    }
                }
                guard digest==sha256,fsync(output)==0,fchmod(output,0o644)==0 else { throw ExportError.encode }
                try check();try parentChain.check();try sourceProtection?.validate(target);try workingVersion?.validateDestination(target)
                var named=stat(),held=stat()
                guard fstat(output,&held)==0,fstatat(parentChain.fd,stage,&named,AT_SYMLINK_NOFOLLOW)==0,
                    held.st_dev==birth.st_dev,held.st_ino==birth.st_ino,named.st_dev==held.st_dev,named.st_ino==held.st_ino,
                    held.st_nlink==1,held.st_size==byteCount else { throw ExportError.encode }
                guard renameat(parentChain.fd,stage,parentChain.fd,targetName)==0 else { throw ExportError.encode }
                published=true;guard fsync(parentChain.fd)==0 else { throw ExportError.encode }
                try parentChain.check()
            } catch { writeError=error }
        }
        if let error=coordinationError ?? writeError { throw error }
    }
}
