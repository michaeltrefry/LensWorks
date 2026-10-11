import Foundation
import CoreGraphics
import CoreImage
import CryptoKit
import Darwin

/// One evaluation's factories own new private directories. All pixel arrays, scalar
/// rows, provider buffers and output buffers share the source plane's admission.
nonisolated struct LWFloatKernelWorkspace {
    let makeBuilder: (Int, Int) throws -> LWFloatPlane.Builder
    let makeScratchDirectory: () throws -> URL
    let fileOwner: LWFloatWorkspace?
    init(makeBuilder: @escaping (Int, Int) throws -> LWFloatPlane.Builder,
         makeScratchDirectory: @escaping () throws -> URL, fileOwner: LWFloatWorkspace? = nil) {
        self.makeBuilder = makeBuilder; self.makeScratchDirectory = makeScratchDirectory; self.fileOwner = fileOwner
    }

    func map(_ source: LWFloatPlane,
             _ operation: (SIMD4<Float>, Int, Int, LWFloatPlane.Sampler) throws -> SIMD4<Float>) throws -> LWFloatPlane {
        let builder = try makeBuilder(source.width, source.height)
        guard builder.workingSet === source.workingSet else { throw ProjectError.invalid }
        let sampler = source.sampler()
        while let range = builder.nextRange {
            try source.checkCancellation(); try fileOwner?.cancellation.check()
            let bytes = try range.validate(frameWidth: source.width, frameHeight: source.height)
            let lease = try source.workingSet.reserve(bytes)
            var pixels = [SIMD4<Float>](repeating: .zero, count: bytes / 16)
            for localY in 0..<range.height {
                try source.checkCancellation(); try fileOwner?.cancellation.check()
                for localX in 0..<range.width {
                    let x = range.x + localX, y = range.y + localY
                    let result = try operation(sampler.pixel(x: x, y: y), x, y, sampler)
                    guard result.x.isFinite, result.y.isFinite, result.z.isFinite,
                          result.w.isFinite, (0...1).contains(result.w) else { throw ProjectError.invalid }
                    pixels[localY * range.width + localX] = result
                }
            }
            let surface = try LWLinearSurface(width: range.width, height: range.height,
                pixels: pixels, maximumBytes: bytes)
            try builder.append(surface, at: range)
            withExtendedLifetime(lease) {}
        }
        return try builder.finish()
    }

    func rgb(_ source: LWFloatPlane,
             _ operation: (FloatImageAdjustmentPixels.RGB, Int, Int) throws -> FloatImageAdjustmentPixels.RGB) throws -> LWFloatPlane {
        try map(source) { pixel, x, y, _ in
            guard pixel.w > 0 else { return pixel }
            let c = try operation(SIMD3(Double(pixel.x), Double(pixel.y), Double(pixel.z)), x, y)
            return SIMD4(Float(c.x), Float(c.y), Float(c.z), pixel.w)
        }
    }

    /// Match the retained Double interpolation order, rather than rounding weights
    /// to Float or changing transparent-edge behavior at tile boundaries.
    static func sample(_ sampler: LWFloatPlane.Sampler, width: Int, height: Int,
                       x: Double, y: Double) throws -> SIMD4<Float> {
        guard x.isFinite, y.isFinite else { throw ProjectError.invalid }
        guard x > -1, y > -1, x < Double(width), y < Double(height) else { return .zero }
        let ix = Int(floor(x)), iy = Int(floor(y)), tx = x - floor(x), ty = y - floor(y)
        var color = SIMD3<Double>.zero, alpha = 0.0
        for dy in 0...1 { for dx in 0...1 {
            let sx = ix + dx, sy = iy + dy
            guard sx >= 0, sy >= 0, sx < width, sy < height else { continue }
            let weight = (dx == 0 ? 1 - tx : tx) * (dy == 0 ? 1 - ty : ty)
            let pixel = try sampler.pixel(x: sx, y: sy)
            let coverage = Double(pixel.w) * weight
            color += SIMD3(Double(pixel.x), Double(pixel.y), Double(pixel.z)) * coverage
            alpha += coverage
        } }
        guard alpha > 0 else { return .zero }
        color /= alpha
        return SIMD4(Float(color.x), Float(color.y), Float(color.z), Float(min(1, max(0, alpha))))
    }

    func scalar(_ plane: LWFloatPlane,
                _ value: (SIMD4<Float>) -> Double) throws -> LWFloatDoubleRows {
        try LWFloatDoubleRows.create(width: plane.width, height: plane.height,
            workingSet: plane.workingSet, directory: makeScratchDirectory(), fileOwner: fileOwner) { y in
            let row = try plane.read(LWFloatRange(x: 0, y: y, width: plane.width, height: 1))
            return row.surface.pixels.map(value)
        }
    }

    /// Full-frame separable running sums. Horizontal and vertical floating-point
    /// update order is identical to the retained array algorithm, across all tiles.
    func blur(_ source: LWFloatDoubleRows, radius inputRadius: Int) throws -> LWFloatDoubleRows {
        let radius = min(64, max(1, inputRadius)), size = Double(2 * radius + 1)
        let width = source.width, height = source.height
        let horizontal = try LWFloatDoubleRows.create(width: width, height: height,
            workingSet: source.workingSet, directory: makeScratchDirectory(), fileOwner: fileOwner) { y in
            let row = try source.read(y)
            var result = [Double](repeating: 0, count: width), sum = 0.0
            for dx in -radius...radius { sum += row.values[min(width - 1, max(0, dx))] }
            for x in 0..<width {
                result[x] = sum / size
                sum += row.values[min(width - 1, x + radius + 1)] - row.values[max(0, x - radius)]
            }
            return result
        }
        let sumsLease = try source.workingSet.reserve(try LWFloatDoubleRows.rowBytes(width))
        var sums = [Double](repeating: 0, count: width)
        for dy in -radius...radius {
            let row = try horizontal.read(min(height - 1, max(0, dy)))
            for x in 0..<width { sums[x] += row.values[x] }
        }
        let result = try LWFloatDoubleRows.create(width: width, height: height,
            workingSet: source.workingSet, directory: makeScratchDirectory(), fileOwner: fileOwner) { y in
            var output = [Double](repeating: 0, count: width)
            for x in 0..<width { output[x] = sums[x] / size }
            let incoming = try horizontal.read(min(height - 1, y + radius + 1))
            let outgoing = try horizontal.read(max(0, y - radius))
            for x in 0..<width { sums[x] += incoming.values[x] - outgoing.values[x] }
            return output
        }
        withExtendedLifetime(sumsLease) {}
        return result
    }
}

/// Immutable f64 scratch rows. Extent may exceed resident memory; only a caller-
/// admitted row and compact row identities are retained. No entire field Data/array.
nonisolated final class LWFloatDoubleRows {
    struct Identity { let device: dev_t; let inode: ino_t; let digest: SIMD4<UInt64> }
    final class Row {
        struct Values:RandomAccessCollection,Equatable {
            typealias Index=Int
            private final class Storage {
                let values:[Double]
                let lease:LWFloatWorkingSet.Lease
                init(_ values:[Double],_ lease:LWFloatWorkingSet.Lease) { self.values=values;self.lease=lease }
            }
            private let storage:Storage
            fileprivate init(_ values:[Double],_ lease:LWFloatWorkingSet.Lease) { storage=Storage(values,lease) }
            var startIndex:Int { 0 }
            var endIndex:Int { storage.values.count }
            func index(after index:Int)->Int { index+1 }
            func index(before index:Int)->Int { index-1 }
            subscript(index:Int)->Double { storage.values[index] }
            static func ==(lhs:Self,rhs:Self)->Bool { lhs.elementsEqual(rhs) }
            static func ==(lhs:Self,rhs:[Double])->Bool { lhs.elementsEqual(rhs) }
        }
        // A values view or slice retains the exact row allocation's charge even
        // after the Row/Reader is released. It cannot expose mutable Array COW.
        let values:Values
        init(_ values:[Double],_ lease:LWFloatWorkingSet.Lease) { self.values=Values(values,lease) }
    }
    let width: Int
    let height: Int
    let workingSet: LWFloatWorkingSet
    private let directory: URL
    private let fileOwner: LWFloatWorkspace?
    private let lifetime: LWFloatWorkspace.ChildLifetime?
    private let fd: Int32
    private struct Parent { let descriptor: Int32; let name: String; let device: dev_t; let inode: ino_t }
    private let parents: [Parent]
    private let parentLease: LWFloatWorkingSet.Lease
    private let directoryDevice: dev_t
    private let directoryInode: ino_t
    private var identities: [Identity] = []
    private let identityLease: LWFloatWorkingSet.Lease
    private var sealed = false
    static func rowBytes(_ width: Int) throws -> Int {
        let (bytes, overflow) = width.multipliedReportingOverflow(by: MemoryLayout<Double>.stride)
        guard width > 0, !overflow else { throw ProjectError.tooLarge }
        return bytes
    }
    private init(width: Int, height: Int, workingSet: LWFloatWorkingSet, directory: URL, fileOwner: LWFloatWorkspace?) throws {
        guard fileOwner == nil || fileOwner!.workingSet === workingSet else { throw ProjectError.invalid }
        let ownedLifetime = try fileOwner?.retainChild(directory)
        try LWFloatPlane.validateExtent(width: width, height: height)
        guard directory.isFileURL, directory.hasNormalizedPath,
            directory.isUnaliasedFilePath else { throw ProjectError.invalid }
        let (bytes, overflow) = height.multipliedReportingOverflow(by: MemoryLayout<Identity>.stride)
        guard !overflow else { throw ProjectError.tooLarge }
        identityLease = try workingSet.reserve(bytes)
        let components = directory.pathComponents
        let (parentBytes, parentOverflow) = components.count.multipliedReportingOverflow(by: MemoryLayout<Parent>.stride)
        let (charge, chargeOverflow) = parentBytes.addingReportingOverflow(directory.path.utf8.count)
        guard !parentOverflow, !chargeOverflow else { throw ProjectError.tooLarge }
        parentLease = try workingSet.reserve(charge)
        var chain: [Parent] = []
        chain.reserveCapacity(components.count)
        let rootFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard rootFD >= 0 else { throw ProjectError.invalid }
        var rootInfo = stat()
        guard fstat(rootFD, &rootInfo) == 0 else { close(rootFD); throw ProjectError.invalid }
        chain.append(Parent(descriptor: rootFD, name: "/", device: rootInfo.st_dev, inode: rootInfo.st_ino))
        do {
            for name in components.dropFirst() {
                let descriptor = openat(chain.last!.descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard descriptor >= 0 else { throw ProjectError.invalid }
                var info = stat()
                guard fstat(descriptor, &info) == 0 else { close(descriptor); throw ProjectError.invalid }
                chain.append(Parent(descriptor: descriptor, name: name, device: info.st_dev, inode: info.st_ino))
            }
        } catch { for parent in chain.reversed() { close(parent.descriptor) }; throw error }
        let descriptor = chain.last!.descriptor
        var info = stat()
        guard fstat(descriptor, &info) == 0, info.st_uid == getuid(),
            (info.st_mode & S_IFMT) == S_IFDIR, (info.st_mode & 0o777) == 0o700 else {
            for parent in chain.reversed() { close(parent.descriptor) }; throw ProjectError.invalid
        }
        self.width = width; self.height = height; self.workingSet = workingSet
        self.directory = directory; self.fileOwner = fileOwner
        lifetime = ownedLifetime
        fd = descriptor; parents = chain
        directoryDevice = info.st_dev; directoryInode = info.st_ino
        do {
            try checkDirectory()
            let duplicate = dup(fd)
            guard duplicate >= 0 else { throw ProjectError.invalid }
            guard let stream = fdopendir(duplicate) else { close(duplicate); throw ProjectError.invalid }
            defer { closedir(stream) }
            errno = 0
            while let entry = readdir(stream) {
                let name = withUnsafeBytes(of: entry.pointee.d_name) { raw in
                    String(cString: raw.baseAddress!.assumingMemoryBound(to: CChar.self))
                }
                guard name == "." || name == ".." else { throw ProjectError.invalid }
            }
            guard errno == 0 else { throw ProjectError.invalid }
        } catch { for parent in chain.reversed() { close(parent.descriptor) }; throw error }
        identities.reserveCapacity(height)
    }
    deinit { for parent in parents.reversed() { close(parent.descriptor) } }
    private func checkDirectory() throws {
        try fileOwner?.cancellation.check()
        for (index, parent) in parents.enumerated() {
            var held = stat(), named = stat()
            guard fstat(parent.descriptor, &held) == 0, held.st_dev == parent.device,
                held.st_ino == parent.inode, (held.st_mode & S_IFMT) == S_IFDIR else { throw ProjectError.invalid }
            if index == 0 {
                guard lstat("/", &named) == 0 else { throw ProjectError.invalid }
            } else {
                guard fstatat(parents[index - 1].descriptor, parent.name, &named, AT_SYMLINK_NOFOLLOW) == 0 else { throw ProjectError.invalid }
            }
            guard named.st_dev == held.st_dev, named.st_ino == held.st_ino,
                (named.st_mode & S_IFMT) == S_IFDIR else { throw ProjectError.invalid }
        }
        var held = stat(), named = stat()
        guard fstat(fd, &held) == 0, lstat(directory.path, &named) == 0,
            held.st_dev == directoryDevice, held.st_ino == directoryInode,
            named.st_dev == held.st_dev, named.st_ino == held.st_ino,
            named.st_uid == getuid(), (named.st_mode & S_IFMT) == S_IFDIR,
            (named.st_mode & 0o777) == 0o700,
            directory.isUnaliasedFilePath else { throw ProjectError.invalid }
    }
    private static func digest(_ data: Data) -> SIMD4<UInt64> {
        let bytes = Array(SHA256.hash(data: data))
        func word(_ i: Int) -> UInt64 { (0..<8).reduce(0) { $0 | UInt64(bytes[i + $1]) << (8 * $1) } }
        return SIMD4(word(0), word(8), word(16), word(24))
    }
    private func checked(_ descriptor: Int32, name: String, bytes: Int, mode: mode_t) throws -> stat {
        var held = stat(), named = stat()
        guard fstat(descriptor, &held) == 0, fstatat(fd, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
            (held.st_mode & S_IFMT) == S_IFREG, held.st_uid == getuid(), held.st_nlink == 1,
            (held.st_mode & 0o777) == mode, held.st_size == bytes,
            named.st_dev == held.st_dev, named.st_ino == held.st_ino,
            named.st_size == held.st_size, named.st_mtimespec.tv_sec == held.st_mtimespec.tv_sec,
            named.st_mtimespec.tv_nsec == held.st_mtimespec.tv_nsec,
            named.st_ctimespec.tv_sec == held.st_ctimespec.tv_sec, named.st_ctimespec.tv_nsec == held.st_ctimespec.tv_nsec else { throw ProjectError.invalid }
        return held
    }
    static func create(width: Int, height: Int, workingSet: LWFloatWorkingSet,
                       directory: URL, fileOwner: LWFloatWorkspace? = nil, row: (Int) throws -> [Double]) throws -> LWFloatDoubleRows {
        let result = try LWFloatDoubleRows(width: width, height: height, workingSet: workingSet, directory: directory, fileOwner: fileOwner)
        let bytes = try rowBytes(width), (charge, overflow) = bytes.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw ProjectError.tooLarge }
        for y in 0..<height {
            try Task.checkCancellation()
            let lease = try workingSet.reserve(charge)
            let values = try row(y)
            guard values.count == width, values.allSatisfy(\.isFinite) else { throw ProjectError.invalid }
            var data = Data(); data.reserveCapacity(bytes)
            for value in values {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
            try result.append(data, y: y)
            withExtendedLifetime(lease) {}
        }
        result.sealed = true
        try result.checkDirectory()
        return result
    }
    private func append(_ data: Data, y: Int) throws {
        guard !sealed, y == identities.count else { throw ProjectError.invalid }
        try checkDirectory()
        let name = String(format: "%08d.f64", y)
        let descriptor = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw ProjectError.invalid }
        defer { close(descriptor) }
        try fileOwner?.registerCreatedFile(directory: directory, name: name, descriptor: descriptor)
        // Retain the exact partial member on a failed write; never infer ownership by enumeration.
        defer { try? fileOwner?.captureWrittenFile(directory: directory, name: name, descriptor: descriptor) }
        try data.withUnsafeBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                try Task.checkCancellation(); try fileOwner?.cancellation.check()
                let n = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ProjectError.encode }; offset += n
            }
        }
        _ = try checked(descriptor, name: name, bytes: data.count, mode: 0o600)
        guard fsync(descriptor) == 0, fchmod(descriptor, 0o444) == 0, fsync(descriptor) == 0, fsync(fd) == 0 else { throw ProjectError.encode }
        let info = try checked(descriptor, name: name, bytes: data.count, mode: 0o444)
        try fileOwner?.captureWrittenFile(directory: directory, name: name, descriptor: descriptor)
        identities.append(Identity(device: info.st_dev, inode: info.st_ino, digest: Self.digest(data)))
        try checkDirectory()
    }
    func read(_ y: Int) throws -> Row {
        try Task.checkCancellation(); try checkDirectory()
        guard sealed, y >= 0, y < height else { throw ProjectError.invalid }
        let bytes = try Self.rowBytes(width), (charge, overflow) = bytes.multipliedReportingOverflow(by: 2)
        guard !overflow else { throw ProjectError.tooLarge }
        let lease = try workingSet.reserve(charge), name = String(format: "%08d.f64", y)
        let descriptor = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw ProjectError.invalid }
        defer { close(descriptor) }
        let before = try checked(descriptor, name: name, bytes: bytes, mode: 0o444), expected = identities[y]
        guard before.st_dev == expected.device, before.st_ino == expected.inode else { throw ProjectError.invalid }
        var data = Data(count: bytes)
        try data.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < bytes {
                try Task.checkCancellation(); try fileOwner?.cancellation.check()
                let n = Darwin.read(descriptor, buffer.baseAddress!.advanced(by: offset), bytes - offset)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw ProjectError.invalid }; offset += n
            }
            var excess: UInt8 = 0
            guard Darwin.read(descriptor, &excess, 1) == 0 else { throw ProjectError.invalid }
        }
        let after = try checked(descriptor, name: name, bytes: bytes, mode: 0o444)
        guard before.st_mtimespec.tv_sec == after.st_mtimespec.tv_sec,
            before.st_mtimespec.tv_nsec == after.st_mtimespec.tv_nsec,
            before.st_ctimespec.tv_sec == after.st_ctimespec.tv_sec, before.st_ctimespec.tv_nsec == after.st_ctimespec.tv_nsec,
            Self.digest(data) == expected.digest else { throw ProjectError.invalid }
        var values = [Double](repeating: 0, count: width)
        for x in 0..<width {
            let bits = (0..<8).reduce(UInt64(0)) { $0 | UInt64(data[x * 8 + $1]) << (8 * $1) }
            values[x] = Double(bitPattern: bits)
        }
        guard values.allSatisfy(\.isFinite) else { throw ProjectError.invalid }
        try checkDirectory()
        return Row(values, lease)
    }
    func value(x: Int, y: Int) throws -> Double {
        guard x >= 0, x < width else { throw ProjectError.invalid }
        return try read(y).values[x]
    }
    /// Per-pass cache holds at most three admitted rows, never a whole field.
    final class Reader {
        let field: LWFloatDoubleRows
        private var rows: [(y: Int, row: Row)] = []
        init(_ field: LWFloatDoubleRows) { self.field = field }
        func row(_ y: Int) throws -> Row {
            try field.checkDirectory(); try Task.checkCancellation()
            if let index = rows.firstIndex(where: { $0.y == y }) {
                let item = rows.remove(at: index); rows.append(item); return item.row
            }
            if rows.count == 3 { rows.removeFirst() }
            let value = try field.read(y); rows.append((y, value)); return value
        }
        func value(x: Int, y: Int) throws -> Double {
            guard x >= 0, x < field.width else { throw ProjectError.invalid }
            return try row(y).values[x]
        }
        func edge(x: Int, y: Int, radius: Int) throws -> Double {
            let radius = max(1, radius), center = try value(x: x, y: y)
            var sum = 0.0, count = 0
            for dy in stride(from: -radius, through: radius, by: radius) {
                let sy = y + dy
                guard sy >= 0, sy < field.height else { continue }
                let values = try row(sy).values
                for dx in stride(from: -radius, through: radius, by: radius) where dx != 0 || dy != 0 {
                    let sx = x + dx
                    if sx >= 0, sx < field.width { sum += abs(values[sx] - center); count += 1 }
                }
            }
            return count == 0 ? 0 : sum / Double(count)
        }
    }
    func reader() -> Reader { Reader(self) }
    func edge(x: Int, y: Int, radius: Int) throws -> Double {
        let radius = max(1, radius), center = try value(x: x, y: y)
        var sum = 0.0, count = 0
        for dy in stride(from: -radius, through: radius, by: radius) {
            let sy = y + dy
            guard sy >= 0, sy < height else { continue }
            let row = try read(sy)
            for dx in stride(from: -radius, through: radius, by: radius) where dx != 0 || dy != 0 {
                let sx = x + dx
                if sx >= 0 && sx < width { sum += abs(row.values[sx] - center); count += 1 }
            }
        }
        return count == 0 ? 0 : sum / Double(count)
    }
}

nonisolated extension LWFloatKernelWorkspace {
    /// Same global retained operator, backed by bounded provider reads rather
    /// than a dependency-ROI array that can exceed native admission at full size.
    func coreImage(_ source:LWFloatPlane,gaussianSigma:Double?,
        motionRadius:Double,motionAngle:Double)throws->LWFloatPlane {
        guard gaussianSigma.map({$0.isFinite && $0>=0}) ?? true,
            motionRadius.isFinite,motionRadius>=0,motionAngle.isFinite else { throw ProjectError.invalid }
        return try LWFloatCoreImage.render(source,makeBuilder:makeBuilder,cancellation:fileOwner?.cancellation) { input in
            let edges=input.clampedToExtent()
            if let sigma=gaussianSigma { return edges.applyingGaussianBlur(sigma:sigma) }
            return edges.applyingFilter("CIMotionBlur",parameters:[kCIInputRadiusKey:motionRadius,kCIInputAngleKey:motionAngle])
        }
    }
    static func coreImageRange(_ dependency: CGRect, extent: CGRect) throws -> LWFloatRange {
        guard !dependency.isNull, !dependency.isInfinite,
            [dependency.minX, dependency.minY, dependency.maxX, dependency.maxY].allSatisfy(\.isFinite),
            dependency.width > 0, dependency.height > 0 else { throw ProjectError.invalid }
        let clipped = dependency.integral.intersection(extent)
        guard !clipped.isNull, clipped.width > 0, clipped.height > 0 else { throw ProjectError.invalid }
        return LWFloatRange(x: Int(clipped.minX), y: Int(extent.height - clipped.maxY),
            width: Int(clipped.width), height: Int(clipped.height))
    }
}
