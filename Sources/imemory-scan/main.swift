import Foundation
import ScanKit

let usage = """
usage: imemory-scan [path] [options]

Measures a folder without changing anything. Default path: /System/Volumes/Data

  --threads N        reading threads (default: \(ScanOptions.defaultThreadCount))
  --top N            largest folders to show (default: 15)
  --exclude-name X   skip entries with this name (repeatable)
  --du-depth N       print folders down to this depth, in the format of `du -k`
  --help             show this help

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n\n\(usage)".utf8))
    exit(2)
}

var root = "/System/Volumes/Data"
var threadCount = ScanOptions.defaultThreadCount
var topCount = 15
var excludedNames: Set<String> = []
var duDepth: Int?

var arguments = Array(CommandLine.arguments.dropFirst())[...]

@MainActor
func integerValue(for option: String) -> Int {
    guard let raw = arguments.popFirst(), let value = Int(raw), value >= 0 else {
        fail("\(option) needs a number")
    }
    return value
}

while let argument = arguments.popFirst() {
    switch argument {
    case "--threads":
        threadCount = integerValue(for: argument)
    case "--top":
        topCount = integerValue(for: argument)
    case "--du-depth":
        duDepth = integerValue(for: argument)
    case "--exclude-name":
        guard let name = arguments.popFirst() else { fail("--exclude-name needs a name") }
        excludedNames.insert(name)
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        if argument.hasPrefix("-") { fail("unknown option \(argument)") }
        root = argument
    }
}

func formatted(_ bytes: Int64) -> String {
    let units: [(Double, String)] = [(1e12, "TB"), (1e9, "GB"), (1e6, "MB"), (1e3, "KB")]
    let value = Double(bytes)
    for (scale, unit) in units where abs(value) >= scale {
        return String(format: "%.2f %@", value / scale, unit).replacingOccurrences(of: ".", with: ",")
    }
    return "\(bytes) B"
}

func seconds(_ duration: Duration) -> Double {
    let parts = duration.components
    return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
}

func peakMemoryBytes() -> Int64 {
    var usage = rusage()
    getrusage(RUSAGE_SELF, &usage)
    return Int64(usage.ru_maxrss)
}

/// Prints directories in `du -k` format: sizes in KiB rounded up, deepest first.
func printDuFormat(tree: FileTree, node: NodeID, depth: Int, maximumDepth: Int) {
    if depth < maximumDepth {
        for child in tree.children(of: node) where tree.kind(of: child) == .directory {
            printDuFormat(tree: tree, node: child, depth: depth + 1, maximumDepth: maximumDepth)
        }
    }
    let kibibytes = (tree.sizes(of: node).allocated + 1023) / 1024
    print("\(kibibytes)\t\(tree.path(of: node))")
}

func printSummary(_ result: ScanResult) {
    let tree = result.tree
    let statistics = result.statistics
    let sizes = tree.sizes(of: tree.root)
    let elapsed = seconds(result.duration)
    let log: (String) -> Void = { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }

    log("Path          \(tree.path(of: tree.root))")
    log("Allocated     \(formatted(sizes.allocated))  (\(sizes.allocated) bytes)")
    log("Logical       \(formatted(sizes.logical))")
    log("Private       \(formatted(sizes.privateBytes))")
    log("Entries       \(tree.count) in \(String(format: "%.2f", elapsed)) s, \(Int(Double(tree.count) / max(elapsed, 0.001))) per second")
    log("  files \(statistics.files), folders \(statistics.directories), symbolic links \(statistics.symlinks), other \(statistics.otherItems)")
    log("Hard links    \(statistics.hardLinkDuplicates) extra links, \(formatted(statistics.hardLinkDuplicateBytes)) not counted twice")
    log("Cloud only    \(statistics.datalessFiles) files, \(statistics.datalessDirectories) folders, not downloaded")
    log("Excluded      \(statistics.excludedItems), other volumes \(statistics.mountPoints)")
    log("Unreadable    \(statistics.unreadableDirectories) folders")
    log("Memory        tree \(formatted(Int64(tree.storageBytes))), process peak \(formatted(peakMemoryBytes()))")

    if !statistics.errorCounts.isEmpty {
        log("Errors")
        for (code, count) in statistics.errorCounts.sorted(by: { $0.value > $1.value }) {
            log("  \(count) × \(String(cString: strerror(code))) (errno \(code))")
        }
        for sample in statistics.errorSamples.prefix(8) {
            log("  e.g. \(sample.path): \(sample.message)")
        }
    }
}

func printLargest(_ tree: FileTree, count: Int) {
    guard count > 0 else { return }
    print("\nLargest folders")
    var frontier = [tree.root]
    var largest: [NodeID] = []
    // Opens the largest directory each time, so each line adds new information.
    while largest.count < count, let next = frontier.indices.max(by: {
        tree.sizes(of: frontier[$0]).allocated < tree.sizes(of: frontier[$1]).allocated
    }) {
        let node = frontier.remove(at: next)
        largest.append(node)
        frontier.append(contentsOf: tree.children(of: node).filter { tree.kind(of: $0) == .directory }.prefix(count))
    }
    for node in largest {
        let sizes = tree.sizes(of: node)
        let size = formatted(sizes.allocated).padding(toLength: 11, withPad: " ", startingAt: 0)
        print("\(size) \(tree.path(of: node))")
    }
}

let scanner = FileScanner(options: ScanOptions(threadCount: threadCount, excludedNames: excludedNames))

do {
    let result = try await scanner.scan(root: root)
    if let duDepth {
        printDuFormat(tree: result.tree, node: result.tree.root, depth: 0, maximumDepth: duDepth)
    } else {
        printLargest(result.tree, count: topCount)
    }
    printSummary(result)
} catch ScanError.rootUnavailable(let path, let code) {
    FileHandle.standardError.write(Data("error: \(path): \(String(cString: strerror(code)))\n".utf8))
    exit(1)
} catch ScanError.rootNotDirectory(let path) {
    FileHandle.standardError.write(Data("error: \(path) is not a folder\n".utf8))
    exit(1)
}
