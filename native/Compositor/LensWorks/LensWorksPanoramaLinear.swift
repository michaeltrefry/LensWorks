import Foundation
import CoreGraphics
import Darwin

/// Pins publication to the admitted physical output directory. A pre-existing Panoramas link
/// is refused, and all temporary/final file operations are relative to the held directory.
nonisolated final class LensWorksPanoramaDestination: @unchecked Sendable {
    let directory: URL
    let descriptor: Int32
    private let parent: Int32
    private let root: URL
    init(output: URL) throws {
        root = output
        let parent = output.path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        guard parent >= 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        self.parent = parent
        if Darwin.mkdirat(parent, "Panoramas", 0o755) != 0, errno != EEXIST { Darwin.close(parent); throw CocoaError(.fileWriteUnknown) }
        let child = Darwin.openat(parent, "Panoramas", O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard child >= 0 else { Darwin.close(parent); throw LensWorksCatalogError.message("Panoramas must be a real folder inside the working-versions folder, not a symbolic link.") }
        descriptor = child; directory = output.appendingPathComponent("Panoramas", isDirectory: true)
    }
    deinit { Darwin.close(descriptor); Darwin.close(parent) }
    func removeUnimportedPublication(named name: String) {
        guard !name.contains("/"), name != ".", name != ".." else { return }
        _ = name.withCString { Darwin.unlinkat(descriptor, $0, 0) }
    }
    func validate() throws {
        var heldRoot = stat(), namedRoot = stat(), held = stat(), named = stat()
        guard fstat(parent, &heldRoot) == 0, root.path.withCString({ lstat($0, &namedRoot) }) == 0,
              fstat(descriptor, &held) == 0, fstatat(parent, "Panoramas", &named, AT_SYMLINK_NOFOLLOW) == 0,
              (namedRoot.st_mode & S_IFMT) == S_IFDIR, (named.st_mode & S_IFMT) == S_IFDIR,
              heldRoot.st_dev == namedRoot.st_dev, heldRoot.st_ino == namedRoot.st_ino,
              held.st_dev == named.st_dev, held.st_ino == named.st_ino else { throw CocoaError(.fileWriteInvalidFileName) }
    }
}

/// Production panorama transport. Matching may quantize descriptors, but resampling, blending,
/// publication and subsequent Camera Raw edits all retain scene-linear floating-point samples.
nonisolated enum LensWorksPanoramaLinear {
    static func stitch(_ urls: [URL], projection: LensWorksPanoramaProjection,
                       boundary: LensWorksPanoramaBoundary) async throws -> LWFloatPlane {
        guard urls.count >= 2 else { throw ProjectError.invalid }
        var planes: [LWFloatPlane] = []
        for url in urls {
            try Task.checkCancellation()
            let (_, plane) = try await LWSourceDeveloper.shared.createPlane(original: LWCatalogNativePath(fileURL: url))
            guard plane.width >= 17, plane.height >= 16,
                  planes.first.map({ $0.width == plane.width && $0.height == plane.height }) ?? true else {
                throw LensWorksCatalogError.message("Panorama frames must have matching dimensions, at least 17 × 16 pixels.")
            }
            planes.append(plane)
        }
        return try render(planes, projection: projection, boundary: boundary)
    }

    @_optimize(speed) static func render(_ planes: [LWFloatPlane], projection: LensWorksPanoramaProjection,
                       boundary: LensWorksPanoramaBoundary) throws -> LWFloatPlane {
        guard let first = planes.first, planes.count >= 2, first.width >= 17, first.height >= 16,
              planes.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { throw ProjectError.invalid }
        var alignments: [LensWorksPanoramaAlignment] = []
        // Only two bounded descriptor grids are resident at a time. Their leases and every
        // pyramid level share the source graph's existing 512 MiB admission, even for 61 MP frames.
        var previous = try LensWorksPanoramaStitcher.Raster(plane: first)
        for plane in planes.dropFirst() {
            let next = try LensWorksPanoramaStitcher.Raster(plane: plane)
            let matched = try LensWorksPanoramaStitcher.match(previous, next, maximumVertical: max(1, 32 / previous.sourceScale),
                minimumOverlap: max(1, (max(16, first.width / 6) + previous.sourceScale - 1) / previous.sourceScale))
            let left = planes[alignments.count]
            var refined = try refine(left, plane, coarseX: matched.dx * previous.sourceScale,
                coarseY: matched.dy * previous.sourceScale, radius: previous.sourceScale == 1 ? 0 : previous.sourceScale)
            if refined.meanSeamError > LensWorksPanoramaStitcher.declaredSeamErrorTolerance {
                // High-frequency detail can alias at every small pyramid level. Exact linear
                // feature votes provide an O(pixels) fallback, never a full-resolution shift scan.
                if let featureMatch = try exactFeatureMatch(left, plane), featureMatch.meanSeamError < refined.meanSeamError {
                    refined = featureMatch
                }
            }
            alignments.append(refined)
            previous = next
        }
        // Drop the last descriptor before admitting output tiles.
        previous = .init(width: 0, height: 0, rgba: [])
        let descriptors = planes.map { LensWorksPanoramaStitcher.Raster(width: $0.width, height: $0.height, rgba: []) }
        let geometryCharge = try LWFloatWorkingSet.sourceGraphs.reserve(DocumentLimits.maxSide * 64)
        defer { withExtendedLifetime(geometryCharge) {} }
        let geometry = try LensWorksPanoramaStitcher.Geometry(rasters: descriptors, projection: projection,
            boundary: boundary, knownAlignments: alignments)
        let workspace = try LWFloatWorkspace(workingSet: .sourceGraphs)
        let builder = try workspace.makeBuilder(width: geometry.width, height: geometry.height)
        while let range = builder.nextRange {
            try Task.checkCancellation()
            let regions = try planes.indices.map { index in try planes[index].read(geometry.sourceRange(for: range, frame: index)) }
            let tile = try LWLinearSurface.admitted(width: range.width, height: range.height,
                maximumBytes: range.width * range.height * 16, workingSet: workspace.workingSet) { index in
                if index % range.width == 0 { try Task.checkCancellation() }
                let value = try geometry.sample(x: range.x + index % range.width, y: range.y + index / range.width) { frame, x, y in
                    let region = regions[frame], left = Int(floor(x)), top = Int(floor(y))
                    let right = min(first.width - 1, left + 1), bottom = min(first.height - 1, top + 1)
                    let tx = Float(x - Double(left)), ty = Float(y - Double(top))
                    func pixel(_ sx: Int, _ sy: Int) throws -> SIMD4<Float> {
                        // A zero-weight neighbour need not extend the footprint at an integer coordinate.
                        let cx = max(region.range.x, min(region.range.x + region.range.width - 1, sx))
                        let cy = max(region.range.y, min(region.range.y + region.range.height - 1, sy))
                        let pixel = region.surface.pixels[(cy - region.range.y) * region.range.width + cx - region.range.x]
                        guard pixel.w == 1 else { throw LensWorksCatalogError.message("Panorama source photos must be opaque.") }
                        return pixel
                    }
                    let blended = try (pixel(left, top) * (1 - tx) + pixel(right, top) * tx) * (1 - ty)
                        + (pixel(left, bottom) * (1 - tx) + pixel(right, bottom) * tx) * ty
                    return SIMD4(blended.x, blended.y, blended.z, 1)
                }
                guard value.w == 1 else { throw LensWorksCatalogError.message("The cropped panorama contains an uncovered pixel.") }
                return value
            }
            try builder.append(tile, at: range)
        }
        return try builder.finish()
    }

    private struct Offset: Hashable { let x: Int, y: Int }
    private static func feature(_ pixel: SIMD4<Float>) -> UInt64 {
        UInt64(pixel.x.bitPattern) &* 0x9e3779b185ebca87
            ^ UInt64(pixel.y.bitPattern) &* 0xc2b2ae3d27d4eb4f
            ^ UInt64(pixel.z.bitPattern) &* 0x165667b19e3779f9
    }
    /// Only unique reference features vote; large flat regions cannot create an all-pairs loop.
    /// This supplements, rather than replaces, noise-tolerant pyramid matching/refinement.
    @_optimize(speed) private static func exactFeatureMatch(_ left: LWFloatPlane, _ right: LWFloatPlane) throws -> LensWorksPanoramaAlignment? {
        let charge = try left.workingSet.reserve(4 * 1024 * 1024)
        defer { withExtendedLifetime(charge) {} }
        var features: [UInt64: Offset] = [:], duplicate = Set<UInt64>()
        let sampler = left.sampler()
        for y in stride(from: 0, to: left.height, by: max(1, (left.height + 31) / 32)) {
            try Task.checkCancellation()
            for x in stride(from: 0, to: left.width, by: max(1, (left.width + 63) / 64)) {
                let key = feature(try sampler.pixel(x: x, y: y))
                if features.updateValue(.init(x: x, y: y), forKey: key) != nil { duplicate.insert(key) }
            }
        }
        for key in duplicate { features.removeValue(forKey: key) }
        guard features.count >= 3 else { return nil }
        let maxDX = left.width - max(16, left.width / 6), maxDY = min(32, left.height / 4)
        var votes: [Offset: Int] = [:]
        for entry in right.manifest.entries {
            try Task.checkCancellation()
            let tile = try right.read(entry.range)
            for y in 0..<entry.range.height { for x in 0..<entry.range.width {
                guard let point = features[feature(tile.surface.pixels[y * entry.range.width + x])] else { continue }
                let offset = Offset(x: point.x - x - entry.range.x, y: point.y - y - entry.range.y)
                if abs(offset.x) <= maxDX, abs(offset.y) <= maxDY,
                   votes[offset] != nil || votes.count < 8192 { votes[offset, default: 0] += 1 }
            } }
        }
        let candidates = votes.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.x == $1.key.x ? $0.key.y < $1.key.y : $0.key.x < $1.key.x
        }.prefix(8)
        var best: LensWorksPanoramaAlignment?
        for (offset, count) in candidates where count >= 3 {
            let match = try refine(left, right, coarseX: offset.x, coarseY: offset.y, radius: 0)
            if best == nil || match.meanSeamError < best!.meanSeamError { best = match }
            if match.meanSeamError == 0 { break }
        }
        return best
    }

    /// Refine descriptor displacement to original pixels without full-resolution descriptor arrays.
    /// At most 64 × 32 source sites, one small right-hand patch per site, and a bounded displacement
    /// neighbourhood. The same sample sites score every candidate, avoiding overlap-size bias.
    @_optimize(speed) private static func refine(_ left: LWFloatPlane, _ right: LWFloatPlane,
        coarseX: Int, coarseY: Int, radius: Int) throws -> LensWorksPanoramaAlignment {
        let charge = try left.workingSet.reserve(512 * 1024)
        defer { withExtendedLifetime(charge) {} }
        let minimumOverlap = max(16, left.width / 6), maxDX = left.width - minimumOverlap
        let maxDY = min(32, left.height / 4)
        guard maxDX >= 0, maxDY >= 0, radius >= 0, radius <= 32 else { throw ProjectError.invalid }
        let centerX = max(-maxDX, min(maxDX, coarseX)), centerY = max(-maxDY, min(maxDY, coarseY))
        let dxs = max(-maxDX, centerX - radius)...min(maxDX, centerX + radius)
        let dys = max(-maxDY, centerY - radius)...min(maxDY, centerY + radius)
        let xStart = max(0, dxs.upperBound), xEnd = min(left.width, right.width + dxs.lowerBound)
        let yStart = max(0, dys.upperBound), yEnd = min(left.height, right.height + dys.lowerBound)
        guard xStart < xEnd, yStart < yEnd else { throw ProjectError.invalid }
        let candidates = dxs.flatMap { dx in dys.map { (x: dx, y: $0) } }
        var errors = [Double](repeating: 0, count: candidates.count), samples = 0
        let reader = left.sampler(), rightReader = right.sampler()
        for y in stride(from: yStart, to: yEnd, by: max(1, (yEnd - yStart + 31) / 32)) {
            try Task.checkCancellation()
            for x in stride(from: xStart, to: xEnd, by: max(1, (xEnd - xStart + 63) / 64)) {
                let a = try reader.pixel(x: x, y: y)
                for (index, offset) in candidates.enumerated() {
                    let b = try rightReader.pixel(x: x - offset.x, y: y - offset.y)
                    for channel in 0..<3 {
                        errors[index] += Double(abs(Int(LensWorksPanoramaStitcher.Raster.descriptor(a[channel]))
                            - Int(LensWorksPanoramaStitcher.Raster.descriptor(b[channel]))))
                    }
                }
                samples += 3
            }
        }
        guard let index = errors.indices.min(by: { errors[$0] < errors[$1] }) else { throw ProjectError.invalid }
        return .init(horizontalOffset: candidates[index].x, verticalOffset: candidates[index].y,
            meanSeamError: errors[index] / Double(samples))
    }

    /// Uncompressed float32 LinearRaw DNG in the established filesystem media workflow.
    /// RGB is extended-linear sRGB, with explicit D50 color/forward matrices and unity neutral;
    /// no tone curve, clipping, integer quantization, camera white balance or display profile is baked in.
    /// Strips keep both encoding residency and file writes bounded, independently of output extent.
    @_optimize(speed) static func writeDNG(_ plane: LWFloatPlane, to url: URL, destination: LensWorksPanoramaDestination? = nil) throws {
        let rowsPerStrip = min(128, plane.height), strips = (plane.height + rowsPerStrip - 1) / rowsPerStrip
        let counts = (0..<strips).map { UInt32(plane.width * min(rowsPerStrip, plane.height - $0 * rowsPerStrip) * 12) }
        var entries: [(UInt16, Value)] = [
            (254, .long([0])), (256, .long([UInt32(plane.width)])), (257, .long([UInt32(plane.height)])),
            (258, .short([32, 32, 32])), (259, .short([1])), (262, .short([34892])),
            (273, .long(Array(repeating: 0, count: strips))), (274, .short([1])), (277, .short([3])),
            (278, .long([UInt32(rowsPerStrip)])), (279, .long(counts)), (284, .short([1])),
            (339, .short([3, 3, 3])), (50706, .byte([1, 4, 0, 0])), (50707, .byte([1, 4, 0, 0])),
            (50708, .ascii("LensWorks linear sRGB panorama")), (50713, .short([1, 1])),
            (50714, .rational([0, 0, 0])), (50717, .long([1, 1, 1])),
            (50721, .srational([3.1338561, -1.6168667, -0.4906146, -0.9787684, 1.9161415, 0.0334540, 0.0719453, -0.2289914, 1.4052427])),
            (50728, .rational([1, 1, 1])), (50778, .short([23])),
            (50964, .srational([0.4360747, 0.3850649, 0.1430804, 0.2225045, 0.7168786, 0.0606169, 0.0139322, 0.0971045, 0.7141733]))
        ]
        let ifdSize = 2 + entries.count * 12 + 4
        let encoded = entries.map { encode($0.1) }
        var extraCount = 0
        for entry in encoded where entry.bytes.count > 4 { extraCount += entry.bytes.count + entry.bytes.count % 2 }
        var offset = UInt32(8 + ifdSize + extraCount), offsets: [UInt32] = []
        for count in counts { offsets.append(offset); offset += count }
        entries[entries.firstIndex(where: { $0.0 == 273 })!].1 = .long(offsets)
        var header = Data([0x49, 0x49, 42, 0]); put(UInt32(8), into: &header); put(UInt16(entries.count), into: &header)
        var extra = Data()
        for entry in entries {
            let value = encode(entry.1)
            put(entry.0, into: &header); put(value.type, into: &header); put(value.count, into: &header)
            if value.bytes.count > 4 {
                put(UInt32(8 + ifdSize + extra.count), into: &header)
                extra.append(value.bytes); if extra.count % 2 != 0 { extra.append(0) }
            } else { header.append(value.bytes); header.append(Data(repeating: 0, count: 4 - value.bytes.count)) }
        }
        put(UInt32(0), into: &header); header.append(extra)
        // Stream privately, then atomically admit the whole file with an exclusive rename.
        // No importer can see a partial .dng; an existing original is never replaced, even in a race.
        let parent: Int32
        if let destination {
            try destination.validate()
            guard url.deletingLastPathComponent() == destination.directory else { throw CocoaError(.fileWriteInvalidFileName) }
            parent = dup(destination.descriptor)
        } else {
            parent = url.deletingLastPathComponent().path.withCString { Darwin.open($0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW) }
        }
        guard parent >= 0 else { throw CocoaError(.fileWriteInvalidFileName) }
        defer { Darwin.close(parent) }
        let temporary = ".panorama-" + UUID().uuidString + ".partial"
        let descriptor = temporary.withCString { Darwin.openat(parent, $0, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600) }
        guard descriptor >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        defer { try? handle.close(); _ = temporary.withCString { Darwin.unlinkat(parent, $0, 0) } }
        try handle.write(contentsOf: header)
        for strip in 0..<strips {
            try Task.checkCancellation()
            let y = strip * rowsPerStrip, rows = min(rowsPerStrip, plane.height - y)
            let charge = try plane.workingSet.reserve(plane.width * rows * 12)
            defer { withExtendedLifetime(charge) {} }
            let tile = try plane.read(.init(x: 0, y: y, width: plane.width, height: rows))
            var data = Data(count: plane.width * rows * 12)
            data.withUnsafeMutableBytes { raw in
                for (index, pixel) in tile.surface.pixels.enumerated() { for channel in 0..<3 {
                    raw.storeBytes(of: pixel[channel].bitPattern.littleEndian, toByteOffset: index * 12 + channel * 4, as: UInt32.self)
                } }
            }
            try handle.write(contentsOf: data)
        }
        try handle.synchronize(); try Task.checkCancellation()
        try destination?.validate()
        let published = temporary.withCString { source in url.lastPathComponent.withCString { target in Darwin.renameatx_np(parent, source, parent, target, UInt32(RENAME_EXCL)) } }
        guard published == 0 else {
            let code = errno
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(code), userInfo: [NSFilePathErrorKey: url.path])
        }
    }

    private enum Value { case byte([UInt8]), ascii(String), short([UInt16]), long([UInt32]), rational([Double]), srational([Double]) }
    private static func put<T: FixedWidthInteger>(_ value: T, into data: inout Data) {
        var le = value.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    private static func encode(_ value: Value) -> (type: UInt16, count: UInt32, bytes: Data) {
        var data = Data()
        switch value {
        case .byte(let v): data.append(contentsOf: v); return (1, UInt32(v.count), data)
        case .ascii(let v): data.append(contentsOf: v.utf8); data.append(0); return (2, UInt32(v.utf8.count + 1), data)
        case .short(let v): for x in v { put(x, into: &data) }; return (3, UInt32(v.count), data)
        case .long(let v): for x in v { put(x, into: &data) }; return (4, UInt32(v.count), data)
        case .rational(let v): for x in v { put(UInt32((x * 1_000_000).rounded()), into: &data); put(UInt32(1_000_000), into: &data) }; return (5, UInt32(v.count), data)
        case .srational(let v): for x in v { put(Int32((x * 1_000_000).rounded()), into: &data); put(Int32(1_000_000), into: &data) }; return (10, UInt32(v.count), data)
        }
    }
}
