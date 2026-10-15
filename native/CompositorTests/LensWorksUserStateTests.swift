import AppKit
import Foundation
import Testing
@testable import Compositor

/// Tests never reach what belongs to the person on this Mac: under XCTest every way into their preferences,
/// Application Support folder, clipboard, Open Recent list and Keychain is a throwaway stand-in, and no source in the
/// app or its tests names the real ones directly. Nothing here writes through an accessor it is checking, so a
/// regression fails the check without touching the person's state.
@MainActor
struct LensWorksUserStateTests {
    /// The stand-ins a process under XCTest gets, and the real things a normal launch gets.
    @Test func aTestProcessGetsStandInsForEverythingThatIsThePersons() throws {
        try #require(LensWorksUserState.isTesting, "this process runs under XCTest")
        #expect(LensWorksUserState.isTesting(environment: ["XCTestConfigurationFilePath": "/x"]) && !LensWorksUserState.isTesting(environment: ["HOME": "/x"]))
        let home = FileManager.default.homeDirectoryForCurrentUser.path

        // Preferences: in memory, and the app's own are what the default-taking types use.
        #expect(LensWorksUserState.defaults is LensWorksVolatileDefaults && LensWorksUserState.defaults !== UserDefaults.standard)
        #expect(LensWorksUserState.defaults(testing: true) is LensWorksVolatileDefaults && LensWorksUserState.defaults(testing: false) === UserDefaults.standard)
        #expect(CompositorApplicationDelegate.catalogDefaults(["LensWorks"]) === LensWorksUserState.defaults)

        // Application Support: a folder of this process's own in the temporary directory, where the shared index goes.
        let support = LensWorksUserState.applicationSupport.path, index = LensWorksCatalogIndex.sharedLocation.path
        let temporary = try LensWorksGrantedFolders.realPath(FileManager.default.temporaryDirectory.path)
        #expect(support.hasPrefix(temporary + "/LensWorksTestState-") && !support.hasPrefix(home + "/Library") && index == support + "/CatalogIndex.sqlite3")
        #expect(LensWorksUserState.applicationSupport(testing: true).path.hasPrefix(temporary + "/LensWorksTestState-"))
        #expect(LensWorksUserState.applicationSupport(testing: false).path == home + "/Library/Application Support/LensWorks")
        #expect(LWModelStore.Configuration.application().managedRoot.path.hasPrefix(support))

        // Clipboard: a private pasteboard, which is what a new editing session copies to and pastes from.
        #expect(LensWorksUserState.pasteboard.name != NSPasteboard.general.name && LensWorksUserState.pasteboard.name.rawValue.hasPrefix("LensWorksTestState-"))
        #expect(LensWorksUserState.pasteboard(testing: false) === NSPasteboard.general && LensWorksUserState.pasteboard(testing: true).name != NSPasteboard.general.name)
        #expect(EditorSession().pasteboard === LensWorksUserState.pasteboard)

        // Keychain: memory.
        #expect(LensWorksUserState.secretStore() is LensWorksMemorySecretStore && LensWorksUserState.secretStore(testing: true) is LensWorksMemorySecretStore
                && LensWorksUserState.secretStore(testing: false) is LensWorksKeychainSecretStore)

        // Open Recent: a list in memory, which is the list the app shows.
        let project = URL(fileURLWithPath: "/LensWorksUserStateTests/\(UUID().uuidString).comp")
        LensWorksUserState.noteRecentProject(project, testing: true)
        #expect(LensWorksUserState.recentProjects.first == project && LensWorksUserState.testRecentProjects.first == project)
        #expect(!NSDocumentController.shared.recentDocumentURLs.contains(project))
        LensWorksUserState.clearRecentProjects(testing: true)
        #expect(LensWorksUserState.recentProjects.isEmpty)
    }

    /// The in-memory preferences behave as preferences and reach no preferences file.
    @Test func volatilePreferencesLiveOnlyInMemory() {
        let defaults: UserDefaults = LensWorksVolatileDefaults(), key = "LensWorksUserStateTests.\(UUID().uuidString)"
        defaults.set(true, forKey: key + ".flag"); defaults.set(7, forKey: key + ".count"); defaults.set(2.5, forKey: key + ".amount")
        defaults.set("text", forKey: key + ".text"); defaults.set(["a", "b"], forKey: key + ".list"); defaults.set(Data([1, 2]), forKey: key + ".data")
        #expect(defaults.bool(forKey: key + ".flag") && defaults.integer(forKey: key + ".count") == 7 && defaults.double(forKey: key + ".amount") == 2.5
                && defaults.string(forKey: key + ".text") == "text" && defaults.stringArray(forKey: key + ".list") == ["a", "b"] && defaults.data(forKey: key + ".data") == Data([1, 2]))
        #expect(defaults.object(forKey: key + ".absent") == nil && defaults.dictionaryRepresentation().count == 6)
        // Nowhere else: not the app's own domain, not the stand-in's nominal suite, not another instance.
        #expect(UserDefaults.standard.object(forKey: key + ".count") == nil && UserDefaults(suiteName: "net.trefry.lensworks.volatile")?.object(forKey: key + ".count") == nil
                && LensWorksVolatileDefaults().object(forKey: key + ".count") == nil)
        defaults.removeObject(forKey: key + ".text")
        #expect(defaults.string(forKey: key + ".text") == nil && defaults.integer(forKey: key + ".count") == 7)
        defaults.removePersistentDomain(forName: "anything")
        #expect(defaults.object(forKey: key + ".count") == nil && defaults.dictionaryRepresentation().isEmpty)
    }

    /// Reads the sources: the person's state is named only in LensWorksUserState, tests name none of it, and every app
    /// a UI test launches carries the marker that puts it on the stand-ins. A new direct use fails here by file name.
    @Test func noSourceReachesThePersonsStateExceptThroughTheOneAccessor() throws {
        let native = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        func sources(_ folder: String) throws -> [(name: String, text: String)] {
            let root = native.appendingPathComponent(folder)
            let files = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil)?.allObjects as? [URL], "\(root.path) is readable")
            return try files.filter { $0.pathExtension == "swift" }.map { (String($0.path.dropFirst(root.path.count + 1)), try String(contentsOf: $0, encoding: .utf8)) }
        }
        // Spelled in pieces so this file does not match itself.
        let standard = "UserDefaults" + ".standard", general = "NSPasteboard" + ".general", recents = "NSDocument" + "Controller"
        let support = ".applicationSupport" + "Directory", keychain = "SecItem", store = "LensWorksKeychainSecretStore" + "("
        let defaulted = [": UserDefaults = " + ".standard", ": NSPasteboard = " + ".general"]
        let app = try sources("Compositor")
        #expect(app.count > 100 && app.contains { $0.name == "IO/LensWorksUserState.swift" })
        for file in app {
            let accessor = file.name == "IO/LensWorksUserState.swift", keychainStore = file.name == "Automation/LensWorksAutomation.swift"
            for token in [standard, general, recents, support] + defaulted where !accessor { #expect(!file.text.contains(token), "\(file.name) names \(token) directly") }
            if !accessor { #expect(!file.text.contains(store), "\(file.name) makes the Keychain store directly") }
            if !keychainStore { #expect(!file.text.contains(keychain), "\(file.name) calls the Keychain directly") }
        }
        // Every @AppStorage names the store.
        for file in app { #expect(file.text.components(separatedBy: "@AppStorage(").count == file.text.components(separatedBy: ", store: LensWorksUserState.defaults)").count, "\(file.name)") }

        let tests = try sources("CompositorTests") + sources("CompositorUITests")
        #expect(tests.count > 50)
        for file in tests where file.name != "LensWorksUserStateTests.swift" {
            for token in [standard, general, support, store, recents + ".shared.note", recents + ".shared.clear"] { #expect(!file.text.contains(token), "\(file.name) names \(token)") }
        }
        // A UI test's app is another process: each one launched carries the marker.
        for file in try sources("CompositorUITests") {
            let launched = file.text.components(separatedBy: "XCUIApplication()").count - 1
            let marked = file.text.components(separatedBy: "launchEnvironment[\"XCTestConfigurationFilePath\"] =").count - 1
            #expect(launched > 0 && marked == launched, "\(file.name): \(launched) apps, \(marked) marked")
        }
    }
}
