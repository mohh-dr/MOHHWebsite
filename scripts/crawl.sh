#!/usr/bin/env bash
# Mirror the pages listed in scripts/urls.txt into ./site (static DR copy).
set -euo pipefail
ORIGIN="${ORIGIN:-https://www.mohh.com.sg}"
HOST="$(echo "$ORIGIN" | sed -E "s#^https?://##; s#[:/].*##")"
MIN_BYTES="${MIN_BYTES:-2000}"          # pages smaller than this = suspect
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
STAGE="$(mktemp -d)"

grep -vE '^\s*(#|$)' "$ROOT/scripts/urls.txt" > "$STAGE/urls.txt"
awk '!seen[$0]++' "$STAGE/urls.txt" > "$STAGE/urls.unique.txt"
mv "$STAGE/urls.unique.txt" "$STAGE/urls.txt"
EXPECTED=$(wc -l < "$STAGE/urls.txt")

# 1. Download pages + CSS/JS/images; convert links to relative so the
#    site works at https://mohh-dr.github.io/mohh-dr/ and on a custom domain.
wget --page-requisites --convert-links --adjust-extension \
     --no-host-directories --force-directories --restrict-file-names=windows \
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

# The sharing-moments and media-centre components request this API at runtime.
# Cache its response and the assets referenced by its articles for static hosting.
wget --tries=3 --timeout=30 --user-agent "mohh-dr-sync/1.0" \
     --output-document="$STAGE/out/media-search.json" \
     "$ORIGIN/bin/mohhwebsites/media-search?category=all&limit=100"
python3 - "$STAGE/out/media-search.json" "$STAGE/out/index.html" "$STAGE/media-assets.txt" "$ORIGIN" <<'PY'
import html, json, re, sys
from urllib.parse import quote, urljoin, urlsplit, urlunsplit

response_path, home_path, output_path, origin = sys.argv[1:]
with open(response_path, encoding="utf-8") as f:
    response = json.load(f)
if response.get("success") is not True or not isinstance(response.get("articles"), list) or not response["articles"]:
    raise SystemExit("Media search API returned no usable articles")

with open(home_path, encoding="utf-8", errors="ignore") as f:
    home = f.read()
match = re.search(r"""data-curated-articles=["']([^"']*)["']""", home, re.I)
if not match:
    raise SystemExit("Homepage is missing the curated sharing-moments article list")
curated_paths = {
    html.unescape(path).strip()
    for path in match.group(1).split(",")
    if path.strip()
}
article_paths = {article.get("path") for article in response["articles"]}
missing_paths = sorted(curated_paths - article_paths)
if missing_paths:
    raise SystemExit("Media search API is missing curated homepage articles: " + ", ".join(missing_paths))

origin_host = urlsplit(origin).netloc
assets = set()
for article in response["articles"]:
    for key in ("featuredImage", "pdfUrl"):
        value = article.get(key)
        if not isinstance(value, str) or not value:
            continue
        url = urljoin(origin + "/", value)
        parsed = urlsplit(url)
        if parsed.scheme not in ("http", "https") or parsed.netloc != origin_host:
            continue
        encoded_path = quote(parsed.path, safe="/%:@!$&'()*+,;=-._~")
        assets.add(urlunsplit((parsed.scheme, parsed.netloc, encoded_path, parsed.query, "")))

with open(output_path, "w", encoding="utf-8") as f:
    f.write("\n".join(sorted(assets)))
    if assets:
        f.write("\n")
if not assets:
    raise SystemExit("Media search API did not reference any downloadable assets")
PY
wget --tries=3 --timeout=30 --user-agent "mohh-dr-sync/1.0" \
     --no-host-directories --force-directories --restrict-file-names=windows \
     -i "$STAGE/media-assets.txt" -P "$STAGE/out"
python3 - "$STAGE/out/media-search.json" "$STAGE/out" "$ORIGIN" <<'PY'
import json, os, sys
from urllib.parse import unquote, urljoin, urlsplit

response_path, output, origin = sys.argv[1:]
with open(response_path, encoding="utf-8") as f:
    response = json.load(f)
origin_host = urlsplit(origin).netloc
for article in response["articles"]:
    for key in ("featuredImage", "pdfUrl"):
        value = article.get(key)
        if not isinstance(value, str) or not value:
            continue
        parsed = urlsplit(urljoin(origin + "/", value))
        if parsed.scheme not in ("http", "https") or parsed.netloc != origin_host or not parsed.path:
            continue
        relative = unquote(parsed.path).lstrip("/")
        local_path = os.path.normpath(os.path.join(output, relative))
        if os.path.commonpath((os.path.abspath(output), os.path.abspath(local_path))) != os.path.abspath(output):
            raise SystemExit("Unsafe media asset path: " + value)
        if not os.path.isfile(local_path) or os.path.getsize(local_path) == 0:
            raise SystemExit("Missing media asset: " + value + " -> " + local_path)
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

# 3. Rebase local asset links and add the navigation shim to mirrored pages.
find "$STAGE/out" -name '*.html' -print0 | while IFS= read -r -d '' f; do
  python3 - "$f" "$ORIGIN" "$STAGE/out" "$STAGE/urls.txt" <<'PY' || { echo "Failed to process mirrored page: $f" >&2; exit 1; }
import os, re, sys
import json
from urllib.parse import urlsplit
p, origin, output_root, url_list = sys.argv[1:]
s = open(p, encoding='utf-8', errors='ignore').read()
s = s.replace(origin + '/', '/')  # leftover absolute links
relative_dir = os.path.relpath(os.path.dirname(p), output_root)
depth = 0 if relative_dir == "." else len(relative_dir.split(os.sep))
relative_root = "../" * depth
mirrored_paths = set()
for url in open(url_list, encoding='utf-8'):
    path = urlsplit(url.strip()).path or "/"
    if path != "/" and path.endswith("/"):
        path = path[:-1]
    if path.lower().endswith(".html"):
        path = path[:-5]
    mirrored_paths.add(path or "/")
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
    var sourceOrigin = __MOHH_ORIGIN__;
    var mirroredPages = __MIRRORED_PATHS__;
    function findSitePath() {
        var scripts = document.getElementsByTagName('script');
        for (var i = 0; i < scripts.length; i++) {
            var src = new URL(scripts[i].src, window.location.href).pathname;
            var marker = '/etc.clientlibs/';
            var markerIndex = src.indexOf(marker);
            if (markerIndex !== -1 && src.indexOf('/clientlib-site.') !== -1) {
                return src.slice(0, markerIndex);
            }
        }
        if (window.location.hostname.endsWith('github.io')) {
            return null;
        }
        return '';
    }
    function getPageUrl(path, assetPath) {
        var parsed = new URL(path, sourceOrigin);
        var normalizedPath = parsed.pathname.replace(/(?:\.html)+$/i, '').replace(/\/$/, '') || '/';
        if (normalizedPath === '/home' || normalizedPath === '/index') {
            normalizedPath = '/';
        }
        if (mirroredPages.indexOf(normalizedPath) === -1) {
            return sourceOrigin + path;
        }
        return assetPath + normalizedPath + parsed.search + parsed.hash;
    }
    window.fetch = function(input, init) {
        var requestUrl = typeof input === 'string' ? input : input && input.url;
        var isSiteTree = requestUrl && /\.sitetree\.json(?:[?#]|$)/i.test(requestUrl);
        var isMediaSearch = requestUrl && /\/bin\/mohhwebsites\/media-search(?:[?#]|$)/i.test(requestUrl);
        if (isSiteTree || isMediaSearch) {
            var assetPath = findSitePath();
            if (assetPath === null) {
                return Promise.reject(new Error('Could not resolve the local MOHH site path'));
            }
            if (isMediaSearch) {
                return nativeFetch.call(window, assetPath + '/media-search.json', init).then(function(response) {
                    if (!response.ok) {
                        return response;
                    }
                    return response.json().then(function(data) {
                        (data.articles || []).forEach(function(article) {
                            ['featuredImage', 'pdfUrl'].forEach(function(key) {
                                if (typeof article[key] === 'string' && article[key].charAt(0) === '/' &&
                                    article[key].slice(0, 2) !== '//') {
                                    article[key] = assetPath + article[key];
                                }
                            });
                            if (typeof article.ctaPath === 'string' && article.ctaPath.charAt(0) === '/' &&
                                article.ctaPath.slice(0, 2) !== '//') {
                                article.ctaPath = sourceOrigin + article.ctaPath;
                            }
                        });
                        return new Response(JSON.stringify(data), {
                            status: response.status,
                            statusText: response.statusText,
                            headers: { 'Content-Type': 'application/json' }
                        });
                    });
                });
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
                                node[key] = getPageUrl(node[key], assetPath);
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
</script>'''.replace('__MOHH_ORIGIN__', json.dumps(origin)).replace(
    '__MIRRORED_PATHS__', json.dumps(sorted(mirrored_paths))
)
s = re.sub(
    r'(<body\b[^>]*>)',
    lambda match: match.group(1) + (navigation_shim if 'data-cmp-is="mega-navigation"' in s else ''),
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

# Remove the legacy notice from pages already present in the merged mirror.
find "$ROOT/site" -name '*.html' -print0 | while IFS= read -r -d '' f; do
  python3 - "$f" "$ROOT/site" "$STAGE/urls.txt" "$ORIGIN" <<'PY' || { echo "Failed to normalize mirrored page links: $f" >&2; exit 1; }
import html, os, posixpath, re, sys
from urllib.parse import urljoin, urlsplit, urlunsplit

path, site_root, url_list, origin = sys.argv[1:]
with open(path, encoding="utf-8", errors="ignore") as f:
    source = f.read()
origin_parts = urlsplit(origin)
mirrored_paths = set()
for url in open(url_list, encoding="utf-8"):
    route = urlsplit(url.strip()).path or "/"
    route = route.rstrip("/") or "/"
    while route.lower().endswith(".html"):
        route = route[:-5]
    if route in ("/home", "/index"):
        route = "/"
    mirrored_paths.add(route)

relative_path = os.path.relpath(path, site_root).replace(os.sep, "/")
current_path = "/" if relative_path == "index.html" else "/" + relative_path
current_dir = posixpath.dirname(relative_path) or "."

def rewrite_link(match):
    value = html.unescape(match.group(2))
    if not value or value.startswith("#"):
        return match.group(0)
    target = urlsplit(urljoin(origin.rstrip("/") + current_path, value))
    if target.scheme not in ("http", "https") or target.netloc.lower() != origin_parts.netloc.lower():
        return match.group(0)

    route = target.path.rstrip("/") or "/"
    had_html_extension = bool(re.search(r"(?:\.html)+$", route, re.I))
    while route.lower().endswith(".html"):
        route = route[:-5]
    if route in ("/home", "/index"):
        route = "/"

    if route in mirrored_paths:
        relative_target = posixpath.relpath(route.lstrip("/") or ".", current_dir)
        if relative_target == ".":
            relative_target = "./"
        rewritten = relative_target + (("?" + target.query) if target.query else "") + (("#" + target.fragment) if target.fragment else "")
    elif had_html_extension or not posixpath.splitext(target.path)[1]:
        rewritten = urlunsplit((origin_parts.scheme, origin_parts.netloc, route, target.query, target.fragment))
    else:
        return match.group(0)
    return match.group(1) + html.escape(rewritten, quote=True) + match.group(3)

updated = re.sub(r"""(\bhref\s*=\s*["'])([^"']*)(["'])""", rewrite_link, source, flags=re.I)
updated = re.sub(
    r'<div style="background:#fff3cd;color:#664d03;padding:8px 16px;font:14px/1\.4 sans-serif;text-align:center;border-bottom:1px solid #ffe69c">This is a backup copy of the MOHH website \(last updated [^<]*?\)\. Some features such as forms and search are temporarily unavailable\.</div>',
    "",
    updated,
)
if updated != source:
    with open(path, "w", encoding="utf-8") as f:
        f.write(updated)
PY
done
echo "Mirrored $EXPECTED page(s)"
