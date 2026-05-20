#!/usr/bin/env bash
set -euo pipefail

: "${BATCH_NAME:?BATCH_NAME is required (example: batch-01)}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

SLUG_FILE="$ROOT/batches/${BATCH_NAME}.txt"

if [ ! -f "$SLUG_FILE" ]; then
  echo "ERROR: batch file not found: $SLUG_FILE"
  exit 1
fi

TMP_DIR="$(mktemp -d)"
BUILD_ROOT="$TMP_DIR/build"
PUBLIC_ROOT="$ROOT/public"
CLEAN_SLUG_FILE="$TMP_DIR/slugs.txt"
DOMAIN_MAP_FILE="$TMP_DIR/domain-map.json"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

echo "==> build-batch: $BATCH_NAME"
echo "==> Using slug file: $SLUG_FILE"

mkdir -p "$BUILD_ROOT"
cp -R "$ROOT/." "$BUILD_ROOT/"
rm -rf "$BUILD_ROOT/.git"
rm -rf "$BUILD_ROOT/public"
rm -rf "$BUILD_ROOT/resources"
rm -rf "$BUILD_ROOT/node_modules"
rm -f "$BUILD_ROOT/.hugo_build.lock"

rm -rf "$PUBLIC_ROOT"
mkdir -p "$PUBLIC_ROOT"
mkdir -p "$PUBLIC_ROOT/_batch"

# Clean slug list
tr -d '\r' < "$SLUG_FILE" | sed '/^[[:space:]]*$/d' | awk '{$1=$1; print}' > "$CLEAN_SLUG_FILE"

if [ ! -s "$CLEAN_SLUG_FILE" ]; then
  echo "ERROR: no slugs found in $SLUG_FILE"
  exit 1
fi

echo "==> Preparing domain map from data/sites/*.json"

python3 - <<PY
import json
import re
from pathlib import Path

build_root = Path("$BUILD_ROOT")
slug_file = Path("$CLEAN_SLUG_FILE")
out_file = Path("$DOMAIN_MAP_FILE")

slugs = [
    line.strip()
    for line in slug_file.read_text(encoding="utf-8").splitlines()
    if line.strip()
]

def clean_domain(value: str) -> str:
    value = (value or "").strip()

    if not value:
        return ""

    value = value.replace("https://", "").replace("http://", "").strip("/")
    value = value.split("/")[0].strip().lower()
    value = re.sub(r"^www\\.", "", value)

    return value

domain_map = {}
missing_domains = []
missing_json = []

for slug in slugs:
    data_file = build_root / "data" / "sites" / f"{slug}.json"

    if not data_file.exists():
        missing_json.append(str(data_file))
        continue

    data = json.loads(data_file.read_text(encoding="utf-8"))

    domain = clean_domain(data.get("domain_main", ""))

    if not domain:
        missing_domains.append(slug)
        continue

    if "/" in domain:
        missing_domains.append(slug)
        continue

    domain_map[domain] = slug

if missing_json:
    print("ERROR: missing data JSON files:")
    for item in missing_json:
        print(" -", item)
    raise SystemExit(1)

if missing_domains:
    print("ERROR: missing or invalid domain_main for these slugs:")
    for slug in missing_domains:
        print(" -", slug)
    print("")
    print('Expected format inside data/sites/<slug>.json:')
    print('"domain_main": "https://example.com"')
    raise SystemExit(1)

out_file.write_text(
    json.dumps(domain_map, ensure_ascii=False, indent=2),
    encoding="utf-8"
)

print(f"==> Domain map ready: {len(domain_map)} domains")
PY

while IFS= read -r SITE_SLUG || [ -n "$SITE_SLUG" ]; do
  SITE_SLUG="$(echo "$SITE_SLUG" | xargs)"

  if [ -z "$SITE_SLUG" ]; then
    continue
  fi

  echo "==> Building slug: $SITE_SLUG"

  SRC_DATA_FILE="$BUILD_ROOT/data/sites/$SITE_SLUG.json"

  if [ ! -f "$SRC_DATA_FILE" ]; then
    echo "ERROR: data/sites/$SITE_SLUG.json not found"
    exit 1
  fi

  SITE_DOMAIN="$(python3 - <<PY
import json
from pathlib import Path

slug = "$SITE_SLUG"
domain_map = json.loads(Path("$DOMAIN_MAP_FILE").read_text(encoding="utf-8"))

for domain, mapped_slug in domain_map.items():
    if mapped_slug == slug:
        print(domain)
        break
PY
)"

  if [ -z "$SITE_DOMAIN" ]; then
    echo "ERROR: domain not found for slug: $SITE_SLUG"
    exit 1
  fi

  CONTENT_INDEX="$BUILD_ROOT/content/sites/$SITE_SLUG/index.md"

  if [ ! -f "$CONTENT_INDEX" ]; then
    echo "ERROR: content/sites/$SITE_SLUG/index.md not found"
    exit 1
  fi

  if [ -z "$CONTENT_INDEX" ]; then
    echo "ERROR: content file not found for $SITE_SLUG"
    exit 1
  fi

  SINGLE_TMP="$TMP_DIR/site-$SITE_SLUG"
  mkdir -p "$SINGLE_TMP"
  cp -R "$BUILD_ROOT/." "$SINGLE_TMP/"

  # Keep only selected data JSON.
  # data/templates remains untouched.
  find "$SINGLE_TMP/data/sites" -type f -name "*.json" ! -name "${SITE_SLUG}.json" -delete

  # Make selected nested content page the homepage for this custom domain.
  SELECTED_TMP="$TMP_DIR/selected-$SITE_SLUG.md"
  cp "$CONTENT_INDEX" "$SELECTED_TMP"

  rm -rf "$SINGLE_TMP/content"
  mkdir -p "$SINGLE_TMP/content"
  cp "$SELECTED_TMP" "$SINGLE_TMP/content/_index.md"

  hugo \
    --source "$SINGLE_TMP" \
    --destination "$PUBLIC_ROOT/$SITE_SLUG" \
    --baseURL "https://$SITE_DOMAIN/" \
    --minify

  rm -rf "$PUBLIC_ROOT/$SITE_SLUG/tags"
  rm -rf "$PUBLIC_ROOT/$SITE_SLUG/categories"
  rm -f "$PUBLIC_ROOT/$SITE_SLUG/index.xml"

done < "$CLEAN_SLUG_FILE"

echo "==> Generating batch manifest"

cp "$CLEAN_SLUG_FILE" "$PUBLIC_ROOT/_batch/slugs.txt"
cp "$DOMAIN_MAP_FILE" "$PUBLIC_ROOT/_batch/domain-map.json"

python3 - <<PY
import json
from pathlib import Path

slug_file = Path("$CLEAN_SLUG_FILE")
domain_map_file = Path("$DOMAIN_MAP_FILE")
public_batch = Path("$PUBLIC_ROOT/_batch")

slugs = [
    line.strip()
    for line in slug_file.read_text(encoding="utf-8").splitlines()
    if line.strip()
]

domain_map = json.loads(domain_map_file.read_text(encoding="utf-8"))

(public_batch / "slugs.json").write_text(
    json.dumps(slugs, ensure_ascii=False, indent=2),
    encoding="utf-8"
)

rows = []

for slug in slugs:
    domain = next((d for d, s in domain_map.items() if s == slug), "")
    rows.append((slug, domain))

html = [
    "<!doctype html>",
    "<html lang='en'>",
    "<head>",
    "  <meta charset='utf-8'>",
    "  <meta name='viewport' content='width=device-width,initial-scale=1'>",
    "  <title>SFTY Batch</title>",
    "  <style>body{font-family:Arial,sans-serif;padding:24px;line-height:1.5} table{border-collapse:collapse;width:100%} th,td{border:1px solid #ddd;padding:10px;text-align:left} th{background:#f5f5f5} a{color:#007f58}</style>",
    "</head>",
    "<body>",
    "  <h1>SFTY Batch</h1>",
    "  <table>",
    "    <thead><tr><th>#</th><th>Slug</th><th>Domain</th><th>Preview</th></tr></thead>",
    "    <tbody>",
]

for i, (slug, domain) in enumerate(rows, start=1):
    html.append(
        f"      <tr><td>{i}</td><td>{slug}</td><td>{domain}</td><td><a href='/{slug}/' target='_blank'>/{slug}/</a></td></tr>"
    )

html += [
    "    </tbody>",
    "  </table>",
    "</body>",
    "</html>",
]

(public_batch / "index.html").write_text("\\n".join(html), encoding="utf-8")
PY

echo "==> Generating Cloudflare Pages function"

mkdir -p "$ROOT/functions"

cat > "$ROOT/functions/[[path]].js" <<'EOF'
async function fetchAsset(context, assetPath, url) {
  let response = await context.env.ASSETS.fetch(
    new Request(new URL(assetPath, url.origin).toString(), context.request)
  );

  if ([301, 302, 307, 308].includes(response.status)) {
    const location = response.headers.get("Location");

    if (location) {
      const followUrl = new URL(location, url.origin);

      response = await context.env.ASSETS.fetch(
        new Request(followUrl.toString(), context.request)
      );
    }
  }

  return response;
}

async function loadDomainMap(context, url) {
  const response = await context.env.ASSETS.fetch(
    new Request(new URL("/_batch/domain-map.json", url.origin).toString(), context.request)
  );

  if (!response.ok) {
    return {};
  }

  return await response.json();
}

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const host = url.hostname.toLowerCase().replace(/^www\./, "");
  let pathname = url.pathname || "/";

  // Preview mode on *.pages.dev
  if (host.endsWith(".pages.dev")) {
    let assetPath = pathname;

    if (assetPath === "/") {
      assetPath = "/_batch/index.html";
    }

    if (assetPath.endsWith("/")) {
      assetPath += "index.html";
    }

    return fetchAsset(context, assetPath, url);
  }

  const domainMap = await loadDomainMap(context, url);
  const slug = domainMap[host];

  if (!slug) {
    return new Response(`Unsupported host: ${host}`, { status: 404 });
  }

  if (pathname.startsWith("/sites/")) {
    pathname = "/";
  }

  let assetPath;

  if (pathname === "/") {
    assetPath = `/${slug}/index.html`;
  } else if (pathname === `/${slug}` || pathname === `/${slug}/`) {
    assetPath = `/${slug}/index.html`;
  } else if (pathname.startsWith(`/${slug}/`)) {
    assetPath = pathname;

    if (assetPath.endsWith("/")) {
      assetPath += "index.html";
    }
  } else {
    assetPath = `/${slug}${pathname}`;

    if (assetPath.endsWith("/")) {
      assetPath += "index.html";
    }
  }

  return fetchAsset(context, assetPath, url);
}
EOF

echo "==> Done: built batch $BATCH_NAME"
echo "==> Visual batch map: /_batch/"
echo "==> Domain map: /_batch/domain-map.json"