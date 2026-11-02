#!/usr/bin/env bash
# Reconstruiește install-ntsenc.sh din src/ + installer/
set -euo pipefail
cd "$(dirname "$0")"
OUT=install-ntsenc.sh
{
  cat installer/head.sh
  for f in ntsenc.py panel.html login.html; do
    echo "cat > \"\$APP/$f\" <<'NTSENC_FILE_EOF'"; cat "src/$f"; echo "NTSENC_FILE_EOF"
  done
  cat installer/tail.sh
} > "$OUT"
chmod +x "$OUT"
bash -n "$OUT" && echo "OK: $OUT ($(wc -l < "$OUT") linii)"
