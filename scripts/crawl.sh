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

# The mega navigation requests this JSON at runtime, which wget cannot discover.
mkdir -p "$STAGE/out"
wget --tries=3 --timeout=30 --user-agent "mohh-dr-sync/1.0" \
     --output-document="$STAGE/out/home.sitetree.json" \
     "$ORIGIN/home.sitetree.json"
python3 - "$STAGE/out/home.sitetree.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding='utf-8') as f:
    tree = json.load(f)
if not isinstance(tree.get("subTree", {}).get("pages"), list) or not tree["subTree"]["pages"]:
    raise SystemExit("Navigation tree is missing its top-level pages")
PY

# CSS/JS reads carousel backgrounds from data-* attributes; download them explicitly.
python3 - "$STAGE/out/index.html" "$STAGE/hero-assets.txt" "$ORIGIN" <<'PY'
import html, re, sys
from urllib.parse import urljoin, urlsplit

page, output, origin = sys.argv[1:]
source = open(page, encoding="utf-8", errors="ignore").read()
origin_host = urlsplit(origin).netloc
assets = set()
for value in re.findall(r'data-(?:desktop|mobile)-bg=["\']([^"\']+)["\']', source, re.I):
    url = urljoin(origin + "/", html.unescape(value))
    parsed = urlsplit(url)
    if parsed.scheme in ("http", "https") and parsed.netloc == origin_host:
        assets.add(url)
with open(output, "w", encoding="utf-8") as f:
    f.write("\n".join(sorted(assets)))
    if assets:
        f.write("\n")
if not assets:
    raise SystemExit("No hero carousel background images found in the homepage")
PY
wget --tries=3 --timeout=30 --user-agent "mohh-dr-sync/1.0" \
     --no-host-directories --force-directories --restrict-file-names=windows \
     -i "$STAGE/hero-assets.txt" -P "$STAGE/out"
python3 - "$STAGE/hero-assets.txt" "$STAGE/out" <<'PY'
import os, sys
from urllib.parse import urlsplit

urls, output = sys.argv[1:]
for url in open(urls, encoding="utf-8"):
    path = os.path.join(output, urlsplit(url.strip()).path.lstrip("/"))
    if not os.path.isfile(path) or os.path.getsize(path) == 0:
        raise SystemExit("Missing hero carousel image: " + url.strip() + " -> " + path)
PY

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
  python3 - "$f" "$BANNER" "$ORIGIN" "$STAGE/out" <<'PY' || { echo "Failed to process mirrored page: $f" >&2; exit 1; }
import os, re, sys
p, banner, origin, output_root = sys.argv[1:]
s = open(p, encoding='utf-8', errors='ignore').read()
s = s.replace(origin + '/', '/')  # leftover absolute links
relative_dir = os.path.relpath(os.path.dirname(p), output_root)
depth = 0 if relative_dir == "." else len(relative_dir.split(os.sep))
relative_root = "../" * depth
s = re.sub(
    r"""(\b(?:href|src|action|poster|data-desktop-bg|data-mobile-bg)\s*=\s*["'])/(?!/)([^"']+)(["'])""",
    lambda match: match.group(1) + relative_root + match.group(2) + match.group(3),
    s,
    flags=re.I,
)
s = re.sub(
    r"""(url\(\s*["'])/(?!/)([^"']+)(["']\s*\))""",
    lambda match: match.group(1) + relative_root + match.group(2) + match.group(3),
    s,
    flags=re.I,
)
navigation_shim = r'''<script>
(function() {
    var nativeFetch = window.fetch;
    window.fetch = function(input, init) {
        var requestUrl = typeof input === 'string' ? input : input && input.url;
        if (requestUrl && /\.sitetree\.json(?:[?#]|$)/i.test(requestUrl)) {
            var scripts = document.getElementsByTagName('script');
            var assetPath = '';
            for (var i = 0; i < scripts.length; i++) {
                var src = new URL(scripts[i].src, window.location.href).pathname;
                var marker = '/etc.clientlibs/';
                var markerIndex = src.indexOf(marker);
                if (markerIndex !== -1 && src.indexOf('/clientlib-site.') !== -1) {
                    assetPath = src.slice(0, markerIndex);
                    break;
                }
            }
            if (!assetPath && window.location.hostname.endsWith('github.io')) {
                return Promise.reject(new Error('Could not resolve the local MOHH site path'));
            }
            var search = new URL(requestUrl, window.location.href).search;
            return nativeFetch.call(window, assetPath + '/home.sitetree.json' + search, init).then(function(response) {
                if (!response.ok) {
                    return response;
                }
                return response.json().then(function(tree) {
                    function addSitePath(node) {
                        if (!node || typeof node !== 'object') {
                            return;
                        }
                        if (Array.isArray(node)) {
                            node.forEach(addSitePath);
                            return;
                        }
                        Object.keys(node).forEach(function(key) {
                            if ((key === 'path' || key === 'currentPagePath') &&
                                typeof node[key] === 'string' && node[key].charAt(0) === '/' &&
                                node[key].slice(0, 2) !== '//') {
                                node[key] = assetPath + node[key];
                            } else {
                                addSitePath(node[key]);
                            }
                        });
                    }
                    addSitePath(tree);
                    return new Response(JSON.stringify(tree), {
                        status: response.status,
                        statusText: response.statusText,
                        headers: { 'Content-Type': 'application/json' }
                    });
                });
            });
        }
        return nativeFetch.apply(window, arguments);
    };
})();
</script>'''
s = re.sub(
    r'(<body\b[^>]*>)',
    lambda match: match.group(1) + banner + (navigation_shim if 'data-cmp-is="mega-navigation"' in s else ''),
    s,
    count=1,
    flags=re.I,
)
s = re.sub(r'<form\b', '<form onsubmit="alert(\'Forms are unavailable on the backup site.\');return false"', s, flags=re.I)
open(p, 'w', encoding='utf-8').write(s)
PY
done

# 4. Merge the new mirror into ./site, retaining GitHub-only files.
cp "$ROOT/site/404.html" "$STAGE/out/" 2>/dev/null || true
touch "$STAGE/out/.nojekyll"
mkdir -p "$ROOT/site"
cp -a "$STAGE/out/." "$ROOT/site/"
echo "Mirrored $EXPECTED page(s) at $STAMP"
