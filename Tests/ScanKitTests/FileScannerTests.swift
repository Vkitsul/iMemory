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

@Suite("Scanning")
struct FileScannerTests {
    @Test("The total matches du on a mixed tree")
    func matchesDu() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("a/b/c")
        try fixture.makeDirectory("vuota")
        try fixture.makeFile("zero", size: 0)
        try fixture.makeFile("small", size: 1)
        try fixture.makeFile("a/quattro-kb", size: 4097)
        try fixture.makeFile("a/b/un-mega", size: 1_048_576)
        try fixture.makeFile("a/b/c/two-mega", size: 2_097_152)

        let result = try await scan(fixture)

        #expect(kilobytes(result.tree.sizes(of: result.tree.root).allocated) == (try fixture.duKilobytes()))
        #expect(result.statistics.files == 5)
        #expect(result.statistics.directories == 5) // radice, a, b, c, vuota
        #expect(result.statistics.errorCounts.isEmpty)
    }

    @Test("Folder totals add up their children")
    func aggregates() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("a/b")
        try fixture.makeFile("a/one", size: 100_000)
        try fixture.makeFile("a/b/two", size: 200_000)

        let tree = try await scan(fixture).tree

        let a = try #require(tree.node(at: "a", under: fixture))
        let children = tree.children(of: a).map { tree.sizes(of: $0).allocated }.reduce(0, +)
        #expect(tree.sizes(of: a).allocated == children)
        #expect(tree.descendantCount(of: a) == 3)
        #expect(tree.descendantCount(of: tree.root) == 4)
    }

    @Test("Children are sorted largest first, then by name")
    func childOrder() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("small", size: 10_000)
        try fixture.makeFile("large", size: 500_000)
        try fixture.makeFile("zzz-empty", size: 0)
        try fixture.makeFile("aaa-empty", size: 0)

        let tree = try await scan(fixture).tree

        #expect(tree.children(of: tree.root).map(tree.name(of:)) == ["large", "small", "aaa-empty", "zzz-empty"])
    }

    @Test("A file with several hard links counts once, as in du")
    func hardLinks() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("x")
        try fixture.makeDirectory("y")
        try fixture.makeFile("x/original", size: 1_000_000)
        try FileManager.default.linkItem(atPath: fixture.path("x/original"), toPath: fixture.path("y/link"))
        try FileManager.default.linkItem(atPath: fixture.path("x/original"), toPath: fixture.path("second"))

        let result = try await scan(fixture)
        let tree = result.tree

        #expect(kilobytes(tree.sizes(of: tree.root).allocated) == (try fixture.duKilobytes()))
        #expect(result.statistics.hardLinkDuplicates == 2)

        // The owner is the smallest path: "second" sorts before "x/original".
        let owner = try #require(tree.node(at: "second", under: fixture))
        let duplicate = try #require(tree.node(at: "x/original", under: fixture))
        #expect(tree.sizes(of: owner).allocated > 0)
        #expect(tree.sizes(of: duplicate).allocated == 0)
        #expect(tree.flags(of: duplicate).contains(.hardLinkDuplicate))
    }

    @Test("The result doesn't depend on the number of threads")
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

    @Test("A symbolic link isn't followed")
    func symlinks() async throws {
        let outside = try Fixture()
        try outside.makeFile("enorme", size: 5_000_000)

        let fixture = try Fixture()
        try fixture.makeFile("vero", size: 10_000)
        try FileManager.default.createSymbolicLink(atPath: fixture.path("outside"), withDestinationPath: outside.root)

        let result = try await scan(fixture)
        let tree = result.tree

        #expect(result.statistics.symlinks == 1)
        #expect(tree.sizes(of: tree.root).allocated < 1_000_000)
        #expect(kilobytes(tree.sizes(of: tree.root).allocated) == (try fixture.duKilobytes()))
        #expect(tree.node(at: "outside/enorme", under: fixture) == nil)
    }

    @Test("A sparse file has more logical than allocated size")
    func sparseFile() async throws {
        let fixture = try Fixture()
        let descriptor = open(fixture.path("sparse"), O_CREAT | O_WRONLY, 0o644)
        try #require(descriptor >= 0)
        #expect(ftruncate(descriptor, 100_000_000) == 0)
        close(descriptor)

        let tree = try await scan(fixture).tree
        let node = try #require(tree.node(at: "sparse", under: fixture))

        #expect(tree.sizes(of: node).logical == 100_000_000)
        #expect(tree.sizes(of: node).allocated < 1_000_000)
        #expect(kilobytes(tree.sizes(of: tree.root).allocated) == (try fixture.duKilobytes()))
    }

    @Test("An APFS clone shows as shared, not private")
    func clones() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("original", size: 1_000_000)
        #expect(clonefile(fixture.path("original"), fixture.path("clone"), 0) == 0)
        try fixture.makeFile("plain", size: 1_000_000)

        let tree = try await scan(fixture).tree
        let clone = try #require(tree.node(at: "clone", under: fixture))
        let normal = try #require(tree.node(at: "plain", under: fixture))

        #expect(tree.sizes(of: clone).allocated >= 1_000_000)
        #expect(tree.sizes(of: clone).privateBytes == 0)
        #expect(tree.sizes(of: normal).privateBytes == tree.sizes(of: normal).allocated)
    }

    @Test("An unreadable folder is reported and the scan goes on")
    func unreadableDirectory() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("locked")
        try fixture.makeFile("locked/secret", size: 10_000)
        try fixture.makeFile("open", size: 10_000)
        #expect(chmod(fixture.path("locked"), 0) == 0)
        defer { chmod(fixture.path("locked"), 0o755) }

        let result = try await scan(fixture)
        let tree = result.tree
        let closed = try #require(tree.node(at: "locked", under: fixture))

        #expect(tree.flags(of: closed).contains(.unreadable))
        #expect(result.statistics.unreadableDirectories == 1)
        #expect(result.statistics.errorCounts[EACCES] == 1)
        #expect(tree.node(at: "open", under: fixture) != nil)
    }

    @Test("The modification date and identifier are read correctly")
    func metadata() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("dated", size: 100)
        var times = [
            timeval(tv_sec: 1_000_000_000, tv_usec: 0),
            timeval(tv_sec: 1_100_000_000, tv_usec: 0),
        ]
        #expect(utimes(fixture.path("dated"), &times) == 0)
        var info = stat()
        #expect(stat(fixture.path("dated"), &info) == 0)

        let tree = try await scan(fixture).tree
        let node = try #require(tree.node(at: "dated", under: fixture))

        #expect(tree.modificationDate(of: node).timeIntervalSince1970 == 1_100_000_000)
        #expect(tree.fileID(of: node) == info.st_ino)
    }

    @Test("Names with non-ASCII characters stay intact")
    func unicodeNames() async throws {
        let fixture = try Fixture()
        let names = ["naïve café résumé", "日本語のファイル", "with spaces and 'quotes'", "line\nbreak", String(repeating: "à", count: 120)]
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

    @Test("Paths beyond PATH_MAX are read")
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
        let file = openat(descriptor, "at-the-bottom", O_CREAT | O_WRONLY, 0o644)
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
        // The reference is stat, not du, which stops here with "File name too long" and reports 0.
        #expect(result.tree.sizes(of: result.tree.root).allocated == info.st_blocks * 512)
    }

    @Test("Excluded entries are neither visited nor counted")
    func exclusions() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("keep")
        try fixture.makeDirectory("keep/Cloud/inside")
        try fixture.makeFile("keep/Cloud/inside/large", size: 1_000_000)
        try fixture.makeFile("keep/small", size: 1_000)

        let result = try await scan(fixture, excluded: ["Cloud"])
        let tree = result.tree

        #expect(result.statistics.excludedItems == 1)
        #expect(tree.sizes(of: tree.root).allocated < 1_000_000)
        #expect(tree.node(at: "keep/Cloud/inside", under: fixture) == nil)
        let excluded = try #require(tree.node(at: "keep/Cloud", under: fixture))
        #expect(tree.flags(of: excluded).contains(.excluded))
    }

    @Test("An invalid root gives a clear error")
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

    @Test("Cancelling stops the scan")
    func cancellation() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("file", size: 10)
        let scanner = FileScanner()
        scanner.cancel()

        await #expect(throws: CancellationError.self) {
            try await scanner.scan(root: fixture.root)
        }
    }

    @Test("Cancelling works even with a blocked folder")
    func cancellationWhileBlocked() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("blocked")
        try fixture.makeFile("blocked/f", size: 10)

        // Like open() while macOS waits for an answer to a permission request.
        let release = DispatchSemaphore(value: 0)
        let reached = Mutex(false)
        var options = ScanOptions(threadCount: 2)
        options.beforeOpeningFolder = { path in
            if path.hasSuffix("/blocked") {
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

    @Test("Cancelling twice, or after the scan ends, does no harm")
    func repeatedCancellation() async throws {
        let fixture = try Fixture()
        try fixture.makeFile("f", size: 10)
        let scanner = FileScanner()

        _ = try await scanner.scan(root: fixture.root)
        scanner.cancel()
        scanner.cancel()
    }

    @Test("Progress reflects the items found")
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
