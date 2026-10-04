import Foundation
import Darwin

/// Bounded, opt-in diagnostics for installed acceptance. Normal launches do no file I/O.
/// Logging is best effort: a fresh file is required, and termination does not drain the writer.
nonisolated enum LensWorksLaunchTrace {
    private static let writer: Writer? = {
        let arguments = ProcessInfo.processInfo.arguments
        guard let index = arguments.firstIndex(of: "--lensworks-evidence"), index + 1 < arguments.count else { return nil }
        return Writer(path: arguments[index + 1] + ".startup.jsonl")
    }()

    static func record(_ event: String, details: @autoclosure () -> [String: String] = [:]) {
        guard let writer else { return }
        writer.record(event, details: details())
    }

    private final class Writer: @unchecked Sendable {
        private let path: String
        private let queue = DispatchQueue(label: "LensWorks acceptance startup trace", qos: .utility)
        private let lock = NSLock()
        private var count = 0
        // Accessed only by the serial writer queue after initialization.
        private var attemptedOpen = false
        private var descriptor: Int32?
        init(path: String) { self.path = path }
        deinit { if let descriptor { Darwin.close(descriptor) } }

        private static func boundedUTF8(_ value: String, bytes limit: Int) -> String {
            var bytes = Array(value.utf8.prefix(limit))
            while !bytes.isEmpty {
                if let result = String(bytes: bytes, encoding: .utf8) { return result }
                bytes.removeLast()
            }
            return ""
        }

        private func openFreshFile() -> Int32? {
            guard path.hasPrefix("/"), !path.utf8.contains(0) else { return nil }
            let components = path.split(separator: "/", omittingEmptySubsequences: false)
            guard components.first?.isEmpty == true,
                  components.count > 1,
                  components.dropFirst().allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
                  let filename = components.last else { return nil }
            // A directory descriptor anchors each step, so a parent path cannot redirect
            // file creation through a symlink or a concurrent pathname replacement.
            var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard parent >= 0 else { return nil }
            defer { Darwin.close(parent) }
            for component in components.dropFirst().dropLast() {
                let next = String(component).withCString {
                    Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                }
                guard next >= 0 else { return nil }
                Darwin.close(parent)
                parent = next
            }
            let file = String(filename).withCString {
                Darwin.openat(parent, $0, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC, S_IRUSR | S_IWUSR)
            }
            guard file >= 0 else { return nil }
            var attributes = stat()
            guard Darwin.fstat(file, &attributes) == 0,
                  attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1 else {
                Darwin.close(file)
                return nil
            }
            return file
        }

        func record(_ event: String, details: [String: String]) {
            let admission = lock.withLock { () -> Int? in
                guard count < 128 else { return nil }
                count += 1; return count
            }
            guard let sequence = admission else { return }
            let boundedEvent = Self.boundedUTF8(event, bytes: 256)
            var boundedDetails: [String: String] = [:]
            for (key, value) in details.prefix(16) {
                boundedDetails[Self.boundedUTF8(key, bytes: 128)] = Self.boundedUTF8(value, bytes: 1024)
            }
            let timestamp = Date().timeIntervalSince1970
            let uptime = ProcessInfo.processInfo.systemUptime
            let pid = getpid()
            let entryDetails = boundedDetails
            queue.async { [self] in
                let entry: [String: Any] = ["event": boundedEvent, "sequence": sequence, "timestamp": timestamp, "uptime": uptime, "pid": pid, "details": entryDetails]
                guard var bytes = try? JSONSerialization.data(withJSONObject: entry, options: [.sortedKeys]) else { return }
                bytes.append(10)
                if !attemptedOpen {
                    attemptedOpen = true
                    descriptor = openFreshFile()
                }
                guard let descriptor else { return }
                var attributes = stat()
                guard Darwin.fstat(descriptor, &attributes) == 0,
                      attributes.st_mode & S_IFMT == S_IFREG, attributes.st_nlink == 1 else {
                    Darwin.close(descriptor)
                    self.descriptor = nil
                    return
                }
                bytes.withUnsafeBytes { buffer in
                    var offset = 0
                    while offset < buffer.count {
                        let written = Darwin.write(descriptor, buffer.baseAddress!.advanced(by: offset), buffer.count - offset)
                        if written < 0 && errno == EINTR { continue }
                        guard written > 0 else {
                            Darwin.close(descriptor)
                            self.descriptor = nil
                            return
                        }
                        offset += written
                    }
                }
            }
        }
    }
}
