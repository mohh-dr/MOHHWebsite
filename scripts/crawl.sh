#!/usr/bin/env bash
# Mirror the pages listed in scripts/urls.txt into ./site (static DR copy).
set -euo pipefail
ORIGIN="${ORIGIN:-https://www.mohh.com.sg}"
HOST="$(echo "$ORIGIN" | sed -E "s#^https?://##; s#[:/].*##")"
MIN_BYTES="${MIN_BYTES:-2000}"          # pages smaller than this = suspect
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"

grep -vE '^\s*(#|$)' "$ROOT/scripts/urls.txt" > "$STAGE/urls.txt"
EXPECTED=$(wc -l < "$STAGE/urls.txt")

# 1. Download pages + CSS/JS/images; convert links to relative so the
#    site works at https://mohh-dr.github.io/mohh-dr/ and on a custom domain.
wget --page-requisites --convert-links --adjust-extension \
     --no-host-directories --restrict-file-names=windows \
     --domains "$HOST" -e robots=off --tries=3 --timeout=30 \
     --user-agent "mohh-dr-sync/1.0" \
     -i "$STAGE/urls.txt" -P "$STAGE/out" || true   # asset 404s are tolerated

# 2. Safety: every listed page must exist and be non-trivial, else abort
#    (keeps the last good mirror instead of publishing a broken one).
fail=0
while read -r url; do
  path="${url#$ORIGIN}"; path="${path%%\?*}"
  [[ -z "$path" || "$path" == */ ]] && path="${path}index.html"
  [[ "$path" != *.html ]] && path="${path}.html"
  f="$STAGE/out/${path#/}"
  if [[ ! -s "$f" || $(stat -c%s "$f") -lt $MIN_BYTES ]]; then
    echo "MISSING/SMALL: $url -> $f"; fail=1
  fi
done < "$STAGE/urls.txt"
[[ $fail -eq 1 ]] && { echo "Aborting: mirror incomplete"; exit 1; }

# 3. Inject DR banner + last-synced stamp into every page.
STAMP="$(TZ=Asia/Singapore date '+%d %b %Y %H:%M SGT')"
BANNER="<div style=\"background:#fff3cd;color:#664d03;padding:8px 16px;font:14px/1.4 sans-serif;text-align:center;border-bottom:1px solid #ffe69c\">This is a backup copy of the MOHH website (last updated ${STAMP}). Some features such as forms and search are temporarily unavailable.</div>"
find "$STAGE/out" -name '*.html' -print0 | while IFS= read -r -d '' f; do
  python3 - "$f" "$BANNER" "$ORIGIN" <<'PY'
import re, sys
p, banner, origin = sys.argv[1:]
s = open(p, encoding='utf-8', errors='ignore').read()
s = s.replace(origin + '/', '/')                       # leftover absolute links
s = re.sub(r'(<body[^>]*>)', r'\1' + banner, s, count=1, flags=re.I)
s = re.sub(r'<form\b', '<form onsubmit="alert(\'Forms are unavailable on the backup site.\');return false"', s, flags=re.I)
open(p, 'w', encoding='utf-8').write(s)
PY
done

# 4. Swap into ./site, keeping repo-managed files.
cp "$ROOT/site/404.html" "$STAGE/out/" 2>/dev/null || true
touch "$STAGE/out/.nojekyll"
rm -rf "$ROOT/site"; mv "$STAGE/out" "$ROOT/site"
echo "Mirrored $EXPECTED page(s) at $STAMP"
