#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE_SVG="$ROOT_DIR/Design/AppIcon/codex-proxy-icon.svg"
OUTPUT_DIR="$ROOT_DIR/Design/AppIcon"
ICONSET_DIR="$ROOT_DIR/Packaging/macOS/AppIcon.iconset"
ICNS_PATH="$ROOT_DIR/Packaging/macOS/AppIcon.icns"
BUILD_CACHE_DIR="${CODEX_PROXY_BUILD_CACHE_DIR:-$ROOT_DIR/.build/codex-proxy-build-cache}"
FINGERPRINT_DIR="$BUILD_CACHE_DIR/app-icon"
FINGERPRINT_FILE="$FINGERPRINT_DIR/AppIcon.fingerprint"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script currently supports macOS only." >&2
  exit 1
fi

if [[ ! -f "$SOURCE_SVG" ]]; then
  echo "Missing source icon: $SOURCE_SVG" >&2
  exit 1
fi

tool_version_hash() {
  {
    command -v qlmanage || true
    command -v sips || true
    command -v iconutil || true
    qlmanage -h 2>&1 || true
    sips -h 2>&1 || true
    iconutil --help 2>&1 || true
  } | shasum -a 256 | awk '{print $1}'
}

current_fingerprint() {
  {
    shasum -a 256 "$SOURCE_SVG"
    shasum -a 256 "$0"
    printf 'tools=%s\n' "$(tool_version_hash)"
  } | shasum -a 256 | awk '{print $1}'
}

icon_outputs_exist() {
  [[ -s "$OUTPUT_DIR/codex-proxy-icon-1024.png" && -s "$ICNS_PATH" ]] || return 1
  for size in 16 32 128 256 512; do
    [[ -s "$ICONSET_DIR/icon_${size}x${size}.png" ]] || return 1
    [[ -s "$ICONSET_DIR/icon_${size}x${size}@2x.png" ]] || return 1
  done
}

CURRENT_FINGERPRINT="$(current_fingerprint)"

if [[ "${CODEX_PROXY_REBUILD_APP_ICON:-0}" != "1" ]] &&
   [[ -f "$FINGERPRINT_FILE" ]] &&
   [[ "$(cat "$FINGERPRINT_FILE")" == "$CURRENT_FINGERPRINT" ]] &&
   icon_outputs_exist; then
  echo "Reusing cached AppIcon outputs: $ICNS_PATH"
  exit 0
fi

if [[ "${CODEX_PROXY_REBUILD_APP_ICON:-0}" == "1" ]]; then
  echo "Rebuilding AppIcon because CODEX_PROXY_REBUILD_APP_ICON=1"
else
  echo "Rendering AppIcon; cache miss or missing outputs."
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
mkdir -p "$FINGERPRINT_DIR"
printf '%s\n' "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE"

echo "Rendered preview: $BASE_PNG"
echo "Rendered iconset: $ICONSET_DIR"
echo "Rendered icns: $ICNS_PATH"
