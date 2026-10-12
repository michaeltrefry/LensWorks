import Foundation

/// Tells its owner when a project package changes on disk, whoever changed it: another app, an agent, a sync
/// client, a git checkout. It listens to the kernel's file system events for the package folder, its manifest and
/// its images folder, so there is no polling and no dependency on the writer using file coordination (which
/// `NSFilePresenter` needs and most other writers skip). Events are coalesced, and the handler runs on the main actor.
///
/// A package is replaced atomically by renaming a sibling over it, which retires the file descriptors being watched;
/// every event therefore re-arms the watch by path, so the new package is watched after the swap.
@MainActor
final class ProjectWatcher {
    let url: URL
    private let onChange: @MainActor () -> Void
    private let sources = SourceBox()
    private var delivery: Task<Void, Never>?
    private var rearm: Task<Void, Never>?
    /// How long to wait after the last event before reporting, so a save that touches several files reports once.
    static let coalescing: Duration = .milliseconds(300)

    init(url: URL, onChange: @escaping @MainActor () -> Void) {
        self.url = url
        self.onChange = onChange
        arm()
    }

    deinit { sources.cancelAll() }

    func stop() {
        delivery?.cancel(); delivery = nil
        rearm?.cancel(); rearm = nil
        sources.cancelAll()
    }

    private var watchedPaths: [String] {
        [url.path, url.appendingPathComponent("manifest.json").path, url.appendingPathComponent("LensWorks.json").path, url.appendingPathComponent("images", isDirectory: true).path]
    }

    /// Watches every path that exists, keeping a source whose path still names the same file: cancelling a source
    /// discards an event it has not delivered yet, so only a path that now names a different file (or none) is
    /// replaced. Returns whether a path gained a new source; changes made to it before it was watched went unseen.
    @discardableResult
    private func arm() -> Bool {
        var armedNew = false
        for path in watchedPaths {
            var status = stat()
            let identity = stat(path, &status) == 0 ? SourceBox.Identity(device: status.st_dev, inode: status.st_ino) : nil
            if let identity, sources.identity(of: path) == identity { continue }
            sources.cancel(path)
            guard identity != nil else { continue }
            let descriptor = open(path, O_EVTONLY)
            guard descriptor >= 0 else { continue }
            var opened = stat()
            guard fstat(descriptor, &opened) == 0 else { close(descriptor); continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: descriptor,
                eventMask: [.write, .extend, .delete, .rename, .link, .attrib], queue: .main)
            source.setEventHandler { [weak self] in
                MainActor.assumeIsolated { self?.noteEvent() }
            }
            source.setCancelHandler { close(descriptor) }
            source.resume()
            sources.set(path, source, identity: SourceBox.Identity(device: opened.st_dev, inode: opened.st_ino))
            armedNew = true
        }
        return armedNew
    }

    /// The dispatch sources by path, kept outside the actor so `deinit` can cancel them from any context.
    private nonisolated final class SourceBox: @unchecked Sendable {
        struct Identity: Equatable { let device: dev_t; let inode: ino_t }
        private let lock = NSLock()
        private var entries: [String: (source: DispatchSourceFileSystemObject, identity: Identity)] = [:]
        var count: Int { lock.withLock { entries.count } }
        func identity(of path: String) -> Identity? { lock.withLock { entries[path]?.identity } }
        func set(_ path: String, _ source: DispatchSourceFileSystemObject, identity: Identity) {
            lock.withLock { entries[path] = (source, identity) }
        }
        func cancel(_ path: String) { lock.withLock { entries.removeValue(forKey: path) }?.source.cancel() }
        func cancelAll() {
            let cancelled = lock.withLock { let l = entries.values.map(\.source); entries.removeAll(); return l }
            for source in cancelled { source.cancel() }
        }
    }

    private func noteEvent() {
        // Re-arm by path once the writer has finished swapping files, retrying briefly while the package
        // is mid-replacement and a path does not exist yet. A path watched anew may already have changed
        // unseen, so that reports again (the owner compares content, so a needless report changes nothing).
        rearm?.cancel()
        rearm = Task { @MainActor [weak self] in
            for _ in 0..<20 {
                try? await Task.sleep(for: .milliseconds(100))
                guard let self, !Task.isCancelled else { return }
                if self.arm() { self.scheduleDelivery() }
                if self.sources.count == self.watchedPaths.count { return }
            }
        }
        scheduleDelivery()
    }

    private func scheduleDelivery() {
        delivery?.cancel()
        delivery = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.coalescing)
            guard let self, !Task.isCancelled else { return }
            self.onChange()
        }
    }
}
