@testable import DuplicateKit
import Foundation
import Synchronization
import Testing
@testable import CleanKit
@testable import RulesKit
import ScanKit

/// A home below a root, as on the real disk.
private final class Home {
    let base: FakeHome
    var root: String { base.path }

    init() throws {
        base = try FakeHome()
        try base.folder("Users/io/Documents")
    }

    func path(_ relative: String) -> String { base.at("Users/io/" + relative) }

    func write(_ data: Data, to relative: String) throws {
        let full = path(relative)
        try FileManager.default.createDirectory(atPath: (full as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        try data.write(to: URL(fileURLWithPath: full))
    }

    func clone(_ source: String, to destination: String) throws {
        #expect(clonefile(path(source), path(destination), 0) == 0)
    }

    func find(minimum: Int64 = 100_000) async throws -> DuplicateSearchResult {
        let tree = try await FileScanner().scan(root: root).tree
        return DuplicateFinder.find(tree: tree, homeInTree: "Users/io", realRoot: root, minimumBytes: minimum)
    }
}

private func random(_ size: Int) -> Data {
    var bytes = [UInt8](repeating: 0, count: size)
    arc4random_buf(&bytes, size)
    return Data(bytes)
}

@Suite("Duplicati")
struct DuplicateFinderTests {
    @Test("Due copie vere sono un gruppo, e si recupera una copia")
    func realCopies() async throws {
        let home = try Home()
        let data = random(500_000)
        try home.write(data, to: "Documents/a")
        try home.write(data, to: "Documents/b")

        let result = try await home.find()
        let group = try #require(result.groups.first)

        #expect(result.groups.count == 1)
        #expect(group.copies == 2)
        #expect(group.files.count == 2)
        #expect(group.reclaimable >= 500_000)
        #expect(group.reclaimable < 600_000)
    }

    @Test("Due cloni APFS non sono duplicati")
    func clonesAreNotDuplicates() async throws {
        let home = try Home()
        try home.write(random(500_000), to: "Documents/originale")
        try home.clone("Documents/originale", to: "Documents/clone")

        #expect(try await home.find().groups.isEmpty)
    }

    @Test("Tre cloni dello stesso file non sono duplicati")
    func threeClones() async throws {
        let home = try Home()
        try home.write(random(500_000), to: "Documents/a")
        try home.clone("Documents/a", to: "Documents/b")
        try home.clone("Documents/a", to: "Documents/c")

        #expect(try await home.find().groups.isEmpty)
    }

    @Test("Un clone diverso dal suo originale dopo una modifica non è un duplicato")
    func divergedClone() async throws {
        let home = try Home()
        try home.write(random(500_000), to: "Documents/a")
        try home.clone("Documents/a", to: "Documents/b")
        let handle = try FileHandle(forWritingTo: URL(fileURLWithPath: home.path("Documents/b")))
        try handle.write(contentsOf: Data([1, 2, 3, 4]))
        try handle.close()

        #expect(try await home.find().groups.isEmpty)
    }

    @Test("Con due cloni e una copia separata si contano due copie, non tre")
    func clonesPlusRealCopy() async throws {
        let home = try Home()
        let data = random(500_000)
        try home.write(data, to: "Documents/a")
        try home.clone("Documents/a", to: "Documents/clone")
        try home.write(data, to: "Documents/separata")

        let group = try #require(try await home.find().groups.first)

        #expect(group.files.count == 3)
        #expect(group.copies == 2)
        #expect(group.reclaimable < 600_000)
        #expect(group.files.filter(\.isClone).map { URL(fileURLWithPath: $0.path).lastPathComponent }.sorted() == ["a", "clone"])
    }

    @Test("Un hard link non è un duplicato")
    func hardLink() async throws {
        let home = try Home()
        try home.write(random(500_000), to: "Documents/a")
        try FileManager.default.linkItem(atPath: home.path("Documents/a"), toPath: home.path("Documents/b"))

        #expect(try await home.find().groups.isEmpty)
    }

    @Test("Stessa dimensione ma contenuto diverso: non sono duplicati", arguments: [
        "inizio", "mezzo", "fine",
    ])
    func sameSizeDifferentContent(place: String) async throws {
        let home = try Home()
        var data = random(1_000_000)
        try home.write(data, to: "Documents/a")
        // Il mezzo sfugge al confronto parziale: lo deve cogliere il confronto completo.
        let index = place == "inizio" ? 10 : place == "mezzo" ? 500_000 : 999_990
        data[index] = data[index] &+ 1
        try home.write(data, to: "Documents/b")

        #expect(try await home.find().groups.isEmpty)
    }

    @Test("Non considera Libreria, cartelle nascoste e pacchetti", arguments: [
        "Library/Caches/copia", ".git/copia", "progetto/.git/copia",
        "Pictures/Foto.photoslibrary/copia", "Applications/Mia.app/copia",
    ])
    func skippedPlaces(relative: String) async throws {
        let home = try Home()
        let data = random(500_000)
        try home.write(data, to: "Documents/originale")
        try home.write(data, to: relative)

        #expect(try await home.find().groups.isEmpty)
    }

    @Test("I file piccoli e vuoti non si considerano")
    func smallFiles() async throws {
        let home = try Home()
        let data = random(50_000)
        try home.write(data, to: "Documents/a")
        try home.write(data, to: "Documents/b")
        try home.write(Data(), to: "Documents/vuoto1")
        try home.write(Data(), to: "Documents/vuoto2")

        #expect(try await home.find(minimum: 100_000).groups.isEmpty)
    }

    @Test("Un file illeggibile si conta e la ricerca prosegue")
    func unreadableFile() async throws {
        let home = try Home()
        let data = random(500_000)
        try home.write(data, to: "Documents/a")
        try home.write(data, to: "Documents/b")
        try home.write(data, to: "Documents/chiuso")
        #expect(chmod(home.path("Documents/chiuso"), 0) == 0)
        defer { chmod(home.path("Documents/chiuso"), 0o644) }

        let result = try await home.find()

        #expect(result.unreadableFiles == 1)
        #expect(result.groups.first?.files.count == 2)
    }

    @Test("La ricerca si può interrompere")
    func cancellation() async throws {
        let home = try Home()
        let data = random(500_000)
        try home.write(data, to: "Documents/a")
        try home.write(data, to: "Documents/b")
        let tree = try await FileScanner().scan(root: home.root).tree

        let result = DuplicateFinder.find(tree: tree, homeInTree: "Users/io", realRoot: home.root, minimumBytes: 100_000, isCancelled: { true })

        #expect(result.wasCancelled)
        #expect(result.groups.isEmpty)
    }

    @Test("I gruppi sono ordinati dal maggior recupero")
    func ordering() async throws {
        let home = try Home()
        let small = random(200_000)
        let large = random(800_000)
        try home.write(small, to: "Documents/p1")
        try home.write(small, to: "Documents/p2")
        try home.write(large, to: "Documents/g1")
        try home.write(large, to: "Documents/g2")

        let groups = try await home.find().groups

        #expect(groups.count == 2)
        #expect(groups[0].reclaimable > groups[1].reclaimable)
    }
}

@Suite("Scelta dei duplicati")
struct DuplicateSelectionTests {
    private func file(_ name: String) -> DuplicateFile {
        DuplicateFile(path: "/x/" + name, fileID: 1, allocated: 10, modified: .now, isClone: false)
    }

    private var group: DuplicateGroup {
        DuplicateGroup(digest: "d", files: [file("a"), file("b"), file("c")], copies: 3, reclaimable: 20)
    }

    @Test("Scegliere tutte le copie di un gruppo non è possibile")
    func everyCopy() {
        #expect(throws: DuplicateSelection.SelectionError.wouldRemoveEveryCopy(digest: "d")) {
            try DuplicateSelection(groups: [group], selected: ["/x/a", "/x/b", "/x/c"])
        }
    }

    @Test("Resta sempre una copia, indicata come da tenere")
    func keepsOne() throws {
        let selection = try DuplicateSelection(groups: [group], selected: ["/x/a", "/x/c"])

        #expect(selection.toRemove.map(\.id) == ["/x/a", "/x/c"])
        #expect(selection.toKeep.map(\.id) == ["/x/b"])
    }

    @Test("Un gruppo senza selezione non partecipa")
    func untouched() throws {
        let selection = try DuplicateSelection(groups: [group], selected: [])

        #expect(selection.toRemove.isEmpty)
        #expect(selection.toKeep.isEmpty)
    }
}

@Suite("Cestino: la copia da tenere")
struct KeepCopyTests {
    private func mover(_ home: Home) throws -> TrashMover {
        try home.base.folder("CestinoFinto")
        let trash = home.base.at("CestinoFinto")
        return TrashMover(
            policy: TrashPolicy(home: home.base.at("Users/io"), appFolders: []),
            runningProcesses: { [] },
            moveToTrash: { url in
                try FileManager.default.moveItem(at: url, to: URL(fileURLWithPath: trash + "/" + url.lastPathComponent))
            }
        )
    }

    private func item(_ home: Home, _ relative: String) throws -> TrashItem {
        var info = stat()
        #expect(lstat(home.path(relative), &info) == 0)
        return TrashItem(path: home.path(relative), fileID: info.st_ino, allocated: 1, kind: .file)
    }

    @Test("Con la copia da tenere al suo posto, l'altra si sposta")
    func normal() async throws {
        let home = try Home()
        try home.write(random(1_000), to: "Documents/a")
        try home.write(random(1_000), to: "Documents/b")

        let report = await try mover(home).run(
            title: "Duplicati",
            items: [try item(home, "Documents/a")],
            mustRemain: [try item(home, "Documents/b")]
        )

        #expect(report.removedItemCount == 1)
        #expect(FileManager.default.fileExists(atPath: home.path("Documents/b")))
    }

    @Test("Se la copia da tenere è sparita, non si sposta nulla")
    func keeperGone() async throws {
        let home = try Home()
        try home.write(random(1_000), to: "Documents/a")
        try home.write(random(1_000), to: "Documents/b")
        let toMove = try item(home, "Documents/a")
        let toKeep = try item(home, "Documents/b")
        try FileManager.default.removeItem(atPath: home.path("Documents/b"))

        let report = await try mover(home).run(title: "Duplicati", items: [toMove], mustRemain: [toKeep])

        #expect(FileManager.default.fileExists(atPath: home.path("Documents/a")))
        #expect(report.removedItemCount == 0)
        #expect(report.rules[0].issues.first?.problem == .copyToKeepChanged)
    }

    @Test("Se la copia da tenere è stata sostituita, non si sposta nulla")
    func keeperReplaced() async throws {
        let home = try Home()
        try home.write(random(1_000), to: "Documents/a")
        try home.write(random(1_000), to: "Documents/b")
        let toMove = try item(home, "Documents/a")
        let toKeep = try item(home, "Documents/b")
        try home.write(random(1_000), to: "Documents/segnaposto")
        try FileManager.default.removeItem(atPath: home.path("Documents/b"))
        try home.write(random(1_000), to: "Documents/b")
        try FileManager.default.removeItem(atPath: home.path("Documents/segnaposto"))

        let report = await try mover(home).run(title: "Duplicati", items: [toMove], mustRemain: [toKeep])

        #expect(report.removedItemCount == 0)
        #expect(report.rules[0].issues.first?.problem == .copyToKeepChanged)
    }

    @Test("Lo stesso file non può essere da spostare e da tenere")
    func sameFileInBoth() async throws {
        let home = try Home()
        try home.write(random(1_000), to: "Documents/a")
        let file = try item(home, "Documents/a")

        let report = await try mover(home).run(title: "Duplicati", items: [file], mustRemain: [file])

        #expect(FileManager.default.fileExists(atPath: home.path("Documents/a")))
        #expect(report.removedItemCount == 0)
    }
}

@Suite("Automazione")
struct AutomationTests {
    private func candidate(_ level: RiskLevel, command: Bool = false, id: String) -> CleanupCandidate {
        let rule = CleaningRule(
            id: id, title: "t", explanation: "e", level: level,
            roots: command ? ["~/Library/Developer/CoreSimulator/Devices"] : ["~/Library/Caches/X"],
            command: command ? CleanupCommand(executable: "/usr/bin/xcrun", arguments: ["simctl", "delete", "unavailable"]) : nil
        )
        return CleanupCandidate(rule: rule, roots: [], commandEstimate: command ? 1 : nil)
    }

    @Test("Le impostazioni di partenza non eliminano nulla")
    func defaults() {
        let settings = AutomationSettings()

        #expect(!settings.cleansOnSchedule)
        #expect(!settings.warnsOnLowSpace)
    }

    @Test("Un file di impostazioni assente o danneggiato non attiva nulla")
    func damagedSettings() throws {
        let home = try FakeHome()
        let url = URL(fileURLWithPath: home.at("impostazioni.json"))

        #expect(!AutomationSettings.load(from: url).cleansOnSchedule)
        try Data("{ non valido".utf8).write(to: url)
        #expect(!AutomationSettings.load(from: url).cleansOnSchedule)
    }

    @Test("Le impostazioni si salvano e si rileggono")
    func roundTrip() throws {
        let home = try FakeHome()
        let url = URL(fileURLWithPath: home.at("sotto/impostazioni.json"))
        var settings = AutomationSettings()
        settings.cleansOnSchedule = true
        settings.interval = .monthly
        settings.lowSpaceThresholdGB = 35

        try settings.save(to: url)

        #expect(AutomationSettings.load(from: url) == settings)
    }

    @Test("Solo le voci sicure che eliminano file possono partire da sole")
    func eligible() {
        let found = ScheduledCleanup.eligible([
            candidate(.safe, id: "sicura"),
            candidate(.review, id: "da-valutare"),
            candidate(.safe, command: true, id: "comando-sicuro"),
            candidate(.review, command: true, id: "comando"),
        ])

        #expect(found.map(\.id) == ["sicura"])
    }

    @Test("Nel catalogo vero le voci automatiche non comprendono simulatori e cache dei browser")
    func eligibleInRealCatalog() throws {
        let rules = try RuleCatalog.builtIn().rules
        let candidates = rules.map { CleanupCandidate(rule: $0, roots: [], commandEstimate: $0.command == nil ? nil : 1) }

        let ids = Set(ScheduledCleanup.eligible(candidates).map(\.id))

        #expect(ids == ["homebrew.cache", "pip.cache", "npm.cache", "logs.old"])
    }

    @Test("La pulizia non è mai dovuta se è spenta")
    func notDueWhenOff() {
        var settings = AutomationSettings()
        settings.lastScheduledCleanup = .distantPast
        settings.scheduleEnabledAt = .distantPast

        #expect(!ScheduledCleanup.isDue(settings: settings, now: .now))
    }

    @Test("Attivarla non elimina subito: la prima aspetta un intervallo intero")
    func firstRunWaits() {
        var settings = AutomationSettings()
        let enabled = Date(timeIntervalSince1970: 1_000_000)
        settings.setCleansOnSchedule(true, now: enabled)

        #expect(!ScheduledCleanup.isDue(settings: settings, now: enabled))
        #expect(!ScheduledCleanup.isDue(settings: settings, now: enabled.addingTimeInterval(6 * 86_400)))
        #expect(ScheduledCleanup.isDue(settings: settings, now: enabled.addingTimeInterval(7 * 86_400)))
    }

    @Test("Riaprire l'app non fa ripartire il conto dell'intervallo")
    func intervalSurvivesRelaunch() throws {
        let home = try FakeHome()
        let url = URL(fileURLWithPath: home.at("impostazioni.json"))
        var settings = AutomationSettings()
        let enabled = Date(timeIntervalSince1970: 1_000_000)
        settings.setCleansOnSchedule(true, now: enabled)
        try settings.save(to: url)

        let reopened = AutomationSettings.load(from: url)

        #expect(ScheduledCleanup.isDue(settings: reopened, now: enabled.addingTimeInterval(8 * 86_400)))
    }

    @Test("Spegnerla e riaccenderla fa ripartire l'attesa intera")
    func reEnableWaitsAgain() {
        var settings = AutomationSettings()
        let start = Date(timeIntervalSince1970: 1_000_000)
        settings.setCleansOnSchedule(true, now: start)
        settings.lastScheduledCleanup = start
        settings.setCleansOnSchedule(false, now: start)
        let later = start.addingTimeInterval(30 * 86_400)
        settings.setCleansOnSchedule(true, now: later)

        #expect(!ScheduledCleanup.isDue(settings: settings, now: later))
        #expect(ScheduledCleanup.isDue(settings: settings, now: later.addingTimeInterval(7 * 86_400)))
    }

    @Test("Senza un riferimento nel tempo non parte")
    func noReference() {
        var settings = AutomationSettings()
        settings.cleansOnSchedule = true

        #expect(!ScheduledCleanup.isDue(settings: settings, now: .now))
    }

    @Test("La frequenza decide quando ripartire", arguments: [
        (AutomationSettings.Interval.weekly, 8.0, true),
        (AutomationSettings.Interval.weekly, 6.0, false),
        (AutomationSettings.Interval.monthly, 8.0, false),
        (AutomationSettings.Interval.monthly, 31.0, true),
    ])
    func interval(interval: AutomationSettings.Interval, days: Double, expected: Bool) {
        var settings = AutomationSettings()
        settings.cleansOnSchedule = true
        settings.interval = interval
        let last = Date(timeIntervalSince1970: 1_000_000)
        settings.lastScheduledCleanup = last

        #expect(ScheduledCleanup.isDue(settings: settings, now: last.addingTimeInterval(days * 86_400)) == expected)
    }

    @Test("L'avviso arriva una volta, e di nuovo solo dopo un recupero")
    func spaceWatch() {
        var watch = SpaceWatch(threshold: 100)

        let warnings = [200, 90, 80, 105, 95, 120, 90].map { watch.shouldWarn(free: Int64($0)) }

        // Sale a 105: sopra la soglia ma entro il margine, quindi a 95 non riavvisa.
        #expect(warnings == [false, true, false, false, false, false, true])
    }

    @Test("Il riconoscimento dello spazio basso segue la soglia")
    func isLow() {
        let watch = SpaceWatch(threshold: 100)

        #expect(watch.isLow(free: 99))
        #expect(!watch.isLow(free: 100))
    }
}
