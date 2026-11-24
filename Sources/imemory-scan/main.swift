import Foundation
import ScanKit

let usage = """
uso: imemory-scan [percorso] [opzioni]

Misura una cartella senza modificare nulla. Percorso predefinito: /System/Volumes/Data

  --threads N        thread di lettura (predefinito: \(ScanOptions.defaultThreadCount))
  --top N            cartelle più grandi da mostrare (predefinito: 15)
  --exclude-name X   salta le voci con questo nome (ripetibile)
  --du-depth N       stampa le cartelle fino a questa profondità, nel formato di `du -k`
  --help             mostra questo aiuto

"""

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("errore: \(message)\n\n\(usage)".utf8))
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
        fail("\(option) richiede un numero")
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
        guard let name = arguments.popFirst() else { fail("--exclude-name richiede un nome") }
        excludedNames.insert(name)
    case "--help", "-h":
        print(usage)
        exit(0)
    default:
        if argument.hasPrefix("-") { fail("opzione sconosciuta \(argument)") }
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

    log("Percorso      \(tree.path(of: tree.root))")
    log("Allocato      \(formatted(sizes.allocated))  (\(sizes.allocated) byte)")
    log("Logico        \(formatted(sizes.logical))")
    log("Privato       \(formatted(sizes.privateBytes))")
    log("Voci          \(tree.count) in \(String(format: "%.2f", elapsed)) s, \(Int(Double(tree.count) / max(elapsed, 0.001))) al secondo")
    log("  file \(statistics.files), cartelle \(statistics.directories), link simbolici \(statistics.symlinks), altro \(statistics.otherItems)")
    log("Hard link     \(statistics.hardLinkDuplicates) doppioni, \(formatted(statistics.hardLinkDuplicateBytes)) non contati due volte")
    log("Solo cloud    \(statistics.datalessFiles) file, \(statistics.datalessDirectories) cartelle, non scaricati")
    log("Esclusi       \(statistics.excludedItems), altri volumi \(statistics.mountPoints)")
    log("Non leggibili \(statistics.unreadableDirectories) cartelle")
    log("Memoria       albero \(formatted(Int64(tree.storageBytes))), picco processo \(formatted(peakMemoryBytes()))")

    if !statistics.errorCounts.isEmpty {
        log("Errori")
        for (code, count) in statistics.errorCounts.sorted(by: { $0.value > $1.value }) {
            log("  \(count) × \(String(cString: strerror(code))) (errno \(code))")
        }
        for sample in statistics.errorSamples.prefix(8) {
            log("  es. \(sample.path): \(sample.message)")
        }
    }
}

func printLargest(_ tree: FileTree, count: Int) {
    guard count > 0 else { return }
    print("\nCartelle più grandi")
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
    FileHandle.standardError.write(Data("errore: \(path): \(String(cString: strerror(code)))\n".utf8))
    exit(1)
} catch ScanError.rootNotDirectory(let path) {
    FileHandle.standardError.write(Data("errore: \(path) non è una cartella\n".utf8))
    exit(1)
}
