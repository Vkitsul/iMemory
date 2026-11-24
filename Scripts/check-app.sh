#!/bin/bash
# Avvia l'app, le fa percorrere un giro fisso e scrive i tempi e le schermate.
# Sola lettura. L'output finisce nella cartella indicata.
#
# uso: Scripts/check-app.sh <cartella-di-output>
set -euo pipefail

OUTPUT="${1:?indica una cartella di output}"
PROJECT="$(cd "$(dirname "$0")/.." && pwd)"
APP="$("$PROJECT/Scripts/build-app.sh")"

rm -rf "$OUTPUT"
mkdir -p "$OUTPUT"

# L'app chiede una schermata scrivendo un file con il numero della finestra.
(
    while [ ! -f "$OUTPUT/fine" ]; do
        for request in "$OUTPUT"/richiesta-*; do
            [ -f "$request" ] || continue
            name="${request##*/richiesta-}"
            screencapture -x -o -l "$(cat "$request")" "$OUTPUT/$name.png" 2>>"$OUTPUT/catture.log" || true
            rm -f "$request"
        done
        sleep 0.1
    done
) &
WATCHER=$!

open -n -W --env IMEMORY_SELFCHECK="$OUTPUT" "$APP"
touch "$OUTPUT/fine"
wait "$WATCHER"
# L'app scrive "fine" per ultimo: senza, si è fermata prima o è andata in crash.
if ! grep -q '^fine$' "$OUTPUT/risultati.txt" 2>/dev/null; then
    echo "ERRORE: il giro non è arrivato in fondo. Controlla ~/Library/Logs/DiagnosticReports" >&2
    cat "$OUTPUT/risultati.txt" 2>/dev/null
    exit 1
fi
cat "$OUTPUT/risultati.txt"
