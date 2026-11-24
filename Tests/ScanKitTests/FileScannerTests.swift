import Foundation
import Synchronization
import Testing
@testable import ScanKit

/// A temporary folder removed at the end of the test. Uses `rm` because its
/// contents can be deeper than `PATH_MAX`.
final class Fixture {
    let root: String

    init() throws {
        let base = FileManager.default.temporaryDirectory.path + "/imemory-test-XXXXXX"
        var template = Array(base.utf8CString)
        guard mkdtemp(&template) != nil else { throw POSIXError(.EIO) }
        // `realpath` removes the /var symlink, so paths compare equal to the scanner's.
        let resolved = realpath(template, nil)!
        root = String(cString: resolved)
        free(resolved)
    }

    deinit {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/rm")
        process.arguments = ["-rf", root]
        try? process.run()
        process.waitUntilExit()
    }

    func path(_ relative: String) -> String { root + "/" + relative }

    func makeDirectory(_ relative: String) throws {
        try FileManager.default.createDirectory(atPath: path(relative), withIntermediateDirectories: true)
    }

    /// Writes random bytes, which APFS cannot compress, so sizes are predictable.
    func makeFile(_ relative: String, size: Int) throws {
        var bytes = [UInt8](repeating: 0, count: size)
        if size > 0 { arc4random_buf(&bytes, size) }
        guard FileManager.default.createFile(atPath: path(relative), contents: Data(bytes)) else {
            throw POSIXError(.EIO)
        }
    }

    func duKilobytes(_ relative: String = "") throws -> Int64 {
        let pipe = Pipe()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/du")
        process.arguments = ["-sk", relative.isEmpty ? root : path(relative)]
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        return Int64(text.split(separator: "\t").first ?? "") ?? -1
    }
}

extension FileTree {
    func node(at relative: String, under fixture: Fixture) -> NodeID? {
        let target = fixture.path(relative)
        return (0..<count).lazy.map { NodeID(index: UInt32($0)) }.first { path(of: $0) == target }
    }

    /// Every path with its allocated size, for comparing two scans.
    var snapshot: [String: Int64] {
        var result: [String: Int64] = [:]
        for index in 0..<count {
            let node = NodeID(index: UInt32(index))
            result[path(of: node)] = sizes(of: node).allocated
        }
        return result
    }
}

private func scan(_ fixture: Fixture, threads: Int = 4, excluded: Set<String> = []) async throws -> ScanResult {
    try await FileScanner(options: ScanOptions(threadCount: threads, excludedNames: excluded)).scan(root: fixture.root)
}

private func kilobytes(_ bytes: Int64) -> Int64 { (bytes + 1023) / 1024 }

@Suite("Scansione")
struct FileScannerTests {
    @Test("Il totale coincide con du su un albero misto")
    func matchesDu() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("a/b/c")
        try fixture.makeDirectory("vuota")
        try fixture.makeFile("zero", size: 0)
        try fixture.makeFile("piccolo", size: 1)
        try fixture.makeFile("a/quattro-kb", size: 4097)
        try fixture.makeFile("a/b/un-mega", size: 1_048_576)
        try fixture.makeFile("a/b/c/due-mega", size: 2_097_152)

        let result = try await scan(fixture)

        #expect(kilobytes(result.tree.sizes(of: result.tree.root).allocated) == (try fixture.duKilobytes()))
        #expect(result.statistics.files == 5)
        #expect(result.statistics.directories == 5) // radice, a, b, c, vuota
        #expect(result.statistics.errorCounts.isEmpty)
    }

    @Test("I totali delle cartelle sommano i figli")
    func aggregates() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("a/b")
        try fixture.makeFile("a/uno", size: 100_000)
        try fixture.makeFile("a/b/due", size: 200_000)

        let tree = try await scan(fixture).tree

        let a = try #require(tree.node(at: "a", under: fixture))
        let children = tree.children(of: a).map { tree.sizes(of: $0).allocated }.reduce(0, +)
        #expect(tree.sizes(of: a).allocated == children)
        #expect(tree.descendantCount(of: a) == 3)
        #expect(tree.descendantCount(of: tree.root) == 4)
    }

    @Test("I figli sono ordinati dal più grande, poi per nome")
    func childOrder() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("piccolo", size: 10_000)
        try fixture.makeFile("grande", size: 500_000)
        try fixture.makeFile("zzz-vuoto", size: 0)
        try fixture.makeFile("aaa-vuoto", size: 0)

        let tree = try await scan(fixture).tree

        #expect(tree.children(of: tree.root).map(tree.name(of:)) == ["grande", "piccolo", "aaa-vuoto", "zzz-vuoto"])
    }

    @Test("Un file con più hard link si conta una volta, come du")
    func hardLinks() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("x")
        try fixture.makeDirectory("y")
        try fixture.makeFile("x/originale", size: 1_000_000)
        try FileManager.default.linkItem(atPath: fixture.path("x/originale"), toPath: fixture.path("y/collegamento"))
        try FileManager.default.linkItem(atPath: fixture.path("x/originale"), toPath: fixture.path("secondo"))

        let result = try await scan(fixture)
        let tree = result.tree

        #expect(kilobytes(tree.sizes(of: tree.root).allocated) == (try fixture.duKilobytes()))
        #expect(result.statistics.hardLinkDuplicates == 2)

        // Il proprietario è il percorso minore: "secondo" viene prima di "x/originale".
        let owner = try #require(tree.node(at: "secondo", under: fixture))
        let duplicate = try #require(tree.node(at: "x/originale", under: fixture))
        #expect(tree.sizes(of: owner).allocated > 0)
        #expect(tree.sizes(of: duplicate).allocated == 0)
        #expect(tree.flags(of: duplicate).contains(.hardLinkDuplicate))
    }

    @Test("Il risultato non dipende dal numero di thread")
    func deterministic() async throws {
        let fixture = try Fixture()
        for index in 0..<40 {
            try fixture.makeDirectory("d\(index)/e")
            try fixture.makeFile("d\(index)/e/f", size: 5_000 + index)
        }
        try FileManager.default.linkItem(atPath: fixture.path("d3/e/f"), toPath: fixture.path("d30/link"))
        try FileManager.default.linkItem(atPath: fixture.path("d3/e/f"), toPath: fixture.path("d7/link"))

        let baseline = try await scan(fixture, threads: 1).tree.snapshot
        for threads in [2, 4, 8, 16] {
            #expect(try await scan(fixture, threads: threads).tree.snapshot == baseline)
        }
    }

    @Test("Un link simbolico non viene seguito")
    func symlinks() async throws {
        let outside = try Fixture()
        try outside.makeFile("enorme", size: 5_000_000)

        let fixture = try Fixture()
        try fixture.makeFile("vero", size: 10_000)
        try FileManager.default.createSymbolicLink(atPath: fixture.path("fuori"), withDestinationPath: outside.root)

        let result = try await scan(fixture)
        let tree = result.tree

        #expect(result.statistics.symlinks == 1)
        #expect(tree.sizes(of: tree.root).allocated < 1_000_000)
        #expect(kilobytes(tree.sizes(of: tree.root).allocated) == (try fixture.duKilobytes()))
        #expect(tree.node(at: "fuori/enorme", under: fixture) == nil)
    }

    @Test("Un file sparso ha più dimensione logica che allocata")
    func sparseFile() async throws {
        let fixture = try Fixture()
        let descriptor = open(fixture.path("sparso"), O_CREAT | O_WRONLY, 0o644)
        try #require(descriptor >= 0)
        #expect(ftruncate(descriptor, 100_000_000) == 0)
        close(descriptor)

        let tree = try await scan(fixture).tree
        let node = try #require(tree.node(at: "sparso", under: fixture))

        #expect(tree.sizes(of: node).logical == 100_000_000)
        #expect(tree.sizes(of: node).allocated < 1_000_000)
        #expect(kilobytes(tree.sizes(of: tree.root).allocated) == (try fixture.duKilobytes()))
    }

    @Test("Un clone APFS risulta condiviso, non privato")
    func clones() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("originale", size: 1_000_000)
        #expect(clonefile(fixture.path("originale"), fixture.path("clone"), 0) == 0)
        try fixture.makeFile("normale", size: 1_000_000)

        let tree = try await scan(fixture).tree
        let clone = try #require(tree.node(at: "clone", under: fixture))
        let normal = try #require(tree.node(at: "normale", under: fixture))

        #expect(tree.sizes(of: clone).allocated >= 1_000_000)
        #expect(tree.sizes(of: clone).privateBytes == 0)
        #expect(tree.sizes(of: normal).privateBytes == tree.sizes(of: normal).allocated)
    }

    @Test("Una cartella illeggibile è segnalata e la scansione continua")
    func unreadableDirectory() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("chiusa")
        try fixture.makeFile("chiusa/segreto", size: 10_000)
        try fixture.makeFile("aperto", size: 10_000)
        #expect(chmod(fixture.path("chiusa"), 0) == 0)
        defer { chmod(fixture.path("chiusa"), 0o755) }

        let result = try await scan(fixture)
        let tree = result.tree
        let closed = try #require(tree.node(at: "chiusa", under: fixture))

        #expect(tree.flags(of: closed).contains(.unreadable))
        #expect(result.statistics.unreadableDirectories == 1)
        #expect(result.statistics.errorCounts[EACCES] == 1)
        #expect(tree.node(at: "aperto", under: fixture) != nil)
    }

    @Test("La data di modifica e l'identificativo sono letti correttamente")
    func metadata() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("datato", size: 100)
        var times = [
            timeval(tv_sec: 1_000_000_000, tv_usec: 0),
            timeval(tv_sec: 1_100_000_000, tv_usec: 0),
        ]
        #expect(utimes(fixture.path("datato"), &times) == 0)
        var info = stat()
        #expect(stat(fixture.path("datato"), &info) == 0)

        let tree = try await scan(fixture).tree
        let node = try #require(tree.node(at: "datato", under: fixture))

        #expect(tree.modificationDate(of: node).timeIntervalSince1970 == 1_100_000_000)
        #expect(tree.fileID(of: node) == info.st_ino)
    }

    @Test("I nomi con caratteri non ASCII restano intatti")
    func unicodeNames() async throws {
        let fixture = try Fixture()
        let names = ["perché è così", "日本語のファイル", "con spazi e 'apici'", "riga\nnuova", String(repeating: "à", count: 120)]
        for name in names {
            try fixture.makeFile(name, size: 10)
        }

        let tree = try await scan(fixture).tree
        let found = tree.children(of: tree.root).map(tree.path(of:))

        for path in found {
            #expect(FileManager.default.fileExists(atPath: path))
        }
        #expect(found.count == names.count)
    }

    @Test("I percorsi oltre PATH_MAX vengono letti")
    func deepPaths() async throws {
        let fixture = try Fixture()
        let component = String(repeating: "p", count: 200)
        var descriptor = open(fixture.root, O_RDONLY | O_DIRECTORY)
        try #require(descriptor >= 0)
        for _ in 0..<30 { // Circa 6000 byte, ben oltre i 1024 di PATH_MAX.
            #expect(mkdirat(descriptor, component, 0o755) == 0)
            let next = openat(descriptor, component, O_RDONLY | O_DIRECTORY)
            close(descriptor)
            try #require(next >= 0)
            descriptor = next
        }
        let file = openat(descriptor, "in-fondo", O_CREAT | O_WRONLY, 0o644)
        try #require(file >= 0)
        var bytes = [UInt8](repeating: 0, count: 50_000)
        arc4random_buf(&bytes, bytes.count)
        #expect(write(file, bytes, bytes.count) == bytes.count)
        var info = stat()
        #expect(fstat(file, &info) == 0)
        close(file)
        close(descriptor)

        let result = try await scan(fixture)

        #expect(result.statistics.errorCounts.isEmpty)
        #expect(result.statistics.directories == 31)
        #expect(result.statistics.files == 1)
        // Il riferimento è stat e non du, che qui si ferma con "File name too long" e riporta 0.
        #expect(result.tree.sizes(of: result.tree.root).allocated == info.st_blocks * 512)
    }

    @Test("Le voci escluse non vengono visitate né conteggiate")
    func exclusions() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("tieni")
        try fixture.makeDirectory("tieni/Nuvola/dentro")
        try fixture.makeFile("tieni/Nuvola/dentro/grande", size: 1_000_000)
        try fixture.makeFile("tieni/piccolo", size: 1_000)

        let result = try await scan(fixture, excluded: ["Nuvola"])
        let tree = result.tree

        #expect(result.statistics.excludedItems == 1)
        #expect(tree.sizes(of: tree.root).allocated < 1_000_000)
        #expect(tree.node(at: "tieni/Nuvola/dentro", under: fixture) == nil)
        let excluded = try #require(tree.node(at: "tieni/Nuvola", under: fixture))
        #expect(tree.flags(of: excluded).contains(.excluded))
    }

    @Test("Una radice non valida produce un errore chiaro")
    func invalidRoots() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("file", size: 10)

        await #expect(throws: ScanError.rootNotDirectory(path: fixture.path("file"))) {
            try await FileScanner().scan(root: fixture.path("file"))
        }
        await #expect(throws: ScanError.rootUnavailable(path: fixture.path("assente"), code: ENOENT)) {
            try await FileScanner().scan(root: fixture.path("assente"))
        }
    }

    @Test("L'annullamento interrompe la scansione")
    func cancellation() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("file", size: 10)
        let scanner = FileScanner()
        scanner.cancel()

        await #expect(throws: CancellationError.self) {
            try await scanner.scan(root: fixture.root)
        }
    }

    @Test("L'annullamento funziona anche con una cartella bloccata")
    func cancellationWhileBlocked() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("bloccata")
        try fixture.makeFile("bloccata/f", size: 10)

        // Come open() mentre macOS aspetta la risposta a una richiesta di permesso.
        let release = DispatchSemaphore(value: 0)
        let reached = Mutex(false)
        var options = ScanOptions(threadCount: 2)
        options.beforeOpeningFolder = { path in
            if path.hasSuffix("/bloccata") {
                reached.withLock { $0 = true }
                release.wait()
            }
        }
        let scanner = FileScanner(options: options)
        defer { release.signal() }

        let scan = Task { try await scanner.scan(root: fixture.root) }
        while !reached.withLock({ $0 }) {
            try await Task.sleep(for: .milliseconds(5))
        }

        let start = ContinuousClock.now
        scanner.cancel()
        await #expect(throws: CancellationError.self) { try await scan.value }
        #expect(start.duration(to: .now) < .seconds(2))
    }

    @Test("Annullare due volte, o a scansione finita, non crea problemi")
    func repeatedCancellation() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("f", size: 10)
        let scanner = FileScanner()

        _ = try await scanner.scan(root: fixture.root)
        scanner.cancel()
        scanner.cancel()
    }

    @Test("L'avanzamento riflette le voci trovate")
    func progress() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("a")
        try fixture.makeFile("a/f", size: 100_000)
        let scanner = FileScanner()

        let result = try await scanner.scan(root: fixture.root)

        #expect(scanner.progress.items == result.tree.count - 1)
        #expect(scanner.progress.allocatedBytes >= 100_000)
    }
}
