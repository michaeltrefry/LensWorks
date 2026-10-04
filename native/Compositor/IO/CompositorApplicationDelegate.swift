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
    let catalog = LensWorksCatalog()
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
        LensWorksLaunchTrace.record("delegate.willFinishLaunching.end")
    }

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
