#!/bin/bash
# Builds iMemory and creates build/iMemory.app. Prints the bundle's path.
#
# Signs with an "Apple Development" certificate if there is one, so that Full Disk
# Access stays valid from one build to the next. Otherwise it signs ad hoc, and macOS
# asks for the permission again after every build.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT/build/iMemory.app"

cd "$PROJECT"
swift build -c release --product iMemoryApp >&2
BIN="$(swift build -c release --show-bin-path)/iMemoryApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/iMemory"
# The icon is regenerated with: swift Scripts/make-icon.swift
cp "$PROJECT/Resources/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

cat >"$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key><string>iMemory</string>
    <key>CFBundleDisplayName</key><string>iMemory</string>
    <key>CFBundleIdentifier</key><string>local.imemory.app</string>
    <key>CFBundleExecutable</key><string>iMemory</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHumanReadableCopyright</key><string>Personal project</string>
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')"
codesign --force --sign "${IDENTITY:--}" "$APP" >&2
echo "Signed with: ${IDENTITY:-ad hoc}" >&2

echo "$APP"
