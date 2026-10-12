import Foundation

/// Where a merged HDR photo came from, embedded in the DNG's XMP packet so the record
/// of its sources travels with the file. The catalog keeps its own copy of the link
/// (LensWorksCatalogIndex.recordSources), which is what the app reads. The packet
/// names each source by file name only and names no catalog: the file is meant to
/// be shared, so it carries no local path.
nonisolated struct LWHDRMergeProvenance: Codable, Equatable, Sendable {
    struct Source: Codable, Equatable, Sendable {
        let catalogImageID: String
        let assetID: String
        let variantID: String
        /// The source's file name; never a path.
        let fileName: String
        let sha256: String
        /// Exposure relative to the reference frame, in stops.
        let relativeExposureEV: Double
        let offset: LWHDROffset
        /// The source's embedded color profile name, when it has one.
        let profile: String?
    }
    let documentID: String
    let deghost: Bool
    let referenceIndex: Int
    /// Stops a renderer adds to the stored (normalized) samples to reproduce the reference exposure.
    let baselineExposure: Double
    let sources: [Source]

    static let namespace = "https://lensworks.trefry.net/ns/hdr-merge/1.0/"

    func xmp(creatorTool: String = "LensWorks Merge to HDR", reference: [String: String] = [:]) -> String {
        func esc(_ s: String) -> String {
            s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
        }
        let ingredients = sources.map { s in
            """
                <rdf:li rdf:parseType="Resource" stRef:filePath="\(esc(s.fileName))" lwhdr:catalogImageID="\(esc(s.catalogImageID))" lwhdr:assetID="\(esc(s.assetID))" lwhdr:variantID="\(esc(s.variantID))" lwhdr:sha256="\(esc(s.sha256))" lwhdr:relativeExposureEV="\(s.relativeExposureEV)" lwhdr:offsetX="\(s.offset.x)" lwhdr:offsetY="\(s.offset.y)"\(s.profile.map { " lwhdr:profile=\"\(esc($0))\"" } ?? "")/>
            """
        }.joined(separator: "\n")
        let copied = reference.sorted { $0.key < $1.key }.map { " \($0.key)=\"\(esc($0.value))\"" }.joined()
        return """
        <?xpacket begin="\u{FEFF}" id="W5M0MpCehiHzreSzNTczkc9d"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
         <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
          <rdf:Description rdf:about="" xmlns:xmp="http://ns.adobe.com/xap/1.0/" xmlns:xmpMM="http://ns.adobe.com/xap/1.0/mm/" xmlns:stRef="http://ns.adobe.com/xap/1.0/sType/ResourceRef#" xmlns:tiff="http://ns.adobe.com/tiff/1.0/" xmlns:exif="http://ns.adobe.com/exif/1.0/" xmlns:aux="http://ns.adobe.com/exif/1.0/aux/" xmlns:lwhdr="\(Self.namespace)" xmp:CreatorTool="\(esc(creatorTool))" xmpMM:DocumentID="xmp.did:\(esc(documentID))" xmpMM:InstanceID="xmp.iid:\(esc(documentID))" lwhdr:deghost="\(deghost)" lwhdr:referenceIndex="\(referenceIndex)" lwhdr:baselineExposure="\(baselineExposure)"\(copied)>
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

    static func parse(xmp: Data) throws -> Self {
        let document = try XMLDocument(data: xmp)
        guard let root = document.rootElement() else { throw LWHDRDNGError.missingProvenance }
        let descriptions = root.elements(forLocalName: "RDF", uri: "http://www.w3.org/1999/02/22-rdf-syntax-ns#")
            .flatMap { $0.elements(forLocalName: "Description", uri: "http://www.w3.org/1999/02/22-rdf-syntax-ns#") }
        guard let description = descriptions.first(where: { $0.attribute(forLocalName: "referenceIndex", uri: namespace) != nil }) else { throw LWHDRDNGError.missingProvenance }
        func attr(_ e: XMLElement, _ name: String, _ uri: String = namespace) -> String? { e.attribute(forLocalName: name, uri: uri)?.stringValue }
        let items = description.elements(forLocalName: "Ingredients", uri: "http://ns.adobe.com/xap/1.0/mm/")
            .flatMap { $0.elements(forLocalName: "Bag", uri: "http://www.w3.org/1999/02/22-rdf-syntax-ns#") }
            .flatMap { $0.elements(forLocalName: "li", uri: "http://www.w3.org/1999/02/22-rdf-syntax-ns#") }
        let sources = try items.map { item -> Source in
            guard let image = attr(item, "catalogImageID"), let asset = attr(item, "assetID"), let variant = attr(item, "variantID"),
                  let path = attr(item, "filePath", "http://ns.adobe.com/xap/1.0/sType/ResourceRef#"), let hash = attr(item, "sha256"),
                  let ev = attr(item, "relativeExposureEV").flatMap(Double.init), let x = attr(item, "offsetX").flatMap(Int.init),
                  let y = attr(item, "offsetY").flatMap(Int.init) else { throw LWHDRDNGError.missingProvenance }
            return Source(catalogImageID: image, assetID: asset, variantID: variant, fileName: path, sha256: hash,
                relativeExposureEV: ev, offset: LWHDROffset(x: x, y: y), profile: attr(item, "profile"))
        }
        guard let documentID = attr(description, "DocumentID", "http://ns.adobe.com/xap/1.0/mm/")?.replacingOccurrences(of: "xmp.did:", with: ""),
              let deghost = attr(description, "deghost").flatMap(Bool.init), let reference = attr(description, "referenceIndex").flatMap(Int.init),
              let baseline = attr(description, "baselineExposure").flatMap(Double.init), !sources.isEmpty else { throw LWHDRDNGError.missingProvenance }
        return Self(documentID: documentID, deghost: deghost, referenceIndex: reference,
            baselineExposure: baseline, sources: sources)
    }
}

nonisolated enum LWHDRDNGError: LocalizedError {
    case invalid, missingProvenance
    var errorDescription: String? {
        switch self {
        case .invalid: "The merged HDR DNG could not be written or read."
        case .missingProvenance: "The DNG carries no LensWorks HDR merge record."
        }
    }
}

/// Writes a merge as an uncompressed 32-bit floating-point LinearRaw DNG 1.4 whose
/// camera space is linear sRGB (D65), so a DNG reader develops it with identity color.
/// Samples are normalized so the brightest channel is 1.0; BaselineExposure restores
/// the reference exposure for renderers that apply it.
nonisolated enum LWHDRDNGWriter {
    /// XYZ (D65) → linear sRGB: ColorMatrix1 for a linear-sRGB camera.
    static let colorMatrix: [Double] = [3.2404542, -1.5371385, -0.4985314, -0.9692660, 1.8760108, 0.0415560, 0.0556434, -0.2040259, 1.0572252]
    /// White-balanced linear sRGB → XYZ (D50): ForwardMatrix1 (Bradford-adapted sRGB).
    static let forwardMatrix: [Double] = [0.4360747, 0.3850649, 0.1430804, 0.2225045, 0.7168786, 0.0606169, 0.0139322, 0.0971045, 0.7141733]

    static func normalization(_ result: LWHDRMergeResult) -> Float {
        var peak: Float = 0
        for value in result.samples { peak = max(peak, value) }
        return peak > 0 && peak.isFinite ? 1 / peak : 1
    }

    /// The whole file in memory, for callers that want the bytes. Merge to HDR… uses `write`.
    static func encode(_ result: LWHDRMergeResult, provenance: LWHDRMergeProvenance, reference: [String: String] = [:]) throws -> Data {
        var file = Data()
        try serialize(result, provenance: provenance, reference: reference) { file.append($0.bindMemory(to: UInt8.self)) }
        return file
    }

    /// Writes the file at `url`, which must not exist, a block at a time: the sample strip is
    /// scaled from the result straight to disk, with no whole-file buffer. An existing file is
    /// never replaced. On a throw (disk full, cancellation) the partial file is left for the caller to remove.
    static func write(_ result: LWHDRMergeResult, provenance: LWHDRMergeProvenance, reference: [String: String] = [:], to url: URL) throws {
        let descriptor = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO, userInfo: [NSFilePathErrorKey: url.path]) }
        let handle = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        try serialize(result, provenance: provenance, reference: reference) { block in
            try Task.checkCancellation()
            try handle.write(contentsOf: Data(block))
        }
        try handle.close()
    }

    /// Emits the file in order: the header, IFD and tag data, then the sample strip in blocks.
    private static func serialize(_ result: LWHDRMergeResult, provenance: LWHDRMergeProvenance, reference: [String: String],
                                  emit: (UnsafeRawBufferPointer) throws -> Void) throws {
        let scale = normalization(result)
        let pixelBytes = result.samples.count * MemoryLayout<Float>.stride
        let xmp = Data(provenance.xmp(reference: reference).utf8)
        guard pixelBytes < Int(UInt32.max) else { throw LWHDRDNGError.invalid }
        let width = UInt32(result.width), height = UInt32(result.height)
        let entries: [(UInt16, Value)] = [
            (254, .long([0])), (256, .long([width])), (257, .long([height])),
            (258, .short([32, 32, 32])), (259, .short([1])), (262, .short([34892])),
            (273, .long([0])), (274, .short([1])), (277, .short([3])),
            (278, .long([height])), (279, .long([UInt32(pixelBytes)])), (284, .short([1])),
            (305, .ascii("LensWorks Merge to HDR")),
            (339, .short([3, 3, 3])), (700, .byte(Array(xmp))),
            (50706, .byte([1, 4, 0, 0])), (50707, .byte([1, 4, 0, 0])),
            (50708, .ascii("LensWorks HDR Merge")), (50713, .short([1, 1])),
            (50714, .rational([0, 0, 0])), (50717, .long([1, 1, 1])),
            (50721, .srational(colorMatrix)), (50728, .rational([1, 1, 1])),
            (50730, .srational([provenance.baselineExposure])),
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
        guard pixelOffset + pixelBytes < Int(UInt32.max) else { throw LWHDRDNGError.invalid }
        if let strip = entries.firstIndex(where: { $0.0 == 273 }) { encodedEntries[strip] = encoded(.long([UInt32(pixelOffset)])) }
        var header = Data([0x49, 0x49, 42, 0])
        func put<T: FixedWidthInteger>(_ value: T) { var le = value.littleEndian; withUnsafeBytes(of: &le) { header.append(contentsOf: $0) } }
        put(UInt32(8)); put(UInt16(entries.count))
        for (index, entry) in entries.enumerated() {
            let item = encodedEntries[index]
            put(entry.0); put(item.type); put(item.count)
            if item.bytes.count > 4 { put(UInt32(extraOffsets[index])) }
            else { header.append(item.bytes); header.append(Data(repeating: 0, count: 4 - item.bytes.count)) }
        }
        put(UInt32(0))
        header.append(extra); header.append(Data(repeating: 0, count: padding))
        try header.withUnsafeBytes { try emit($0) }
        // Little-endian IEEE floats: the in-memory layout on every Mac LensWorks runs on (arm64).
        var block = [Float](repeating: 0, count: min(result.samples.count, 1 << 18))
        var offset = 0
        while offset < result.samples.count {
            let count = min(block.count, result.samples.count - offset)
            for index in 0..<count {
                let value = result.samples[offset + index]
                guard value.isFinite else { throw LWHDRDNGError.invalid }
                block[index] = max(0, value) * scale
            }
            try block.withUnsafeBytes { try emit(UnsafeRawBufferPointer(rebasing: $0[0..<(count * MemoryLayout<Float>.stride)])) }
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
/// the merged file's format and read its XMP provenance and float samples.
nonisolated struct LWDNGInspection: Sendable {
    let tags: [UInt16: [Double]]
    let xmp: Data?
    let width: Int, height: Int
    let floatSamples: [Float]?

    init(_ data: Data) throws {
        let bytes = [UInt8](data)
        guard bytes.count >= 8, bytes[0] == 0x49, bytes[1] == 0x49, bytes[2] == 42, bytes[3] == 0 else { throw LWHDRDNGError.invalid }
        func u16(_ o: Int) throws -> Int { guard o + 2 <= bytes.count else { throw LWHDRDNGError.invalid }; return Int(bytes[o]) | Int(bytes[o + 1]) << 8 }
        func u32(_ o: Int) throws -> Int { guard o + 4 <= bytes.count else { throw LWHDRDNGError.invalid }; return Int(bytes[o]) | Int(bytes[o + 1]) << 8 | Int(bytes[o + 2]) << 16 | Int(bytes[o + 3]) << 24 }
        let ifd = try u32(4), count = try u16(ifd)
        var tags: [UInt16: [Double]] = [:], xmp: Data?
        for index in 0..<count {
            let e = ifd + 2 + index * 12
            let tag = UInt16(try u16(e)), type = try u16(e + 2), n = try u32(e + 4)
            let size = [1: 1, 2: 1, 3: 2, 4: 4, 5: 8, 7: 1, 9: 4, 10: 8, 11: 4, 12: 8][type] ?? 0
            guard size > 0, n <= bytes.count else { throw LWHDRDNGError.invalid }
            let base = n * size > 4 ? try u32(e + 8) : e + 8
            guard base + n * size <= bytes.count else { throw LWHDRDNGError.invalid }
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

    func provenance() throws -> LWHDRMergeProvenance {
        guard let xmp else { throw LWHDRDNGError.missingProvenance }
        return try LWHDRMergeProvenance.parse(xmp: xmp)
    }
}
