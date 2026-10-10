import Foundation

nonisolated enum LWSourceTileTransport {
    /// One owned decode, then bounded range jobs. The source plane never crosses
    /// the ABI as a complete result array, and no range request restarts the codec.
    static func materialize(owner: LWManagedSession, request: LWDocumentSourceDevelopment,
        limits: LWApplicationExportsDtoDecodeLimits, workerBytes: LWCatalogU64,
        workingSet: LWFloatWorkingSet,
        makeBuilder: (Int, Int) throws -> LWFloatPlane.Builder) async throws -> (LWFloatPlane, LWManagedSourcePlaneDescriptor) {
        try Task.checkCancellation()
        let job = try await owner.openDocumentSourcePlane(request, limits: limits, workerBytes: workerBytes)
        let result: LWManagedResult
        do { result = try await job.wait() }
        catch { try? await job.close(); throw error }
        // Retain/release the plane result even if the checked job-release step
        // fails. The outer source session keeps cleanup ownership for retry.
        defer { result.buffer.release() }
        try await job.close()
        guard case .sourcePlane(let descriptor) = result.descriptor else { throw ProjectError.invalid }
        try validatePlane(descriptor,request:request,limits:limits,workerBytes:workerBytes,workingSet:workingSet)
        let width = Int(descriptor.width), height = Int(descriptor.height)
        let builder = try makeBuilder(width, height)
        guard builder.width == width, builder.height == height, builder.workingSet === workingSet else { throw ProjectError.invalid }
        while let range = builder.nextRange {
            try Task.checkCancellation()
            let bytes = try range.validate(frameWidth: width, frameHeight: height)
            // Native copies: ABI Data, Float samples, SIMD samples and transient
            // conversion/provider state. Builder independently charges its encoded write.
            let lease = try workingSet.reserve(bytes * 4)
            defer { withExtendedLifetime(lease) {} }
            let tileJob = try await owner.documentSourcePlaneTile(result.buffer, range: try range.native,
                maximumOutputBytes: LWCatalogU64(UInt64(bytes)))
            do {
                let tileResult = try await tileJob.wait()
                defer { tileResult.buffer.release() }
                guard case .sourceTile(let tile) = tileResult.descriptor else { throw ProjectError.invalid }
                try validateTile(tile,plane:descriptor,request:request,range:range,workingSet:workingSet)
                let samples = try await tileResult.floatSamples(maximumBytes: bytes)
                var pixels = [SIMD4<Float>](); pixels.reserveCapacity(bytes / 16)
                for offset in stride(from: 0, to: samples.count, by: 4) {
                    pixels.append(SIMD4(samples[offset], samples[offset + 1], samples[offset + 2], samples[offset + 3]))
                }
                try builder.append(LWLinearSurface(width: range.width, height: range.height,
                    pixels: pixels, maximumBytes: bytes), at: range)
                try await tileJob.close()
            } catch { try? await tileJob.close(); throw error }
        }
        let current = try await owner.documentSourceRevision(original: request.original, maximumEncodedBytes: limits.max_encoded_bytes)
        guard try sameEncoded(current.original_revision,request.original_revision,workingSet:workingSet) else { throw ProjectError.invalid }
        try Task.checkCancellation()
        return (try builder.finish(), descriptor)
    }
    static func validatePlane(_ plane:LWManagedSourcePlaneDescriptor,request:LWDocumentSourceDevelopment,
        limits:LWApplicationExportsDtoDecodeLimits,workerBytes:LWCatalogU64,workingSet:LWFloatWorkingSet = .sourceGraphs)throws {
        try plane.validate(length:0)
        let pixels=UInt64(plane.width).multipliedReportingOverflow(by:UInt64(plane.height))
        guard !pixels.overflow,pixels.partialValue <= limits.max_intermediate_pixels.value,
            pixels.partialValue <= UInt64(DocumentLimits.maxSurfacePixels),
            limits.max_allocation_bytes.value>0,limits.max_allocation_bytes.value<=workerBytes.value,
            try sameAuthority(plane.source_authority,request,workingSet:workingSet) else { throw ProjectError.invalid }
    }
    static func validateTile(_ tile:LWManagedSourceTileDescriptor,plane:LWManagedSourcePlaneDescriptor,
        request:LWDocumentSourceDevelopment,range:LWFloatRange,workingSet:LWFloatWorkingSet = .sourceGraphs)throws {
        let bytes=try range.validate(frameWidth:Int(plane.width),frameHeight:Int(plane.height))
        try tile.validate(length:UInt64(bytes))
        guard tile.tile_rect == (try range.native),tile.frame_width == plane.width,tile.frame_height == plane.height,
            try sameAuthority(tile.source_authority,request,workingSet:workingSet),
            try sameEncoded(tile.metadata,plane.metadata,workingSet:workingSet),
            try sameEncoded(tile.provenance,plane.provenance,workingSet:workingSet) else { throw ProjectError.invalid }
    }
    private static func sameEncoded<T:Encodable>(_ lhs:T,_ rhs:T,workingSet:LWFloatWorkingSet) throws -> Bool {
        let left=try LWSourceMetadataStorage.encode(lhs,maximumBytes:1024*1024,workingSet:workingSet,catalogCodec:true)
        let right=try LWSourceMetadataStorage.encode(rhs,maximumBytes:1024*1024,workingSet:workingSet,catalogCodec:true)
        defer { withExtendedLifetime((left,right)) {} }
        return left.equals(right)
    }
    private static func sameAuthority(_ lhs: LWDocumentSourceDevelopment, _ rhs: LWDocumentSourceDevelopment,
        workingSet:LWFloatWorkingSet) throws -> Bool {
        let left=try LWSourceMetadataStorage.encode(lhs,maximumBytes:1024*1024,workingSet:workingSet,catalogCodec:true)
        let right=try LWSourceMetadataStorage.encode(rhs,maximumBytes:1024*1024,workingSet:workingSet,catalogCodec:true)
        defer { withExtendedLifetime((left,right)) {} }
        let a=try left.decodeCatalog(LWCatalogJSON.self),b=try right.decodeCatalog(LWCatalogJSON.self)
        defer { withExtendedLifetime((a.owner,b.owner)) {} }
        return a.value==b.value
    }
}
