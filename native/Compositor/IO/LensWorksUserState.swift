import AppKit
import Foundation

/// The one way into what belongs to the person on this Mac rather than to a document: their preferences, LensWorks's
/// folder in Application Support (the working-version index, the model store), their clipboard, their File › Open
/// Recent list and the automation secret in their Keychain.
///
/// A process running under XCTest (a unit-test host, or an app a UI test launched with the test marker in its
/// environment) gets a throwaway stand-in for every one of them, made fresh for that process and never written
/// where the person's are. A test that needs its own passes it to the type under test as before; one that passes
/// nothing can no longer reach the person's by default. Nothing else in the app names `UserDefaults.standard`,
/// `NSPasteboard.general`, the Application Support folder, `NSDocumentController`'s recent list or the Keychain
/// directly (LensWorksUserStateTests reads the sources to hold that).
nonisolated enum LensWorksUserState {
    /// Whether this process runs under XCTest.
    static let isTesting = isTesting(environment: ProcessInfo.processInfo.environment)
    static func isTesting(environment: [String: String]) -> Bool { environment["XCTestConfigurationFilePath"] != nil }

    /// The person's preferences; under XCTest, preferences kept in memory for this process only.
    static let defaults: UserDefaults = defaults(testing: isTesting)
    static func defaults(testing: Bool) -> UserDefaults { testing ? LensWorksVolatileDefaults() : .standard }

    /// LensWorks's folder in the person's Application Support; under XCTest, a folder of this process's own in the
    /// temporary directory.
    static let applicationSupport: URL = applicationSupport(testing: isTesting)
    static func applicationSupport(testing: Bool) -> URL {
        if testing {
            // The real path: the index refuses a folder reached through a link, and the temporary directory is one.
            let temporary = FileManager.default.temporaryDirectory.path
            let real = temporary.withCString { realpath($0, nil) }.map { pointer in defer { free(pointer) }; return String(cString: pointer) } ?? temporary
            let folder = URL(fileURLWithPath: real, isDirectory: true).appendingPathComponent("LensWorksTestState-\(UUID().uuidString)", isDirectory: true)
            lensWorksTestStateFolders.append(folder.path)
            atexit { for path in lensWorksTestStateFolders { try? FileManager.default.removeItem(atPath: path) } }
            return folder
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("LensWorks", isDirectory: true)
    }

    /// The person's clipboard; under XCTest, a private pasteboard of this process's own.
    static let pasteboard: NSPasteboard = pasteboard(testing: isTesting)
    static func pasteboard(testing: Bool) -> NSPasteboard {
        guard testing else { return .general }
        let name = NSPasteboard.Name("LensWorksTestState-\(UUID().uuidString)")
        lensWorksTestStatePasteboards.append(name.rawValue)
        atexit { for name in lensWorksTestStatePasteboards { NSPasteboard(name: NSPasteboard.Name(name)).releaseGlobally() } }
        return NSPasteboard(name: name)
    }

    /// Where the automation secret is kept: the person's Keychain; under XCTest, memory.
    static func secretStore(testing: Bool = isTesting) -> LensWorksAutomationSecretStore {
        testing ? LensWorksMemorySecretStore() : LensWorksKeychainSecretStore()
    }

    /// The projects in File › Open Recent, which macOS keeps for the person.
    @MainActor static var recentProjects: [URL] { isTesting ? testRecentProjects : NSDocumentController.shared.recentDocumentURLs }
    /// Adds a project to File › Open Recent; under XCTest, to a list kept in memory for this process.
    @MainActor static func noteRecentProject(_ url: URL, testing: Bool = isTesting) {
        if testing { testRecentProjects.removeAll { $0 == url }; testRecentProjects.insert(url, at: 0) }
        else { NSDocumentController.shared.noteNewRecentDocumentURL(url) }
    }
    @MainActor static func clearRecentProjects(testing: Bool = isTesting) {
        if testing { testRecentProjects = [] } else { NSDocumentController.shared.clearRecentDocuments(nil) }
    }
    @MainActor private(set) static var testRecentProjects: [URL] = []
}

/// What a test process made in place of the person's, removed when the process ends.
nonisolated(unsafe) private var lensWorksTestStateFolders: [String] = []
nonisolated(unsafe) private var lensWorksTestStatePasteboards: [String] = []

/// Preferences that live only in this process: nothing is read from or written to any preferences file. Values a
/// launch passed on the command line (`-Key value`) are still read, since those are the launch's, not the person's.
nonisolated final class LensWorksVolatileDefaults: UserDefaults, @unchecked Sendable {
    private var values: [String: Any] = [:]
    private let lock = NSLock()
    private let arguments = UserDefaults.standard.volatileDomain(forName: UserDefaults.argumentDomain)
    init() { super.init(suiteName: "net.trefry.lensworks.volatile")! }
    override func object(forKey defaultName: String) -> Any? { lock.withLock { values[defaultName] } ?? arguments[defaultName] }
    override func set(_ value: Any?, forKey defaultName: String) { lock.withLock { values[defaultName] = value } }
    override func removeObject(forKey defaultName: String) { lock.withLock { values[defaultName] = nil } }
    override func removePersistentDomain(forName domainName: String) { lock.withLock { values = [:] } }
    override func dictionaryRepresentation() -> [String: Any] { lock.withLock { values } }
}
