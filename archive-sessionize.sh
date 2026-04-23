#!/usr/bin/env bash
#
# archive.sh — Vendor Sessionize embeds and Font Awesome for site archival
#
# Run this in a year-specific repo (e.g. bsidesorlando/2025) while the
# Sessionize endpoints are still live. Safe to re-run (idempotent).
#
# Requirements: curl, sed, grep (standard macOS/Linux tools)
#
# What it does:
#   1. Downloads rendered HTML from each Sessionize embed
#   2. Downloads the Sessionize CSS for each embed
#   3. Downloads speaker/session photos referenced in the HTML
#   4. Rewrites image URLs to local paths
#   5. Replaces <script> tags in .md files with {% include %} tags
#   6. Downloads Font Awesome CSS + webfonts locally
#   7. Updates _includes/head.html to use local Font Awesome
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "╔══════════════════════════════════════════╗"
echo "║  BSides Orlando Site Archive Script      ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# ─── Auto-discover Sessionize embeds from the repo ─────────────────
# Scans all .md and .html files for <script> tags pointing to sessionize.com
# and extracts: source_file, sessionize_id, view_type
EMBEDS=()
while IFS= read -r match; do
  # match format: filepath:...<script ...src="https://sessionize.com/api/v2/ID/view/TYPE">...
  md_file=$(echo "$match" | cut -d: -f1)
  sid=$(echo "$match" | grep -oE 'api/v2/[^/]+' | sed 's|api/v2/||')
  view=$(echo "$match" | grep -oE 'view/[^"]+' | sed 's|view/||')
  name=$(basename "$md_file" .md)
  # Also handle .html source files
  name=$(basename "$name" .html)
  EMBEDS+=("${name}|${sid}|${view}|${md_file}")
done < <(grep -rl --include='*.md' --include='*.html' 'sessionize.com/api/v2/.*/view/' . \
  | xargs grep -n '<script.*src="https://sessionize.com/api/v2/[^"]*"' 2>/dev/null || true)

if [ ${#EMBEDS[@]} -eq 0 ]; then
  echo "  ℹ No Sessionize embeds found in the repo"
else
  echo "  Found ${#EMBEDS[@]} Sessionize embed(s):"
  for entry in "${EMBEDS[@]}"; do
    IFS='|' read -r name sid view md_file <<< "$entry"
    echo "    • $md_file → $name ($view)"
  done
fi
echo ""

# ─── Create directories ────────────────────────────────────────────
mkdir -p _includes/archived
mkdir -p assets/vendor/fontawesome/css
mkdir -p assets/vendor/fontawesome/webfonts
mkdir -p assets/vendor/sessionize/images

# ─── Helper: download with retries ─────────────────────────────────
fetch() {
  local url="$1"
  local output="$2"
  local max_retries=3
  local attempt=1

  while [ $attempt -le $max_retries ]; do
    if curl -sfL --max-time 30 "$url" -o "$output" 2>/dev/null; then
      return 0
    fi
    echo "  ⚠ Attempt $attempt failed for $(basename "$output"), retrying..."
    attempt=$((attempt + 1))
    sleep 2
  done

  echo "  ✗ Failed to download: $url"
  return 1
}

# ─── Vendor Sessionize embeds ──────────────────────────────────────
for entry in "${EMBEDS[@]}"; do
  IFS='|' read -r name sid view md_file <<< "$entry"
  echo "── Archiving Sessionize: $name ──"

  base_url="https://sessionize.com/api/v2/${sid}"
  html_file="_includes/archived/${name}.html"

  # 1. Fetch the rendered HTML
  echo "  → Downloading HTML..."
  if ! fetch "${base_url}/view/${view}?under=True" "$html_file"; then
    echo "  ✗ Skipping $name (HTML download failed)"
    continue
  fi

  # 2. Fetch the embed CSS
  echo "  → Downloading CSS..."
  css_file="assets/vendor/sessionize/${name}.css"
  if fetch "${base_url}/embedstyle" "$css_file"; then
    # Rewrite the HTML to use local CSS instead of the Sessionize URL
    sed -i.bak "s|href=\"${base_url}/embedstyle\"|href=\"/assets/vendor/sessionize/${name}.css\"|g" "$html_file"
    # Also handle any other sessionize embedstyle URLs in case of variations
    sed -i.bak "s|href=\"https://sessionize.com/api/v2/[^\"]*embedstyle\"|href=\"/assets/vendor/sessionize/${name}.css\"|g" "$html_file"
  fi

  # 3. Download speaker/session images referenced in the HTML
  echo "  → Downloading images..."
  image_urls=$(grep -oE 'src="https://sessionize\.com/image/[^"]*"' "$html_file" | sed 's/src="//;s/"$//' || true)

  if [ -n "$image_urls" ]; then
    img_count=0
    while IFS= read -r img_url; do
      # Extract filename from URL: e.g. cceb-200o200o2-35bh6CnKFYb9yMX5xXsgBk.png
      img_filename=$(echo "$img_url" | sed 's|https://sessionize.com/image/||')
      local_path="assets/vendor/sessionize/images/${img_filename}"

      if [ ! -f "$local_path" ]; then
        fetch "$img_url" "$local_path" || true
      fi

      # Rewrite the src in the HTML to use local path
      # Use | as sed delimiter since URLs contain /
      escaped_url=$(printf '%s' "$img_url" | sed 's/[&/\]/\\&/g')
      escaped_local=$(printf '%s' "/assets/vendor/sessionize/images/${img_filename}" | sed 's/[&/\]/\\&/g')
      sed -i.bak "s|${escaped_url}|/assets/vendor/sessionize/images/${img_filename}|g" "$html_file"

      img_count=$((img_count + 1))
    done <<< "$image_urls"
    echo "  ✓ Downloaded $img_count images"
  else
    echo "  ✓ No images to download"
  fi

  # 4. Replace the <script> tag in the markdown file with an include
  if [ -f "$md_file" ]; then
    echo "  → Updating $md_file..."
    # Match the sessionize script tag and replace with jekyll include
    sed -i.bak "s|<script type=\"text/javascript\" src=\"https://sessionize.com/api/v2/${sid}/view/${view}\"></script>|{% include archived/${name}.html %}|g" "$md_file"
    echo "  ✓ Replaced <script> with {% include archived/${name}.html %}"
  else
    echo "  ⚠ $md_file not found, skipping replacement"
  fi

  echo ""
done

# ─── Vendor Font Awesome ───────────────────────────────────────────
echo "── Archiving Font Awesome ──"

FA_CDN="https://cdn.jsdelivr.net/npm/@fortawesome/fontawesome-free@5"
FA_LOCAL="assets/vendor/fontawesome"

# 1. Download the CSS
echo "  → Downloading CSS..."
fetch "${FA_CDN}/css/all.min.css" "${FA_LOCAL}/css/all.min.css"

# 2. Parse the CSS for webfont URLs and download them
echo "  → Downloading webfonts..."
font_urls=$(grep -oE 'url\([^)]*\)' "${FA_LOCAL}/css/all.min.css" | grep -oE '\.\./webfonts/[^?)]*' || true)

if [ -n "$font_urls" ]; then
  font_count=0
  while IFS= read -r font_path; do
    font_file=$(basename "$font_path")
    if [ ! -f "${FA_LOCAL}/webfonts/${font_file}" ]; then
      fetch "${FA_CDN}/webfonts/${font_file}" "${FA_LOCAL}/webfonts/${font_file}" || true
    fi
    font_count=$((font_count + 1))
  done <<< "$font_urls"
  echo "  ✓ Downloaded $font_count font files"
fi

# 3. Update the CSS to use relative paths (../webfonts/ is already correct
#    relative to css/all.min.css, so no change needed)

# 4. Update _includes/head.html to use local Font Awesome
HEAD_FILE="_includes/head.html"
if [ -f "$HEAD_FILE" ]; then
  echo "  → Updating $HEAD_FILE..."

  # Replace the preload line
  sed -i.bak 's|href="https://cdn.jsdelivr.net/npm/@fortawesome/fontawesome-free@5/css/all.min.css"|href="/assets/vendor/fontawesome/css/all.min.css"|g' "$HEAD_FILE"

  echo "  ✓ Updated Font Awesome references"
fi

echo ""

# ─── Cleanup .bak files created by sed ─────────────────────────────
echo "── Cleaning up ──"
find . -name '*.bak' -delete 2>/dev/null || true
echo "  ✓ Removed backup files"

echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  ✓ Archive complete!                     ║"
echo "╠══════════════════════════════════════════╣"
echo "║  Vendored:                               ║"
echo "║  • _includes/archived/*.html             ║"
echo "║  • assets/vendor/sessionize/             ║"
echo "║  • assets/vendor/fontawesome/            ║"
echo "║                                          ║"
echo "║  Review changes with: git diff           ║"
echo "║  Commit with: git add -A && git commit   ║"
echo "╚══════════════════════════════════════════╝"