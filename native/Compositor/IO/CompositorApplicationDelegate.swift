import AppKit

final class CompositorApplicationDelegate: NSObject, NSApplicationDelegate {
    let workspace = {
        LensWorksLaunchTrace.record("delegate.workspace.begin")
        let workspace = ProjectWorkspace()
        LensWorksLaunchTrace.record("delegate.workspace.end")
        return workspace
    }()
    var session: EditorSession { workspace.current.session }
    var projects: ProjectController { workspace.current.controller }
    var showEditor: (() -> Void)?
    let catalog = LensWorksCatalog(defaults: CompositorApplicationDelegate.catalogDefaults())
    /// Automation (for example a CI fixture import) can keep catalog preferences out of the
    /// app's own domain with `--lensworks-defaults-suite <name>`.
    static func catalogDefaults(_ arguments: [String] = ProcessInfo.processInfo.arguments) -> UserDefaults {
        guard let index = arguments.firstIndex(of: "--lensworks-defaults-suite"), index + 1 < arguments.count,
              !arguments[index + 1].isEmpty, let suite = UserDefaults(suiteName: arguments[index + 1]) else { return .standard }
        return suite
    }
    override init() {
        super.init()
        LensWorksLaunchTrace.record("delegate.initialized")
    }

    // Finder Open With and Dock drops, including files delivered during launch.
    func application(_ application: NSApplication, open urls: [URL]) {
        LensWorksLaunchTrace.record("delegate.openURLs", details: ["count": String(urls.count), "showEditorInstalled": String(showEditor != nil)])
        // Reopening a window that's already showing makes SwiftUI rebuild it, so the app blinks out and back:
        // only a closed editor is reopened.
        if !application.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("editor") == true }) {
            if let showEditor { showEditor() }
            // Launched to open a file, SwiftUI makes no window, and the editor that would set `showEditor` never
            // appears. A Dock click's reopen event makes the window, so the app sends itself one once launched.
            else { DispatchQueue.main.async { Self.reopen() } }
        }
        application.activate()
        Task { await workspace.receive(urls) }
    }

    private static func reopen() {
        let event = NSAppleEventDescriptor(eventClass: AEEventClass(kCoreEventClass), eventID: AEEventID(kAEReopenApplication),
                                           targetDescriptor: .currentProcess(), returnID: AEReturnID(kAutoGenerateReturnID),
                                           transactionID: AETransactionID(kAnyTransactionID))
        _ = try? event.sendEvent(options: .noReply, timeout: 1)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        LensWorksLaunchTrace.record("delegate.willFinishLaunching.begin")
        // Always dark, alerts and open/save panels included, whatever the Mac is set to.
        NSApp.appearance = NSAppearance(named: .darkAqua)
        // Slider knobs snap to a click on the track instead of gliding there.
        SliderSnap.install()
        pinEditorWindowFrameForUITests()
        LensWorksLaunchTrace.record("delegate.willFinishLaunching.end")
    }

    /// UI tests pass `-LensWorksPinnedWindowFrame "{{x, y}, {w, h}}"` (AppKit screen coordinates) so every launch
    /// captures the editor window at the same frame on the same display. Without it macOS restores or places the
    /// window wherever it likes, which on a multi-display host can be a display with a different backing scale.
    /// A pinned window also stops autosaving, so tests leave the user's remembered window frame alone. Every
    /// window update re-checks it, so a later placement or restoration cannot move it either. An opaque backdrop
    /// window sits right behind it: the window's rounded corners otherwise show whatever other apps have on screen
    /// there, which would differ between captures.
    private func pinEditorWindowFrameForUITests() {
        let arguments = ProcessInfo.processInfo.arguments
        guard let flag = arguments.firstIndex(of: "-LensWorksPinnedWindowFrame"), arguments.indices.contains(flag + 1) else { return }
        let value = arguments[flag + 1]
        let frame = NSRectFromString(value)
        guard frame.width > 0, frame.height > 0 else { return }
        pinnedWindowObserver = NotificationCenter.default.addObserver(forName: NSWindow.didUpdateNotification, object: nil, queue: .main) { [unowned self] notification in
            MainActor.assumeIsolated {
                guard let window = notification.object as? NSWindow, window.identifier?.rawValue.hasPrefix("editor") == true else { return }
                if !window.frameAutosaveName.isEmpty { window.setFrameAutosaveName("") }
                if window.isRestorable { window.isRestorable = false }
                if window.frame != frame { window.setFrame(frame, display: true) }
                if window.isVisible, self.pinnedWindowBackdrop?.isVisible != true {
                    let backdrop = self.pinnedWindowBackdrop ?? NSWindow(contentRect: frame, styleMask: .borderless, backing: .buffered, defer: false)
                    backdrop.isReleasedWhenClosed = false
                    backdrop.backgroundColor = .black
                    backdrop.hasShadow = false
                    backdrop.ignoresMouseEvents = true
                    backdrop.setAccessibilityElement(false)
                    backdrop.setFrame(frame, display: false)
                    backdrop.order(.below, relativeTo: window.windowNumber)
                    self.pinnedWindowBackdrop = backdrop
                }
            }
        }
    }
    private var pinnedWindowObserver: NSObjectProtocol?
    private var pinnedWindowBackdrop: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        LensWorksLaunchTrace.record("delegate.didFinishLaunching", details: ["windows": String(NSApp.windows.count), "visibleWindows": String(NSApp.windows.filter(\.isVisible).count)])
        // A fresh installed launch can finish with no admitted SwiftUI window.
        // Reuse the Finder-open fallback after scene registration gets its next turn.
        DispatchQueue.main.async {
            guard !NSApp.windows.contains(where: { $0.isVisible && $0.identifier?.rawValue.hasPrefix("editor") == true }) else { return }
            LensWorksLaunchTrace.record("delegate.launchReopen.admitted")
            Self.reopen()
        }
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        LensWorksLaunchTrace.record("delegate.reopen", details: ["hasVisibleWindows": String(flag), "showEditorInstalled": String(showEditor != nil)])
        if !flag { showEditor?() }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // What's still open (a dialog, a gradient waiting for Apply) is settled by confirmQuit, which beeps if
        // something, a save still running say, has to finish first.
        guard !workspace.isManaging else { return .terminateCancel }
        Task {
            guard await workspace.confirmQuit() else { sender.reply(toApplicationShouldTerminate: false); return }
            do {
                try await catalog.close()
                sender.reply(toApplicationShouldTerminate: true)
            } catch {
                catalog.error = "The catalog worker is still draining. Retry Quit after it finishes. " + error.localizedDescription
                sender.reply(toApplicationShouldTerminate: false)
            }
        }
        return .terminateLater
    }
}
