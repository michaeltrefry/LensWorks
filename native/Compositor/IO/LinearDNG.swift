import Foundation

/// The kinds of catalog photo LensWorks derives from other catalog photos.
nonisolated enum LensWorksDerivedKind: String, Codable, Sendable, CaseIterable {
    case hdr, panorama
}

/// One source photo as a merged file's own record names it: by catalog identity, file name
/// (never a path: the file is meant to be shared) and the SHA-256 of its original.
nonisolated struct LWDerivedSourceRecord: Codable, Equatable, Sendable {
    let catalogImageID: String
    let assetID: String
    let variantID: String
    /// The source's file name; never a path.
    let fileName: String
    let sha256: String
}

/// What a merged DNG says about where it came from, whichever merge made it.
nonisolated struct LWDerivedMergeRecord: Equatable, Sendable {
    let kind: LensWorksDerivedKind
    let sources: [LWDerivedSourceRecord]
}

nonisolated enum LWLinearDNGError: LocalizedError {
    case invalid, missingProvenance
    var errorDescription: String? {
        switch self {
        case .invalid: "The merged DNG could not be written or read."
        case .missingProvenance: "The DNG carries no LensWorks merge record."
        }
    }
}

/// The XMP packet a merged DNG carries: one rdf:Description with the merge's own fields and an
/// xmpMM:Ingredients bag with one entry per source. Each merge has its own namespace and prefix.
nonisolated enum LWDerivedXMP {
    static let rdf = "http://www.w3.org/1999/02/22-rdf-syntax-ns#"
    static let mediaManagement = "http://ns.adobe.com/xap/1.0/mm/"
    static let resourceReference = "http://ns.adobe.com/xap/1.0/sType/ResourceRef#"

    static func escape(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// `fields` are the merge's attributes on the description; each source's `extra` follow its identity.
    static func packet(creatorTool: String, documentID: String, prefix: String, namespace: String, fields: [(String, String)],
                       sources: [(record: LWDerivedSourceRecord, extra: [(String, String)])], reference: [String: String]) -> String {
        let ingredients = sources.map { source in
            let identity = [("catalogImageID", source.record.catalogImageID), ("assetID", source.record.assetID), ("variantID", source.record.variantID), ("sha256", source.record.sha256)]
            let attributes = (identity + source.extra).map { " \(prefix):\($0.0)=\"\(escape($0.1))\"" }.joined()
            return "        <rdf:li rdf:parseType=\"Resource\" stRef:filePath=\"\(escape(source.record.fileName))\"\(attributes)/>"
        }.joined(separator: "\n")
        let own = fields.map { " \(prefix):\($0.0)=\"\(escape($0.1))\"" }.joined()
        let copied = reference.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(escape($0.value))\"" }.joined()
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="\(rdf)">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:xmpMM="\(mediaManagement)" xmlns:stRef="\(resourceReference)" xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" xmlns:\(prefix)="\(namespace)" xmp:CreatorTool="\(escape(creatorTool))" xmpMM:DocumentID="xmp.did:\(escape(documentID))" xmpMM:InstanceID="xmp.iid:\(escape(documentID))"\(own)\(copied)>
           <xmpMM:Ingredients>
            <rdf:Bag>
        \(ingredients)
            </rdf:Bag>
           </xmpMM:Ingredients>
          </rdf:Description>
         </rdf:RDF>
        </x:xmpmeta>
        <?xpacket end="w"?>
        """
    }

    struct Parsed {
        let documentID: String
        let description: XMLElement
        let items: [XMLElement]
        let namespace: String
        func field(_ name: String) -> String? { description.attribute(forLocalName: name, uri: namespace)?.stringValue }
        func field(_ name: String, of item: XMLElement) -> String? { item.attribute(forLocalName: name, uri: namespace)?.stringValue }
        /// Every source's identity; throws when one is incomplete.
        func sources() throws -> [LWDerivedSourceRecord] {
            try items.map { item in
                guard let image = field("catalogImageID", of: item), let asset = field("assetID", of: item), let variant = field("variantID", of: item),
                      let path = item.attribute(forLocalName: "filePath", uri: LWDerivedXMP.resourceReference)?.stringValue,
                      let hash = field("sha256", of: item) else { throw LWLinearDNGError.missingProvenance }
                return LWDerivedSourceRecord(catalogImageID: image, assetID: asset, variantID: variant, fileName: path, sha256: hash)
            }
        }
    }
    /// The description that carries `marker` in `namespace`, with its ingredients; throws `missingProvenance` without one.
    static func parse(xmp: Data, namespace: String, marker: String) throws -> Parsed {
        guard let document = try? XMLDocument(data: xmp), let root = document.rootElement() else { throw LWLinearDNGError.missingProvenance }
        let descriptions = root.elements(forLocalName: "RDF", uri: rdf).flatMap { $0.elements(forLocalName: "Description", uri: rdf) }
        guard let description = descriptions.first(where: { $0.attribute(forLocalName: marker, uri: namespace) != nil }) else { throw LWLinearDNGError.missingProvenance }
        let items = description.elements(forLocalName: "Ingredients", uri: mediaManagement)
            .flatMap { $0.elements(forLocalName: "Bag", uri: rdf) }.flatMap { $0.elements(forLocalName: "li", uri: rdf) }
        guard let documentID = description.attribute(forLocalName: "DocumentID", uri: mediaManagement)?.stringValue?.replacingOccurrences(of: "xmp.did:", with: ""),
              !items.isEmpty else { throw LWLinearDNGError.missingProvenance }
        return Parsed(documentID: documentID, description: description, items: items, namespace: namespace)
    }
}

/// Writes linear RGB as an uncompressed 32-bit floating-point LinearRaw DNG 1.4 whose camera
/// space is linear sRGB (D65), so a DNG reader develops it with identity color. The caller
/// supplies samples already normalized so the brightest channel is 1.0; BaselineExposure
/// restores the exposure for renderers that apply it.
nonisolated enum LWLinearDNGWriter {
    /// XYZ (D65) → linear sRGB: ColorMatrix1 for a linear-sRGB camera.
    static let colorMatrix: [Double] = [3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434, -0.2040259, 1.0572252]
    /// White-balanced linear sRGB → XYZ (D50): ForwardMatrix1 (Bradford-adapted sRGB).
    static let forwardMatrix: [Double] = [0.4360747, 0.3850649, 0.1430804, 0.2225045, 0.7168786, 0.0606169, 0.0139322, 0.0971045, 0.7141733]

    /// What the file says about itself, apart from its samples.
    struct Header {
        let width: Int, height: Int
        /// TIFF Software, and DNG UniqueCameraModel.
        let software: String, model: String
        let xmp: String
        let baselineExposure: Double
    }
    /// The scale that brings a picture whose brightest sample is `peak` to 1.0.
    static func normalization(peak: Float) -> Float { peak > 0 && peak.isFinite ? 1 / peak : 1 }

    /// Writes the file at `url`, which must not exist, a block at a time: `samples(first, block)`
    /// fills `block` with the normalized samples starting at sample index `first` (R, G, B per
    /// pixel, row-major), so there is no whole-file buffer. An existing file is never replaced.
    /// On a throw (disk full, cancellation) the partial file is left for the caller to remove.
    static func write(_ header: Header, to url: URL, samples: (Int, UnsafeMutableBufferPointer<Float>) throws -> Void) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path]) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try serialize(header, samples: samples) { block in
            try Task.checkCancellation()
            try handle.write(contentsOf: Data(block))
        }
        try handle.close()
    }

    /// Emits the file in order: the header, IFD and tag data, then the sample strip in blocks.
    static func serialize(_ header: Header, samples: (Int, UnsafeMutableBufferPointer<Float>) throws -> Void, emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        let sampleCount = header.width * header.height * 3
        let pixelBytes = sampleCount * MemoryLayout<Float>.stride
        let xmp = Data(header.xmp.utf8)
        guard header.width > 0, header.height > 0, pixelBytes < Int(UInt32.max) else { throw LWLinearDNGError.invalid }
        let width = UInt32(header.width), height = UInt32(header.height)
        let entries: [(UInt16, Value)] = [
            (254, .long([0])), (256, .long([width])), (257, .long([height])),
            (258, .short([32, 32, 32])), (259, .short([1])), (262, .short([34892])),
            (273, .long([0])), (274, .short([1])), (277, .short([3])),
            (278, .long([height])), (279, .long([UInt32(pixelBytes)])), (284, .short([1])),
            (305, .ascii(header.software)),
            (339, .short([3, 3, 3])), (700, .byte(Array(xmp))),
            (50706, .byte([1, 4, 0, 0])), (50707, .byte([1, 4, 0, 0])),
            (50708, .ascii(header.model)), (50713, .short([1, 1])),
            (50714, .rational([0, 0, 0])), (50717, .long([1, 1, 1])),
            (50721, .srational(colorMatrix)), (50728, .rational([1, 1, 1])),
            (50730, .srational([header.baselineExposure])),
            (50778, .short([21])), (50964, .srational(forwardMatrix)),
        ]
        let ifdSize = 2 + entries.count * 12 + 4
        var encodedEntries = entries.map { encoded($0.1) }
        var extra = Data(), extraOffsets: [Int] = []
        for item in encodedEntries {
            extraOffsets.append(8 + ifdSize + extra.count)
            if item.bytes.count > 4 { extra.append(item.bytes); if extra.count % 2 == 1 { extra.append(0) } }
        }
        var pixelOffset = 8 + ifdSize + extra.count
        let padding = (4 - pixelOffset % 4) % 4
        pixelOffset += padding
        guard pixelOffset + pixelBytes < Int(UInt32.max) else { throw LWLinearDNGError.invalid }
        if let strip = entries.firstIndex(where: { $0.0 == 273 }) { encodedEntries[strip] = encoded(.long([UInt32(pixelOffset)])) }
        var head = Data([0x49, 0x49, 42, 0])
        func put<T: FixedWidthInteger>(_ value: T) { var le = value.littleEndian; withUnsafeBytes(of: &le) { head.append(contentsOf: $0) } }
        put(UInt32(8)); put(UInt16(entries.count))
        for (index, entry) in entries.enumerated() {
            let item = encodedEntries[index]
            put(entry.0); put(item.type); put(item.count)
            if item.bytes.count > 4 { put(UInt32(extraOffsets[index])) }
            else { head.append(item.bytes); head.append(Data(repeating: 0, count: 4 - item.bytes.count)) }
        }
        put(UInt32(0))
        head.append(extra); head.append(Data(repeating: 0, count: padding))
        try head.withUnsafeBytes { try emit($0) }
        // Little-endian IEEE floats: the in-memory layout on every Mac LensWorks runs on (arm64).
        var block = [Float](repeating: 0, count: min(sampleCount, 3 << 16))
        var offset = 0
        while offset < sampleCount {
            let count = min(block.count, sampleCount - offset)
            try block.withUnsafeMutableBufferPointer { buffer in
                let part = UnsafeMutableBufferPointer(rebasing: buffer[0..<count])
                try samples(offset, part)
                for value in part where !value.isFinite || value < 0 { throw LWLinearDNGError.invalid }
                try emit(UnsafeRawBufferPointer(part))
            }
            offset += count
        }
    }

    private enum Value { case byte([UInt8]), ascii(String), short([UInt16]), long([UInt32]), rational([Double]), srational([Double]) }
    private static func encoded(_ value: Value) -> (type: UInt16, count: UInt32, bytes: Data) {
        var data = Data()
        func put<T: FixedWidthInteger>(_ v: T) { var le = v.littleEndian; withUnsafeBytes(of: &le) { data.append(contentsOf: $0) } }
        switch value {
        case .byte(let v): data.append(contentsOf: v); return (1, UInt32(v.count), data)
        case .ascii(let s): data.append(contentsOf: Array(s.utf8) + [0]); return (2, UInt32(s.utf8.count + 1), data)
        case .short(let v): v.forEach(put); return (3, UInt32(v.count), data)
        case .long(let v): v.forEach(put); return (4, UInt32(v.count), data)
        case .rational(let v): v.forEach { put(UInt32(($0 * 1_000_000).rounded())); put(UInt32(1_000_000)) }; return (5, UInt32(v.count), data)
        case .srational(let v): v.forEach { put(Int32(($0 * 1_000_000).rounded())); put(Int32(1_000_000)) }; return (10, UInt32(v.count), data)
        }
    }
}

/// Minimal reader for the first IFD of a little-endian TIFF/DNG: enough to verify
/// a merged file's format and read its XMP provenance and float samples.
nonisolated struct LWDNGInspection: Sendable {
    let tags: [UInt16: [Double]]
    let xmp: Data?
    let width: Int, height: Int
    let floatSamples: [Float]?

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0x49, bytes[1] == 0x49, bytes[2] == 42, bytes[3] == 0 else { throw LWLinearDNGError.invalid }
        func u16(_ o: Int) throws -> Int { guard o + 2 <= bytes.count else { throw LWLinearDNGError.invalid }; return Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) throws -> Int { guard o + 4 <= bytes.count else { throw LWLinearDNGError.invalid }; return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        let ifd = try u32(4), count = try u16(ifd)
        var tags: [UInt16: [Double]] = [:], xmp: Data?
        for index in 0..<count {
            let e = ifd + 2 + index * 12
            let tag = UInt16(try u16(e)), type = try u16(e + 2), n = try u32(e + 4)
            let size = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8, 11: 4, 12: 8][type] ?? 0
            guard size > 0, n <= bytes.count else { throw LWLinearDNGError.invalid }
            let base = n * size > 4 ? try u32(e + 8) : e + 8
            guard base + n * size <= bytes.count else { throw LWLinearDNGError.invalid }
            if tag == 700 { xmp = Data(bytes[base..<(base + n)]); continue }
            var values: [Double] = []
            for i in 0..<min(n, 64) {
                let o = base + i * size
                switch type {
                case 1, 2, 7: values.append(Double(bytes[o]))
                case 3: values.append(Double(try u16(o)))
                case 4: values.append(Double(try u32(o)))
                case 5: values.append(Double(try u32(o)) / Double(max(1, try u32(o + 4))))
                case 10: values.append(Double(Int32(truncatingIfNeeded: try u32(o))) / Double(Int32(truncatingIfNeeded: max(1, try u32(o + 4)))))
                default: break
                }
            }
            tags[tag] = values
        }
        self.tags = tags; self.xmp = xmp
        width = Int(tags[256]?.first ?? 0); height = Int(tags[257]?.first ?? 0)
        let isFloat: Bool = tags[339]?.first == 3 && tags[258]?.first == 32 && tags[259]?.first == 1 && tags[277]?.first == 3
        let offset: Int = Int(tags[273]?.first ?? -1), length: Int = Int(tags[279]?.first ?? -1)
        if isFloat, offset >= 0, length == width * height * 12, offset + length <= bytes.count {
            var samples = [Float](); samples.reserveCapacity(length / 4)
            for o in stride(from: offset, to: offset + length, by: 4) {
                let b0 = UInt32(bytes[o]), b1 = UInt32(bytes[o + 1]) << 8, b2 = UInt32(bytes[o + 2]) << 16, b3 = UInt32(bytes[o + 3]) << 24
                samples.append(Float(bitPattern: b0 | b1 | b2 | b3))
            }
            floatSamples = samples
        } else { floatSamples = nil }
    }

    /// The XMP packet of the DNG at `url`, read from its first IFD alone: the samples, hundreds of
    /// megabytes, are never read. Throws `missingProvenance` for a TIFF/DNG without one and
    /// `invalid` for any other file.
    static func xmp(at url: URL) throws -> Data {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        func bytes(_ offset: Int, _ count: Int) throws -> [UInt8] {
            try handle.seek(toOffset: UInt64(offset))
            guard let data = try handle.read(upToCount: count), data.count == count else { throw LWLinearDNGError.invalid }
            return [UInt8](data)
        }
        func u16(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 }
        func u32(_ b: [UInt8], _ o: Int) -> Int { Int(b[o]) | Int(b[o + 1]) << 8 | Int(b[o + 2]) << 16 | Int(b[o + 3]) << 24 }
        let header = try bytes(0, 8)
        guard header[0] == 0x49, header[1] == 0x49, header[2] == 42, header[3] == 0 else { throw LWLinearDNGError.invalid }
        let ifd = u32(header, 4), count = u16(try bytes(ifd, 2), 0)
        let entries = try bytes(ifd + 2, count * 12)
        for index in 0..<count where u16(entries, index * 12) == 700 {
            let e = index * 12, type = u16(entries, e + 2), length = u32(entries, e + 4)
            guard type == 1 || type == 7, length > 4, length <= 1024 * 1024 else { throw LWLinearDNGError.missingProvenance }
            return Data(try bytes(u32(entries, e + 8), length))
        }
        throw LWLinearDNGError.missingProvenance
    }

    /// The LensWorks merge record of the DNG at `url`, whichever merge wrote it.
    static func mergeRecord(at url: URL) throws -> LWDerivedMergeRecord {
        let packet = try xmp(at: url)
        if let hdr = try? LWHDRMergeProvenance.parse(xmp: packet) { return LWDerivedMergeRecord(kind: .hdr, sources: hdr.sources.map(\.record)) }
        let panorama = try LWPanoramaProvenance.parse(xmp: packet)
        return LWDerivedMergeRecord(kind: .panorama, sources: panorama.sources.map(\.record))
    }
}
