import Foundation

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

    struct MatchingWork: Sendable {
        var coarseComparisons = 0
        var refinementSamples = 0
        var featurePixels = 0
        var peakFeatureVotes = 0
    }
    struct AlignmentResult: Sendable {
        let alignments: [LensWorksPanoramaAlignment]
        let work: MatchingWork
    }
    /// The production matching phase, shared with deterministic work-budget regressions.
    @_optimize(speed) static func align(_ planes: [LWFloatPlane]) throws -> AlignmentResult {
        guard let first = planes.first, planes.count >= 2, first.width >= 17, first.height >= 16,
              planes.allSatisfy({ $0.width == first.width && $0.height == first.height }) else { throw ProjectError.invalid }
        var work = MatchingWork()
        var alignments: [LensWorksPanoramaAlignment] = []
        // Only two bounded descriptor grids are resident at a time. Their leases and every
        // pyramid level share the source graph's existing 512 MiB admission, even for 61 MP frames.
        for index in 1..<planes.count {
            let left = planes[index - 1], plane = planes[index]
            let matchingRange = try LensWorksPanoramaStitcher.Raster.MatchingRange.measure([left, plane])
            guard matchingRange.high != matchingRange.low else {
                throw LensWorksCatalogError.message("The selected photos contain no reliable contrast from which to establish an overlapping seam.")
            }
            let previous = try LensWorksPanoramaStitcher.Raster(plane: left, matchingRange: matchingRange)
            let next = try LensWorksPanoramaStitcher.Raster(plane: plane, matchingRange: matchingRange)
            let matched = try LensWorksPanoramaStitcher.match(previous, next, maximumVertical: max(1, 32 / previous.sourceScale),
                minimumOverlap: max(1, (max(16, first.width / 6) + previous.sourceScale - 1) / previous.sourceScale))
            work.coarseComparisons += matched.comparisons
            var refined = try refine(left, plane, coarseX: matched.dx * previous.sourceScale,
                coarseY: matched.dy * previous.sourceScale, radius: previous.sourceScale == 1 ? 0 : previous.sourceScale, matchingRange: matchingRange, work: &work)
            if refined.meanSeamError > 0 || matched.ambiguous {
                // Quantization or averaging can alias even to a zero-error coarse proposal.
                // Every nonzero actual-float mismatch may be improved by exact linear feature
                // votes; the fallback remains O(pixels), never a full-resolution shift scan.
                let featureMatch = try exactFeatureMatch(left, plane, matchingRange: matchingRange, work: &work)
                if matched.ambiguous {
                    guard let featureMatch else {
                        throw LensWorksCatalogError.message("The overlapping seam is ambiguous: the selected photos do not contain enough distinct matching detail.")
                    }
                    refined = featureMatch
                } else if let featureMatch, featureMatch.meanSeamError < refined.meanSeamError {
                    refined = featureMatch
                }
            }
            alignments.append(refined)
        }
        return .init(alignments: alignments, work: work)
    }

    @_optimize(speed) static func render(_ planes: [LWFloatPlane], projection: LensWorksPanoramaProjection,
                       boundary: LensWorksPanoramaBoundary) throws -> LWFloatPlane {
        let alignments = try align(planes).alignments
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
                    let right = min(planes[frame].width - 1, left + 1), bottom = min(planes[frame].height - 1, top + 1)
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
    @_optimize(speed) private static func exactFeatureMatch(_ left: LWFloatPlane, _ right: LWFloatPlane,
        matchingRange: LensWorksPanoramaStitcher.Raster.MatchingRange, work: inout MatchingWork) throws -> LensWorksPanoramaAlignment? {
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
                work.featurePixels += 1
                guard let point = features[feature(tile.surface.pixels[y * entry.range.width + x])] else { continue }
                let offset = Offset(x: point.x - x - entry.range.x, y: point.y - y - entry.range.y)
                if abs(offset.x) <= maxDX, abs(offset.y) <= maxDY,
                   votes[offset] != nil || votes.count < 8192 { votes[offset, default: 0] += 1 }
            } }
        }
        work.peakFeatureVotes = max(work.peakFeatureVotes, votes.count)
        let candidates = votes.sorted {
            if $0.value != $1.value { return $0.value > $1.value }
            return $0.key.x == $1.key.x ? $0.key.y < $1.key.y : $0.key.x < $1.key.x
        }.prefix(8)
        if candidates.count > 1, candidates[candidates.startIndex].value == candidates[candidates.index(after: candidates.startIndex)].value { return nil }
        var best: LensWorksPanoramaAlignment?
        for (offset, count) in candidates where count >= 3 {
            let match = try refine(left, right, coarseX: offset.x, coarseY: offset.y, radius: 0, matchingRange: matchingRange, work: &work)
            if best == nil || match.meanSeamError < best!.meanSeamError { best = match }
            if match.meanSeamError == 0 { break }
        }
        return best
    }

    /// Refine descriptor displacement to original pixels without full-resolution descriptor arrays.
    /// At most 64 × 32 source sites, one small right-hand patch per site, and a bounded displacement
    /// neighbourhood. The same sample sites score every candidate, avoiding overlap-size bias.
    @_optimize(speed) private static func refine(_ left: LWFloatPlane, _ right: LWFloatPlane,
        coarseX: Int, coarseY: Int, radius: Int,
        matchingRange: LensWorksPanoramaStitcher.Raster.MatchingRange, work: inout MatchingWork) throws -> LensWorksPanoramaAlignment {
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
                    work.refinementSamples += 1
                    for channel in 0..<3 {
                        errors[index] += matchingRange.difference(a[channel], b[channel], channel: channel)
                    }
                }
                samples += 3
            }
        }
        guard let index = errors.indices.min(by: { errors[$0] < errors[$1] }) else { throw ProjectError.invalid }
        return .init(horizontalOffset: candidates[index].x, verticalOffset: candidates[index].y,
            meanSeamError: errors[index] / Double(samples))
    }

}
