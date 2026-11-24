#!/bin/bash
# Compila iMemory e crea build/iMemory.app. Stampa il percorso del bundle.
#
# Firma con un certificato "Apple Development" se esiste, così l'Accesso completo al
# disco resta valido fra una compilazione e l'altra. Altrimenti usa la firma ad hoc,
# con cui macOS richiede di nuovo il permesso dopo ogni compilazione.
set -euo pipefail

PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$PROJECT/build/iMemory.app"

cd "$PROJECT"
swift build -c release --product iMemoryApp >&2
BIN="$(swift build -c release --show-bin-path)/iMemoryApp"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp "$BIN" "$APP/Contents/MacOS/iMemory"

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
    <key>CFBundleShortVersionString</key><string>0.1</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>CFBundleDevelopmentRegion</key><string>it</string>
    <key>LSMinimumSystemVersion</key><string>27.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSPrincipalClass</key><string>NSApplication</string>
</dict>
</plist>
PLIST

IDENTITY="$(security find-identity -v -p codesigning | awk -F'"' '/Apple Development/ { print $2; exit }')"
codesign --force --sign "${IDENTITY:--}" "$APP" >&2
echo "Firma: ${IDENTITY:-ad hoc}" >&2

echo "$APP"
