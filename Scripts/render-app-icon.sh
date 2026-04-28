#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SVG="$ROOT_DIR/Design/AppIcon/codex-proxy-icon.svg"
OUTPUT_DIR="$ROOT_DIR/Design/AppIcon"
ICONSET_DIR="$ROOT_DIR/Packaging/macOS/AppIcon.iconset"
ICNS_PATH="$ROOT_DIR/Packaging/macOS/AppIcon.icns"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script currently supports macOS only." >&2
  exit 1
fi

if [[ ! -f "$SOURCE_SVG" ]]; then
  echo "Missing source icon: $SOURCE_SVG" >&2
  exit 1
fi

mkdir -p "$OUTPUT_DIR"
rm -rf "$ICONSET_DIR"
mkdir -p "$ICONSET_DIR"

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
TMP_SVG="$TMP_DIR/codex-proxy-icon-render-$(date +%s%N).svg"

cp "$SOURCE_SVG" "$TMP_SVG"
qlmanage -t -s 1024 -o "$TMP_DIR" "$TMP_SVG" >/dev/null 2>&1
mv -f "$TMP_DIR/$(basename "$TMP_SVG").png" "$OUTPUT_DIR/codex-proxy-icon-1024.png"

BASE_PNG="$OUTPUT_DIR/codex-proxy-icon-1024.png"

for size in 16 32 128 256 512; do
  sips -z "$size" "$size" "$BASE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}.png" >/dev/null
  double_size=$((size * 2))
  sips -z "$double_size" "$double_size" "$BASE_PNG" --out "$ICONSET_DIR/icon_${size}x${size}@2x.png" >/dev/null
done

iconutil -c icns "$ICONSET_DIR" -o "$ICNS_PATH"

echo "Rendered preview: $BASE_PNG"
echo "Rendered iconset: $ICONSET_DIR"
echo "Rendered icns: $ICNS_PATH"
