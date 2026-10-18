import Foundation

/// One instantiated module: its own linear memory and globals, and the budget of the run in progress.
nonisolated final class WasmInstance {
    let module: WasmModule
    let limits: WasmLimits
    private(set) var memory: [UInt8]
    private var globals: [UInt64]
    private var executed: UInt64 = 0
    private var deadline: UInt64 = 0
    private let memoryCeiling: Int

    static let pageSize = 65_536

    init(module: WasmModule, limits: WasmLimits = .default) throws {
        self.module = module
        self.limits = limits
        memoryCeiling = min(module.memoryMaxPages ?? limits.maxMemoryPages, limits.maxMemoryPages)
        memory = [UInt8](repeating: 0, count: (module.memoryMinPages ?? 0) * Self.pageSize)
        globals = module.globals.map(\.value)
        for segment in module.data {
            guard segment.offset >= 0, segment.offset + segment.bytes.count <= memory.count else { throw WasmError.trap("data segment is out of bounds") }
            memory.replaceSubrange(segment.offset..<segment.offset + segment.bytes.count, with: segment.bytes)
        }
        beginRun()
        if let start = module.start { _ = try execute(start, args: [], depth: 0) }
    }

    /// Starts a fresh instruction and time budget; every `call` until the next `beginRun` draws on it.
    func beginRun() {
        executed = 0
        deadline = DispatchTime.now().uptimeNanoseconds + UInt64(limits.maxSeconds * 1_000_000_000)
    }

    @discardableResult func call(_ name: String, _ args: [UInt64]) throws -> UInt64? {
        guard let export = module.exports[name], export.kind == 0 else { throw WasmError.missingExport(name) }
        guard module.functions[export.index].type.params.count == args.count else { throw WasmError.trap("wrong argument count for “\(name)”") }
        return try execute(export.index, args: args, depth: 0)
    }

    func growMemory(toPages pages: Int) throws {
        guard pages <= memoryCeiling else { throw WasmError.memoryLimit }
        if pages * Self.pageSize > memory.count { memory += [UInt8](repeating: 0, count: pages * Self.pageSize - memory.count) }
    }
    func write(_ bytes: ArraySlice<UInt8>, at address: Int) throws {
        guard address >= 0, address + bytes.count <= memory.count else { throw WasmError.trap("host write is out of bounds") }
        memory.replaceSubrange(address..<address + bytes.count, with: bytes)
    }
    func read(at address: Int, count: Int) throws -> ArraySlice<UInt8> {
        guard address >= 0, address + count <= memory.count else { throw WasmError.trap("host read is out of bounds") }
        return memory[address..<address + count]
    }

    private struct Label { var continuation: Int; var height: Int; var arity: Int; var isLoop: Bool }

    private func address(_ base: UInt64, _ offset: UInt64, _ size: Int) throws -> Int {
        let end = UInt64(UInt32(truncatingIfNeeded: base)) + offset + UInt64(size)
        guard end <= UInt64(memory.count) else { throw WasmError.trap("out of bounds memory access") }
        return Int(end) - size
    }
    private func load(_ base: UInt64, _ offset: UInt64, size: Int) throws -> UInt64 {
        let at = try address(base, offset, size)
        return memory.withUnsafeBytes { raw in
            switch size {
            case 1: UInt64(raw[at])
            case 2: UInt64(raw.loadUnaligned(fromByteOffset: at, as: UInt16.self))
            case 4: UInt64(raw.loadUnaligned(fromByteOffset: at, as: UInt32.self))
            default: raw.loadUnaligned(fromByteOffset: at, as: UInt64.self)
            }
        }
    }
    private func store(_ base: UInt64, _ offset: UInt64, _ value: UInt64, size: Int) throws {
        let at = try address(base, offset, size)
        memory.withUnsafeMutableBytes { raw in
            switch size {
            case 1: raw[at] = UInt8(truncatingIfNeeded: value)
            case 2: raw.storeBytes(of: UInt16(truncatingIfNeeded: value), toByteOffset: at, as: UInt16.self)
            case 4: raw.storeBytes(of: UInt32(truncatingIfNeeded: value), toByteOffset: at, as: UInt32.self)
            default: raw.storeBytes(of: value, toByteOffset: at, as: UInt64.self)
            }
        }
    }

    private func execute(_ index: Int, args: [UInt64], depth: Int) throws -> UInt64? {
        guard depth < limits.maxCallDepth else { throw WasmError.trap("call stack exhausted") }
        let function = module.functions[index]
        let code = function.code
        var locals = args + [UInt64](repeating: 0, count: function.locals.count)
        var stack: [UInt64] = []
        stack.reserveCapacity(32)
        var labels = [Label(continuation: code.count - 1, height: 0, arity: function.type.results.count, isLoop: false)]
        var pc = 0
        let invalid = WasmError.trap("invalid module")

        func pop() throws -> UInt64 {
            guard let value = stack.popLast() else { throw invalid }
            return value
        }
        func pop32() throws -> UInt32 { UInt32(truncatingIfNeeded: try pop()) }
        func push32(_ value: UInt32) { stack.append(UInt64(value)) }
        func push(_ flag: Bool) { stack.append(flag ? 1 : 0) }
        /// Branches to the label `depth` out; true when that label is the function's own (a return).
        func branch(_ depth: Int) throws -> Bool {
            guard depth < labels.count else { throw invalid }
            let level = labels.count - 1 - depth
            let label = labels[level]
            let carry = label.isLoop ? 0 : label.arity
            guard stack.count >= label.height + carry else { throw invalid }
            let values = Array(stack.suffix(carry))
            stack.removeSubrange(label.height...)
            stack.append(contentsOf: values)
            if level == 0 { return true }
            labels.removeLast(label.isLoop ? depth : depth + 1)
            pc = label.continuation + 1
            return false
        }

        run: while pc < code.count {
            executed += 1
            if executed > limits.maxInstructions { throw WasmError.outOfFuel }
            if executed & 0x3FF == 0 {
                if DispatchTime.now().uptimeNanoseconds > deadline { throw WasmError.timeout }
                if stack.count > 65_536 { throw WasmError.trap("operand stack exhausted") }
            }
            let ins = code[pc]
            pc += 1
            switch ins.op {
            case 0x00: throw WasmError.trap("unreachable code was executed")
            case 0x01: break
            case 0x02: labels.append(Label(continuation: ins.target, height: stack.count, arity: ins.arity, isLoop: false))
            case 0x03: labels.append(Label(continuation: ins.target, height: stack.count, arity: ins.arity, isLoop: true))
            case 0x04:
                let condition = try pop32()
                labels.append(Label(continuation: ins.target, height: stack.count, arity: ins.arity, isLoop: false))
                if condition == 0 { pc = ins.alt != 0 ? ins.alt + 1 : ins.target }
            case 0x05: pc = ins.target
            case 0x0B:
                if labels.count == 1 { break run }
                labels.removeLast()
            case 0x0C: if try branch(Int(ins.immediate)) { break run }
            case 0x0D: if try pop32() != 0, try branch(Int(ins.immediate)) { break run }
            case 0x0E:
                let table = function.tables[Int(ins.immediate)]
                let selector = Int(try pop32())
                if try branch(selector < table.count - 1 ? table[selector] : table[table.count - 1]) { break run }
            case 0x0F: if try branch(labels.count - 1) { break run }
            case 0x10:
                let count = module.functions[Int(ins.immediate)].type.params.count
                guard stack.count >= count else { throw invalid }
                let arguments = Array(stack.suffix(count))
                stack.removeLast(count)
                if let result = try execute(Int(ins.immediate), args: arguments, depth: depth + 1) { stack.append(result) }
            case 0x1A: _ = try pop()
            case 0x1B:
                let condition = try pop32(), second = try pop(), first = try pop()
                stack.append(condition != 0 ? first : second)
            case 0x20:
                guard Int(ins.immediate) < locals.count else { throw invalid }
                stack.append(locals[Int(ins.immediate)])
            case 0x21, 0x22:
                guard Int(ins.immediate) < locals.count else { throw invalid }
                let value = try pop()
                locals[Int(ins.immediate)] = value
                if ins.op == 0x22 { stack.append(value) }
            case 0x23:
                guard Int(ins.immediate) < globals.count else { throw invalid }
                stack.append(globals[Int(ins.immediate)])
            case 0x24:
                guard Int(ins.immediate) < globals.count, module.globals[Int(ins.immediate)].mutable else { throw invalid }
                globals[Int(ins.immediate)] = try pop()
            case 0x28: stack.append(try load(try pop(), ins.immediate, size: 4))
            case 0x29: stack.append(try load(try pop(), ins.immediate, size: 8))
            case 0x2C: stack.append(UInt64(UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: try load(try pop(), ins.immediate, size: 1))))))
            case 0x2D: stack.append(try load(try pop(), ins.immediate, size: 1))
            case 0x2E: stack.append(UInt64(UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: try load(try pop(), ins.immediate, size: 2))))))
            case 0x2F: stack.append(try load(try pop(), ins.immediate, size: 2))
            case 0x36, 0x37, 0x3A, 0x3B:
                let value = try pop(), base = try pop()
                try store(base, ins.immediate, value, size: ins.op == 0x37 ? 8 : ins.op == 0x36 ? 4 : ins.op == 0x3A ? 1 : 2)
            case 0x3F: push32(UInt32(memory.count / Self.pageSize))
            case 0x40:
                let delta = Int(try pop32()), pages = memory.count / Self.pageSize
                if pages + delta > memoryCeiling { push32(UInt32.max) }
                else { try growMemory(toPages: pages + delta); push32(UInt32(pages)) }
            case 0x41, 0x42: stack.append(ins.immediate)
            case 0x45: push(try pop32() == 0)
            case 0x46...0x4F:
                let b = try pop32(), a = try pop32()
                switch ins.op {
                case 0x46: push(a == b)
                case 0x47: push(a != b)
                case 0x48: push(Int32(bitPattern: a) < Int32(bitPattern: b))
                case 0x49: push(a < b)
                case 0x4A: push(Int32(bitPattern: a) > Int32(bitPattern: b))
                case 0x4B: push(a > b)
                case 0x4C: push(Int32(bitPattern: a) <= Int32(bitPattern: b))
                case 0x4D: push(a <= b)
                case 0x4E: push(Int32(bitPattern: a) >= Int32(bitPattern: b))
                default: push(a >= b)
                }
            case 0x50: push(try pop() == 0)
            case 0x51...0x5A:
                let b = try pop(), a = try pop()
                switch ins.op {
                case 0x51: push(a == b)
                case 0x52: push(a != b)
                case 0x53: push(Int64(bitPattern: a) < Int64(bitPattern: b))
                case 0x54: push(a < b)
                case 0x55: push(Int64(bitPattern: a) > Int64(bitPattern: b))
                case 0x56: push(a > b)
                case 0x57: push(Int64(bitPattern: a) <= Int64(bitPattern: b))
                case 0x58: push(a <= b)
                case 0x59: push(Int64(bitPattern: a) >= Int64(bitPattern: b))
                default: push(a >= b)
                }
            case 0x67: push32(UInt32(try pop32().leadingZeroBitCount))
            case 0x68: push32(UInt32(try pop32().trailingZeroBitCount))
            case 0x69: push32(UInt32(try pop32().nonzeroBitCount))
            case 0x6A...0x78:
                let b = try pop32(), a = try pop32()
                switch ins.op {
                case 0x6A: push32(a &+ b)
                case 0x6B: push32(a &- b)
                case 0x6C: push32(a &* b)
                case 0x6D:
                    guard b != 0 else { throw WasmError.trap("integer divide by zero") }
                    let (q, overflow) = Int32(bitPattern: a).dividedReportingOverflow(by: Int32(bitPattern: b))
                    guard !overflow else { throw WasmError.trap("integer overflow") }
                    push32(UInt32(bitPattern: q))
                case 0x6E:
                    guard b != 0 else { throw WasmError.trap("integer divide by zero") }
                    push32(a / b)
                case 0x6F:
                    guard b != 0 else { throw WasmError.trap("integer divide by zero") }
                    push32(UInt32(bitPattern: Int32(bitPattern: a).remainderReportingOverflow(dividingBy: Int32(bitPattern: b)).partialValue))
                case 0x70:
                    guard b != 0 else { throw WasmError.trap("integer divide by zero") }
                    push32(a % b)
                case 0x71: push32(a & b)
                case 0x72: push32(a | b)
                case 0x73: push32(a ^ b)
                case 0x74: push32(a &<< b)
                case 0x75: push32(UInt32(bitPattern: Int32(bitPattern: a) &>> Int32(bitPattern: b)))
                case 0x76: push32(a &>> b)
                case 0x77: push32((a &<< (b & 31)) | (a &>> ((32 &- b) & 31)))
                default: push32((a &>> (b & 31)) | (a &<< ((32 &- b) & 31)))
                }
            case 0x79: stack.append(UInt64(try pop().leadingZeroBitCount))
            case 0x7A: stack.append(UInt64(try pop().trailingZeroBitCount))
            case 0x7B: stack.append(UInt64(try pop().nonzeroBitCount))
            case 0x7C...0x8A:
                let b = try pop(), a = try pop()
                switch ins.op {
                case 0x7C: stack.append(a &+ b)
                case 0x7D: stack.append(a &- b)
                case 0x7E: stack.append(a &* b)
                case 0x7F:
                    guard b != 0 else { throw WasmError.trap("integer divide by zero") }
                    let (q, overflow) = Int64(bitPattern: a).dividedReportingOverflow(by: Int64(bitPattern: b))
                    guard !overflow else { throw WasmError.trap("integer overflow") }
                    stack.append(UInt64(bitPattern: q))
                case 0x80:
                    guard b != 0 else { throw WasmError.trap("integer divide by zero") }
                    stack.append(a / b)
                case 0x81:
                    guard b != 0 else { throw WasmError.trap("integer divide by zero") }
                    stack.append(UInt64(bitPattern: Int64(bitPattern: a).remainderReportingOverflow(dividingBy: Int64(bitPattern: b)).partialValue))
                case 0x82:
                    guard b != 0 else { throw WasmError.trap("integer divide by zero") }
                    stack.append(a % b)
                case 0x83: stack.append(a & b)
                case 0x84: stack.append(a | b)
                case 0x85: stack.append(a ^ b)
                case 0x86: stack.append(a &<< b)
                case 0x87: stack.append(UInt64(bitPattern: Int64(bitPattern: a) &>> Int64(bitPattern: b)))
                case 0x88: stack.append(a &>> b)
                case 0x89: stack.append((a &<< (b & 63)) | (a &>> ((64 &- b) & 63)))
                default: stack.append((a &>> (b & 63)) | (a &<< ((64 &- b) & 63)))
                }
            case 0xA7: push32(try pop32())
            case 0xAC: stack.append(UInt64(bitPattern: Int64(Int32(bitPattern: try pop32()))))
            case 0xAD: stack.append(UInt64(try pop32()))
            case 0xC0: push32(UInt32(bitPattern: Int32(Int8(truncatingIfNeeded: try pop32()))))
            case 0xC1: push32(UInt32(bitPattern: Int32(Int16(truncatingIfNeeded: try pop32()))))
            default: throw invalid
            }
        }
        guard function.type.results.count == 1 else { return nil }
        return try pop()
    }
}

/// The plugin ABI: a module exporting `filter(ptr: i32, pixelCount: i32)`. The host copies up to `chunkPixels`
/// straight-alpha RGBA8 pixels into the module's memory at `pixelOffset`, calls `filter`, and reads the same bytes
/// back, repeating until the layer is done. The whole layer draws on one instruction and time budget.
nonisolated enum WasmFilterRunner {
    static let pixelOffset = 65_536
    static let chunkPixels = 16_384
    static let entryPoint = "filter"

    /// Parses `bytes` and checks it is a filter plugin; throws the reason it is not. Rejects any import.
    @discardableResult static func validate(_ bytes: [UInt8], limits: WasmLimits = .default) throws -> WasmModule {
        let module = try WasmModule(bytes: bytes, limits: limits)
        guard let export = module.exports[entryPoint], export.kind == 0 else { throw WasmError.missingExport(entryPoint) }
        let type = module.functions[export.index].type
        guard type.params == [.i32, .i32], type.results.isEmpty else { throw WasmError.malformed("“filter” must take (i32, i32) and return nothing") }
        return module
    }

    /// Runs the plugin over `pixels` (straight-alpha RGBA8) and returns the result. Blocking: call from a worker thread.
    static func run(_ bytes: [UInt8], pixels: [UInt8], limits: WasmLimits = .default) throws -> [UInt8] {
        let instance = try WasmInstance(module: validate(bytes, limits: limits), limits: limits)
        try instance.growMemory(toPages: (pixelOffset + chunkPixels * 4) / WasmInstance.pageSize)
        instance.beginRun()
        var result = pixels
        var start = 0
        while start < pixels.count {
            let end = min(start + chunkPixels * 4, pixels.count)
            try instance.write(pixels[start..<end], at: pixelOffset)
            try instance.call(entryPoint, [UInt64(pixelOffset), UInt64((end - start) / 4)])
            result.replaceSubrange(start..<end, with: try instance.read(at: pixelOffset, count: end - start))
            start = end
        }
        return result
    }

    /// `run` on a thread of its own with a stack deep enough for the interpreter, so the caller stays responsive.
    static func runIsolated(_ bytes: [UInt8], pixels: [UInt8], limits: WasmLimits = .default) async throws -> [UInt8] {
        try await withCheckedThrowingContinuation { continuation in
            let thread = Thread { continuation.resume(with: Result { try run(bytes, pixels: pixels, limits: limits) }) }
            thread.stackSize = 16 << 20
            thread.qualityOfService = .userInitiated
            thread.start()
        }
    }
}
