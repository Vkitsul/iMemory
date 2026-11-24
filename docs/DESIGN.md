# iMemory: design document

A native macOS app that shows where disk space goes and helps free it without risk.

Status: every milestone, M0 to M5, is written and verified with automated tests and a scripted run of the app. It has not yet been used with a real mouse and keyboard, nor for a real cleanup.

Scope: a personal project for macOS 27, published as is. It isn't notarized or distributed as a binary.

## 1. What the measurements showed

The design comes from measuring a real Mac before writing any code. The exact figures depend on the machine, but three findings shaped the app:

1. **Emptying caches gives back little.** On the development machine, caches were under 2% of the used space, and most of them come back anyway. An app that only clears caches wouldn't solve the problem.
2. **The value is in understanding.** Most of the space sat in app data, photo libraries, device backups, and folders that need Full Disk Access to read, not in documents. So the main feature is exploring, with cleaning right beside it.
3. **The same folder has several sizes.** `/Applications` measured about 32 GB logical, 26 GB allocated, and 21 GB private. Showing the wrong figure means promising space that won't come back.

Other findings:

- **Full Disk Access matters.** Without it, hundreds of folders in the home can't be read, and over a fifth of the used space went unexplained.
- **Some space can't be attributed.** Even with Full Disk Access, a few GB stay in folders that need root, or in APFS metadata. Because APFS clones count several times in an allocated total, the unattributed space is a range: the app shows its lower bound and says so.
- **The system volumes take tens of GB** (System, Preboot, Recovery, VM). macOS manages them and the app doesn't touch them.

## 2. Principles

1. **Nothing is deleted without a preview.** The exact list is always shown before acting.
2. **Honest numbers.** Freed space is measured on the volume after the operation, not estimated. Moving to the Trash doesn't count as freed.
3. **Every item explains itself.** What it is, who creates it, what happens if you delete it, whether it comes back.
4. **No scaremongering.** No health score, no invented "danger", no RAM cleaning.
5. **Works offline.** No information about your files leaves the Mac.

### Deliberately out of scope

- **RAM cleaning.** macOS already manages memory, and forcing it empty slows the system down, because it has to reload what it had cached.
- **Deleting files protected by SIP**, or changing anything in `/System`.
- **System snapshots.** `com.apple.os.update` snapshots belong to software updates: they're shown and never touched.

## 3. Features

| Section | What it does |
|---|---|
| Overview | Space by category, largest folders, what grew since the last scan, suggested actions |
| Explore | A treemap and a list you can navigate, with filters by kind, age, and size |
| Apps | Size, the space that really comes back, last use when known, uninstalling with leftovers |
| Large files | Files over 100 MB outside the Library, hidden folders, and packages, filtered by kind and age |
| Duplicates | Real copies, leaving out APFS clones, which don't take space twice. At least one copy always stays |
| Cleanup | Caches and old logs, driven by rules and grouped by risk level |
| Developer | Simulators, DerivedData, device support, Homebrew, pip, npm |
| History | Every operation with its files, measured space, and outcome |
| Automation | Menu bar icon, low space warning, scheduled cleanups of safe items only, off by default |

The feature that sets the app apart most is **"what grew"**: comparing saved scans shows at once that a folder took 12 GB this week.

## 4. Cleaning safely

Every item belongs to one of four levels.

| Level | Examples | Selected by default | How it's removed |
|---|---|---|---|
| Safe | Homebrew, pip, and npm caches, logs untouched for 30 days | Yes | Deleted directly |
| Review first | Browser and Steam caches, DerivedData, simulator data | No | Deleted directly, or by the tool's own command |
| Personal | Apps, leftovers, large files, duplicates | Never: you pick them | Moved to the Trash |
| Protected | Keychains, `Application Support` without a rule, system data | Can't be selected | Never |

For caches the Trash would be pointless: the space would stay used until it's emptied.

`Application Support` is protected by default, even though it's large, because real data is mixed in with caches. Only subfolders covered by an explicit rule are touched.

### Path of every removal

The code is in `Sources/CleanKit`, the only module allowed to change the disk.

1. **Plan.** An immutable list of items, each with its rule, file identifier, and expected size, shown before acting.
2. **Checks right before acting:**
   - the rule is still valid, and the plan's roots are the ones it names
   - the owner apps aren't open (checked again for each rule)
   - the root is opened one component at a time, without following links, and has the same identifier as in the scan
   - every item has the same identifier as in the scan, or it's skipped
3. **Removal.** Each step opens a single component relative to a folder already open, and refuses links. A link planted anywhere, even during the removal, can't take it outside its folder. It doesn't cross into other volumes and doesn't download files from the cloud. Items that appeared after the scan stay.
4. **Verification.** The volume's used space is read right before and right after, without waiting, and the result goes to History. APFS frees space at once, while waiting lets other apps' writes into the figure: in one test, 12 MB per second of writes by other apps turned 400 MB into 143 MB within 20 seconds. If the measured figure and the bytes of the removed files diverge, the report shows both.

### Moving to the Trash

Apps, leftovers, and personal files always go to the Trash, where they can be recovered. The report says so: the space is freed only when the Trash is emptied, and the app doesn't empty it. `TrashPolicy` allows only:

- **apps:** a `.app` bundle in the app folders, at most one subfolder down
- **leftovers:** direct children of known `~/Library` folders, never the folder itself, and never `Keychains` or `Mail`, for example
- **files:** regular files in the home, outside `~/Library`, hidden folders such as `.git`, and the inside of packages such as the Photos library

Before moving each item, the path is opened again without following links and its identifier is compared with the scan. Nothing moves while the app is open. If the system refuses, for example for a root-owned app such as Xcode, the error goes in the report without asking for privileges: move it from the Finder.

**Leftovers.** What's found by exact bundle identifier and isn't app data starts selected. App data, which may hold your work, and anything found by name only always start unselected.

**Last use.** It comes from Spotlight, which knew it for only about one app in five on the development machine. When it's missing, the app says "unknown", never "never used".

### Duplicates

`DuplicateKit` compares files over 1 MB in the home, with the same exclusions as large files, at rising cost: same size, same start and end, then SHA-256 of the whole content. It doesn't download files from the cloud. The search runs only when asked, because it reads files.

- **Clones:** files sharing the same clone count as a single copy. A group made only of clones doesn't appear.
- **Selection:** no file starts selected, and `DuplicateSelection` refuses to remove every copy in a group.
- **Copy to keep:** when moving, the app checks that it still exists and is the one scanned. Otherwise nothing moves.

### Scheduled cleanups

They're the only exception to "nothing is deleted without a preview", so their limits are strict:

- they're **off by default**, and a missing or damaged settings file leaves them off
- they cover only "Safe" items that delete files: never commands, apps, personal files, or items to review
- the first one runs a full interval after they're turned on, and the screen lists what they would delete now
- every run goes to History, marked as scheduled
- they run only while the app is open: there's no launch at login

### Rules as data

Rules live in `Sources/RulesKit/catalog.json`, compiled into the app, so they can be reviewed without touching the engine:

```json
{
  "id": "homebrew.cache",
  "title": "Homebrew cache",
  "explanation": "Packages already downloaded. Homebrew downloads them again when needed.",
  "level": "safe",
  "roots": ["~/Library/Caches/Homebrew"],
  "ownerProcesses": []
}
```

A rule can only name folders allowed by a list written in code (`RootPolicy`): subfolders of `~/Library/Caches` and `~/.npm`, `~/Library/Logs`, and two Xcode folders. A mistake in the catalog can at worst point at another cache, never at documents or `Application Support`, and a catalog with an invalid rule is refused as a whole.

Tool commands are a closed list in code too (`CommandPolicy`), written in full with absolute paths: `xcrun simctl delete unavailable`, `xcrun simctl erase all`, `brew cleanup --prune=all`. They run without a shell, so nothing in the arguments can be interpreted, and with a time limit. The simulators folder is allowed only for a command, never for direct removal.

A command appears only when it has work to do: the tool is asked in read-only mode (`simctl list`, `brew cleanup --dry-run`). For a command the estimate is a maximum, "up to", because what it really frees is up to the tool. The Homebrew cache stays a rule of its own, so its items can be seen one by one; the command appears only when there's more than the cache.

## 5. Architecture

**Stack:** Swift 6 and SwiftUI, AppKit where needed, SwiftPM modules, and no external dependencies. Built with Xcode 27.2 and Swift 6.4.

```
iMemoryApp (SwiftUI)
   ├── ScanKit       scanning, in-memory tree, saved scans, recovery estimates
   ├── RulesKit      rule catalog and planning
   ├── CleanKit      checks, removal, commands, Trash, history, automation rules
   ├── DuplicateKit  size → partial hash → full hash
   └── AppsKit       installed apps, leftovers, large files
```

Only `CleanKit` can change the disk. The other modules are read-only, and that boundary keeps the risky part small and testable.

### Scanning

The engine is in `Sources/ScanKit`, the command-line tool is `imemory-scan`, and the comparison with `du` is `Scripts/compare-du.sh`. The first prototype stays in `Spikes/ScanSpike`.

**Choice: `getattrlistbulk`**, for accuracy:

- it recognizes hard links by file identifier, while `FileManager` counts them several times (44 MiB too many in a caches folder, in one test)
- it reads `ATTR_CMNEXT_PRIVATESIZE`, needed to estimate the space that really comes back

**Results on the data volume** of the development machine, with about 1 million entries and without Full Disk Access:

| Threads | Time | System time | Peak memory |
|---:|---:|---:|---:|
| 1 | 37.6 s | 11.6 s | 220 MB |
| 2 | 21.8 s | 13.2 s | 216 MB |
| **4 (default)** | **13.4 s** | **14.9 s** | **195 MB** |
| 8 | 11.9 s | 22.7 s | 202 MB |

These are warm-cache times. With 8 threads the scan is 11% faster but uses 52% more system CPU, so the default is 4.

**With Full Disk Access**, about 1.25 million entries and 4 threads:

| Measurement | Time | Peak memory |
|---|---:|---:|
| After `sudo purge` | 14.9 s | 252 MB |
| Warm | 14.7 s | 251 MB |

The two times are almost the same, so `purge` may not evict file system metadata. A truly cold run, right after a restart, wasn't measured.

**Comparison with `du`:** running a scan, `du`, and a scan again, the `du` total fell between the two scans in all three tests, including the one with Full Disk Access. The two scans differ by 1–2 MiB over about 126 GiB because the disk is in use, mostly in `/private/var`, so the check can't be more precise than that.

**Known differences from `du`:**

- beyond `PATH_MAX`, `du` stops with an error and reports 0, while the engine reads the file
- the `/home` mount point weighs 1 KiB for `du` and 0 for the engine
- a hard link can land in a different folder with the same total: `du` gives it to the first path it meets, the engine always to the smallest path
- `du` may download cloud folders to list them, so the script leaves them out of both measurements

Other points about the engine:

- **Three sizes per node:** logical, allocated, private. The UI shows allocated; recovery estimates use private.
- **Recovery estimate.** The sum of private sizes is a lower bound: two clones in the same folder both count as "shared", yet deleting both frees their space. For apps, `RecoveryEstimator` reads `ATTR_CMNEXT_CLONEID` and `ATTR_CMNEXT_CLONE_REFCNT`, and counts shared space only when every file sharing it is in the set. It matched the space really freed within 10 MB in tests of 150 MB. On the development machine, Xcode took 4.2 GB, but uninstalling it would give back only 1.3 GB.
- **Deterministic hard links:** the owner is the smallest path, so two scans never show growth that didn't happen.
- **Cloud-only files:** never downloaded. Checked on Google Drive, OneDrive, and iCloud: the space used was identical before and after a scan.
- **Other volumes:** the root is `/System/Volumes/Data`, and the scan doesn't cross into other devices, so firmlinks aren't counted twice.
- **Memory:** the tree takes 106 MB for 1.25 million entries. The temporary peak during a scan is about 250 MB for about 15 seconds.

### Stalled scans

While macOS waits for an answer to a permission request, `open()` blocks. After 8 seconds without new entries the app says so, and Cancel still works: the wait ends at once and the blocked thread finishes by itself once the system releases it. With ad hoc signing every build counts as a new app, so these requests can come back.

### Interface and responsiveness

The app is in `Sources/iMemoryApp`, in SwiftUI. `Scripts/build-app.sh` builds it into `build/iMemory.app`. `Scripts/check-app.sh` drives it through a fixed route and records the main thread's worst stall.

**The list is an `NSTableView`, not SwiftUI's `Table`.** With 42,680 rows, re-sorting a `Table` blocked the app for up to 12.5 seconds, because it compares every row. `NSTableView` reloads only the visible rows.

**Filtering and sorting run in the background** above 5,000 rows, so the main thread stays free.

**Results** with about 1 million entries, without Full Disk Access:

| Operation | Worst stall |
|---|---:|
| Opening a folder | 35–110 ms |
| Sorting, searching, and filtering 42,680 rows | 40–90 ms |
| Selecting a row | 10–20 ms |
| Resizing the window | 25–100 ms |
| Going back to Overview | 150 ms |
| Reopening Explore | 250 ms |
| Opening Explore the first time | 350–520 ms |

These costs depend on the open folder's contents, not on the total number of entries. Switching sections is the slowest part.

### Permissions and distribution

- **Full Disk Access:** needed for a complete scan. The app works without it, and says clearly what it couldn't read.
- **No sandbox, so no Mac App Store.** The sandbox would stop the app from reading and cleaning other apps' folders.
- **Distribution:** none. You build and run it yourself; it isn't notarized and has no automatic updates.
- **Minimum version:** macOS 27, with no compatibility code for earlier versions.
- **Signing:** `build-app.sh` uses an "Apple Development" certificate if there is one, and signs ad hoc otherwise. With ad hoc signing, macOS ties Full Disk Access to a single build, so the permission has to be granted again after every build. The free "Apple Development" certificate comes from adding an Apple ID in Xcode. The command-line tool doesn't need it, because it uses the permissions of the terminal it runs in.
- **No privileged helper.** Nothing in the home folder needs administrator rights, and a helper would add attack surface.

## 6. Interface

A single window with a sidebar: Overview, Explore, Apps, Large files, Duplicates, Cleanup, Developer, History, Automation.

- **Overview:** the space bar, what grew, suggested actions with the space they'd recover.
- **Explore:** the treemap on the left, the list on the right, the path on top. Selecting in one updates the other.
- **Details panel:** the three sizes, last modification, and notes about the item.
- **Confirmation:** the number of items, the estimated space as a range, what happens next, and the cost of each item that needs reviewing.

During a scan you see the entries found and the space measured, and you can cancel. Results can be explored only once the scan ends.

## 7. Tests

- **Engine:** automatic comparison with `du` on trees with hard links, clones, symbolic links, sparse files, and paths beyond `PATH_MAX`.
- **Measurements on the disk:** the tests that compare the volume's space run in a single serial suite, because side by side they'd skew each other. They retry up to three times: a wrong estimate fails every time, while other apps' writes don't last three runs.
- **Safety:** `CleanKit` works only on a fake home in a temporary folder, with adversarial cases: symbolic links in the root, along the path, and inside folders, paths with `..`, files and folders replaced after the scan, an open owner app, hard links, protected files, unreadable folders, a volume mounted inside the folder, and paths beyond `PATH_MAX`.
- **Commands:** run with a recorder instead of the real tools, plus checks of the runner itself on harmless programs.
- **Duplicates:** real APFS clones, hard links, and files that differ only in the middle.
- **Scripted run:** `Scripts/check-app.sh` also goes through a full cleanup and a full uninstall from the screens, on a fake home with a fake Trash. It never runs a cleanup on real data.
- **Rules:** catalog validation. No rule can point at forbidden roots such as `~`, `~/Documents`, `~/Library/Application Support`, or `/`.
- **Not covered by automated tests:** cloud-only files inside a folder being cleaned. The behaviour is set (`IOPOL_MATERIALIZE_DATALESS_FILES_OFF`), but these files can't be created in a test.

## 8. Milestones

| Milestone | Content | State |
|---|---|---|
| M0 | `ScanKit` and the CLI | Done: totals equal to `du` on the whole disk; a measurement after a restart is missing |
| M1 | Read-only app: Overview, Explore | Stalls under 110 ms with about 1 million entries; still to try with mouse and keyboard |
| M2 | `RulesKit`, `CleanKit`, Cleanup, History | Adversarial tests pass; on a fake home, measured space within 5% of the expected; no real cleanup yet |
| M3 | Developer section | Commands tested with recorded runs; `simctl erase all` and `brew cleanup` have never run for real |
| M4 | Apps and large files | Recovery estimate checked against real removals of test files; a real app has never been moved to the real Trash |
| M5 | Duplicates and automation | No APFS clone reported as a duplicate, checked with real clones; notifications, the menu bar menu, and a real scheduled cleanup have never run |

In the first two milestones the app couldn't delete anything: the risky part came only once the measurements were verified.

## 9. Open points

- **External volumes:** left out.
- **Localization:** the interface is in English only.
