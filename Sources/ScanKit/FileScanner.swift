import Foundation
import Synchronization

public struct ScanOptions: Sendable {
    /// Worker threads that list directories.
    public var threadCount: Int
    /// Names skipped wherever they appear, such as cloud folders.
    public var excludedNames: Set<String>
    /// Runs before each folder is opened. Lets a test make a folder block, as one does
    /// while macOS waits for an answer to a permission prompt.
    var beforeOpeningFolder: (@Sendable (String) -> Void)?

    public init(threadCount: Int = ScanOptions.defaultThreadCount, excludedNames: Set<String> = []) {
        self.threadCount = max(1, threadCount)
        self.excludedNames = excludedNames
    }

    public static var defaultThreadCount: Int {
        min(4, ProcessInfo.processInfo.activeProcessorCount)
    }
}

public struct ScanIssue: Equatable, Sendable {
    public let path: String
    public let code: Int32

    public var message: String { String(cString: strerror(code)) }
}

public struct ScanStatistics: Sendable {
    static let maximumSamples = 20
    static let noParentRef = UInt64.max

    public var files = 0
    public var directories = 0
    public var symlinks = 0
    public var otherItems = 0
    public var hardLinkDuplicates = 0
    public var hardLinkDuplicateBytes: Int64 = 0
    public var datalessFiles = 0
    public var datalessDirectories = 0
    public var unreadableDirectories = 0
    public var mountPoints = 0
    public var excludedItems = 0
    /// Failures by `errno`.
    public var errorCounts: [Int32: Int] = [:]
    /// The first failures met, for diagnosis. `errorCounts` has the totals.
    public var errorSamples: [ScanIssue] = []
}

public struct ScanResult: Sendable {
    public let tree: FileTree
    public let statistics: ScanStatistics
    public let duration: Duration
}

public struct ScanProgress: Equatable, Sendable {
    public let items: Int
    public let allocatedBytes: Int64
}

public enum ScanError: Error, Equatable {
    case rootUnavailable(path: String, code: Int32)
    case rootNotDirectory(path: String)
}

/// Measures a directory tree without changing it. Never crosses onto another volume
/// and never downloads cloud content.
///
/// Uses `getattrlistbulk` because it exposes file IDs and clone-aware private sizes,
/// which `FileManager` does not.
public final class FileScanner: Sendable {
    private let options: ScanOptions
    private let itemsSeen = Atomic<Int>(0)
    private let bytesSeen = Atomic<Int64>(0)
    private let cancelled = Atomic<Bool>(false)
    /// Ends a running scan's wait, so that cancelling works even if a thread is stuck.
    private let abandon = Mutex<(@Sendable () -> Void)?>(nil)

    public init(options: ScanOptions = ScanOptions()) {
        self.options = options
    }

    public var progress: ScanProgress {
        ScanProgress(items: itemsSeen.load(ordering: .relaxed), allocatedBytes: bytesSeen.load(ordering: .relaxed))
    }

    /// Returns from `scan` at once, even if a thread is blocked in the system waiting for
    /// something such as a permission prompt. That thread ends on its own when released.
    public func cancel() {
        cancelled.store(true, ordering: .relaxed)
        abandon.withLock { $0 }?()
    }

    public func scan(root: String) async throws -> ScanResult {
        let start = ContinuousClock.now

        guard let resolved = realpath(root, nil) else {
            throw ScanError.rootUnavailable(path: root, code: errno)
        }
        let rootPath = String(cString: resolved)
        free(resolved)

        var rootInfo = stat()
        guard lstat(rootPath, &rootInfo) == 0 else {
            throw ScanError.rootUnavailable(path: rootPath, code: errno)
        }
        guard rootInfo.st_mode & S_IFMT == S_IFDIR else {
            throw ScanError.rootNotDirectory(path: rootPath)
        }

        var seed = NodeBuffer()
        let rootRef = NodeRef(buffer: 0, position: 0)
        Array(rootPath.utf8).withUnsafeBufferPointer { name in
            _ = seed.append(
                parent: ScanStatistics.noParentRef,
                kind: .directory,
                flags: [],
                name: name,
                sizes: NodeSizes(logical: rootInfo.st_size, allocated: rootInfo.st_blocks * 512, privateBytes: 0),
                fileID: rootInfo.st_ino,
                modTime: Int64(rootInfo.st_mtimespec.tv_sec)
            )
        }

        let run = ScanRun(
            seed: seed,
            firstItem: WorkItem(path: Array(rootPath.utf8), ref: rootRef.rawValue),
            device: rootInfo.st_dev,
            excludedNames: Set(options.excludedNames.map { Array($0.utf8) }),
            threadCount: options.threadCount,
            beforeOpeningFolder: options.beforeOpeningFolder,
            scanner: self
        )

        let (tree, statistics): (FileTree, ScanStatistics) = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                let once = ResumeOnce(continuation)
                abandon.withLock { $0 = { once.resume(throwing: CancellationError()) } }
                if cancelled.load(ordering: .relaxed) {
                    once.resume(throwing: CancellationError())
                }
                run.start { [self] (buffers: inout [NodeBuffer]) in
                    if cancelled.load(ordering: .relaxed) {
                        once.resume(throwing: CancellationError())
                    } else {
                        once.resume(returning: TreeBuilder.build(buffers: &buffers, rootRef: rootRef))
                    }
                }
            }
        } onCancel: {
            cancel()
        }

        return ScanResult(tree: tree, statistics: statistics, duration: start.duration(to: .now))
    }

    fileprivate var isCancelled: Bool { cancelled.load(ordering: .relaxed) }

    fileprivate func report(items: Int, bytes: Int64) {
        itemsSeen.add(items, ordering: .relaxed)
        bytesSeen.add(bytes, ordering: .relaxed)
    }
}

/// Workers finishing and a cancellation can both try to end the wait. Only the first counts.
private final class ResumeOnce: Sendable {
    private let continuation: Mutex<CheckedContinuation<(FileTree, ScanStatistics), any Error>?>

    init(_ continuation: CheckedContinuation<(FileTree, ScanStatistics), any Error>) {
        self.continuation = Mutex(continuation)
    }

    func resume(returning value: sending (FileTree, ScanStatistics)) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(returning: value)
    }

    func resume(throwing error: any Error) {
        let pending = continuation.withLock { stored in
            defer { stored = nil }
            return stored
        }
        pending?.resume(throwing: error)
    }
}

private struct WorkItem: Sendable {
    let path: [UInt8]
    let ref: UInt64
}

/// State of one scan: a shared stack of directories to list, and the worker threads
/// that drain it. Workers are real threads because `getattrlistbulk` blocks, and a
/// blocking call would starve Swift's cooperative pool.
private final class ScanRun: @unchecked Sendable {
    private static let bufferSize = 256 * 1024

    private let condition = NSCondition()
    private var stack: [WorkItem]
    private var activeWorkers = 0
    private var buffers: [NodeBuffer]

    private let device: dev_t
    private let excludedNames: Set<[UInt8]>
    private let threadCount: Int
    private let beforeOpeningFolder: (@Sendable (String) -> Void)?
    private let scanner: FileScanner

    init(
        seed: NodeBuffer,
        firstItem: WorkItem,
        device: dev_t,
        excludedNames: Set<[UInt8]>,
        threadCount: Int,
        beforeOpeningFolder: (@Sendable (String) -> Void)?,
        scanner: FileScanner
    ) {
        stack = [firstItem]
        buffers = [seed] + Array(repeating: NodeBuffer(), count: threadCount)
        self.device = device
        self.excludedNames = excludedNames
        self.threadCount = threadCount
        self.beforeOpeningFolder = beforeOpeningFolder
        self.scanner = scanner
    }

    func start(completion: @escaping @Sendable (inout [NodeBuffer]) -> Void) {
        let group = DispatchGroup()
        for worker in 1...threadCount {
            group.enter()
            let thread = Thread { [self] in
                runWorker(bufferIndex: worker)
                group.leave()
            }
            thread.qualityOfService = .userInitiated
            thread.start()
        }
        group.notify(queue: .global(qos: .userInitiated)) { [self] in
            completion(&buffers)
        }
    }

    private func runWorker(bufferIndex: Int) {
        // Without this, listing a folder that lives only in the cloud would download it.
        setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES, IOPOL_SCOPE_THREAD, IOPOL_MATERIALIZE_DATALESS_FILES_OFF)

        let memory = UnsafeMutableRawPointer.allocate(byteCount: Self.bufferSize, alignment: 8)
        defer { memory.deallocate() }

        var nodes = NodeBuffer()
        var discovered: [WorkItem] = []
        while let item = nextItem() {
            discovered.removeAll(keepingCapacity: true)
            list(item, into: &nodes, discovered: &discovered, bufferIndex: bufferIndex, memory: memory)
            finish(discovered)
        }

        condition.lock()
        buffers[bufferIndex] = nodes
        condition.unlock()
    }

    private func nextItem() -> WorkItem? {
        condition.lock()
        defer { condition.unlock() }
        while true {
            if scanner.isCancelled {
                stack.removeAll()
            }
            if let item = stack.popLast() {
                activeWorkers += 1
                return item
            }
            if activeWorkers == 0 {
                condition.broadcast()
                return nil
            }
            condition.wait()
        }
    }

    private func finish(_ discovered: [WorkItem]) {
        condition.lock()
        stack.append(contentsOf: discovered)
        activeWorkers -= 1
        if !discovered.isEmpty || activeWorkers == 0 {
            condition.broadcast()
        }
        condition.unlock()
    }

    private func list(
        _ item: WorkItem,
        into nodes: inout NodeBuffer,
        discovered: inout [WorkItem],
        bufferIndex: Int,
        memory: UnsafeMutableRawPointer
    ) {
        if let beforeOpeningFolder {
            beforeOpeningFolder(String(decoding: item.path, as: UTF8.self))
        }
        let descriptor = Self.openDirectory(item.path)
        guard descriptor >= 0 else {
            markFailure(errno, item: item, nodes: &nodes)
            return
        }
        defer { close(descriptor) }

        // The mount status check below should catch every mount point before it is
        // opened. This guards against any that report differently.
        var info = stat()
        if fstat(descriptor, &info) == 0, info.st_dev != device {
            nodes.lateFlags.append((item.ref, NodeFlags.mountPoint.rawValue))
            return
        }

        var attributes = BulkRequest.attributeList
        var pendingItems = 0
        var pendingBytes: Int64 = 0

        while true {
            let returned = getattrlistbulk(descriptor, &attributes, memory, Self.bufferSize, BulkRequest.options)
            if returned < 0 {
                if errno == EINTR { continue }
                markFailure(errno, item: item, nodes: &nodes)
                break
            }
            if returned == 0 { break }

            var cursor = UnsafeRawPointer(memory)
            for _ in 0..<returned {
                let (entry, length) = BulkEntry.decode(at: cursor)
                cursor += length

                if entry.error != 0 {
                    nodes.recordError(Int32(entry.error), path: item.path + [UInt8(ascii: "/")] + Array(entry.name))
                    continue
                }
                record(entry, in: item, nodes: &nodes, discovered: &discovered, bufferIndex: bufferIndex)
                pendingItems += 1
                pendingBytes += entry.allocated
            }
        }
        scanner.report(items: pendingItems, bytes: pendingBytes)
    }

    @inline(__always)
    private func record(
        _ entry: BulkEntry,
        in item: WorkItem,
        nodes: inout NodeBuffer,
        discovered: inout [WorkItem],
        bufferIndex: Int
    ) {
        let kind = entry.kind
        var flags: NodeFlags = []
        var shouldEnter = kind == .directory

        if kind == .file, entry.linkCount > 1 {
            flags.insert(.multipleLinks)
        }
        if entry.flags & BulkRequest.fileIsDataless != 0 {
            flags.insert(.dataless)
            shouldEnter = false
        }
        if kind == .directory, entry.mountStatus & BulkRequest.directoryIsMountPoint != 0 {
            flags.insert(.mountPoint)
            shouldEnter = false
        }
        if !excludedNames.isEmpty, excludedNames.contains(Array(entry.name)) {
            flags.insert(.excluded)
            shouldEnter = false
        }

        // An excluded entry stays visible in the tree but weighs nothing, as with `du -I`.
        let sizes = flags.contains(.excluded)
            ? NodeSizes(logical: 0, allocated: 0, privateBytes: 0)
            : NodeSizes(logical: entry.logical, allocated: entry.allocated, privateBytes: entry.privateSize)

        let position = nodes.append(
            parent: item.ref,
            kind: kind,
            flags: flags,
            name: entry.name,
            sizes: sizes,
            fileID: entry.fileID,
            modTime: entry.modTime
        )

        if shouldEnter {
            var path = item.path
            path.reserveCapacity(path.count + entry.name.count + 1)
            if path.last != UInt8(ascii: "/") {
                path.append(UInt8(ascii: "/"))
            }
            path.append(contentsOf: entry.name)
            discovered.append(WorkItem(path: path, ref: NodeRef(buffer: bufferIndex, position: position).rawValue))
        }
    }

    private func markFailure(_ code: Int32, item: WorkItem, nodes: inout NodeBuffer) {
        if code == EDEADLK {
            // The kernel refused to download this folder, as requested.
            nodes.lateFlags.append((item.ref, NodeFlags.dataless.rawValue))
        } else {
            nodes.lateFlags.append((item.ref, NodeFlags.unreadable.rawValue))
            nodes.recordError(code, path: item.path)
        }
    }

    private static let openFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    private static func openDirectory(_ path: [UInt8]) -> Int32 {
        if path.count < PATH_MAX {
            let descriptor = (path + [0]).withUnsafeBufferPointer { bytes in
                bytes.withMemoryRebound(to: CChar.self) { open($0.baseAddress!, openFlags) }
            }
            return descriptor
        }
        return openDeepDirectory(path)
    }

    /// Paths beyond `PATH_MAX` cannot be opened in one call, so they are walked one
    /// component at a time.
    private static func openDeepDirectory(_ path: [UInt8]) -> Int32 {
        var current = open("/", openFlags)
        guard current >= 0 else { return -1 }
        for component in path.split(separator: UInt8(ascii: "/")) {
            let next = (Array(component) + [0]).withUnsafeBufferPointer { bytes in
                bytes.withMemoryRebound(to: CChar.self) { openat(current, $0.baseAddress!, openFlags) }
            }
            let failure = errno
            close(current)
            guard next >= 0 else {
                errno = failure
                return -1
            }
            current = next
        }
        return current
    }
}

public struct VolumeCapacity: Sendable {
    public let total: Int64
    public let available: Int64
    public let availableForImportantUsage: Int64
    public let availableForOpportunisticUsage: Int64
    /// Space used by this volume alone, as `df` reports it. It can't be derived from
    /// `total` and `available`, or from `statfs`, because those describe the whole APFS
    /// container that the volume shares with others.
    public let volumeUsed: Int64

    public init(path: String) throws {
        volumeUsed = try Self.spaceUsed(byVolumeAt: path)
        let values = try URL(fileURLWithPath: path).resourceValues(forKeys: [
            .volumeTotalCapacityKey,
            .volumeAvailableCapacityKey,
            .volumeAvailableCapacityForImportantUsageKey,
            .volumeAvailableCapacityForOpportunisticUsageKey,
        ])
        total = Int64(values.volumeTotalCapacity ?? 0)
        available = Int64(values.volumeAvailableCapacity ?? 0)
        availableForImportantUsage = values.volumeAvailableCapacityForImportantUsage ?? 0
        availableForOpportunisticUsage = values.volumeAvailableCapacityForOpportunisticUsage ?? 0
    }

    private static func spaceUsed(byVolumeAt path: String) throws -> Int64 {
        var list = attrlist()
        list.bitmapcount = 5
        list.volattr = 0x8000_0000 | 0x0080_0000 // ATTR_VOL_INFO | ATTR_VOL_SPACEUSED

        var buffer = (length: UInt32(0), used: Int64(0))
        let result = withUnsafeMutableBytes(of: &buffer) { bytes in
            getattrlist(path, &list, bytes.baseAddress!, bytes.count, 0)
        }
        guard result == 0 else {
            throw ScanError.rootUnavailable(path: path, code: errno)
        }
        return withUnsafeBytes(of: &buffer) { bytes in
            bytes.loadUnaligned(fromByteOffset: 4, as: Int64.self)
        }
    }
}
