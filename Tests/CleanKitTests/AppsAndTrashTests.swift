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
    var home: String { base.at("Users/io") }

    init() throws {
        base = try FakeHome()
        try base.folder(appFolderName)
        try base.folder("Users/io/Library")
    }

    func at(_ relative: String) -> String { base.at(relative) }
    func homeAt(_ relative: String) -> String { "Users/io/" + relative }

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
        try base.file(relative + "/Contents/binario", size: size)
        if store {
            try base.folder(relative + "/Contents/_MASReceipt")
        }
        return relative
    }

    func tree() async throws -> FileTree {
        try await FileScanner().scan(root: root).tree
    }

    func apps(lastUsed: @escaping (String) -> Date? = { _ in nil }) async throws -> [InstalledApp] {
        AppFinder.apps(tree: try await tree(), appFolders: [appFolderName, homeAt(appFolderName)], homeInTree: "Users/io", realRoot: root, lastUsed: lastUsed)
    }

    func files(minimum: Int64 = 1_000_000) async throws -> [LargeFile] {
        LargeFileFinder.files(tree: try await tree(), homeInTree: "Users/io", realRoot: root, minimumBytes: minimum)
    }

    var policy: TrashPolicy {
        TrashPolicy(home: home, appFolders: [at(appFolderName), home + "/Applications"])
    }

    /// A Trash that is just a folder in the fake Mac.
    func mover(running: Set<String> = []) throws -> TrashMover {
        try base.folder("CestinoFinto")
        let trash = at("CestinoFinto")
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

@Suite("App installate")
struct AppFinderTests {
    @Test("Trova le app, anche nelle sottocartelle, e ne legge i dati")
    func findsApps() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Grande", identifier: "com.prova.grande", size: 3_000_000)
        try mac.base.folder("Applications/Utilities")
        try mac.makeApp("Interna", identifier: "com.prova.interna", folder: "Applications/Utilities", size: 100_000)
        try mac.base.folder("Users/io/Applications")
        try mac.makeApp("Mia", identifier: "com.prova.mia", folder: "Users/io/Applications", size: 100_000)

        let apps = try await mac.apps()

        #expect(Set(apps.map(\.name)) == ["Grande", "Interna", "Mia"])
        let grande = try #require(apps.first)
        #expect(grande.name == "Grande")
        #expect(grande.version == "1.2")
        #expect(grande.bundleIdentifier == "com.prova.grande")
        #expect(grande.allocated >= 3_000_000)
    }

    @Test("Una cartella .app senza identificativo non è un'app")
    func ignoresBrokenBundles() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Applications/Rotta.app/Contents")
        try Data("non è un plist".utf8).write(to: URL(fileURLWithPath: mac.at("Applications/Rotta.app/Contents/Info.plist")))

        #expect(try await mac.apps().isEmpty)
    }

    @Test("Le app dentro un'altra app non vengono proposte")
    func ignoresNestedApps() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Esterna", identifier: "com.prova.esterna")
        try mac.base.folder("Applications/Esterna.app/Contents/Helpers")
        try mac.makeApp("Helper", identifier: "com.prova.helper", folder: "Applications/Esterna.app/Contents/Helpers")

        #expect(try await mac.apps().map(\.name) == ["Esterna"])
    }

    @Test("Un ultimo utilizzo sconosciuto resta sconosciuto")
    func unknownLastUsed() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Prova", identifier: "com.prova.a")

        #expect(try await mac.apps { _ in nil }.first?.lastUsed == nil)
        let date = Date(timeIntervalSince1970: 1_000_000_000)
        #expect(try await mac.apps { _ in date }.first?.lastUsed == date)
    }

    @Test("Riconosce le app di App Store")
    func appStore() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Store", identifier: "com.prova.store", store: true)

        #expect(try await mac.apps().first?.isFromAppStore == true)
    }

    @Test("Le cache si propongono e i dati no")
    func leftoverDefaults() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Prova", identifier: "com.prova.a")
        try mac.base.folder("Users/io/Library/Caches/com.prova.a")
        try mac.base.folder("Users/io/Library/Application Support/com.prova.a")
        try mac.base.folder("Users/io/Library/Containers/com.prova.a")
        try mac.base.folder("Users/io/Library/Preferences")
        try mac.base.file("Users/io/Library/Preferences/com.prova.a.plist", size: 100)
        try mac.base.folder("Users/io/Library/Saved Application State/com.prova.a.savedState")
        try mac.base.folder("Users/io/Library/Group Containers/TEAM123.com.prova.a")

        let leftovers = try #require(try await mac.apps().first).leftovers
        func isDefault(_ suffix: String) throws -> Bool {
            try #require(leftovers.first { $0.path.hasSuffix(suffix) }).isSelectedByDefault
        }

        #expect(leftovers.count == 6)
        #expect(try isDefault("Caches/com.prova.a"))
        #expect(try isDefault("Preferences/com.prova.a.plist"))
        #expect(try isDefault("Saved Application State/com.prova.a.savedState"))
        #expect(try !isDefault("Application Support/com.prova.a"))
        #expect(try !isDefault("Containers/com.prova.a"))
        #expect(try !isDefault("Group Containers/TEAM123.com.prova.a"))
    }

    @Test("Quanto è trovato solo per nome non si propone mai")
    func nameMatchesAreNotDefault() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Prova", identifier: "com.prova.a")
        try mac.base.folder("Users/io/Library/Caches/Prova")
        try mac.base.folder("Users/io/Library/Application Support/Prova")

        let leftovers = try #require(try await mac.apps().first).leftovers

        #expect(leftovers.count == 2)
        #expect(leftovers.allSatisfy { !$0.matchedByIdentifier && !$0.isSelectedByDefault })
    }

    @Test("Un nome troppo corto non basta per collegare una cartella")
    func shortNames() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Go", identifier: "com.prova.go")
        try mac.base.folder("Users/io/Library/Application Support/Go")

        #expect(try await mac.apps().first?.leftovers.isEmpty == true)
    }

    @Test("Le cartelle simili non vengono prese per residui")
    func similarNames() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Note", identifier: "com.prova.note")
        try mac.base.folder("Users/io/Library/Application Support/Note Vecchie")
        try mac.base.folder("Users/io/Library/Caches/com.prova.note.altra")

        #expect(try await mac.apps().first?.leftovers.isEmpty == true)
    }
}

@Suite("File grandi")
struct LargeFileTests {
    @Test("Elenca i file grandi, dal più grande, con la categoria")
    func listsFiles() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Users/io/Downloads/sotto")
        try mac.base.file("Users/io/Downloads/installer.dmg", size: 3_000_000)
        try mac.base.file("Users/io/Downloads/sotto/archivio.zip", size: 2_000_000)
        try mac.base.file("Users/io/film.MKV", size: 1_500_000)
        try mac.base.file("Users/io/piccolo.dmg", size: 10_000)

        let files = try await mac.files()

        #expect(files.map { URL(fileURLWithPath: $0.path).lastPathComponent } == ["installer.dmg", "archivio.zip", "film.MKV"])
        #expect(files.map(\.category) == [.installer, .archive, .video])
    }

    @Test("Non elenca Libreria, cartelle nascoste e interni dei pacchetti", arguments: [
        "Library/Application Support/x/grande",
        ".git/objects/pack/grande",
        "progetto/.git/objects/pack/grande",
        "Pictures/Photos Library.photoslibrary/originals/grande",
        "Applications/Mia.app/Contents/grande",
        "lavoro/Progetto.xcodeproj/grande",
    ])
    func skippedPlaces(relative: String) async throws {
        let mac = try FakeMac()
        let path = "Users/io/" + relative
        try mac.base.folder((path as NSString).deletingLastPathComponent)
        try mac.base.file(path, size: 2_000_000)

        #expect(try await mac.files().isEmpty)
    }

    @Test("Non elenca file nascosti")
    func hiddenFiles() async throws {
        let mac = try FakeMac()
        try mac.base.file("Users/io/.nascosto", size: 2_000_000)

        #expect(try await mac.files().isEmpty)
    }

    @Test("Un hard link compare una sola volta")
    func hardLinks() async throws {
        let mac = try FakeMac()
        try mac.base.file("Users/io/uno", size: 2_000_000)
        try FileManager.default.linkItem(atPath: mac.at("Users/io/uno"), toPath: mac.at("Users/io/due"))

        #expect(try await mac.files().count == 1)
    }
}

@Suite("Cestino: regole di ammissione")
struct TrashPolicyTests {
    private let policy = TrashPolicy(home: "/Users/io", appFolders: ["/Applications", "/Users/io/Applications"])

    private func allows(_ path: String, _ kind: TrashItem.Kind) -> Bool {
        policy.allows(TrashItem(path: path, fileID: 1, allocated: 1, kind: kind))
    }

    @Test("Le app si ammettono solo nelle cartelle delle app", arguments: [
        ("/Applications/Prova.app", true),
        ("/Applications/Utilities/Prova.app", true),
        ("/Users/io/Applications/Prova.app", true),
        ("/Applications/Altra.app/Contents/Helpers/Prova.app", false),
        ("/Applications/a/b/Prova.app", false),
        ("/Users/io/Downloads/Prova.app", false),
        ("/System/Applications/Safari.app", false),
        ("/Applications", false),
        ("/Applications/Prova", false),
        ("/Applications/../Users/io/Prova.app", false),
        ("Applications/Prova.app", false),
    ])
    func apps(path: String, expected: Bool) {
        #expect(allows(path, .app) == expected)
    }

    @Test("I residui si ammettono solo come figli diretti di cartelle note", arguments: [
        ("/Users/io/Library/Caches/com.prova.a", true),
        ("/Users/io/Library/Preferences/com.prova.a.plist", true),
        ("/Users/io/Library/Application Support/Prova", true),
        ("/Users/io/Library/Caches", false),
        ("/Users/io/Library/Application Support", false),
        ("/Users/io/Library/Caches/a/b", false),
        ("/Users/io/Library/Keychains/login.keychain-db", false),
        ("/Users/io/Library/Mail/V10", false),
        ("/Users/io/Documents/tesi", false),
        ("/Users/io/Library/Caches/../Keychains", false),
    ])
    func leftovers(path: String, expected: Bool) {
        #expect(allows(path, .leftover) == expected)
    }

    @Test("I file si ammettono nella Home, fuori da Libreria, nascosti e pacchetti", arguments: [
        ("/Users/io/Downloads/grande.dmg", true),
        ("/Users/io/film.mov", true),
        ("/Users/io/Library/Caches/grande", false),
        ("/Users/io/.ssh/id_rsa", false),
        ("/Users/io/progetto/.git/objects/pack", false),
        ("/Users/io/Pictures/Foto.photoslibrary/originals/a.jpg", false),
        ("/Users/io/Applications/Prova.app/Contents/a", false),
        ("/Users/altro/Downloads/a", false),
        ("/etc/hosts", false),
        ("/Users/io/../altro/a", false),
    ])
    func files(path: String, expected: Bool) {
        #expect(allows(path, .file) == expected)
    }
}

@Suite("Cestino: spostamento")
struct TrashMoverTests {
    @Test("Disinstallare sposta app e residui scelti, e nient'altro")
    func uninstall() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Prova", identifier: "com.prova.a")
        try mac.base.folder("Users/io/Library/Caches/com.prova.a")
        try mac.base.folder("Users/io/Library/Application Support/com.prova.a")
        let app = try #require(try await mac.apps().first)
        let chosen = app.leftovers.filter(\.isSelectedByDefault)
        let items = [TrashItem(path: app.path, fileID: app.fileID, allocated: app.allocated, kind: .app)]
            + chosen.map { TrashItem(path: $0.path, fileID: $0.fileID, allocated: $0.allocated, kind: .leftover) }

        let report = await try mac.mover().run(title: "Prova", items: items, executable: "Prova")

        #expect(!mac.base.exists("Applications/Prova.app"))
        #expect(!mac.base.exists("Users/io/Library/Caches/com.prova.a"))
        #expect(mac.base.exists("Users/io/Library/Application Support/com.prova.a"))
        #expect(mac.base.exists("CestinoFinto/Prova.app/Contents/Info.plist"))
        #expect(report.issueCount == 0)
        #expect(report.isTrashOperation)
        #expect(report.removedItemCount == 2)
    }

    @Test("Con l'app aperta non si sposta nulla")
    func appRunning() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Prova", identifier: "com.prova.a")
        let app = try #require(try await mac.apps().first)

        let report = await try mac.mover(running: ["Prova"]).run(
            title: "Prova",
            items: [TrashItem(path: app.path, fileID: app.fileID, allocated: 1, kind: .app)],
            executable: "Prova"
        )

        #expect(mac.base.exists("Applications/Prova.app"))
        #expect(report.rules[0].blockedBy == ["Prova"])
    }

    @Test("Un nome lungo viene riconosciuto anche se il sistema lo tronca")
    func longExecutableName() {
        #expect(RunningProcesses.contains("Eseguibile Molto Lungo Davvero", in: ["Eseguibile Molto"]))
        #expect(!RunningProcesses.contains("Eseguibile Molto Lungo", in: ["Altro"]))
    }

    @Test("Un elemento sostituito dopo la scansione resta al suo posto")
    func replaced() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Prova", identifier: "com.prova.a")
        let app = try #require(try await mac.apps().first)
        try FileManager.default.moveItem(atPath: mac.at("Applications/Prova.app"), toPath: mac.at("Applications/Vecchia.app"))
        try mac.makeApp("Prova", identifier: "com.prova.nuova")

        let report = await try mac.mover().run(
            title: "Prova",
            items: [TrashItem(path: app.path, fileID: app.fileID, allocated: 1, kind: .app)]
        )

        #expect(mac.base.exists("Applications/Prova.app"))
        #expect(report.rules[0].issues.first?.problem == .changedSinceScan)
    }

    @Test("Un'app sostituita da un link simbolico non viene seguita")
    func symlinkedApp() async throws {
        let mac = try FakeMac()
        try mac.makeApp("Prova", identifier: "com.prova.a")
        try mac.base.folder("Users/io/Documents")
        try mac.base.file("Users/io/Documents/tesi")
        let id = try mac.fileID("Applications/Prova.app")
        try FileManager.default.removeItem(atPath: mac.at("Applications/Prova.app"))
        try mac.base.link("Applications/Prova.app", to: mac.at("Users/io/Documents"))

        let report = await try mac.mover().run(
            title: "Prova",
            items: [TrashItem(path: mac.at("Applications/Prova.app"), fileID: id, allocated: 1, kind: .app)]
        )

        #expect(mac.base.exists("Users/io/Documents/tesi"))
        #expect(report.removedItemCount == 0)
        #expect(report.issueCount == 1)
    }

    @Test("Un link simbolico nel percorso viene rifiutato")
    func symlinkInPath() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Altrove")
        try mac.base.file("Altrove/grande")
        try mac.base.link("Users/io/Downloads", to: mac.at("Altrove"))
        let id = try mac.fileID("Altrove/grande")

        let report = await try mac.mover().run(
            title: "File",
            items: [TrashItem(path: mac.at("Users/io/Downloads/grande"), fileID: id, allocated: 1, kind: .file)]
        )

        #expect(mac.base.exists("Altrove/grande"))
        #expect(report.rules[0].issues.first?.problem == .symbolicLinkInPath)
    }

    @Test("Una cartella al posto di un file resta al suo posto")
    func folderInsteadOfFile() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Users/io/Documents")
        let id = try mac.fileID("Users/io/Documents")

        let report = await try mac.mover().run(
            title: "File",
            items: [TrashItem(path: mac.at("Users/io/Documents"), fileID: id, allocated: 1, kind: .file)]
        )

        #expect(mac.base.exists("Users/io/Documents"))
        #expect(report.rules[0].issues.first?.problem == .changedSinceScan)
    }

    @Test("Un elemento fuori dalle regole non viene spostato", arguments: [
        "Users/io/.ssh/id_rsa",
        "Users/io/Library/Keychains/login.keychain-db",
        "private/segreto",
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

    @Test("Se il sistema rifiuta lo spostamento, si riporta e si prosegue")
    func trashRefused() async throws {
        let mac = try FakeMac()
        try mac.base.folder("Users/io/Downloads")
        try mac.base.file("Users/io/Downloads/a")
        try mac.base.file("Users/io/Downloads/b")
        let fail = Mutex(true)
        let mover = TrashMover(policy: mac.policy, runningProcesses: { [] }, moveToTrash: { url in
            if fail.withLock({ value in defer { value = false }; return value }) {
                throw POSIXError(.EPERM)
            }
            try FileManager.default.removeItem(at: url)
        })

        let report = await mover.run(title: "File", items: [
            TrashItem(path: mac.at("Users/io/Downloads/a"), fileID: try mac.fileID("Users/io/Downloads/a"), allocated: 1, kind: .file),
            TrashItem(path: mac.at("Users/io/Downloads/b"), fileID: try mac.fileID("Users/io/Downloads/b"), allocated: 1, kind: .file),
        ])

        #expect(report.issueCount == 1)
        #expect(report.removedItemCount == 1)
    }

    @Test("La cronologia scritta prima del Cestino si legge ancora")
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
    @Test("Il Cestino di sistema accetta un file e lo si può ritrovare")
    func realTrash() throws {
        let home = try FakeHome()
        try home.file("da-cestinare-imemory-test")
        var result: NSURL?

        try FileManager.default.trashItem(at: URL(fileURLWithPath: home.at("da-cestinare-imemory-test")), resultingItemURL: &result)
        defer { if let result { try? FileManager.default.removeItem(at: result as URL) } }

        let moved = try #require(result as URL?)
        #expect(!home.exists("da-cestinare-imemory-test"))
        #expect(FileManager.default.fileExists(atPath: moved.path))
    }
}

@Suite("Stima del recupero")
struct RecoveryEstimateTests {
    @Test("Un file normale torna per intero")
    func plainFile() throws {
        let home = try FakeHome()
        try home.file("a", size: 3_000_000)

        let estimate = RecoveryEstimator.estimate(paths: [home.at("a")])

        #expect(estimate.recoverable == estimate.allocated)
        #expect(estimate.recoverable >= 3_000_000)
    }

    @Test("Due cloni nello stesso insieme tornano una volta sola")
    func clonesInsideSet() throws {
        let home = try FakeHome()
        try home.folder("app")
        try home.file("app/a", size: 5_000_000)
        #expect(clonefile(home.at("app/a"), home.at("app/b"), 0) == 0)

        let estimate = RecoveryEstimator.estimate(paths: [home.at("app")])

        #expect(estimate.allocated >= 10_000_000)
        #expect(abs(estimate.recoverable - 5_000_000) < 200_000)
    }

    @Test("Un clone con l'originale fuori dall'insieme non libera nulla")
    func cloneOutsideSet() throws {
        let home = try FakeHome()
        try home.folder("app")
        try home.file("originale", size: 5_000_000)
        #expect(clonefile(home.at("originale"), home.at("app/clone"), 0) == 0)

        let estimate = RecoveryEstimator.estimate(paths: [home.at("app")])

        #expect(estimate.allocated >= 5_000_000)
        #expect(estimate.recoverable < 200_000)
    }

    @Test("Tre cloni con uno fuori non liberano nulla, e con tutti dentro sì")
    func partialGroup() throws {
        let home = try FakeHome()
        try home.folder("app")
        try home.file("app/a", size: 5_000_000)
        #expect(clonefile(home.at("app/a"), home.at("app/b"), 0) == 0)
        #expect(clonefile(home.at("app/a"), home.at("fuori"), 0) == 0)

        #expect(RecoveryEstimator.estimate(paths: [home.at("app")]).recoverable < 200_000)
        #expect(abs(RecoveryEstimator.estimate(paths: [home.at("app"), home.at("fuori")]).recoverable - 5_000_000) < 200_000)
    }

    @Test("Un hard link con l'altro nome fuori dall'insieme non libera nulla")
    func hardLinks() throws {
        let home = try FakeHome()
        try home.folder("app")
        try home.file("app/a", size: 5_000_000)
        try FileManager.default.linkItem(atPath: home.at("app/a"), toPath: home.at("fuori"))

        let outside = RecoveryEstimator.estimate(paths: [home.at("app")])
        let both = RecoveryEstimator.estimate(paths: [home.at("app"), home.at("fuori")])

        #expect(outside.recoverable < 200_000)
        #expect(both.recoverable >= 5_000_000)
        #expect(both.allocated < 5_500_000)
    }

    @Test("Un percorso assente non conta")
    func missingPath() {
        #expect(RecoveryEstimator.estimate(paths: ["/percorso/inesistente/imemory"]).allocated == 0)
    }
}
