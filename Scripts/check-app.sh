#!/bin/bash
# Launches the app, drives it through a fixed route, and writes timings and screenshots.
# Read-only on your data. The output goes to the given folder.
#
# usage: Scripts/check-app.sh <output-folder>
set -euo pipefail

OUTPUT="${1:?give an output folder}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$("$PROJECT/Scripts/build-app.sh")"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

# The app asks for a screenshot by writing a file with its window number.
(
    while [ ! -f "$OUTPUT/stop" ]; do
        for request in "$OUTPUT"/request-*; do
            [ -f "$request" ] || continue
            name="${request##*/request-}"
            screencapture -x -o -l "$(cat "$request")" "$OUTPUT/$name.png" 2>>"$OUTPUT/captures.log" || true
            rm -f "$request"
        done
        sleep 0.1
    done
) &
WATCHER=$!

open -n -W --env IMEMORY_SELFCHECK="$OUTPUT" "$APP"
touch "$OUTPUT/stop"
wait "$WATCHER"

# The app writes "done" last: without it, it stopped early or crashed.
if ! grep -q '^done$' "$OUTPUT/results.txt" 2>/dev/null; then
    echo "ERROR: the route didn't finish. Check ~/Library/Logs/DiagnosticReports" >&2
    cat "$OUTPUT/results.txt" 2>/dev/null
    exit 1
fi
cat "$OUTPUT/results.txt"
