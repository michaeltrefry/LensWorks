import Foundation

/// A small WebAssembly interpreter for filter plugins (epic requirement E26).
///
/// The sandbox is the interpreter itself: a module can only compute over its own linear memory. It has no imports (a
/// module that declares one is rejected at load), so no filesystem, network or host function exists for it to reach.
/// Execution is bounded by an instruction budget, a wall-clock deadline and a memory ceiling, and every failure is a
/// thrown `WasmError` rather than a crash. Supported: the integer MVP (i32/i64 arithmetic, control flow, calls, memory,
/// globals). Floating-point, tables, indirect calls and multi-value blocks are rejected when the module is loaded.
nonisolated struct WasmLimits: Equatable, Sendable {
    /// Instructions one run may execute before it is terminated.
    var maxInstructions: UInt64 = 2_000_000_000
    /// Wall-clock seconds one run may take before it is terminated.
    var maxSeconds: Double = 10
    /// Linear-memory pages (64 KiB each) a module may declare or grow to.
    var maxMemoryPages: Int = 1024
    var maxCallDepth = 64
    static let `default` = WasmLimits()
}

nonisolated enum WasmError: LocalizedError, Equatable, Sendable {
    case malformed(String)
    case unsupported(String)
    case hostImport(String)
    case memoryLimit
    case trap(String)
    case outOfFuel
    case timeout
    case missingExport(String)
    var errorDescription: String? {
        switch self {
        case .malformed(let why): "The plugin is not a valid WebAssembly module: \(why)."
        case .unsupported(let what): "The plugin uses \(what), which the filter sandbox does not support."
        case .hostImport(let name): "The plugin imports “\(name)”. Filter plugins run with no host access and may not declare imports."
        case .memoryLimit: "The plugin needs more memory than the sandbox allows."
        case .trap(let why): "The plugin failed: \(why)."
        case .outOfFuel: "The plugin was stopped: it ran past its instruction limit."
        case .timeout: "The plugin was stopped: it ran past its time limit."
        case .missingExport(let name): "The plugin does not export “\(name)”."
        }
    }
}

nonisolated struct WasmModule: Sendable {
    enum ValueType: UInt8, Sendable { case i32 = 0x7F, i64 = 0x7E }
    struct FunctionType: Equatable, Sendable { var params: [ValueType]; var results: [ValueType] }
    struct Instruction: Sendable {
        var op: UInt8
        var immediate: UInt64 = 0
        /// block/if/else: index of the matching `end`; loop: its own index. Resolved when the body is decoded.
        var target = 0
        /// if: index of its `else`, or 0 when it has none.
        var alt = 0
        /// block/loop/if: how many values the label carries.
        var arity = 0
    }
    struct Function: Sendable {
        var type: FunctionType
        var locals: [ValueType]
        var code: [Instruction]
        var tables: [[Int]] = []
    }
    struct Global: Sendable { var value: UInt64; var mutable: Bool }
    var types: [FunctionType] = []
    var functionTypeIndices: [Int] = []
    var functions: [Function] = []
    var memoryMinPages: Int?
    var memoryMaxPages: Int?
    var globals: [Global] = []
    var exports: [String: (kind: UInt8, index: Int)] = [:]
    var start: Int?
    var data: [(offset: Int, bytes: [UInt8])] = []

    init(bytes: [UInt8], limits: WasmLimits = .default) throws {
        var reader = WasmReader(bytes: bytes)
        guard try reader.bytes(4) == [0x00, 0x61, 0x73, 0x6D] else { throw WasmError.malformed("missing magic number") }
        guard try reader.bytes(4) == [0x01, 0x00, 0x00, 0x00] else { throw WasmError.malformed("unsupported version") }
        var bodies: [[UInt8]] = []
        while !reader.atEnd {
            let id = try reader.byte()
            let size = Int(try reader.u32())
            var section = WasmReader(bytes: try reader.bytes(size))
            switch id {
            case 0, 12: break
            case 1:
                for _ in 0..<(try section.u32()) {
                    guard try section.byte() == 0x60 else { throw WasmError.malformed("bad function type") }
                    let params = try section.vector { try Self.valueType(&$0) }
                    let results = try section.vector { try Self.valueType(&$0) }
                    guard results.count <= 1 else { throw WasmError.unsupported("multiple results") }
                    types.append(.init(params: params, results: results))
                }
            case 2:
                if let first = try section.vector({ r -> String in
                    let module = try r.name(), field = try r.name()
                    return module + "." + field
                }).first { throw WasmError.hostImport(first) }
            case 3:
                functionTypeIndices = try section.vector { Int(try $0.u32()) }
                guard functionTypeIndices.allSatisfy({ $0 < types.count }) else { throw WasmError.malformed("unknown type") }
            case 4: if try section.u32() > 0 { throw WasmError.unsupported("tables") }
            case 5:
                let count = try section.u32()
                guard count <= 1 else { throw WasmError.unsupported("multiple memories") }
                if count == 1 {
                    let flag = try section.byte()
                    guard flag <= 1 else { throw WasmError.unsupported("shared memory") }
                    memoryMinPages = Int(try section.u32())
                    if flag == 1 { memoryMaxPages = Int(try section.u32()) }
                    guard memoryMinPages! <= limits.maxMemoryPages else { throw WasmError.memoryLimit }
                }
            case 6:
                for _ in 0..<(try section.u32()) {
                    _ = try Self.valueType(&section)
                    let mutable = try section.byte() == 1
                    globals.append(.init(value: try Self.constantExpression(&section), mutable: mutable))
                }
            case 7:
                for _ in 0..<(try section.u32()) {
                    let name = try section.name(), kind = try section.byte(), index = Int(try section.u32())
                    exports[name] = (kind, index)
                }
            case 8: start = Int(try section.u32())
            case 9: if try section.u32() > 0 { throw WasmError.unsupported("element segments") }
            case 10:
                for _ in 0..<(try section.u32()) { bodies.append(try section.bytes(Int(try section.u32()))) }
            case 11:
                for _ in 0..<(try section.u32()) {
                    guard try section.u32() == 0 else { throw WasmError.unsupported("passive data segments") }
                    let offset = Int(UInt32(truncatingIfNeeded: try Self.constantExpression(&section)))
                    data.append((offset, try section.bytes(Int(try section.u32()))))
                }
            default: throw WasmError.malformed("unknown section \(id)")
            }
        }
        guard bodies.count == functionTypeIndices.count else { throw WasmError.malformed("function and code counts differ") }
        for (index, body) in bodies.enumerated() {
            functions.append(try Self.decode(body, type: types[functionTypeIndices[index]], module: self))
        }
        if let start, start >= functions.count || !functions[start].type.params.isEmpty { throw WasmError.malformed("bad start function") }
        for (_, export) in exports where export.kind == 0 && export.index >= functions.count { throw WasmError.malformed("bad export") }
    }

    private static func valueType(_ reader: inout WasmReader) throws -> ValueType {
        let byte = try reader.byte()
        guard let type = ValueType(rawValue: byte) else { throw WasmError.unsupported("a floating-point or reference type") }
        return type
    }
    private static func constantExpression(_ reader: inout WasmReader) throws -> UInt64 {
        let op = try reader.byte()
        let value: UInt64
        switch op {
        case 0x41: value = UInt64(UInt32(truncatingIfNeeded: try reader.s32()))
        case 0x42: value = UInt64(bitPattern: try reader.s64())
        default: throw WasmError.unsupported("a non-constant initializer")
        }
        guard try reader.byte() == 0x0B else { throw WasmError.malformed("bad constant expression") }
        return value
    }

    /// Decodes one function body into instructions with resolved branch targets.
    private static func decode(_ body: [UInt8], type: FunctionType, module: WasmModule) throws -> Function {
        var reader = WasmReader(bytes: body)
        var locals: [ValueType] = []
        for _ in 0..<(try reader.u32()) {
            let count = Int(try reader.u32())
            let kind = try valueType(&reader)
            guard locals.count + count <= 50_000 else { throw WasmError.malformed("too many locals") }
            locals += Array(repeating: kind, count: count)
        }
        var code: [Instruction] = []
        var tables: [[Int]] = []
        var open: [Int] = []
        let totalFunctions = module.functionTypeIndices.count
        while !reader.atEnd {
            let op = try reader.byte()
            var ins = Instruction(op: op)
            switch op {
            case 0x00, 0x01, 0x0F, 0x1A, 0x1B, 0x45...0x5A, 0x67...0x8A, 0xA7, 0xAC, 0xAD, 0xC0, 0xC1: break
            case 0x02, 0x03, 0x04:
                let block = try reader.byte()
                switch block {
                case 0x40: ins.arity = 0
                case 0x7F, 0x7E: ins.arity = 1
                default: throw WasmError.unsupported("a multi-value block")
                }
                if op == 0x03 { ins.target = code.count }
                open.append(code.count)
            case 0x05:
                guard let top = open.last, code[top].op == 0x04 else { throw WasmError.malformed("else without if") }
                code[top].alt = code.count
                open.removeLast(); open.append(code.count)
            case 0x0B:
                guard let top = open.popLast() else {
                    code.append(ins)
                    guard reader.atEnd else { throw WasmError.malformed("code after function end") }
                    return Function(type: type, locals: locals, code: code, tables: tables)
                }
                if code[top].op != 0x03 { code[top].target = code.count }
                // A then-branch that ends at an else, or an if without one, jumps to this end; a loop branches back to itself.
                if code[top].op == 0x05, let owner = code.indices.last(where: { code[$0].op == 0x04 && code[$0].alt == top }) { code[owner].target = code.count }
            case 0x0C, 0x0D: ins.immediate = UInt64(try reader.u32())
            case 0x0E:
                var table = try reader.vector { Int(try $0.u32()) }
                table.append(Int(try reader.u32()))
                ins.immediate = UInt64(tables.count); tables.append(table)
            case 0x10:
                let callee = Int(try reader.u32())
                guard callee < totalFunctions else { throw WasmError.malformed("unknown function") }
                ins.immediate = UInt64(callee)
            case 0x20...0x24: ins.immediate = UInt64(try reader.u32())
            case 0x28, 0x29, 0x2C...0x2F, 0x36, 0x37, 0x3A, 0x3B:
                _ = try reader.u32()   // alignment hint
                ins.immediate = UInt64(try reader.u32())
            case 0x3F, 0x40: guard try reader.byte() == 0 else { throw WasmError.malformed("bad memory index") }
            case 0x41: ins.immediate = UInt64(UInt32(truncatingIfNeeded: try reader.s32()))
            case 0x42: ins.immediate = UInt64(bitPattern: try reader.s64())
            default: throw WasmError.unsupported(String(format: "the instruction 0x%02X", op))
            }
            code.append(ins)
        }
        throw WasmError.malformed("function without end")
    }
}

nonisolated struct WasmReader {
    let bytes: [UInt8]
    var position = 0
    init(bytes: [UInt8]) { self.bytes = bytes }
    var atEnd: Bool { position >= bytes.count }
    mutating func byte() throws -> UInt8 {
        guard position < bytes.count else { throw WasmError.malformed("unexpected end") }
        defer { position += 1 }
        return bytes[position]
    }
    mutating func bytes(_ count: Int) throws -> [UInt8] {
        guard count >= 0, position + count <= bytes.count else { throw WasmError.malformed("unexpected end") }
        defer { position += count }
        return Array(bytes[position..<position + count])
    }
    mutating func u32() throws -> UInt32 {
        var result: UInt64 = 0, shift: UInt64 = 0
        while true {
            let b = try byte()
            result |= UInt64(b & 0x7F) << shift
            if b & 0x80 == 0 { break }
            shift += 7
            guard shift < 35 else { throw WasmError.malformed("integer too long") }
        }
        guard result <= UInt64(UInt32.max) else { throw WasmError.malformed("integer too large") }
        return UInt32(result)
    }
    mutating func s64() throws -> Int64 {
        var result: Int64 = 0, shift: Int64 = 0, b: UInt8
        repeat {
            b = try byte()
            if shift < 64 { result |= Int64(b & 0x7F) << shift }
            shift += 7
            guard shift < 77 else { throw WasmError.malformed("integer too long") }
        } while b & 0x80 != 0
        if shift < 64, b & 0x40 != 0 { result |= -(Int64(1) << shift) }
        return result
    }
    mutating func s32() throws -> Int32 { Int32(truncatingIfNeeded: try s64()) }
    mutating func name() throws -> String {
        let count = Int(try u32())
        guard let text = String(bytes: try bytes(count), encoding: .utf8) else { throw WasmError.malformed("bad name") }
        return text
    }
    mutating func vector<T>(_ element: (inout WasmReader) throws -> T) throws -> [T] {
        let count = Int(try u32())
        guard count <= bytes.count else { throw WasmError.malformed("bad vector length") }
        var items: [T] = []
        for _ in 0..<count { items.append(try element(&self)) }
        return items
    }
}
