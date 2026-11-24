#!/bin/bash
# Confronta imemory-scan con du. Sola lettura.
#
# Esegue scansione, du e di nuovo scansione: su un disco in uso i totali cambiano
# da soli, e la differenza fra le due scansioni dà la misura di quel movimento.
#
# Le cartelle cloud sono escluse anche per du, perché du le scaricherebbe per elencarle.
#
# uso: Scripts/compare-du.sh [percorso] [profondità]
set -uo pipefail

ROOT="${1:-/System/Volumes/Data}"
DEPTH="${2:-2}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
SCAN="$(cd "$PROJECT" && swift build -c release --show-bin-path)/imemory-scan"
OUT="$(mktemp -d)"

[ -x "$SCAN" ] || { echo "Prima compila: swift build -c release" >&2; exit 2; }

CLOUD_DU=(-I CloudStorage -I "Mobile Documents")
CLOUD_SCAN=(--exclude-name CloudStorage --exclude-name "Mobile Documents")

"$SCAN" "$ROOT" "${CLOUD_SCAN[@]}" --du-depth "$DEPTH" >"$OUT/before.txt" 2>"$OUT/before.log"
/usr/bin/du -xk -d "$DEPTH" "${CLOUD_DU[@]}" "$ROOT" >"$OUT/du.txt" 2>"$OUT/du.err"
"$SCAN" "$ROOT" "${CLOUD_SCAN[@]}" --du-depth "$DEPTH" >"$OUT/after.txt" 2>"$OUT/after.log"

total() { awk -F'\t' -v root="$ROOT" '$2 == root { print $1 }' "$1"; }
BEFORE=$(total "$OUT/before.txt")
DU=$(total "$OUT/du.txt")
AFTER=$(total "$OUT/after.txt")

echo "Totali in KiB"
echo "  scansione prima  $BEFORE"
echo "  du               $DU"
echo "  scansione dopo   $AFTER"
echo "  du - prima       $((DU - BEFORE))"
echo "  dopo - prima     $((AFTER - BEFORE))   (movimento del disco)"
echo "  errori di du     $(wc -l <"$OUT/du.err" | tr -d ' ')"
echo
echo "Cartelle con la differenza più grande, in KiB (du - scansione dopo)"
awk -F'\t' '
    NR == FNR { scan[$2] = $1; next }
    { d = $1 - scan[$2]; if (!($2 in scan)) d = "solo-du"; print d "\t" $1 "\t" $2 }
' "$OUT/after.txt" "$OUT/du.txt" |
    awk -F'\t' '$1 != 0' |
    awk -F'\t' '{ a = $1 < 0 ? -$1 : $1; print a "\t" $0 }' |
    sort -rn | head -15 | cut -f2-
echo
echo "Riepilogo della prima scansione"
cat "$OUT/before.log"
echo
echo "File di lavoro: $OUT"
