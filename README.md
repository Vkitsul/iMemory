# iMemory

A native macOS app that shows where your disk space goes and helps you free it without risk.

- **See where the space is:** an overview by category, a treemap you can explore, and what grew since the last scan.
- **Get rid of what you don't need:** caches, old logs, developer leftovers, apps with their leftovers, large files, and real duplicates.
- **Know what you'll really get back:** sizes account for APFS clones and hard links, and every cleanup is measured on the disk afterwards.

## Safety first

- Nothing is deleted without showing you the exact list first.
- Caches and logs are deleted only in folders allowed by a list written in code, never in your documents.
- Apps, leftovers, large files, and duplicates go to the Trash, where you can restore them.
- Removal opens every path without following symbolic links, so a link can't redirect it anywhere else.
- Developer tools are cleaned only with their own commands, from a closed list, without a shell.
- Scheduled cleanups are off by default and cover only safe items.

The full reasoning is in [docs/DESIGN.md](docs/DESIGN.md).

## Requirements

- macOS 27
- Xcode 27.2 or later (Swift 6.4)

## Build and run

```bash
Scripts/build-app.sh
open build/iMemory.app
```

For a complete scan, give iMemory Full Disk Access in System Settings, Privacy & Security. Without it the app still works, and tells you which folders it couldn't read.

With ad hoc signing, macOS asks for the permission again after every build. Adding your Apple ID in Xcode gives you a free "Apple Development" certificate, which `build-app.sh` uses automatically.

## Command-line scanner

```bash
swift run -c release imemory-scan --top 20
```

`Scripts/compare-du.sh` checks the scanner's totals against `du`.

## Tests

```bash
swift test
```

Tests that delete files work only in temporary folders. `Scripts/check-app.sh` drives the app through a fixed route and runs a full cleanup and uninstall on a fake home, never on your data.

## Status

A personal project, published as is. Every feature is built and covered by automated tests, but the app hasn't been used much for real cleanups yet. Use it carefully, and start with the items marked "Safe".

## Project layout

| Folder | What's inside |
|---|---|
| `Sources/ScanKit` | Disk scanner, size and recovery estimates |
| `Sources/RulesKit` | Cleanup rules and their catalog |
| `Sources/CleanKit` | The only module that changes the disk |
| `Sources/AppsKit` | Installed apps, leftovers, large files |
| `Sources/DuplicateKit` | Duplicate search |
| `Sources/iMemoryApp` | The SwiftUI app |
| `Sources/imemory-scan` | Command-line scanner |
| `Scripts` | Build, icon, and verification scripts |
