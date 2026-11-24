import CoreGraphics
import Foundation
import Testing
@testable import ScanKit

private func scan(_ fixture: Fixture) async throws -> FileTree {
    try await FileScanner().scan(root: fixture.root).tree
}

@Suite("Tree queries")
struct TreeQueriesTests {
    @Test("A relative path finds the right node")
    func relativePaths() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("a/b c")
        try fixture.makeFile("a/b c/file", size: 100)

        let tree = try await scan(fixture)

        let found = try #require(tree.node(atRelativePath: "a/b c/file"))
        #expect(tree.path(of: found) == fixture.path("a/b c/file"))
        #expect(tree.node(atRelativePath: "") == tree.root)
        #expect(tree.node(atRelativePath: "a/assente") == nil)
    }

    @Test("Largest folders skip those holding only another folder")
    func largestDirectories() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("wrapper/inside/large")
        try fixture.makeDirectory("wrapper/inside/medium")
        try fixture.makeDirectory("little")
        try fixture.makeFile("wrapper/inside/large/f", size: 3_000_000)
        try fixture.makeFile("wrapper/inside/medium/f", size: 1_000_000)
        try fixture.makeFile("little/f", size: 200_000)

        let tree = try await scan(fixture)
        let paths = tree.largestDirectories(limit: 3).map(tree.path(of:))

        #expect(paths == [
            fixture.path("wrapper/inside"),
            fixture.path("wrapper/inside/large"),
            fixture.path("wrapper/inside/medium"),
        ])
    }

    @Test("Unreadable folders are counted per subtree")
    func unreadableCount() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("sub/locked")
        try fixture.makeDirectory("other/locked")
        #expect(chmod(fixture.path("sub/locked"), 0) == 0)
        #expect(chmod(fixture.path("other/locked"), 0) == 0)
        defer {
            chmod(fixture.path("sub/locked"), 0o755)
            chmod(fixture.path("other/locked"), 0o755)
        }

        let tree = try await scan(fixture)
        let under = try #require(tree.node(atRelativePath: "sub"))

        #expect(tree.unreadableDirectoryCount(under: under) == 1)
        #expect(tree.unreadableDirectoryCount(under: tree.root) == 2)
    }

    @Test("Categories don't overlap and add up to the capacity")
    func breakdown() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("Applications")
        try fixture.makeDirectory("Users/me/Library/Caches")
        try fixture.makeDirectory("Users/me/Library/Developer")
        try fixture.makeDirectory("Users/me/Library/Application Support/MobileSync")
        try fixture.makeDirectory("Users/me/Library/Application Support/App")
        try fixture.makeDirectory("Users/me/Pictures")
        try fixture.makeDirectory("Users/me/Documents")
        try fixture.makeDirectory("private")
        try fixture.makeFile("Applications/f", size: 100_000)
        try fixture.makeFile("Users/me/Library/Caches/f", size: 200_000)
        try fixture.makeFile("Users/me/Library/Developer/f", size: 300_000)
        try fixture.makeFile("Users/me/Library/Application Support/MobileSync/f", size: 400_000)
        try fixture.makeFile("Users/me/Library/Application Support/App/f", size: 500_000)
        try fixture.makeFile("Users/me/Pictures/f", size: 600_000)
        try fixture.makeFile("Users/me/Documents/f", size: 700_000)
        try fixture.makeFile("private/f", size: 800_000)

        let tree = try await scan(fixture)
        let measured = tree.sizes(of: tree.root).allocated
        let result = StorageBreakdown(
            tree: tree,
            homePath: "Users/me",
            total: measured + 5_000_000,
            free: 2_000_000,
            volumeUsed: measured + 1_000_000
        )

        func bytes(_ kind: StorageBreakdown.Kind) -> Int64 {
            result.entries.first { $0.kind == kind }?.bytes ?? -1
        }
        func allocated(_ path: String) throws -> Int64 {
            tree.sizes(of: try #require(tree.node(atRelativePath: path))).allocated
        }

        #expect(bytes(.applications) == (try allocated("Applications")))
        #expect(bytes(.caches) == (try allocated("Users/me/Library/Caches")))
        #expect(bytes(.iPhoneBackups) == (try allocated("Users/me/Library/Application Support/MobileSync")))
        #expect(bytes(.appData) == (try allocated("Users/me/Library/Application Support/App")))
        #expect(bytes(.userFiles) == (try allocated("Users/me/Documents")))
        #expect(bytes(.systemData) == (try allocated("private")))
        #expect(bytes(.unattributed) == 1_000_000)
        #expect(bytes(.otherVolumes) == 2_000_000)
        #expect(result.entries.map(\.bytes).reduce(0, +) + result.free == result.total)
        #expect(result.entries.map(\.bytes) == result.entries.map(\.bytes).sorted(by: >))
    }
}

@Suite("Comparing scans")
struct SnapshotTests {
    private func snapshot(_ folders: [String: Int64], unreadable: Int = 0) -> ScanSnapshot {
        ScanSnapshot(date: .now, unreadableDirectories: unreadable, folders: folders)
    }

    @Test("Reports the subfolder that explains the growth, not its parents")
    func reportsMostSpecificFolder() throws {
        let old = snapshot(["Users": 1_000_000_000, "Users/me": 1_000_000_000, "Users/me/Video": 100_000_000])
        let new = snapshot(["Users": 3_000_000_000, "Users/me": 3_000_000_000, "Users/me/Video": 2_100_000_000])

        let growth = try #require(new.growth(since: old))

        #expect(growth.map(\.path) == ["Users/me/Video"])
        #expect(growth[0].added == 2_000_000_000)
    }

    @Test("A new folder counts as growth and shrunk ones don't")
    func newAndShrunkFolders() throws {
        let old = snapshot(["Shrunk": 900_000_000])
        let new = snapshot(["Shrunk": 100_000_000, "New": 500_000_000])

        #expect(try #require(new.growth(since: old)).map(\.path) == ["New"])
    }

    @Test("Small growth doesn't show")
    func smallGrowthIsIgnored() throws {
        let new = snapshot(["A": 150_000_000])
        let old = snapshot(["A": 100_000_000])

        #expect(try #require(new.growth(since: old)).isEmpty)
    }

    @Test("Scans with different permissions aren't compared")
    func permissionChange() {
        let old = snapshot(["A": 1_000_000_000], unreadable: 800)
        let new = snapshot(["A": 9_000_000_000], unreadable: 200)

        #expect(new.growth(since: old) == nil)
    }

    @Test("The snapshot records large folders with relative paths")
    func capturesFromTree() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("large/inside")
        try fixture.makeDirectory("little")
        try fixture.makeFile("large/inside/f", size: 3_000_000)
        try fixture.makeFile("little/f", size: 10_000)

        let tree = try await FileScanner().scan(root: fixture.root).tree
        let result = ScanSnapshot(tree: tree, unreadableDirectories: 0, minimumBytes: 1_000_000)

        #expect(Set(result.folders.keys) == ["large", "large/inside"])
    }
}

@Suite("Volume capacity")
struct VolumeCapacityTests {
    @Test("The volume's space excludes the container's other volumes")
    func usedExcludesOtherVolumes() throws {
        let capacity = try VolumeCapacity(path: "/System/Volumes/Data")
        let systemVolume = try VolumeCapacity(path: "/")

        #expect(capacity.volumeUsed > 0)
        #expect(systemVolume.volumeUsed > 0)
        // I volumi dello stesso contenitore si dividono lo spazio occupato.
        #expect(capacity.volumeUsed + systemVolume.volumeUsed <= capacity.total - capacity.available)
    }
}

@Suite("Treemap")
struct TreemapTests {
    private static let bounds = CGRect(x: 10, y: 20, width: 800, height: 500)

    @Test("Areas are proportional to the values", arguments: [
        [100],
        [60, 30, 10],
        [5, 5, 5, 5],
        [1_000_000, 1, 1, 1],
        Array(stride(from: 200, through: 1, by: -1)),
    ] as [[Double]])
    func proportionalAreas(values: [Double]) {
        let rects = Treemap.squarify(values, in: Self.bounds)
        let total = values.reduce(0, +)
        let fullArea = Double(Self.bounds.width * Self.bounds.height)

        #expect(rects.count == values.count)
        for (value, rect) in zip(values, rects) {
            let area = Double(rect.width * rect.height)
            #expect(abs(area - value / total * fullArea) < fullArea * 1e-6)
        }
    }

    @Test("Rectangles stay in bounds and don't overlap")
    func noOverlap() {
        let values = (1...60).reversed().map { Double($0 * $0) }
        let rects = Treemap.squarify(values, in: Self.bounds)
        let tolerance: CGFloat = 1e-6

        for rect in rects {
            #expect(rect.minX >= Self.bounds.minX - tolerance && rect.maxX <= Self.bounds.maxX + tolerance)
            #expect(rect.minY >= Self.bounds.minY - tolerance && rect.maxY <= Self.bounds.maxY + tolerance)
        }
        for (position, first) in rects.enumerated() {
            for second in rects[(position + 1)...] {
                let overlap = first.insetBy(dx: tolerance, dy: tolerance).intersection(second.insetBy(dx: tolerance, dy: tolerance))
                #expect(overlap.isNull || overlap.width * overlap.height < 1e-6)
            }
        }
    }

    @Test("Rectangles don't get thin when rearranging is enough")
    func reasonableAspectRatio() {
        let rects = Treemap.squarify([40, 30, 20, 10], in: CGRect(x: 0, y: 0, width: 400, height: 400))
        for rect in rects {
            #expect(max(rect.width / rect.height, rect.height / rect.width) < 3)
        }
    }

    @Test("Edge cases: no values, zero sum, zero area")
    func edgeCases() {
        #expect(Treemap.squarify([], in: Self.bounds).isEmpty)
        #expect(Treemap.squarify([0, 0], in: Self.bounds).allSatisfy { $0.width * $0.height == 0 })
        #expect(Treemap.squarify([1], in: .zero).allSatisfy { $0.width * $0.height == 0 })
    }

    @Test("Items too small are grouped and nested children stay inside their parent")
    func cells() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("large")
        try fixture.makeFile("large/one", size: 4_000_000)
        try fixture.makeFile("large/two", size: 2_000_000)
        for index in 0..<50 {
            try fixture.makeFile("tiny\(index)", size: 4096)
        }

        let tree = try await scan(fixture)
        let cells = Treemap.cells(tree: tree, root: tree.root, size: CGSize(width: 200, height: 150))

        let grouped = try #require(cells.first { $0.node == nil && $0.depth == 0 })
        #expect(grouped.groupedItems > 0)

        let parent = try #require(cells.first { $0.hasNestedCells })
        let nested = cells.filter { $0.depth == 1 }
        #expect(!nested.isEmpty)
        for cell in nested {
            #expect(parent.rect.insetBy(dx: -1e-6, dy: -1e-6).contains(cell.rect))
        }

        let parentIndex = try #require(cells.firstIndex(of: parent))
        let firstNested = try #require(cells.firstIndex { $0.depth == 1 })
        #expect(parentIndex < firstNested)
    }

    @Test("A folder with a single subfolder shows the innermost contents")
    func dominantSubfolderIsExpanded() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("Users/me")
        try fixture.makeFile("Users/me/one", size: 3_000_000)
        try fixture.makeFile("Users/me/two", size: 1_000_000)

        let tree = try await scan(fixture)
        let cells = Treemap.cells(tree: tree, root: tree.root, size: CGSize(width: 400, height: 300))
        let nested = cells.filter { $0.depth == 1 }.compactMap(\.node).map(tree.name(of:))

        #expect(nested == ["one", "two"])
    }

    @Test("A huge folder produces few cells")
    func cellCountIsBounded() async throws {
        let fixture = try Fixture()
        for index in 0..<2000 {
            try fixture.makeFile("f\(index)", size: 4096)
        }

        let tree = try await scan(fixture)
        let cells = Treemap.cells(tree: tree, root: tree.root, size: CGSize(width: 200, height: 100))

        #expect(cells.count <= 301)
    }
}
