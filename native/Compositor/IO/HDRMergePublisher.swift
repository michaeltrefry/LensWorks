import Foundation
import CryptoKit

/// Classic little-endian TIFF/DNG 1.4 writer for a single uncompressed linear 32-bit float RGB image.
nonisolated enum LinearFloatDNG {
    /// XYZ(D65) -> linear sRGB, so the stored RGB is interpreted as linear sRGB by RAW development.
    private static let colorMatrix: [Int32] = [32406, -15372, -4986, -9689, 18758, 415, 557, -2040, 10570]

    static func encode(width: Int, height: Int, rgb: [Float], description: String) throws -> Data {
        guard width > 0, height > 0, rgb.count == width * height * 3 else { throw HDRMergeError.invalidFrame }
        struct Entry { let tag: UInt16; let type: UInt16; let count: UInt32; var value: Data }
        func u16(_ v: UInt16) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func u32(_ v: UInt32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        func i32(_ v: Int32) -> Data { withUnsafeBytes(of: v.littleEndian) { Data($0) } }
        let text = Data((description + "\0").utf8)
        let make = Data("LensWorks\0".utf8), model = Data("HDR Merge\0".utf8)
        let pixelBytes = UInt32(width * height * 3 * 4)
        var entries: [Entry] = [
            .init(tag: 254, type: 4, count: 1, value: u32(0)),
            .init(tag: 256, type: 4, count: 1, value: u32(UInt32(width))),
            .init(tag: 257, type: 4, count: 1, value: u32(UInt32(height))),
            .init(tag: 258, type: 3, count: 3, value: u16(32) + u16(32) + u16(32)),
            .init(tag: 259, type: 3, count: 1, value: u16(1)),
            .init(tag: 262, type: 3, count: 1, value: u16(34892)), // LinearRaw
            .init(tag: 270, type: 2, count: UInt32(text.count), value: text),
            .init(tag: 271, type: 2, count: UInt32(make.count), value: make),
            .init(tag: 272, type: 2, count: UInt32(model.count), value: model),
            .init(tag: 273, type: 4, count: 1, value: u32(0)), // patched below
            .init(tag: 274, type: 3, count: 1, value: u16(1)),
            .init(tag: 277, type: 3, count: 1, value: u16(3)),
            .init(tag: 278, type: 4, count: 1, value: u32(UInt32(height))),
            .init(tag: 279, type: 4, count: 1, value: u32(pixelBytes)),
            .init(tag: 284, type: 3, count: 1, value: u16(1)),
            .init(tag: 339, type: 3, count: 3, value: u16(3) + u16(3) + u16(3)), // IEEE float
            .init(tag: 50706, type: 1, count: 4, value: Data([1, 4, 0, 0])),
            .init(tag: 50707, type: 1, count: 4, value: Data([1, 4, 0, 0])),
            .init(tag: 50708, type: 2, count: UInt32(model.count), value: model),
            .init(tag: 50721, type: 10, count: 9, value: colorMatrix.reduce(Data()) { $0 + i32($1) + i32(10000) }),
            .init(tag: 50728, type: 5, count: 3, value: (0..<3).reduce(Data()) { acc, _ in acc + u32(1) + u32(1) }),
            .init(tag: 50778, type: 3, count: 1, value: u16(21)), // D65
        ]
        entries.sort { $0.tag < $1.tag }
        let ifdSize = 2 + entries.count * 12 + 4
        let extraOffset = 8 + ifdSize
        var extras = Data(), placed: [(Entry, UInt32?)] = []
        for e in entries {
            if e.value.count > 4 {
                if extras.count % 2 == 1 { extras.append(0) }
                placed.append((e, UInt32(extraOffset + extras.count))); extras.append(e.value)
            } else { placed.append((e, nil)) }
        }
        if extras.count % 4 != 0 { extras.append(Data(count: 4 - extras.count % 4)) }
        let pixelOffset = UInt32(extraOffset + extras.count)
        var out = Data("II".utf8) + u16(42) + u32(8) + u16(UInt16(entries.count))
        for (e, offset) in placed {
            out += u16(e.tag) + u16(e.type) + u32(e.count)
            if e.tag == 273 { out += u32(pixelOffset) }
            else if let offset { out += u32(offset) }
            else { out += e.value + Data(count: 4 - e.value.count) }
        }
        out += u32(0) + extras
        var pixels = Data(capacity: rgb.count * 4)
        for v in rgb { pixels.append(u32(v.bitPattern)) }
        return out + pixels
    }
}

nonisolated struct HDRMergeSourceRecord: Codable, Equatable, Sendable {
    let path: String
    let sha256: String
}

/// Provenance written beside the merged DNG; the catalog item for the DNG is linked to these sources.
nonisolated struct HDRMergeLinkRecord: Codable, Equatable, Sendable {
    let merged: String
    let sources: [HDRMergeSourceRecord]
    let deghost: Bool
    let align: Bool
}

nonisolated struct HDRMergePublication: Sendable {
    let dng: URL
    let link: URL
    let record: HDRMergeLinkRecord
}

/// Registers a published merge as a catalog item. The production conformer imports the destination folder.
protocol HDRMergeCatalogRegistering {
    func registerMerged(_ publication: HDRMergePublication) async throws
}

nonisolated enum HDRMergePublisher {
    static func sha256(_ url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1024 * 1024), !chunk.isEmpty { hasher.update(data: chunk) }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// Writes `<name>.dng` and `<name>.dng.sources.json` into the media folder. Sources are only read.
    static func publish(_ result: HDRMergeResult, sources: [URL], into directory: URL, name: String,
                        options: HDRMergeOptions) throws -> HDRMergePublication {
        let dng = directory.appendingPathComponent(name).appendingPathExtension("dng")
        let link = dng.appendingPathExtension("sources.json")
        let resolved = Set(sources.map { $0.resolvingSymlinksInPath().standardizedFileURL.path })
        guard !resolved.contains(dng.resolvingSymlinksInPath().standardizedFileURL.path) else { throw HDRMergeError.destinationIsSource }
        guard !FileManager.default.fileExists(atPath: dng.path), !FileManager.default.fileExists(atPath: link.path) else { throw HDRMergeError.destinationExists }
        let records = try sources.map { HDRMergeSourceRecord(path: $0.standardizedFileURL.path, sha256: try sha256($0)) }
        let record = HDRMergeLinkRecord(merged: dng.lastPathComponent, sources: records, deghost: options.deghost, align: options.align)
        let description = "LensWorks HDR merge of " + sources.map(\.lastPathComponent).joined(separator: ", ")
        let bytes = try LinearFloatDNG.encode(width: result.width, height: result.height, rgb: result.rgb, description: description)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try atomicWrite(bytes, to: dng)
        try atomicWrite(try encoder.encode(record), to: link)
        return HDRMergePublication(dng: dng, link: link, record: record)
    }

    private static func atomicWrite(_ data: Data, to url: URL) throws {
        let temp = url.deletingLastPathComponent().appendingPathComponent(".\(UUID().uuidString).partial")
        try data.write(to: temp)
        try FileManager.default.moveItem(at: temp, to: url)
    }
}
