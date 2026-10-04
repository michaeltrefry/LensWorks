import Foundation

/// serde_json::Value distinguishes floating numbers from integers. Foundation Codable otherwise
/// decodes 1.0 as Int64(1) and encodes Double(1) as 1. Preserve that distinction at the JSON boundary.
nonisolated enum LWCatalogCodec {
    static func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        let index = try NumberIndex(data: data)
        let decoder = JSONDecoder()
        decoder.userInfo[.lwNumberKinds] = NumberKinds(floating: Set(index.ranges.keys))
        return try decoder.decode(type, from: data)
    }
    static func encode<Value: Encodable>(_ value: Value) throws -> Data {
        let kinds = NumberKinds(floating: [])
        let encoder = JSONEncoder()
        encoder.userInfo[.lwNumberKinds] = kinds
        var data = try encoder.encode(value)
        let paths = kinds.paths
        guard !paths.isEmpty else { return data }
        let index = try NumberIndex(data: data, wanted: paths)
        for range in index.ranges.values.sorted(by: { $0.lowerBound > $1.lowerBound }) {
            let token = data[range]
            if !token.contains(46), !token.contains(101), !token.contains(69) {
                data.replaceSubrange(range.upperBound..<range.upperBound, with: [46, 48])
            }
        }
        return data
    }
    static func path(_ keys: [any CodingKey]) -> String {
        keys.map { "/" + $0.stringValue.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1") }.joined()
    }
    static func isFloating(_ decoder: any Decoder) -> Bool {
        (decoder.userInfo[.lwNumberKinds] as? NumberKinds)?.paths.contains(path(decoder.codingPath)) == true
    }
    static func recordFloating(_ encoder: any Encoder) {
        (encoder.userInfo[.lwNumberKinds] as? NumberKinds)?.record(path(encoder.codingPath))
    }
    private final class NumberKinds: @unchecked Sendable {
        private let lock = NSLock()
        private var floating: Set<String>
        init(floating: Set<String>) { self.floating = floating }
        var paths: Set<String> { lock.withLock { floating } }
        func record(_ path: String) { _ = lock.withLock { floating.insert(path) } }
    }
    private struct NumberIndex {
        private let bytes: [UInt8]
        private let wanted: Set<String>?
        private var offset = 0
        private(set) var ranges: [String: Range<Int>] = [:]
        init(data: Data, wanted: Set<String>? = nil) throws {
            bytes = Array(data); self.wanted = wanted
            try value(path: "", depth: 0)
            whitespace()
            guard offset == bytes.count else { throw LensWorksManagedError.protocolViolation("Trailing JSON input.") }
        }
        private mutating func whitespace() { while offset < bytes.count && [9, 10, 13, 32].contains(bytes[offset]) { offset += 1 } }
        private mutating func consume(_ unit: UInt8) throws {
            whitespace()
            guard offset < bytes.count, bytes[offset] == unit else { throw LensWorksManagedError.protocolViolation("Malformed JSON structure.") }
            offset += 1
        }
        private mutating func string() throws -> String {
            whitespace(); let start = offset
            try consume(34)
            while offset < bytes.count {
                let unit = bytes[offset]; offset += 1
                if unit == 34 { return try JSONDecoder().decode(String.self, from: Data(bytes[start..<offset])) }
                if unit == 92 { guard offset < bytes.count else { break }; offset += 1 }
            }
            throw LensWorksManagedError.protocolViolation("Unterminated JSON string.")
        }
        private mutating func value(path: String, depth: Int) throws {
            guard depth <= 512 else { throw LensWorksManagedError.resourceLimit("JSON nesting exceeds the retained decoder boundary.") }
            whitespace()
            guard offset < bytes.count else { throw LensWorksManagedError.protocolViolation("Missing JSON value.") }
            switch bytes[offset] {
            case 123:
                offset += 1; whitespace()
                if offset < bytes.count, bytes[offset] == 125 { offset += 1; return }
                while true {
                    let name = try string(); try consume(58)
                    let component = name.replacingOccurrences(of: "~", with: "~0").replacingOccurrences(of: "/", with: "~1")
                    try value(path: path + "/" + component, depth: depth + 1); whitespace()
                    guard offset < bytes.count else { throw LensWorksManagedError.protocolViolation("Unterminated JSON object.") }
                    if bytes[offset] == 125 { offset += 1; return }
                    try consume(44)
                }
            case 91:
                offset += 1; whitespace()
                if offset < bytes.count, bytes[offset] == 93 { offset += 1; return }
                var index = 0
                while true {
                    try value(path: path + "/Index " + String(index), depth: depth + 1); index += 1; whitespace()
                    guard offset < bytes.count else { throw LensWorksManagedError.protocolViolation("Unterminated JSON array.") }
                    if bytes[offset] == 93 { offset += 1; return }
                    try consume(44)
                }
            case 34: _ = try string()
            case 116, 102, 110:
                while offset < bytes.count, (97...122).contains(bytes[offset]) { offset += 1 }
            default:
                let start = offset
                while offset < bytes.count, [45, 43, 46, 69, 101].contains(bytes[offset]) || (48...57).contains(bytes[offset]) { offset += 1 }
                guard start < offset else { throw LensWorksManagedError.protocolViolation("Malformed JSON scalar.") }
                let token = bytes[start..<offset]
                if wanted?.contains(path) == true || (wanted == nil && (token.contains(46) || token.contains(101) || token.contains(69))) { ranges[path] = start..<offset }
            }
        }
    }
}

nonisolated private extension CodingUserInfoKey {
    static let lwNumberKinds = CodingUserInfoKey(rawValue: "LensWorks.retainedJSONNumberKinds")!
}
