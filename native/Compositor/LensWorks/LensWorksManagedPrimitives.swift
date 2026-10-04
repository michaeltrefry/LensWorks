import Foundation

nonisolated enum LensWorksManagedError: Error, LocalizedError, Sendable {
    case native(code: String, message: String)
    case abi(status: Int32, operation: String)
    case protocolViolation(String)
    case closed
    case resourceLimit(String)

    var errorDescription: String? {
        switch self {
        case .native(_, let message), .protocolViolation(let message), .resourceLimit(let message): message
        case .abi(let status, let operation): "Catalog ABI \(operation) failed with status \(status)."
        case .closed: "The catalog resource has been released."
        }
    }
}

/// Authority integers use the retained canonical decimal-string wire format, never JSON numbers.
nonisolated struct LWCatalogI64: Codable, Sendable, Hashable {
    let value: Int64
    init(_ value: Int64) { self.value = value }
    init(decimal: String) throws {
        guard let value = Int64(decimal), String(value) == decimal else {
            throw LensWorksManagedError.protocolViolation("Expected a canonical signed 64-bit decimal string.")
        }
        self.value = value
    }
    init(from decoder: any Decoder) throws { try self.init(decimal: decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(String(value)) }
}

nonisolated struct LWCatalogU64: Codable, Sendable, Hashable {
    let value: UInt64
    init(_ value: UInt64) { self.value = value }
    init(decimal: String) throws {
        guard let value = UInt64(decimal), String(value) == decimal else {
            throw LensWorksManagedError.protocolViolation("Expected a canonical unsigned 64-bit decimal string.")
        }
        self.value = value
    }
    init(from decoder: any Decoder) throws { try self.init(decimal: decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(String(value)) }
}

nonisolated struct LWCatalogU128: Codable, Sendable, Hashable {
    let decimal: String
    init(decimal: String) throws {
        let maximum = "340282366920938463463374607431768211455"
        guard !decimal.isEmpty, decimal.utf8.allSatisfy({ (48...57).contains($0) }),
              decimal == "0" || decimal.first != "0", decimal.count < maximum.count || (decimal.count == maximum.count && decimal <= maximum) else {
            throw LensWorksManagedError.protocolViolation("Expected a canonical unsigned 128-bit decimal string.")
        }
        self.decimal = decimal
    }
    init(from decoder: any Decoder) throws { try self.init(decimal: decoder.singleValueContainer().decode(String.self)) }
    func encode(to encoder: any Encoder) throws { var container = encoder.singleValueContainer(); try container.encode(decimal) }
}

nonisolated enum LWCatalogSessionKind: Sendable {}
nonisolated enum LWCatalogJobKind: Sendable {}
nonisolated enum LWCatalogBufferKind: Sendable {}
nonisolated enum LWCatalogSubscriptionKind: Sendable {}
nonisolated struct LWCatalogHandle<Kind: Sendable>: Codable, Sendable, Hashable {
    let value: UInt64
    init(_ value: UInt64) throws {
        guard value != 0 else { throw LensWorksManagedError.protocolViolation("A catalog handle cannot be zero.") }
        self.value = value
    }
    init(from decoder: any Decoder) throws { try self.init(LWCatalogU64(from: decoder).value) }
    func encode(to encoder: any Encoder) throws { try LWCatalogU64(value).encode(to: encoder) }
}
typealias LWCatalogSessionHandle = LWCatalogHandle<LWCatalogSessionKind>
typealias LWCatalogJobHandle = LWCatalogHandle<LWCatalogJobKind>
typealias LWCatalogBufferHandle = LWCatalogHandle<LWCatalogBufferKind>
typealias LWCatalogSubscriptionHandle = LWCatalogHandle<LWCatalogSubscriptionKind>

/// Retains native filesystem units, including non-UTF-8 Unix names and foreign Windows paths.
nonisolated enum LWCatalogNativePath: Codable, Sendable, Hashable {
    case unixBytes([UInt8])
    case windowsWide([UInt16])
    private enum Keys: String, CodingKey { case encoding, units }
    init(unixBytes: [UInt8]) throws {
        guard !unixBytes.contains(0) else { throw LensWorksManagedError.protocolViolation("Native paths cannot contain NUL.") }
        self = .unixBytes(unixBytes)
    }
    init(fileURL: URL) throws {
        guard fileURL.isFileURL else { throw LensWorksManagedError.protocolViolation("A native path requires a file URL.") }
        let bytes = fileURL.withUnsafeFileSystemRepresentation { pointer -> [UInt8]? in
            guard let pointer else { return nil }
            return Array(UnsafeRawBufferPointer(start: pointer, count: strlen(pointer)))
        }
        guard let bytes else { throw LensWorksManagedError.protocolViolation("The file URL has no native path representation.") }
        try self.init(unixBytes: bytes)
    }
    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: Keys.self)
        switch try container.decode(String.self, forKey: .encoding) {
        case "UnixBytes": self = .unixBytes(try container.decode([UInt8].self, forKey: .units))
        case "WindowsWide": self = .windowsWide(try container.decode([UInt16].self, forKey: .units))
        default: throw LensWorksManagedError.protocolViolation("Unknown native path encoding.")
        }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: Keys.self)
        switch self {
        case .unixBytes(let units): try container.encode("UnixBytes", forKey: .encoding); try container.encode(units, forKey: .units)
        case .windowsWide(let units): try container.encode("WindowsWide", forKey: .encoding); try container.encode(units, forKey: .units)
        }
    }
    /// Foreign units remain data and are never implicitly converted into a local path.
    func localFileURL() throws -> URL {
        guard case .unixBytes(let bytes) = self, !bytes.contains(0) else {
            throw LensWorksManagedError.protocolViolation("This path needs an explicit platform mapping.")
        }
        return (bytes + [0]).withUnsafeBufferPointer { buffer in
            URL(fileURLWithFileSystemRepresentation: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: CChar.self), isDirectory: false, relativeTo: nil)
        }
    }
}

/// Used only where the retained public DTO itself carries arbitrary JSON values.
nonisolated indirect enum LWCatalogJSON: Codable, Sendable, Equatable {
    case null, bool(Bool), string(String), signed(Int64), unsigned(UInt64), number(Double)
    case array([LWCatalogJSON]), object([String: LWCatalogJSON])
    init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() { self = .null }
        else if let value = try? container.decode(Bool.self) { self = .bool(value) }
        else if let value = try? container.decode(String.self) { self = .string(value) }
        else if LWCatalogCodec.isFloating(decoder), let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode(Int64.self) { self = .signed(value) }
        else if let value = try? container.decode(UInt64.self) { self = .unsigned(value) }
        else if let value = try? container.decode(Double.self), value.isFinite { self = .number(value) }
        else if let value = try? container.decode([LWCatalogJSON].self) { self = .array(value) }
        else { self = .object(try container.decode([String: LWCatalogJSON].self)) }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null: try container.encodeNil()
        case .bool(let value): try container.encode(value)
        case .string(let value): try container.encode(value)
        case .signed(let value): try container.encode(value)
        case .unsigned(let value): try container.encode(value)
        case .number(let value): LWCatalogCodec.recordFloating(encoder); guard value.isFinite else { throw LensWorksManagedError.protocolViolation("JSON numbers must be finite.") }; try container.encode(value)
        case .array(let value): try container.encode(value)
        case .object(let value): try container.encode(value)
        }
    }
}

nonisolated struct LWCatalogPair<A: Codable & Sendable, B: Codable & Sendable>: Codable, Sendable {
    let first: A
    let second: B
    init(first: A, second: B) { self.first = first; self.second = second }
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        first = try container.decode(A.self); second = try container.decode(B.self)
        guard container.isAtEnd else { throw LensWorksManagedError.protocolViolation("Expected exactly two tuple elements.") }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer(); try container.encode(first); try container.encode(second)
    }
}

nonisolated struct LWCatalogCodingKey: CodingKey, Hashable {
    let stringValue: String
    var intValue: Int? { nil }
    init(_ value: String) { stringValue = value }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}

nonisolated struct LWCatalogTriple<A: Codable & Sendable, B: Codable & Sendable, C: Codable & Sendable>: Codable, Sendable {
    let first: A
    let second: B
    let third: C
    init(first: A, second: B, third: C) { self.first = first; self.second = second; self.third = third }
    init(from decoder: any Decoder) throws {
        var container = try decoder.unkeyedContainer()
        first = try container.decode(A.self); second = try container.decode(B.self); third = try container.decode(C.self)
        guard container.isAtEnd else { throw LensWorksManagedError.protocolViolation("Expected exactly three tuple elements.") }
    }
    func encode(to encoder: any Encoder) throws {
        var container = encoder.unkeyedContainer(); try container.encode(first); try container.encode(second); try container.encode(third)
    }
}

nonisolated extension KeyedDecodingContainer where Key == LWCatalogCodingKey {
    func lwRequireKeys(_ allowed: [String]) throws {
        let allowed = Set(allowed)
        guard allKeys.allSatisfy({ allowed.contains($0.stringValue) }) else {
            throw LensWorksManagedError.protocolViolation("The retained DTO rejects unknown fields.")
        }
    }
}

/// Lightroom's exact hex_bytes field adapter preserves opaque packet bytes rather than Unicode text.
nonisolated struct LWCatalogHexBytes: Codable, Sendable, Equatable {
    let bytes: [UInt8]
    init(_ bytes: [UInt8]) { self.bytes = bytes }
    init(from decoder: any Decoder) throws {
        let text = try decoder.singleValueContainer().decode(String.self)
        let units = Array(text.utf8)
        guard units.count.isMultiple(of: 2) else { throw LensWorksManagedError.protocolViolation("Expected even-length hexadecimal bytes.") }
        func nibble(_ unit: UInt8) throws -> UInt8 {
            switch unit {
            case 48...57: return unit - 48
            case 65...70: return unit - 55
            case 97...102: return unit - 87
            default: throw LensWorksManagedError.protocolViolation("Expected hexadecimal bytes.")
            }
        }
        bytes = try stride(from: 0, to: units.count, by: 2).map { try nibble(units[$0]) << 4 | nibble(units[$0 + 1]) }
    }
    func encode(to encoder: any Encoder) throws {
        let digits = Array("0123456789abcdef".utf8)
        var text: [UInt8] = []; text.reserveCapacity(bytes.count * 2)
        for byte in bytes { text.append(digits[Int(byte >> 4)]); text.append(digits[Int(byte & 15)]) }
        var c = encoder.singleValueContainer(); try c.encode(String(decoding: text, as: UTF8.self))
    }
}

/// Retained fixed f32/f64 fields always serialize as floating JSON numbers, including integral values.
nonisolated struct LWCatalogFloat32: Codable, Sendable, Equatable {
    let value: Float
    init(_ value: Float) { self.value = value }
    init(from decoder: any Decoder) throws { value = try decoder.singleValueContainer().decode(Float.self) }
    func encode(to encoder: any Encoder) throws {
        guard value.isFinite else { throw LensWorksManagedError.protocolViolation("Retained floating values must be finite.") }
        LWCatalogCodec.recordFloating(encoder)
        var c = encoder.singleValueContainer(); try c.encode(Double(value))
    }
}
nonisolated struct LWCatalogFloat64: Codable, Sendable, Equatable {
    let value: Double
    init(_ value: Double) { self.value = value }
    init(from decoder: any Decoder) throws { value = try decoder.singleValueContainer().decode(Double.self) }
    func encode(to encoder: any Encoder) throws {
        guard value.isFinite else { throw LensWorksManagedError.protocolViolation("Retained floating values must be finite.") }
        LWCatalogCodec.recordFloating(encoder)
        var c = encoder.singleValueContainer(); try c.encode(value)
    }
}
