import CoreGraphics
import Foundation
import Testing
@testable import ScanKit

private func scan(_ fixture: Fixture) async throws -> FileTree {
    try await FileScanner().scan(root: fixture.root).tree
}

@Suite("Interrogazioni sull'albero")
struct TreeQueriesTests {
    @Test("Un percorso relativo trova il nodo giusto")
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

    @Test("Le cartelle più grandi saltano quelle che contengono solo un'altra cartella")
    func largestDirectories() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("involucro/dentro/grande")
        try fixture.makeDirectory("involucro/dentro/media")
        try fixture.makeDirectory("piccola")
        try fixture.makeFile("involucro/dentro/grande/f", size: 3_000_000)
        try fixture.makeFile("involucro/dentro/media/f", size: 1_000_000)
        try fixture.makeFile("piccola/f", size: 200_000)

        let tree = try await scan(fixture)
        let paths = tree.largestDirectories(limit: 3).map(tree.path(of:))

        #expect(paths == [
            fixture.path("involucro/dentro"),
            fixture.path("involucro/dentro/grande"),
            fixture.path("involucro/dentro/media"),
        ])
    }

    @Test("Le cartelle illeggibili si contano per sottoalbero")
    func unreadableCount() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("sotto/chiusa")
        try fixture.makeDirectory("altra/chiusa")
        #expect(chmod(fixture.path("sotto/chiusa"), 0) == 0)
        #expect(chmod(fixture.path("altra/chiusa"), 0) == 0)
        defer {
            chmod(fixture.path("sotto/chiusa"), 0o755)
            chmod(fixture.path("altra/chiusa"), 0o755)
        }

        let tree = try await scan(fixture)
        let under = try #require(tree.node(atRelativePath: "sotto"))

        #expect(tree.unreadableDirectoryCount(under: under) == 1)
        #expect(tree.unreadableDirectoryCount(under: tree.root) == 2)
    }

    @Test("Le categorie non si sovrappongono e sommano alla capacità")
    func breakdown() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("Applications")
        try fixture.makeDirectory("Users/io/Library/Caches")
        try fixture.makeDirectory("Users/io/Library/Developer")
        try fixture.makeDirectory("Users/io/Library/Application Support/MobileSync")
        try fixture.makeDirectory("Users/io/Library/Application Support/App")
        try fixture.makeDirectory("Users/io/Pictures")
        try fixture.makeDirectory("Users/io/Documents")
        try fixture.makeDirectory("private")
        try fixture.makeFile("Applications/f", size: 100_000)
        try fixture.makeFile("Users/io/Library/Caches/f", size: 200_000)
        try fixture.makeFile("Users/io/Library/Developer/f", size: 300_000)
        try fixture.makeFile("Users/io/Library/Application Support/MobileSync/f", size: 400_000)
        try fixture.makeFile("Users/io/Library/Application Support/App/f", size: 500_000)
        try fixture.makeFile("Users/io/Pictures/f", size: 600_000)
        try fixture.makeFile("Users/io/Documents/f", size: 700_000)
        try fixture.makeFile("private/f", size: 800_000)

        let tree = try await scan(fixture)
        let measured = tree.sizes(of: tree.root).allocated
        let result = StorageBreakdown(
            tree: tree,
            homePath: "Users/io",
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
        #expect(bytes(.caches) == (try allocated("Users/io/Library/Caches")))
        #expect(bytes(.iPhoneBackups) == (try allocated("Users/io/Library/Application Support/MobileSync")))
        #expect(bytes(.appData) == (try allocated("Users/io/Library/Application Support/App")))
        #expect(bytes(.userFiles) == (try allocated("Users/io/Documents")))
        #expect(bytes(.systemData) == (try allocated("private")))
        #expect(bytes(.unattributed) == 1_000_000)
        #expect(bytes(.otherVolumes) == 2_000_000)
        #expect(result.entries.map(\.bytes).reduce(0, +) + result.free == result.total)
        #expect(result.entries.map(\.bytes) == result.entries.map(\.bytes).sorted(by: >))
    }
}

@Suite("Confronto fra scansioni")
struct SnapshotTests {
    private func snapshot(_ folders: [String: Int64], unreadable: Int = 0) -> ScanSnapshot {
        ScanSnapshot(date: .now, unreadableDirectories: unreadable, folders: folders)
    }

    @Test("Riporta la sottocartella che spiega la crescita, non i genitori")
    func reportsMostSpecificFolder() throws {
        let old = snapshot(["Users": 1_000_000_000, "Users/io": 1_000_000_000, "Users/io/Video": 100_000_000])
        let new = snapshot(["Users": 3_000_000_000, "Users/io": 3_000_000_000, "Users/io/Video": 2_100_000_000])

        let growth = try #require(new.growth(since: old))

        #expect(growth.map(\.path) == ["Users/io/Video"])
        #expect(growth[0].added == 2_000_000_000)
    }

    @Test("Una cartella nuova conta come crescita e quelle ridotte no")
    func newAndShrunkFolders() throws {
        let old = snapshot(["Ridotta": 900_000_000])
        let new = snapshot(["Ridotta": 100_000_000, "Nuova": 500_000_000])

        #expect(try #require(new.growth(since: old)).map(\.path) == ["Nuova"])
    }

    @Test("Le crescite piccole non compaiono")
    func smallGrowthIsIgnored() throws {
        let new = snapshot(["A": 150_000_000])
        let old = snapshot(["A": 100_000_000])

        #expect(try #require(new.growth(since: old)).isEmpty)
    }

    @Test("Con permessi diversi le scansioni non si confrontano")
    func permissionChange() {
        let old = snapshot(["A": 1_000_000_000], unreadable: 800)
        let new = snapshot(["A": 9_000_000_000], unreadable: 200)

        #expect(new.growth(since: old) == nil)
    }

    @Test("La fotografia registra le cartelle grandi con percorsi relativi")
    func capturesFromTree() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("grande/dentro")
        try fixture.makeDirectory("piccola")
        try fixture.makeFile("grande/dentro/f", size: 3_000_000)
        try fixture.makeFile("piccola/f", size: 10_000)

        let tree = try await FileScanner().scan(root: fixture.root).tree
        let result = ScanSnapshot(tree: tree, unreadableDirectories: 0, minimumBytes: 1_000_000)

        #expect(Set(result.folders.keys) == ["grande", "grande/dentro"])
    }
}

@Suite("Capacità del volume")
struct VolumeCapacityTests {
    @Test("Lo spazio del volume non comprende gli altri volumi del contenitore")
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

    @Test("Le aree sono proporzionali ai valori", arguments: [
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

    @Test("I rettangoli restano nei limiti e non si sovrappongono")
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

    @Test("I rettangoli non diventano sottili quando basta riorganizzarli")
    func reasonableAspectRatio() {
        let rects = Treemap.squarify([40, 30, 20, 10], in: CGRect(x: 0, y: 0, width: 400, height: 400))
        for rect in rects {
            #expect(max(rect.width / rect.height, rect.height / rect.width) < 3)
        }
    }

    @Test("Casi limite: nessun valore, somma nulla, area nulla")
    func edgeCases() {
        #expect(Treemap.squarify([], in: Self.bounds).isEmpty)
        #expect(Treemap.squarify([0, 0], in: Self.bounds).allSatisfy { $0.width * $0.height == 0 })
        #expect(Treemap.squarify([1], in: .zero).allSatisfy { $0.width * $0.height == 0 })
    }

    @Test("Le voci troppo piccole si raggruppano e i figli annidati stanno nel genitore")
    func cells() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("grande")
        try fixture.makeFile("grande/uno", size: 4_000_000)
        try fixture.makeFile("grande/due", size: 2_000_000)
        for index in 0..<50 {
            try fixture.makeFile("minuscolo\(index)", size: 4096)
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

    @Test("Una cartella con una sola sottocartella mostra il contenuto più interno")
    func dominantSubfolderIsExpanded() async throws {
        let fixture = try Fixture()
        try fixture.makeDirectory("Users/io")
        try fixture.makeFile("Users/io/uno", size: 3_000_000)
        try fixture.makeFile("Users/io/due", size: 1_000_000)

        let tree = try await scan(fixture)
        let cells = Treemap.cells(tree: tree, root: tree.root, size: CGSize(width: 400, height: 300))
        let nested = cells.filter { $0.depth == 1 }.compactMap(\.node).map(tree.name(of:))

        #expect(nested == ["uno", "due"])
    }

    @Test("Una cartella enorme produce poche celle")
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
