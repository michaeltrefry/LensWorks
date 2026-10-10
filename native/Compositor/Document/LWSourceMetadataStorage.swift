import Foundation
import Darwin
import CoreGraphics
import CryptoKit

/// Native retained metadata uses the same admission owner as source tiles. These
/// explicit data/collection/object allowances are admission accounting, not a
/// measurement of Foundation's allocator or whole-process RSS.
nonisolated final class LWSourceMetadataStorage: @unchecked Sendable {
    let capacity: Int
    let workingSet: LWFloatWorkingSet
    private let lease: LWFloatWorkingSet.Lease
    private let decodedPayload:Bool
    private let inheritedPayloadOwners:[LWSourceMetadataStorage]
    var payloadOwners:[LWSourceMetadataStorage] { decodedPayload ? [self]:inheritedPayloadOwners }
    var payloadOwnerCount:Int { decodedPayload ? 1:inheritedPayloadOwners.count }
    func forEachPayloadOwner(_ visit:(LWSourceMetadataStorage)->Void) {
        if decodedPayload { visit(self) } else { for owner in inheritedPayloadOwners { visit(owner) } }
    }
    init(bytes: Int, workingSet: LWFloatWorkingSet = .sourceGraphs,decodedPayload:Bool=false,
        payloadOwners:[LWSourceMetadataStorage]=[]) throws {
        try Task.checkCancellation()
        lease = try workingSet.reserve(LWSourceMetadataStorage.sum(bytes,(payloadOwners.isEmpty ? 0:LWSourceMetadataStorage.collectionBytes(count:payloadOwners.count,stride:MemoryLayout<LWSourceMetadataStorage>.stride))))
        capacity = bytes; self.workingSet = workingSet;self.decodedPayload=decodedPayload;inheritedPayloadOwners=payloadOwners
    }
    static func sum(_ a: Int, _ b: Int) throws -> Int {
        let n=a.addingReportingOverflow(b); guard a>=0,b>=0,!n.overflow else { throw ProjectError.tooLarge };return n.partialValue
    }
    static func product(_ a: Int, _ b: Int) throws -> Int {
        let n=a.multipliedReportingOverflow(by:b);guard a>=0,b>=0,!n.overflow else { throw ProjectError.tooLarge };return n.partialValue
    }
    static func collectionBytes(count: Int, stride: Int) throws -> Int {
        try sum(256,product(count,try sum(product(stride,2),128)))
    }
    /// Scan the already charged input without constructing JSON objects. Every
    /// value/container/string start admits a typed-object/decoder bookkeeping
    /// allowance; raw strings/data admit a second retained/copy allocation.
    static func decodingBytes(_ data: Data) throws -> Int {
        var tokens=0,inString=false,escaped=false,inScalar=false
        for (index,c) in data.enumerated() {
            if index % 4096 == 0 { try Task.checkCancellation() }
            if inString {
                if escaped { escaped=false } else if c==92 { escaped=true } else if c==34 { inString=false }
                continue
            }
            if c==34 { tokens=try sum(tokens,1);inString=true;inScalar=false }
            else if c==91 || c==123 { tokens=try sum(tokens,1);inScalar=false }
            else if c==93 || c==125 || c==44 || c==58 || c==32 || c==9 || c==10 || c==13 { inScalar=false }
            else if !inScalar { tokens=try sum(tokens,1);inScalar=true }
        }
        return try sum(4096,sum(product(data.count,2),product(tokens,256)))
    }
    static let decoderKey = CodingUserInfoKey(rawValue:"LensWorks.sourceMetadataAdmission")!
    static func decode<T: Decodable>(_ type: T.Type, from data: Data,
        workingSet: LWFloatWorkingSet = .sourceGraphs) throws -> (value:T, owner:LWSourceMetadataStorage) {
        let owner=try LWSourceMetadataStorage(bytes:decodingBytes(data),workingSet:workingSet,decodedPayload:true)
        let decoder=JSONDecoder();decoder.userInfo[decoderKey]=owner
        let value=try decoder.decode(type,from:data);try Task.checkCancellation()
        return (value,owner)
    }
    static func withDecodeCharge<T>(from data:Data,workingSet:LWFloatWorkingSet = .sourceGraphs,_ body:() throws -> T) throws -> T {
        let owner=try LWSourceMetadataStorage(bytes:decodingBytes(data),workingSet:workingSet)
        defer { withExtendedLifetime(owner) {} }
        return try body()
    }
    func validate(bytes: Int) throws {
        try Task.checkCancellation();guard bytes>=0,bytes<=capacity else { throw ProjectError.tooLarge }
    }
}

/// Cache entries retain their pre-read charge. Node hydration adds its own
/// retained copy charge before installing Data into decoded value collections.
nonisolated final class LWSourceOwnedData: @unchecked Sendable {
    private let data: Data
    let owner: LWSourceMetadataStorage
    fileprivate init(data:Data,owner:LWSourceMetadataStorage) { self.data=data;self.owner=owner }
    /// Escaping read-only bytes keep the exact input allocation's owner. A naked
    /// mutable Data getter would let an alias outlive that owner or COW without
    /// admission; publication/hydration therefore use the explicit transfer below.
    struct Bytes:RandomAccessCollection,Sendable {
        typealias Index=Int
        fileprivate let storage:LWSourceOwnedData
        var startIndex:Int { 0 }
        var endIndex:Int { storage.data.count }
        func index(after index:Int)->Int { index+1 }
        func index(before index:Int)->Int { index-1 }
        subscript(index:Int)->UInt8 { storage.data[storage.data.startIndex+index] }
    }
    var bytes:Bytes { Bytes(storage:self) }
    var count:Int { data.count }
    var isEmpty:Bool { data.isEmpty }
    var sha256:String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    func equals(_ other:LWSourceOwnedData)->Bool { data == other.data }
    func decode<T:Decodable>(_ type:T.Type) throws -> (value:T,owner:LWSourceMetadataStorage) {
        defer { withExtendedLifetime(self) {} }
        return try LWSourceMetadataStorage.decode(type,from:data,workingSet:owner.workingSet)
    }
    func decodeCatalog<T:Decodable>(_ type:T.Type) throws -> (value:T,owner:LWSourceMetadataStorage) {
        defer { withExtendedLifetime(self) {} }
        let decodedOwner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.decodingBytes(data),workingSet:owner.workingSet,decodedPayload:true)
        let value=try LWCatalogCodec.decode(type,from:data)
        try Task.checkCancellation();return (value,decodedOwner)
    }
    /// The caller must retain this admitted destination owner alongside every
    /// returned model/package value. It is charged before a distinct buffer is
    /// allocated; immutable cache input can never be mutated by a recipient.
    func copyData(ownedBy destination:LWSourceMetadataStorage) throws -> Data {
        guard destination.workingSet === owner.workingSet else { throw ProjectError.invalid }
        try destination.validate(bytes:LWSourceMetadataStorage.sum(LWSourceMetadataStorage.product(count,2),4096))
        try Task.checkCancellation()
        guard count>0 else { return Data() }
        let pointer=UnsafeMutableRawPointer.allocate(byteCount:count,alignment:MemoryLayout<UInt8>.alignment)
        data.withUnsafeBytes { raw in pointer.copyMemory(from:raw.baseAddress!,byteCount:raw.count) }
        let result=Data(bytesNoCopy:pointer,count:count,deallocator:.custom { pointer,_ in
            pointer.deallocate();withExtendedLifetime(destination) {}
        })
        try Task.checkCancellation();return result
    }
    /// Reference fixtures can supply in-memory bytes; real package readers keep
    /// the held/named no-follow file admission below. No uncharged copy is made.
    static func retaining(_ data:Data,workingSet:LWFloatWorkingSet = .sourceGraphs)throws->LWSourceOwnedData {
        let owner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.sum(LWSourceMetadataStorage.product(data.count,2),4096),workingSet:workingSet)
        return LWSourceOwnedData(data:data,owner:owner)
    }
    static func read(_ url:URL,maximumBytes:Int,workingSet:LWFloatWorkingSet = .sourceGraphs) throws -> LWSourceOwnedData {
        guard url.isFileURL,url.standardizedFileURL==url,url.resolvingSymlinksInPath()==url,
            maximumBytes>=0,maximumBytes<=LWFloatWorkingSet.maximumBytes else { throw ProjectError.invalid }
        let parent=try LWFloatDirectoryChain(url.deletingLastPathComponent())
        let fd=openat(parent.fd,url.lastPathComponent,O_RDONLY|O_NOFOLLOW|O_CLOEXEC)
        guard fd>=0 else { throw ProjectError.missingImage };defer { close(fd) }
        var before=stat(),initialNamed=stat()
        guard fstat(fd,&before)==0,fstatat(parent.fd,url.lastPathComponent,&initialNamed,AT_SYMLINK_NOFOLLOW)==0,
            (before.st_mode&S_IFMT)==S_IFREG,before.st_nlink==1,before.st_uid==getuid(),same(before,initialNamed) else { throw ProjectError.invalid }
        guard before.st_size>=0,before.st_size<=maximumBytes else { throw ProjectError.tooLarge }
        try parent.check()
        let count=Int(before.st_size)
        let owner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.sum(LWSourceMetadataStorage.product(count,2),4096),workingSet:workingSet)
        var data=Data(count:count)
        try data.withUnsafeMutableBytes { buffer in
            var offset=0
            while offset<count {
                try Task.checkCancellation()
                let amount=Darwin.read(fd,buffer.baseAddress!.advanced(by:offset),min(1024*1024,count-offset))
                if amount<0 && errno==EINTR { continue }
                guard amount>0 else { throw ProjectError.invalid };offset+=amount
            }
        }
        var after=stat(),named=stat()
        guard fstat(fd,&after)==0,fstatat(parent.fd,url.lastPathComponent,&named,AT_SYMLINK_NOFOLLOW)==0,
            same(before,after),same(after,named) else { throw ProjectError.invalid }
        try parent.check();try Task.checkCancellation();return LWSourceOwnedData(data:data,owner:owner)
    }
    private static func same(_ a:stat,_ b:stat)->Bool {
        a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_size==b.st_size && a.st_mode==b.st_mode &&
        a.st_uid==b.st_uid && a.st_nlink==b.st_nlink && a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec &&
        a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec
    }
}

nonisolated extension LWSourceRetouchStroke {
    var retainedMetadataBytes:Int {
        var n=MemoryLayout<Self>.stride
        func add(_ bytes:Int) { n=(try? LWSourceMetadataStorage.sum(n,bytes)) ?? Int.max }
        add((try? LWSourceMetadataStorage.collectionBytes(count:points.count,stride:MemoryLayout<CGPoint>.stride)) ?? Int.max)
        add((try? LWSourceMetadataStorage.collectionBytes(count:color.count,stride:MemoryLayout<Float>.stride)) ?? Int.max)
        add(captureFrame.retainedMetadataBytes);add(selectionFrame?.retainedMetadataBytes ?? 0)
        add((try? LWSourceMetadataStorage.sum(256,LWSourceMetadataStorage.product(selectionSourceCoverage?.count ?? 0,2))) ?? Int.max)
        return n
    }
}
nonisolated extension LWSourceRetouchFrame {
    var retainedMetadataBytes:Int {
        var n=(try? LWSourceMetadataStorage.collectionBytes(count:geometry.values.count,stride:MemoryLayout<Double>.stride)) ?? Int.max
        n=(try? LWSourceMetadataStorage.sum(n,LWSourceMetadataStorage.collectionBytes(count:stages.count,stride:MemoryLayout<LWSourcePixelStage>.stride))) ?? Int.max
        for stage in stages { n=(try? LWSourceMetadataStorage.sum(n,stage.retainedMetadataBytes)) ?? Int.max }
        return n
    }
}
nonisolated extension LWSourcePixelStage {
    var retainedMetadataBytes:Int { (try? LWSourceMetadataStorage.collectionBytes(count:homography?.values.count ?? 0,stride:MemoryLayout<Double>.stride)) ?? Int.max }
}
nonisolated extension CameraRawSettings {
    var retainedMetadataBytes:Int {
        var n=MemoryLayout<Self>.stride
        func add(_ count:Int,_ stride:Int) { n=(try? LWSourceMetadataStorage.sum(n,LWSourceMetadataStorage.collectionBytes(count:count,stride:stride))) ?? Int.max }
        for points in [curve.rgb,curve.red,curve.green,curve.blue] { add(points.count,MemoryLayout<CurvePoint>.stride) }
        for values in [mixer.hue,mixer.saturation,mixer.luminance] { add(values.count,MemoryLayout<Double>.stride) }
        add(mixer.points.count,MemoryLayout<CameraRawPointColor>.stride);add(geometry.guides.count,MemoryLayout<CameraRawGeometryGuide>.stride)
        return n
    }
}
nonisolated extension LWSourceRetainedFilter {
    var retainedMetadataBytes:Int {
        var n=MemoryLayout<Self>.stride
        for bytes in [captureFrame.retainedMetadataBytes,selectionFrame?.retainedMetadataBytes ?? 0,pixelStage.retainedMetadataBytes,settings.cameraRaw.retainedMetadataBytes] {
            n=(try? LWSourceMetadataStorage.sum(n,bytes)) ?? Int.max
        }
        for channel in settings.curves.channels { n=(try? LWSourceMetadataStorage.sum(n,LWSourceMetadataStorage.collectionBytes(count:channel.count,stride:MemoryLayout<CurvePoint>.stride))) ?? Int.max }
        return (try? LWSourceMetadataStorage.sum(n,LWSourceMetadataStorage.product(settings.dither.characters.utf8.count,2))) ?? Int.max
    }
}

nonisolated extension ProjectManifest {
    func metadataCopy(additionalBytes:Int=0,workingSet:LWFloatWorkingSet?=nil) throws -> Self {
        let selected=workingSet ?? metadataStorage?.workingSet ?? .sourceGraphs
        if let old=metadataStorage,let workingSet { guard old.workingSet === workingSet else { throw ProjectError.invalid } }
        let charge=try LWSourceMetadataStorage.sum(additionalBytes,LWSourceMetadataStorage.sum(4096,LWSourceMetadataStorage.collectionBytes(count:layers.count,
            stride:max(MemoryLayout<ProjectLayerRecord>.stride,MemoryLayout<ImageLayer>.stride))))
        let owner=try LWSourceMetadataStorage(bytes:charge,workingSet:selected,payloadOwners:metadataStorage?.payloadOwners ?? [])
        var result=self;result.metadataStorage=owner;return result
    }
}

nonisolated extension ProjectSnapshot {
    /// Reserve every value-container projection before a canvas edit can trigger
    /// copy-on-write. Pixel/decoded-source owners remain shared immutable values.
    func metadataProjection(workingSet:LWFloatWorkingSet) throws -> Self {
        let imageCount=try LWSourceMetadataStorage.sum(images.count,masks.count)
        let topology=try LWSourceMetadataStorage.collectionBytes(count:imageCount,
            stride:MemoryLayout<UUID>.stride+MemoryLayout<ImportedImage>.stride)
        let manifest=try manifest.metadataCopy(additionalBytes:topology,workingSet:workingSet)
        return .init(manifest:manifest,images:images,masks:masks,workingVersion:workingVersion,history:history)
    }
}


/// Preflight visits immutable Codable values without materializing a JSON tree.
/// The escaped-wire and per-value allowances reserve Foundation's explicit
/// encoding work before JSONEncoder runs; they do not certify process RSS.
nonisolated extension LWSourceMetadataStorage {
    static func encode<T:Encodable>(_ value:T,maximumBytes:Int,
        workingSet:LWFloatWorkingSet = .sourceGraphs,
        formatting:JSONEncoder.OutputFormatting = [],catalogCodec:Bool=false) throws -> LWSourceOwnedData {
        guard maximumBytes>0,maximumBytes<=8*1024*1024 else { throw ProjectError.invalid }
        let scanOwner=try LWSourceMetadataStorage(bytes:16*1024,workingSet:workingSet)
        let estimate=LWSourceEncodingEstimate()
        try estimate.value(value,depth:0)
        let peak=try sum(4096,sum(product(estimate.bytes,4),product(estimate.tokens,256)))
        let encodeOwner=try LWSourceMetadataStorage(bytes:peak,workingSet:workingSet)
        defer { withExtendedLifetime((scanOwner,encodeOwner)) {} }
        try Task.checkCancellation()
        let data:Data
        if catalogCodec {
            guard formatting.isEmpty else { throw ProjectError.invalid }
            data=try LWCatalogCodec.encode(value)
        } else {
            let encoder=JSONEncoder();encoder.outputFormatting=formatting;data=try encoder.encode(value)
        }
        guard data.count<=maximumBytes else { throw ProjectError.tooLarge }
        let retained=try LWSourceMetadataStorage(bytes:sum(product(data.count,2),4096),workingSet:workingSet)
        try Task.checkCancellation()
        return LWSourceOwnedData(data:data,owner:retained)
    }
}
nonisolated private final class LWSourceEncodingEstimate {
    var bytes=0,tokens=0
    var fault:Error?
    func charge(_ count:Int) throws {
        if let fault { throw fault }
        bytes=try LWSourceMetadataStorage.sum(bytes,count)
        tokens=try LWSourceMetadataStorage.sum(tokens,1)
        guard bytes<=LWFloatWorkingSet.maximumBytes,tokens<=LWFloatWorkingSet.maximumBytes/256 else { throw ProjectError.tooLarge }
        if tokens%256==0 { try Task.checkCancellation() }
    }
    func record(_ count:Int) { do { try charge(count) } catch { fault=error } }
    func key(_ key:String,depth:Int) throws {
        // Includes quotes, punctuation and prettyPrinted indentation; six bytes
        // per UTF8 byte safely covers JSON escapes without allocating a string.
        try charge(LWSourceMetadataStorage.sum(LWSourceMetadataStorage.product(key.utf8.count,6),16+depth*4))
    }
    func value<T:Encodable>(_ value:T,depth:Int) throws {
        guard depth<=64 else { throw ProjectError.invalid }
        if let fault { throw fault }
        if let data=value as? Data {
            let groups=try LWSourceMetadataStorage.sum(data.count,2)/3
            try charge(LWSourceMetadataStorage.sum(LWSourceMetadataStorage.product(groups,4),16));return
        }
        try value.encode(to:LWSourceCountingEncoder(estimate:self,depth:depth))
        if let fault { throw fault }
    }
}
nonisolated private struct LWSourceCountingEncoder:Encoder {
    let estimate:LWSourceEncodingEstimate
    let depth:Int
    var codingPath:[any CodingKey] { [] }
    var userInfo:[CodingUserInfoKey:Any] { [:] }
    private func enterContainer() {
        guard depth<=64 else { estimate.fault=ProjectError.invalid;return }
        estimate.record(16+depth*4)
    }
    func container<Key:CodingKey>(keyedBy type:Key.Type)->KeyedEncodingContainer<Key> {
        enterContainer()
        return KeyedEncodingContainer(LWSourceCountingKeyed<Key>(encoder:self))
    }
    func unkeyedContainer()->any UnkeyedEncodingContainer {
        enterContainer();return LWSourceCountingUnkeyed(encoder:self)
    }
    func singleValueContainer()->any SingleValueEncodingContainer { LWSourceCountingSingle(encoder:self) }
    var child:Self { .init(estimate:estimate,depth:depth+1) }
}
nonisolated private struct LWSourceCountingKeyed<Key:CodingKey>:KeyedEncodingContainerProtocol {
    let encoder:LWSourceCountingEncoder
    var codingPath:[any CodingKey] { [] }
    mutating func encode(_ value:Bool,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:String,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Double,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Float,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int8,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int16,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int32,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int64,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int128,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt8,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt16,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt32,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt64,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt128,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encodeNil(forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.charge(4) }
    mutating func encode<T:Encodable>(_ value:T,forKey key:Key) throws { try encoder.estimate.key(key.stringValue,depth:encoder.depth);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func nestedContainer<N:CodingKey>(keyedBy type:N.Type,forKey key:Key)->KeyedEncodingContainer<N> {
        do { try encoder.estimate.key(key.stringValue,depth:encoder.depth) } catch { encoder.estimate.fault=error }
        return encoder.child.container(keyedBy:type)
    }
    mutating func nestedUnkeyedContainer(forKey key:Key)->any UnkeyedEncodingContainer {
        do { try encoder.estimate.key(key.stringValue,depth:encoder.depth) } catch { encoder.estimate.fault=error }
        return encoder.child.unkeyedContainer()
    }
    mutating func superEncoder()->any Encoder { encoder.child }
    mutating func superEncoder(forKey key:Key)->any Encoder {
        do { try encoder.estimate.key(key.stringValue,depth:encoder.depth) } catch { encoder.estimate.fault=error }
        return encoder.child
    }
}
nonisolated private struct LWSourceCountingUnkeyed:UnkeyedEncodingContainer {
    let encoder:LWSourceCountingEncoder
    var count=0
    var codingPath:[any CodingKey] { [] }
    mutating func encode(_ value:Bool) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:String) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Double) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Float) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int8) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int16) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int32) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int64) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:Int128) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt8) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt16) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt32) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt64) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encode(_ value:UInt128) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func encodeNil() throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4) }
    mutating func encode<T:Encodable>(_ value:T) throws { count+=1;try encoder.estimate.charge(16+encoder.depth*4);try encoder.estimate.value(value,depth:encoder.depth+1) }
    mutating func nestedContainer<N:CodingKey>(keyedBy type:N.Type)->KeyedEncodingContainer<N> { count+=1;return encoder.child.container(keyedBy:type) }
    mutating func nestedUnkeyedContainer()->any UnkeyedEncodingContainer { count+=1;return encoder.child.unkeyedContainer() }
    mutating func superEncoder()->any Encoder { count+=1;return encoder.child }
}
nonisolated private struct LWSourceCountingSingle:SingleValueEncodingContainer {
    let encoder:LWSourceCountingEncoder
    var codingPath:[any CodingKey] { [] }
    func encodeNil() throws { try encoder.estimate.charge(4) }
    func encode(_ value:Bool) throws { try encoder.estimate.charge(5) }
    func encode(_ value:String) throws { try encoder.estimate.charge(LWSourceMetadataStorage.sum(LWSourceMetadataStorage.product(value.utf8.count,6),16)) }
    func encode(_ value:Double) throws { guard value.isFinite else { throw ProjectError.invalid };try encoder.estimate.charge(64) }
    func encode(_ value:Float) throws { guard value.isFinite else { throw ProjectError.invalid };try encoder.estimate.charge(64) }
    func encode(_ value:Int) throws { try encoder.estimate.charge(41) }
    func encode(_ value:Int8) throws { try encoder.estimate.charge(41) }
    func encode(_ value:Int16) throws { try encoder.estimate.charge(41) }
    func encode(_ value:Int32) throws { try encoder.estimate.charge(41) }
    func encode(_ value:Int64) throws { try encoder.estimate.charge(41) }
    func encode(_ value:UInt) throws { try encoder.estimate.charge(41) }
    func encode(_ value:UInt8) throws { try encoder.estimate.charge(41) }
    func encode(_ value:UInt16) throws { try encoder.estimate.charge(41) }
    func encode(_ value:UInt32) throws { try encoder.estimate.charge(41) }
    func encode(_ value:UInt64) throws { try encoder.estimate.charge(41) }
    func encode(_ value:Int128) throws { try encoder.estimate.charge(41) }
    func encode(_ value:UInt128) throws { try encoder.estimate.charge(41) }
    func encode<T:Encodable>(_ value:T) throws { try encoder.estimate.value(value,depth:encoder.depth+1) }
}
