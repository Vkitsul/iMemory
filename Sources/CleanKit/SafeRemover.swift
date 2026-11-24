import Darwin

/// Why something in a plan was not removed.
public enum RemovalProblem: Error, Codable, Sendable, Equatable {
    /// The path has `..`, is absolute, or otherwise points outside its root.
    case outsideRoot
    /// Part of the path is a symbolic link where a folder was expected.
    case symbolicLinkInPath
    /// The file is no longer the one that was scanned.
    case changedSinceScan
    /// A different volume is mounted here.
    case otherVolume
    /// The system refused, with this `errno`.
    case system(code: Int32)
    /// A command ended with this status, or `nil` if it failed to start or timed out.
    case commandFailed(status: Int32?, output: String)
    /// The system wouldn't move this to the Trash.
    case trashFailed(message: String)
    /// The copy meant to stay is gone or different, so nothing moved.
    case copyToKeepChanged
}

struct RemovalOutcome {
    var freedBytes: Int64 = 0
    var problems: [(path: String, problem: RemovalProblem)] = []
}

/// Removes files using descriptors, never full paths.
///
/// Every step opens one path component relative to a folder already held open, and
/// refuses to follow links. So a symbolic link planted anywhere, even while the removal
/// is running, can't redirect it outside the folder it started in. Only the entry names
/// themselves are ever unlinked, so a link's target is never touched.
enum SafeRemover {
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC

    /// Walks an absolute path from `/` without following links.
    /// - Returns: A descriptor for the folder, which the caller closes.
    static func openDirectory(atAbsolutePath path: String) -> Result<Int32, RemovalProblem> {
        guard path.hasPrefix("/") else { return .failure(.outsideRoot) }
        let components = path.split(separator: "/")
        guard !components.contains(".."), !components.contains(".") else { return .failure(.outsideRoot) }

        var current = open("/", directoryFlags)
        guard current >= 0 else { return .failure(.system(code: errno)) }

        for component in components {
            let next = openat(current, String(component), directoryFlags)
            let code = errno
            close(current)
            guard next >= 0 else { return .failure(problem(forOpenError: code)) }
            current = next
        }
        return .success(current)
    }

    /// Removes one planned entry below an open root.
    static func removeItem(
        relativePath: String,
        expectedFileID: UInt64,
        rootDescriptor: Int32,
        rootPath: String,
        device: dev_t
    ) -> RemovalOutcome {
        var outcome = RemovalOutcome()
        let displayPath = rootPath + "/" + relativePath

        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        guard !relativePath.hasPrefix("/"), !components.isEmpty,
              components.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." })
        else {
            outcome.problems.append((displayPath, .outsideRoot))
            return outcome
        }

        // Keeps the folder holding the entry open while walking down to it.
        var parent = dup(rootDescriptor)
        guard parent >= 0 else {
            outcome.problems.append((displayPath, .system(code: errno)))
            return outcome
        }
        defer { close(parent) }

        for component in components.dropLast() {
            let next = openat(parent, component, directoryFlags)
            let code = errno
            guard next >= 0 else {
                // Gone since the scan means there is nothing left to do.
                if code != ENOENT {
                    outcome.problems.append((displayPath, problem(forOpenError: code)))
                }
                return outcome
            }
            close(parent)
            parent = next
        }

        let name = components[components.count - 1]
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno != ENOENT {
                outcome.problems.append((displayPath, .system(code: errno)))
            }
            return outcome
        }
        guard info.st_ino == expectedFileID else {
            outcome.problems.append((displayPath, .changedSinceScan))
            return outcome
        }

        removeEntry(name: name, parent: parent, path: displayPath, device: device, outcome: &outcome)
        return outcome
    }

    private static func removeEntry(
        name: String,
        parent: Int32,
        path: String,
        device: dev_t,
        outcome: inout RemovalOutcome
    ) {
        var info = stat()
        guard fstatat(parent, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno != ENOENT {
                outcome.problems.append((path, .system(code: errno)))
            }
            return
        }

        if info.st_mode & S_IFMT == S_IFDIR {
            guard info.st_dev == device else {
                outcome.problems.append((path, .otherVolume))
                return
            }
            let descriptor = openat(parent, name, directoryFlags)
            guard descriptor >= 0 else {
                outcome.problems.append((path, problem(forOpenError: errno)))
                return
            }
            // Checked again on the open folder: a volume can be mounted over the path,
            // and `fstatat` above may see what lies underneath it.
            var opened = stat()
            guard fstat(descriptor, &opened) == 0, opened.st_dev == device else {
                close(descriptor)
                outcome.problems.append((path, .otherVolume))
                return
            }

            for child in entryNames(in: descriptor) {
                removeEntry(name: child, parent: descriptor, path: path + "/" + child, device: device, outcome: &outcome)
            }
            close(descriptor)

            if unlinkat(parent, name, AT_REMOVEDIR) != 0, errno != ENOENT {
                // A folder still holding something that failed adds nothing to the report.
                if errno != ENOTEMPTY {
                    outcome.problems.append((path, .system(code: errno)))
                }
            }
        } else {
            guard unlinkat(parent, name, 0) == 0 else {
                if errno != ENOENT {
                    outcome.problems.append((path, .system(code: errno)))
                }
                return
            }
            // Removing one of several hard links frees nothing.
            if info.st_nlink <= 1 {
                outcome.freedBytes += Int64(info.st_blocks) * 512
            }
        }
    }

    /// Reads all names up front, because removing entries while reading can skip some.
    private static func entryNames(in descriptor: Int32) -> [String] {
        let copy = dup(descriptor)
        guard copy >= 0, let directory = fdopendir(copy) else { return [] }
        defer { closedir(directory) }

        var names: [String] = []
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) {
                    String(cString: $0)
                }
            }
            if name != "." && name != ".." {
                names.append(name)
            }
        }
        return names
    }

    private static func problem(forOpenError code: Int32) -> RemovalProblem {
        // Opening with O_NOFOLLOW | O_DIRECTORY reports a link as one of these.
        code == ELOOP || code == ENOTDIR ? .symbolicLinkInPath : .system(code: code)
    }
}
