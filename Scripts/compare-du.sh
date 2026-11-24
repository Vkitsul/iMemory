#!/bin/bash
# Compares imemory-scan with du. Read-only.
#
# Runs a scan, du, then a scan again: on a disk in use the totals change by themselves,
# and the difference between the two scans measures that movement.
#
# Cloud folders are excluded for du too, because du would download them to list them.
#
# usage: Scripts/compare-du.sh [path] [depth]
set -uo pipefail

ROOT="${1:-/System/Volumes/Data}"
DEPTH="${2:-2}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$(cd "$PROJECT" && swift build -c release --show-bin-path)/imemory-scan"
OUT="$(mktemp -d)"

[ -x "$SCAN" ] || { echo "Build first: swift build -c release" >&2; exit 2; }

CLOUD_DU=(-I CloudStorage -I "Mobile Documents")
CLOUD_SCAN=(--exclude-name CloudStorage --exclude-name "Mobile Documents")

"$SCAN" "$ROOT" "${CLOUD_SCAN[@]}" --du-depth "$DEPTH" >"$OUT/before.txt" 2>"$OUT/before.log"
/usr/bin/du -xk -d "$DEPTH" "${CLOUD_DU[@]}" "$ROOT" >"$OUT/du.txt" 2>"$OUT/du.err"
"$SCAN" "$ROOT" "${CLOUD_SCAN[@]}" --du-depth "$DEPTH" >"$OUT/after.txt" 2>"$OUT/after.log"

total() { awk -F'\t' -v root="$ROOT" '$2 == root { print $1 }' "$1"; }
BEFORE=$(total "$OUT/before.txt")
DU=$(total "$OUT/du.txt")
AFTER=$(total "$OUT/after.txt")

echo "Totals in KiB"
echo "  scan before      $BEFORE"
echo "  du               $DU"
echo "  scan after       $AFTER"
echo "  du - before      $((DU - BEFORE))"
echo "  after - before   $((AFTER - BEFORE))   (disk movement)"
echo "  du errors        $(wc -l <"$OUT/du.err" | tr -d ' ')"
echo
echo "Folders with the largest difference, in KiB (du - scan after)"
awk -F'\t' '
    NR == FNR { scan[$2] = $1; next }
    { d = $1 - scan[$2]; if (!($2 in scan)) d = "du-only"; print d "\t" $1 "\t" $2 }
' "$OUT/after.txt" "$OUT/du.txt" |
    awk -F'\t' '$1 != 0' |
    awk -F'\t' '{ a = $1 < 0 ? -$1 : $1; print a "\t" $0 }' |
    sort -rn | head -15 | cut -f2-
echo
echo "Summary of the first scan"
cat "$OUT/before.log"
echo
echo "Working files: $OUT"
