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

# Чистим slug list
tr -d '\r' < "$SLUG_FILE" | sed '/^[[:space:]]*$/d' | awk '{$1=$1; print}' > "$CLEAN_SLUG_FILE"

if [ ! -s "$CLEAN_SLUG_FILE" ]; then
  echo "ERROR: no slugs found in $SLUG_FILE"
  exit 1
fi

while IFS= read -r SITE_SLUG || [ -n "$SITE_SLUG" ]; do
  SITE_SLUG="$(echo "$SITE_SLUG" | xargs)"

  if [ -z "$SITE_SLUG" ]; then
    continue
  fi

  echo "==> Building slug: $SITE_SLUG"

  SRC_CONTENT_DIR="$BUILD_ROOT/content/sites/$SITE_SLUG"
  SRC_DATA_FILE="$BUILD_ROOT/data/sites/$SITE_SLUG.json"

  if [ ! -d "$SRC_CONTENT_DIR" ]; then
    echo "ERROR: content/sites/$SITE_SLUG not found"
    exit 1
  fi

  if [ ! -f "$SRC_DATA_FILE" ]; then
    echo "ERROR: data/sites/$SITE_SLUG.json not found"
    exit 1
  fi

  # домен нужен только для корректного baseURL / OG
  SITE_DOMAIN="$(python3 - <<PY
import json
with open("$SRC_DATA_FILE", "r", encoding="utf-8") as f:
    data = json.load(f)
print(data.get("domain_russia", "").strip())
PY
)"

  if [ -z "$SITE_DOMAIN" ]; then
    echo "ERROR: domain_russia not found in data/sites/$SITE_SLUG.json"
    exit 1
  fi

  SINGLE_TMP="$TMP_DIR/site-$SITE_SLUG"
  mkdir -p "$SINGLE_TMP"
  cp -R "$BUILD_ROOT/." "$SINGLE_TMP/"

  find "$SINGLE_TMP/content/sites" -mindepth 1 -maxdepth 1 -type d ! -name "$SITE_SLUG" -exec rm -rf {} +
  find "$SINGLE_TMP/data/sites" -type f -name "*.json" ! -name "${SITE_SLUG}.json" -delete

  cp "$SINGLE_TMP/content/sites/$SITE_SLUG/index.md" "$SINGLE_TMP/content/_index.md"

  hugo \
    --source "$SINGLE_TMP" \
    --destination "$PUBLIC_ROOT/$SITE_SLUG" \
    --baseURL "https://$SITE_DOMAIN/" \
    --minify

  rm -rf "$PUBLIC_ROOT/$SITE_SLUG/sites"
  rm -rf "$PUBLIC_ROOT/$SITE_SLUG/tags"
  rm -rf "$PUBLIC_ROOT/$SITE_SLUG/categories"
  rm -f "$PUBLIC_ROOT/$SITE_SLUG/index.xml"
done < "$CLEAN_SLUG_FILE"

echo "==> Generating batch manifest"
cp "$CLEAN_SLUG_FILE" "$PUBLIC_ROOT/_batch/slugs.txt"

python3 - <<PY
import json
from pathlib import Path

slug_file = Path("$CLEAN_SLUG_FILE")
public_batch = Path("$PUBLIC_ROOT/_batch")

slugs = [line.strip() for line in slug_file.read_text(encoding="utf-8").splitlines() if line.strip()]

(public_batch / "slugs.json").write_text(
    json.dumps(slugs, ensure_ascii=False, indent=2),
    encoding="utf-8"
)

html = [
    "<!doctype html>",
    "<html lang='ru'>",
    "<head>",
    "  <meta charset='utf-8'>",
    "  <meta name='viewport' content='width=device-width,initial-scale=1'>",
    "  <title>Batch slugs</title>",
    "  <style>body{font-family:Arial,sans-serif;padding:24px;line-height:1.5} table{border-collapse:collapse;width:100%} th,td{border:1px solid #ddd;padding:10px;text-align:left} th{background:#f5f5f5}</style>",
    "</head>",
    "<body>",
    "  <h1>Batch slugs</h1>",
    "  <table>",
    "    <thead><tr><th>#</th><th>Slug</th></tr></thead>",
    "    <tbody>",
]
for i, slug in enumerate(slugs, start=1):
    html.append(f"      <tr><td>{i}</td><td>{slug}</td></tr>")
html += [
    "    </tbody>",
    "  </table>",
    "</body>",
    "</html>",
]
(public_batch / "index.html").write_text("\n".join(html), encoding="utf-8")
PY

echo "==> Generating Pages function"
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

export async function onRequest(context) {
  const url = new URL(context.request.url);
  const host = url.hostname.toLowerCase().replace(/^www\./, "");
  let pathname = url.pathname || "/";

  // 1) Для pages.dev: тест батча, /_batch/, /50pribyli/
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

  // 2) Рабочий режим для .ru доменов
  if (!host.endsWith(".ru")) {
    return new Response(`Unsupported host: ${host}`, { status: 404 });
  }

  const slug = host.replace(/\.ru$/, "");

  // Старые мусорные пути /sites/... показывают главную текущего домена
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