import AppsKit
import Foundation
import Synchronization
import Testing
@testable import CleanKit
@testable import ScanKit

private let appFolderName = "Applications"

/// A fake Mac: `Applications` beside `Users/io`, as on the data volume. Nothing here
/// reaches the real Trash except the one test that says so.
private final class FakeMac {
    let base: FakeHome
    var root: String { base.path }
    var home: String { base.at("Users/me") }

    init() throws {
        base = try FakeHome()
        try base.folder(appFolderName)
        try base.folder("Users/me/Library")
    }

    func at(_ relative: String) -> String { base.at(relative) }
    func homeAt(_ relative: String) -> String { "Users/me/" + relative }

    @discardableResult
    func makeApp(
        _ name: String,
        identifier: String,
        executable: String? = nil,
        folder: String = appFolderName,
        size: Int = 200_000,
        store: Bool = false
    ) throws -> String {
        let relative = "\(folder)/\(name).app"
        try base.folder(relative + "/Contents")
        var info: [String: Any] = ["CFBundleIdentifier": identifier, "CFBundleName": name, "CFBundleShortVersionString": "1.2"]
        info["CFBundleExecutable"] = executable ?? name
        let data = try PropertyListSerialization.data(fromPropertyList: info, format: .xml, options: 0)
        try data.write(to: URL(fileURLWithPath: at(relative + "/Contents/Info.plist")))
        try base.file(relative + "/Contents/binary", size: size)
        if store {
            try base.folder(relative + "/Contents/_MASReceipt")
        }
        return relative
    }

    func tree() async throws -> FileTree {
        try await FileScanner().scan(root: root).tree
    }

    func apps(lastUsed: @escaping (String) -> Date? = { _ in nil }) async throws -> [InstalledApp] {
        AppFinder.apps(tree: try await tree(), appFolders: [appFolderName, homeAt(appFolderName)], homeInTree: "Users/me", realRoot: root, lastUsed: lastUsed)
    }

    func files(minimum: Int64 = 1_000_000) async throws -> [LargeFile] {
        LargeFileFinder.files(tree: try await tree(), homeInTree: "Users/me", realRoot: root, minimumBytes: minimum)
    }

    var policy: TrashPolicy {
        TrashPolicy(home: home, appFolders: [at(appFolderName), home + "/Applications"])
    }

    /// A Trash that is just a folder in the fake Mac.
    func mover(running: Set<String> = []) throws -> TrashMover {
        try base.folder("FakeTrash")
        let trash = at("FakeTrash")
        return TrashMover(policy: policy, runningProcesses: { running }, moveToTrash: { url in
            try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: trash + "/" + url.lastPathComponent))
        })
    }

    func fileID(_ relative: String) throws -> UInt64 {
        var info = stat()
        guard lstat(at(relative), &info) == 0 else { throw POSIXError(.ENOENT) }
        return info.st_ino
    }
}

@Suite("Installed apps")
struct AppFinderTests {
    @Test("Finds apps, in subfolders too, and reads their details")
    func findsApps() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Large", identifier: "com.sample.large", size: 3_000_000)
        try mac.base.folder("Applications/Utilities")
        try mac.makeApp("Inner", identifier: "com.sample.interna", folder: "Applications/Utilities", size: 100_000)
        try mac.base.folder("Users/me/Applications")
        try mac.makeApp("Mine", identifier: "com.sample.mia", folder: "Users/me/Applications", size: 100_000)

        let apps = try await mac.apps()

        #expect(Set(apps.map(\.name)) == ["Large", "Inner", "Mine"])
        let grande = try #require(apps.first)
        #expect(grande.name == "Large")
        #expect(grande.version == "1.2")
        #expect(grande.bundleIdentifier == "com.sample.large")
        #expect(grande.allocated >= 3_000_000)
    }

    @Test("A .app folder without an identifier isn't an app")
    func ignoresBrokenBundles() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Applications/Broken.app/Contents")
        try Data("not a plist".utf8).write(to: URL(fileURLWithPath: mac.at("Applications/Broken.app/Contents/Info.plist")))

        #expect(try await mac.apps().isEmpty)
    }

    @Test("Apps inside another app aren't offered")
    func ignoresNestedApps() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Outer", identifier: "com.sample.esterna")
        try mac.base.folder("Applications/Outer.app/Contents/Helpers")
        try mac.makeApp("Helper", identifier: "com.sample.helper", folder: "Applications/Outer.app/Contents/Helpers")

        #expect(try await mac.apps().map(\.name) == ["Outer"])
    }

    @Test("An unknown last use stays unknown")
    func unknownLastUsed() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Sample", identifier: "com.sample.a")

        #expect(try await mac.apps { _ in nil }.first?.lastUsed == nil)
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(try await mac.apps { _ in date }.first?.lastUsed == date)
    }

    @Test("Recognizes App Store apps")
    func appStore() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Store", identifier: "com.sample.store", store: true)

        #expect(try await mac.apps().first?.isFromAppStore == true)
    }

    @Test("Caches are offered and data isn't")
    func leftoverDefaults() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Sample", identifier: "com.sample.a")
        try mac.base.folder("Users/me/Library/Caches/com.sample.a")
        try mac.base.folder("Users/me/Library/Application Support/com.sample.a")
        try mac.base.folder("Users/me/Library/Containers/com.sample.a")
        try mac.base.folder("Users/me/Library/Preferences")
        try mac.base.file("Users/me/Library/Preferences/com.sample.a.plist", size: 100)
        try mac.base.folder("Users/me/Library/Saved Application State/com.sample.a.savedState")
        try mac.base.folder("Users/me/Library/Group Containers/TEAM123.com.sample.a")

        let leftovers = try #require(try await mac.apps().first).leftovers
        func isDefault(_ suffix: String) throws -> Bool {
            try #require(leftovers.first { $0.path.hasSuffix(suffix) }).isSelectedByDefault
        }

        #expect(leftovers.count == 6)
        #expect(try isDefault("Caches/com.sample.a"))
        #expect(try isDefault("Preferences/com.sample.a.plist"))
        #expect(try isDefault("Saved Application State/com.sample.a.savedState"))
        #expect(try !isDefault("Application Support/com.sample.a"))
        #expect(try !isDefault("Containers/com.sample.a"))
        #expect(try !isDefault("Group Containers/TEAM123.com.sample.a"))
    }

    @Test("What's found by name only is never offered")
    func nameMatchesAreNotDefault() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Sample", identifier: "com.sample.a")
        try mac.base.folder("Users/me/Library/Caches/Sample")
        try mac.base.folder("Users/me/Library/Application Support/Sample")

        let leftovers = try #require(try await mac.apps().first).leftovers

        #expect(leftovers.count == 2)
        #expect(leftovers.allSatisfy { !$0.matchedByIdentifier && !$0.isSelectedByDefault })
    }

    @Test("A name that's too short isn't enough to link a folder")
    func shortNames() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Go", identifier: "com.sample.go")
        try mac.base.folder("Users/me/Library/Application Support/Go")

        #expect(try await mac.apps().first?.leftovers.isEmpty == true)
    }

    @Test("Similar folders aren't taken for leftovers")
    func similarNames() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Note", identifier: "com.sample.note")
        try mac.base.folder("Users/me/Library/Application Support/Note Old")
        try mac.base.folder("Users/me/Library/Caches/com.sample.note.other")

        #expect(try await mac.apps().first?.leftovers.isEmpty == true)
    }
}

@Suite("Large files")
struct LargeFileTests {
    @Test("Lists large files, largest first, with their category")
    func listsFiles() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Users/me/Downloads/sub")
        try mac.base.file("Users/me/Downloads/installer.dmg", size: 3_000_000)
        try mac.base.file("Users/me/Downloads/sub/archive.zip", size: 2_000_000)
        try mac.base.file("Users/me/movie.MKV", size: 1_500_000)
        try mac.base.file("Users/me/small.dmg", size: 10_000)

        let files = try await mac.files()

        #expect(files.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["installer.dmg", "archive.zip", "movie.MKV"])
        #expect(files.map(\.category) == [.installer, .archive, .video])
    }

    @Test("Doesn't list the Library, hidden folders, or package contents", arguments: [
        "Library/Application Support/x/large",
        ".git/objects/pack/large",
        "project/.git/objects/pack/large",
        "Pictures/Photos Library.photoslibrary/originals/large",
        "Applications/Mine.app/Contents/large",
        "work/Progetto.xcodeproj/large",
    ])
    func skippedPlaces(relative: String) async throws {
        let mac = try FakeMac()
        let path = "Users/me/" + relative
        try mac.base.folder((path as NSString).deletingLastPathComponent)
        try mac.base.file(path, size: 2_000_000)

        #expect(try await mac.files().isEmpty)
    }

    @Test("Doesn't list hidden files")
    func hiddenFiles() async throws {
        let mac = try FakeMac()
        try mac.base.file("Users/me/.hidden", size: 2_000_000)

        #expect(try await mac.files().isEmpty)
    }

    @Test("A hard link shows only once")
    func hardLinks() async throws {
        let mac = try FakeMac()
        try mac.base.file("Users/me/one", size: 2_000_000)
        try FileManager.default.linkItem(atPath: mac.at("Users/me/one"), toPath: mac.at("Users/me/two"))

        #expect(try await mac.files().count == 1)
    }
}

@Suite("Trash: what is allowed")
struct TrashPolicyTests {
    private let policy = TrashPolicy(home: "/Users/me", appFolders: ["/Applications", "/Users/me/Applications"])

    private func allows(_ path: String, _ kind: TrashItem.Kind) -> Bool {
        policy.allows(TrashItem(path: path, fileID: 1, allocated: 1, kind: kind))
    }

    @Test("Apps are allowed only in the app folders", arguments: [
        ("/Applications/Sample.app", true),
        ("/Applications/Utilities/Sample.app", true),
        ("/Users/me/Applications/Sample.app", true),
        ("/Applications/Altra.app/Contents/Helpers/Sample.app", false),
        ("/Applications/a/b/Sample.app", false),
        ("/Users/me/Downloads/Sample.app", false),
        ("/System/Applications/Safari.app", false),
        ("/Applications", false),
        ("/Applications/Sample", false),
        ("/Applications/../Users/me/Sample.app", false),
        ("Applications/Sample.app", false),
    ])
    func apps(path: String, expected: Bool) {
        #expect(allows(path, .app) == expected)
    }

    @Test("Leftovers are allowed only as direct children of known folders", arguments: [
        ("/Users/me/Library/Caches/com.sample.a", true),
        ("/Users/me/Library/Preferences/com.sample.a.plist", true),
        ("/Users/me/Library/Application Support/Sample", true),
        ("/Users/me/Library/Caches", false),
        ("/Users/me/Library/Application Support", false),
        ("/Users/me/Library/Caches/a/b", false),
        ("/Users/me/Library/Keychains/login.keychain-db", false),
        ("/Users/me/Library/Mail/V10", false),
        ("/Users/me/Documents/thesis", false),
        ("/Users/me/Library/Caches/../Keychains", false),
    ])
    func leftovers(path: String, expected: Bool) {
        #expect(allows(path, .leftover) == expected)
    }

    @Test("Files are allowed in the home, outside the Library, hidden folders, and packages", arguments: [
        ("/Users/me/Downloads/large.dmg", true),
        ("/Users/me/movie.mov", true),
        ("/Users/me/Library/Caches/large", false),
        ("/Users/me/.ssh/id_rsa", false),
        ("/Users/me/project/.git/objects/pack", false),
        ("/Users/me/Pictures/Foto.photoslibrary/originals/a.jpg", false),
        ("/Users/me/Applications/Sample.app/Contents/a", false),
        ("/Users/altro/Downloads/a", false),
        ("/etc/hosts", false),
        ("/Users/me/../altro/a", false),
    ])
    func files(path: String, expected: Bool) {
        #expect(allows(path, .file) == expected)
    }
}

@Suite("Trash: moving")
struct TrashMoverTests {
    @Test("Uninstalling moves the app and chosen leftovers, and nothing else")
    func uninstall() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Sample", identifier: "com.sample.a")
        try mac.base.folder("Users/me/Library/Caches/com.sample.a")
        try mac.base.folder("Users/me/Library/Application Support/com.sample.a")
        let app = try #require(try await mac.apps().first)
        let chosen = app.leftovers.filter(\.isSelectedByDefault)
        let items = [TrashItem(path: app.path, fileID: app.fileID, allocated: app.allocated, kind: .app)]
            + chosen.map { TrashItem(path: $0.path, fileID: $0.fileID, allocated: $0.allocated, kind: .leftover) }

        let report = await try mac.mover().run(title: "Sample", items: items, executable: "Sample")

        #expect(!mac.base.exists("Applications/Sample.app"))
        #expect(!mac.base.exists("Users/me/Library/Caches/com.sample.a"))
        #expect(mac.base.exists("Users/me/Library/Application Support/com.sample.a"))
        #expect(mac.base.exists("FakeTrash/Sample.app/Contents/Info.plist"))
        #expect(report.issueCount == 0)
        #expect(report.isTrashOperation)
        #expect(report.removedItemCount == 2)
    }

    @Test("Nothing moves while the app is open")
    func appRunning() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Sample", identifier: "com.sample.a")
        let app = try #require(try await mac.apps().first)

        let report = await try mac.mover(running: ["Sample"]).run(
            title: "Sample",
            items: [TrashItem(path: app.path, fileID: app.fileID, allocated: 1, kind: .app)],
            executable: "Sample"
        )

        #expect(mac.base.exists("Applications/Sample.app"))
        #expect(report.rules[0].blockedBy == ["Sample"])
    }

    @Test("A long name is recognized even when the system truncates it")
    func longExecutableName() {
        #expect(RunningProcesses.contains("Eseguibile Molto Lungo Davvero", in: ["Eseguibile Molto"]))
        #expect(!RunningProcesses.contains("Eseguibile Molto Lungo", in: ["Altro"]))
    }

    @Test("An item replaced after the scan stays where it is")
    func replaced() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Sample", identifier: "com.sample.a")
        let app = try #require(try await mac.apps().first)
        try FileManager.default.moveItem(atPath: mac.at("Applications/Sample.app"), toPath: mac.at("Applications/Old.app"))
        try mac.makeApp("Sample", identifier: "com.sample.nuova")

        let report = await try mac.mover().run(
            title: "Sample",
            items: [TrashItem(path: app.path, fileID: app.fileID, allocated: 1, kind: .app)]
        )

        #expect(mac.base.exists("Applications/Sample.app"))
        #expect(report.rules[0].issues.first?.problem == .changedSinceScan)
    }

    @Test("An app replaced by a symbolic link isn't followed")
    func symlinkedApp() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Sample", identifier: "com.sample.a")
        try mac.base.folder("Users/me/Documents")
        try mac.base.file("Users/me/Documents/thesis")
        let id = try mac.fileID("Applications/Sample.app")
        try FileManager.default.removeItem(atPath: mac.at("Applications/Sample.app"))
        try mac.base.link("Applications/Sample.app", to: mac.at("Users/me/Documents"))

        let report = await try mac.mover().run(
            title: "Sample",
            items: [TrashItem(path: mac.at("Applications/Sample.app"), fileID: id, allocated: 1, kind: .app)]
        )

        #expect(mac.base.exists("Users/me/Documents/thesis"))
        #expect(report.removedItemCount == 0)
        #expect(report.issueCount == 1)
    }

    @Test("A symbolic link in the path is refused")
    func symlinkInPath() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Elsewhere")
        try mac.base.file("Elsewhere/large")
        try mac.base.link("Users/me/Downloads", to: mac.at("Elsewhere"))
        let id = try mac.fileID("Elsewhere/large")

        let report = await try mac.mover().run(
            title: "File",
            items: [TrashItem(path: mac.at("Users/me/Downloads/large"), fileID: id, allocated: 1, kind: .file)]
        )

        #expect(mac.base.exists("Elsewhere/large"))
        #expect(report.rules[0].issues.first?.problem == .symbolicLinkInPath)
    }

    @Test("A folder in place of a file stays where it is")
    func folderInsteadOfFile() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Users/me/Documents")
        let id = try mac.fileID("Users/me/Documents")

        let report = await try mac.mover().run(
            title: "File",
            items: [TrashItem(path: mac.at("Users/me/Documents"), fileID: id, allocated: 1, kind: .file)]
        )

        #expect(mac.base.exists("Users/me/Documents"))
        #expect(report.rules[0].issues.first?.problem == .changedSinceScan)
    }

    @Test("An item outside the rules isn't moved", arguments: [
        "Users/me/.ssh/id_rsa",
        "Users/me/Library/Keychains/login.keychain-db",
        "private/secret",
    ])
    func outsidePolicy(relative: String) async throws {
        let mac = try FakeMac()
        try mac.base.folder((relative as NSString).deletingLastPathComponent)
        try mac.base.file(relative)
        let id = try mac.fileID(relative)

        let report = await try mac.mover().run(
            title: "File",
            items: [TrashItem(path: mac.at(relative), fileID: id, allocated: 1, kind: .file)]
        )

        #expect(mac.base.exists(relative))
        #expect(report.rules[0].issues.first?.problem == .outsideRoot)
    }

    @Test("If the system refuses to move something, it's reported and the rest goes on")
    func trashRefused() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Users/me/Downloads")
        try mac.base.file("Users/me/Downloads/a")
        try mac.base.file("Users/me/Downloads/b")
        let fail = Mutex(true)
        let mover = TrashMover(policy: mac.policy, runningProcesses: { [] }, moveToTrash: { url in
            if fail.withLock({ value in defer { value = false }; return value }) {
                throw POSIXError(.EPERM)
            }
            try FileManager.default.removeItem(at: url)
        })

        let report = await mover.run(title: "File", items: [
            TrashItem(path: mac.at("Users/me/Downloads/a"), fileID: try mac.fileID("Users/me/Downloads/a"), allocated: 1, kind: .file),
            TrashItem(path: mac.at("Users/me/Downloads/b"), fileID: try mac.fileID("Users/me/Downloads/b"), allocated: 1, kind: .file),
        ])

        #expect(report.issueCount == 1)
        #expect(report.removedItemCount == 1)
    }

    @Test("History written before the Trash existed still loads")
    func oldHistory() throws {
        let line = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","date":"2026-11-05T10:00:00Z","rules":[],"measuredFreed":5,"wasCancelled":false}"#
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        let report = try decoder.decode(CleanupReport.self, from: Data(line.utf8))

        #expect(!report.isTrashOperation)
        #expect(report.measuredFreed == 5)
    }

    /// The one test that touches the real Trash, to prove the real call works. It moves a
    /// file made here and removes exactly that file again.
    @Test("The system Trash takes a file and it can be found again")
    func realTrash() throws {
        let home = try FakeHome()
        try home.file("to-trash-imemory-test")
        var result: NSURL?

        try FileManager.default.trashItem(at: URL(fileURLWithPath: home.at("to-trash-imemory-test")), resultingItemURL: &result)
        defer { if let result { try? FileManager.default.removeItem(at: result as URL) } }

        let moved = try #require(result as URL?)
        #expect(!home.exists("to-trash-imemory-test"))
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }
}

@Suite("Recovery estimate")
struct RecoveryEstimateTests {
    @Test("A plain file comes back in full")
    func plainFile() throws {
        let home = try FakeHome()
        try home.file("a", size: 3_000_000)

        let estimate = RecoveryEstimator.estimate(paths: [home.at("a")])

        #expect(estimate.recoverable == estimate.allocated)
        #expect(estimate.recoverable >= 3_000_000)
    }

    @Test("Two clones in the same set come back once")
    func clonesInsideSet() throws {
        let home = try FakeHome()
        try home.folder("app")
        try home.file("app/a", size: 5_000_000)
        #expect(clonefile(home.at("app/a"), home.at("app/b"), 0) == 0)

        let estimate = RecoveryEstimator.estimate(paths: [home.at("app")])

        #expect(estimate.allocated >= 10_000_000)
        #expect(abs(estimate.recoverable - 5_000_000) < 200_000)
    }

    @Test("A clone whose original is outside the set frees nothing")
    func cloneOutsideSet() throws {
        let home = try FakeHome()
        try home.folder("app")
        try home.file("original", size: 5_000_000)
        #expect(clonefile(home.at("original"), home.at("app/clone"), 0) == 0)

        let estimate = RecoveryEstimator.estimate(paths: [home.at("app")])

        #expect(estimate.allocated >= 5_000_000)
        #expect(estimate.recoverable < 200_000)
    }

    @Test("Three clones with one outside free nothing, and with all inside they do")
    func partialGroup() throws {
        let home = try FakeHome()
        try home.folder("app")
        try home.file("app/a", size: 5_000_000)
        #expect(clonefile(home.at("app/a"), home.at("app/b"), 0) == 0)
        #expect(clonefile(home.at("app/a"), home.at("outside"), 0) == 0)

        #expect(RecoveryEstimator.estimate(paths: [home.at("app")]).recoverable < 200_000)
        #expect(abs(RecoveryEstimator.estimate(paths: [home.at("app"), home.at("outside")]).recoverable - 5_000_000) < 200_000)
    }

    @Test("A hard link with its other name outside the set frees nothing")
    func hardLinks() throws {
        let home = try FakeHome()
        try home.folder("app")
        try home.file("app/a", size: 5_000_000)
        try FileManager.default.linkItem(atPath: home.at("app/a"), toPath: home.at("outside"))

        let outside = RecoveryEstimator.estimate(paths: [home.at("app")])
        let both = RecoveryEstimator.estimate(paths: [home.at("app"), home.at("outside")])

        #expect(outside.recoverable < 200_000)
        #expect(both.recoverable >= 5_000_000)
        #expect(both.allocated < 5_500_000)
    }

    @Test("A missing path doesn't count")
    func missingPath() {
        #expect(RecoveryEstimator.estimate(paths: ["/percorso/inesistente/imemory"]).allocated == 0)
    }
}
