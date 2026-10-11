import Foundation
import CryptoKit

/// Package-only projection: complete source semantics stay in memory; large owned
/// backing bytes are content-addressed files, never base64 inside the manifest.
nonisolated enum LWSourcePackageArchive {
    struct Reference: Codable, Equatable, Sendable {
        let name:String
        let bytes:Int
        let sha256:String
        func validate(suffix:String) throws {
            guard bytes > 0,bytes <= LWSourceDeveloper.maximumResultBytes,
                  sha256.count == 64,sha256.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }),
                  name == sha256 + suffix else { throw ProjectError.invalid }
        }
    }
    /// One coordinated package read shares immutable hydrated generations across
    /// current/history references. Content identity and every backing join are
    /// still checked; a cache hit never substitutes missing declared assets.
    final class HydrationCache {
        struct Entry {
            let node:LWLiveSourceNode
            let dataReferences:[Reference]
            let planeReferences:[String:LWFloatPlaneArchive.Reference]
            let owner:LWSourceMetadataStorage
        }
        private var entries:[String:Entry]=[:]
        private let workingSet:LWFloatWorkingSet
        init(workingSet:LWFloatWorkingSet = .sourceGraphs) { self.workingSet=workingSet }
        func entry(_ name:String)->Entry? { entries[name] }
        func publish(_ name:String,node:LWLiveSourceNode,selected:[Reference?],composites:[Reference],
            selections:[Int:Reference],assets:[UUID:LWSourcePlaneAsset]) throws {
            guard entries[name]==nil else { throw ProjectError.invalid }
            let count=try LWSourceMetadataStorage.sum(selected.count,LWSourceMetadataStorage.sum(composites.count,selections.count))
            let bytes=try LWSourceMetadataStorage.sum(2048,LWSourceMetadataStorage.sum(
                LWSourceMetadataStorage.collectionBytes(count:count,stride:MemoryLayout<Reference>.stride),
                LWSourceMetadataStorage.collectionBytes(count:assets.count,stride:MemoryLayout<LWFloatPlaneArchive.Reference>.stride+128)))
            // Reserve projected collection growth before compacting/appending or
            // building the retained plane dictionary. Input collections are COW
            // views of the independently admitted decoded record/node.
            let owner=try LWSourceMetadataStorage(bytes:bytes,workingSet:workingSet)
            var data:[Reference]=[],planes:[String:LWFloatPlaneArchive.Reference]=[:]
            data.reserveCapacity(count);planes.reserveCapacity(assets.count)
            for reference in selected { if let reference { data.append(reference) } }
            for reference in composites { data.append(reference) }
            for reference in selections.values { data.append(reference) }
            for asset in assets.values { planes[asset.reference.manifestSHA256+".plane"]=asset.reference }
            try Task.checkCancellation()
            entries[name]=Entry(node:node,dataReferences:data,planeReferences:planes,owner:owner)
        }
    }
    private struct Record: Codable {
        let version:Int
        var node:LWLiveSourceNode
        let selected:[Reference?]
        let composites:[Reference]
        let selections:[Int:Reference]
    }
    static func digest(_ data:Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    static func validMetadataName(_ name:String) -> Bool {
        let hash=String(name.dropLast(5))
        return name == hash + ".json" && hash.count == 64 && hash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) })
    }
    static func externalize(_ value:ProjectManifest,maximumBytes:Int) throws -> (manifest:ProjectManifest,assets:[String:Data],planes:[String:LWSourcePlaneAsset],ownership:[LWSourceMetadataStorage]) {
        var manifest=try value.metadataCopy(),assets:[String:Data]=[:],planes:[String:LWSourcePlaneAsset]=[:],used=0,ownership:[LWSourceMetadataStorage]=[]
        func insert(_ data:Data,suffix:String) throws -> Reference {
            guard !data.isEmpty,data.count <= maximumBytes else { throw ProjectError.tooLarge }
            let hash=digest(data),name=hash+suffix
            if let existing=assets[name] { guard existing == data else { throw ProjectError.invalid } }
            else {
                guard data.count <= maximumBytes-used else { throw ProjectError.tooLarge }
                let owner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.sum(LWSourceMetadataStorage.product(data.count,2),1024))
                used += data.count;assets[name]=data;ownership.append(owner)
            }
            return Reference(name:name,bytes:data.count,sha256:hash)
        }
        for index in manifest.layers.indices {
            guard let source=manifest.layers[index].liveSource else {
                if let file=manifest.layers[index].liveSourceFile { guard validMetadataName(file) else { throw ProjectError.invalid } }
                continue
            }
            guard manifest.layers[index].liveSourceFile == nil else { throw ProjectError.invalid }
            try source.validateBackingAssets()
            var node=try source.metadataCopy(),selected:[Reference?]=[],composites:[Reference]=[],selections:[Int:Reference]=[:]
            let projectionOwner=try LWSourceMetadataStorage(bytes:LWSourceMetadataStorage.sum(4096,
                LWSourceMetadataStorage.collectionBytes(count:source.selectedDevelopments.count+source.sampleComposites.count+source.retouch.count+source.planeAssets.count,stride:MemoryLayout<Reference>.stride+128)))
            ownership.append(projectionOwner)
            for backing in source.planeAssets.values {
                try backing.reference.validate()
                guard let plane = backing.plane, backing.reference == (try LWFloatPlaneArchive.reference(plane)) else { throw ProjectError.invalid }
                let name = backing.reference.manifestSHA256 + ".plane"
                if let existing = planes[name] { guard existing == backing else { throw ProjectError.invalid } }
                else { planes[name] = backing }
            }
            for i in node.selectedDevelopments.indices {
                let step=node.selectedDevelopments[i]
                if step.sourceCoveragePlaneID == nil { _=try LWLinearSurface.packageExtent(step.sourceCoverage,maximumFileBytes:maximumBytes) }
                selected.append(step.sourceCoveragePlaneID == nil ? try insert(step.sourceCoverage,suffix:".data") : nil)
                node.selectedDevelopments[i] = .init(settings:step.settings,whiteBalance:step.whiteBalance,seed:step.seed,
                    sourceCoverage:Data(),sourceCoveragePlaneID:step.sourceCoveragePlaneID,coverageFrame:step.coverageFrame)
            }
            for i in node.sampleComposites.indices {
                let item=node.sampleComposites[i]
                composites.append(try insert(item.payload,suffix:".data"))
                node.sampleComposites[i] = .init(revision:item.revision,sourceID:item.sourceID,upstreamRevision:item.upstreamRevision,payload:Data())
            }
            for i in node.retouch.indices {
                if let data=node.retouch[i].selectionSourceCoverage {
                    selections[i]=try insert(data,suffix:".data");node.retouch[i].selectionSourceCoverage=nil
                }
            }
            let record=Record(version:2,node:node,selected:selected,composites:composites,selections:selections)
            let encoded=try LWSourceMetadataStorage.encode(record,maximumBytes:4*1024*1024,formatting:[.sortedKeys])
            defer { withExtendedLifetime(encoded) {} }
            let reference=try insert(encoded.copyData(ownedBy:encoded.owner),suffix:".json")
            manifest.layers[index].liveSource=nil;manifest.layers[index].liveSourceFile=reference.name
        }
        return (manifest,assets,planes,ownership)
    }
    /// In-memory reference callers explicitly retain their input allocation. Real
    /// current/history package paths use readOwned and held no-follow readers.
    static func hydrate(_ value:ProjectManifest, read:(String,Int) throws -> Data,
        readPlane: ((String,LWFloatPlaneArchive.Reference) throws -> LWFloatPlane)? = nil,
        cache:HydrationCache = HydrationCache()) throws -> ProjectManifest {
        try hydrate(value,readOwned:{ name,maximum in
            let data=try read(name,maximum)
            guard data.count<=maximum else { throw ProjectError.tooLarge }
            return try LWSourceOwnedData.retaining(data,workingSet:value.metadataStorage?.workingSet ?? .sourceGraphs)
        },readPlane:readPlane,cache:cache)
    }
    static func hydrate(_ value:ProjectManifest, readOwned:(String,Int) throws -> LWSourceOwnedData,
        readPlane: ((String,LWFloatPlaneArchive.Reference) throws -> LWFloatPlane)? = nil,
        cache:HydrationCache = HydrationCache()) throws -> ProjectManifest {
        var manifest=try value.metadataCopy()
        for index in manifest.layers.indices {
            guard let name=manifest.layers[index].liveSourceFile else { continue }
            guard manifest.layers[index].liveSource == nil,validMetadataName(name) else { throw ProjectError.invalid }
            let bytes=try readOwned(name,4*1024*1024)
            guard bytes.count<=4*1024*1024,bytes.sha256+".json" == name else { throw ProjectError.invalid }
            if let cached=cache.entry(name) {
                for reference in cached.dataReferences {
                    try reference.validate(suffix:".data")
                    let data=try readOwned(reference.name,reference.bytes)
                    guard data.count==reference.bytes,data.sha256==reference.sha256 else { throw ProjectError.invalid }
                }
                for (path,reference) in cached.planeReferences {
                    guard let readPlane else { throw ProjectError.missingImage }
                    let plane=try readPlane(path,reference)
                    guard try LWFloatPlaneArchive.reference(plane)==reference else { throw ProjectError.invalid }
                }
                try cached.node.validateBackingAssets()
                manifest.layers[index].liveSource=cached.node;manifest.layers[index].liveSourceFile=nil;continue
            }
            let decoded=try bytes.decode(Record.self)
            let record=decoded.value
            guard (record.version == 1 || record.version == 2),record.selected.count == record.node.selectedDevelopments.count,
                  record.composites.count == record.node.sampleComposites.count,
                  record.node.selectedDevelopments.count <= 128,record.node.sampleComposites.count <= 10000,
                  record.node.retouch.count <= 10000,
                  record.selections.keys.allSatisfy(record.node.retouch.indices.contains) else { throw ProjectError.invalid }
            func backing(_ reference:Reference,owner:LWSourceMetadataStorage) throws -> Data {
                try reference.validate(suffix:".data")
                let data=try readOwned(reference.name,reference.bytes)
                guard data.count == reference.bytes,data.sha256 == reference.sha256 else { throw ProjectError.invalid }
                return try data.copyData(ownedBy:owner)
            }
            var backingCharge=0
            func admit(_ reference:Reference) throws {
                try reference.validate(suffix:".data")
                backingCharge=try LWSourceMetadataStorage.sum(backingCharge,LWSourceMetadataStorage.sum(1024,LWSourceMetadataStorage.product(reference.bytes,2)))
            }
            // Walk the admitted record directly: no uncharged compactMap,
            // concatenation or Dictionary.Values-to-Array copies precede reserve.
            for reference in record.selected { if let reference { try admit(reference) } }
            for reference in record.composites { try admit(reference) }
            for reference in record.selections.values { try admit(reference) }
            var node=try record.node.metadataCopy(additionalBytes:backingCharge)
            guard let backingOwner=node.metadataStorage else { throw ProjectError.invalid }
            for key in node.planeAssets.keys {
                let backing = node.planeAssets[key]!
                guard let readPlane else { throw ProjectError.missingImage }
                let plane = try readPlane(backing.reference.manifestSHA256 + ".plane",backing.reference)
                guard backing.reference == (try LWFloatPlaneArchive.reference(plane)) else { throw ProjectError.invalid }
                node.planeAssets[key]!.plane = plane
            }
            for i in node.selectedDevelopments.indices {
                let step=node.selectedDevelopments[i];guard step.sourceCoverage.isEmpty else { throw ProjectError.invalid }
                if let reference = record.selected[i] {
                    guard step.sourceCoveragePlaneID == nil else { throw ProjectError.invalid }
                    node.selectedDevelopments[i] = .init(settings:step.settings,whiteBalance:step.whiteBalance,seed:step.seed,sourceCoverage:try backing(reference,owner:backingOwner),coverageFrame:step.coverageFrame)
                } else {
                    guard let key = step.sourceCoveragePlaneID,node.planeAssets[key] != nil else { throw ProjectError.invalid }
                }
            }
            for i in node.sampleComposites.indices {
                let item=node.sampleComposites[i];guard item.payload.isEmpty else { throw ProjectError.invalid }
                node.sampleComposites[i] = .init(revision:item.revision,sourceID:item.sourceID,upstreamRevision:item.upstreamRevision,payload:try backing(record.composites[i],owner:backingOwner))
            }
            for i in node.retouch.indices {
                guard node.retouch[i].selectionSourceCoverage == nil else { throw ProjectError.invalid }
                if let reference=record.selections[i] { node.retouch[i].selectionSourceCoverage=try backing(reference,owner:backingOwner) }
            }
            try node.validateBackingAssets();try node.compactMetadataStorage()
            try cache.publish(name,node:node,selected:record.selected,composites:record.composites,
                selections:record.selections,assets:node.planeAssets)
            manifest.layers[index].liveSource=node;manifest.layers[index].liveSourceFile=nil
        }
        return manifest
    }
}
