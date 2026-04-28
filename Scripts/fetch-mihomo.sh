#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
VERSION="v1.19.23"
CACHE_METADATA_NAME=".mihomo-cache"
FORCE_REFRESH=0
POSITIONAL_ARGS=()

usage() {
  cat >&2 <<'EOF'
Usage: fetch-mihomo.sh [--force-refresh] [dest_dir] [arch] [platform]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-refresh)
      FORCE_REFRESH=1
      ;;
    --help|-h)
      usage
      exit 0
      ;;
    -*)
      echo "Unknown option: $1" >&2
      usage
      exit 1
      ;;
    *)
      POSITIONAL_ARGS+=("$1")
      ;;
  esac
  shift
done

if [[ ${#POSITIONAL_ARGS[@]} -gt 3 ]]; then
  usage
  exit 1
fi

DEST_DIR_OVERRIDE="${POSITIONAL_ARGS[0]:-}"
REQUESTED_ARCH="${POSITIONAL_ARGS[1]:-$(uname -m)}"
REQUESTED_PLATFORM="${POSITIONAL_ARGS[2]:-$(uname -s)}"

normalize_platform() {
  case "$1" in
    Darwin|darwin|macOS|macos)
      echo "darwin"
      ;;
    Linux|linux)
      echo "linux"
      ;;
    *)
      echo "Unsupported mihomo target platform: $1" >&2
      exit 1
      ;;
  esac
}

TARGET_PLATFORM="$(normalize_platform "$REQUESTED_PLATFORM")"

case "$TARGET_PLATFORM:$REQUESTED_ARCH" in
  darwin:arm64|darwin:aarch64)
    TARGET_ARCH="arm64"
    ASSET_NAME="mihomo-darwin-arm64-${VERSION}.gz"
    CACHE_DIR="$ROOT_DIR/ThirdParty/mihomo/$TARGET_ARCH"
    ;;
  darwin:x86_64|darwin:amd64)
    TARGET_ARCH="amd64"
    ASSET_NAME="mihomo-darwin-amd64-compatible-${VERSION}.gz"
    CACHE_DIR="$ROOT_DIR/ThirdParty/mihomo/$TARGET_ARCH"
    ;;
  linux:arm64|linux:aarch64)
    TARGET_ARCH="arm64"
    ASSET_NAME="mihomo-linux-arm64-${VERSION}.gz"
    CACHE_DIR="$ROOT_DIR/ThirdParty/mihomo/linux-$TARGET_ARCH"
    ;;
  linux:x86_64|linux:amd64)
    TARGET_ARCH="amd64"
    ASSET_NAME="mihomo-linux-amd64-compatible-${VERSION}.gz"
    CACHE_DIR="$ROOT_DIR/ThirdParty/mihomo/linux-$TARGET_ARCH"
    ;;
  *)
    echo "Unsupported mihomo target architecture: $REQUESTED_ARCH ($TARGET_PLATFORM)" >&2
    exit 1
    ;;
esac

DEST_DIR="${DEST_DIR_OVERRIDE:-$CACHE_DIR}"
DOWNLOAD_URL="${MIHOMO_DOWNLOAD_URL:-https://github.com/MetaCubeX/mihomo/releases/download/${VERSION}/${ASSET_NAME}}"
CACHE_BIN="$CACHE_DIR/mihomo"
CACHE_METADATA="$CACHE_DIR/$CACHE_METADATA_NAME"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

write_cache_metadata() {
  local metadata_path="$1"

  cat > "$metadata_path" <<EOF
version=$VERSION
platform=$TARGET_PLATFORM
arch=$TARGET_ARCH
asset=$ASSET_NAME
EOF
}

cache_is_current() {
  [[ -x "$CACHE_BIN" && -f "$CACHE_METADATA" ]] || return 1
  grep -Fxq "version=$VERSION" "$CACHE_METADATA" &&
    grep -Fxq "platform=$TARGET_PLATFORM" "$CACHE_METADATA" &&
    grep -Fxq "arch=$TARGET_ARCH" "$CACHE_METADATA" &&
    grep -Fxq "asset=$ASSET_NAME" "$CACHE_METADATA"
}

ensure_cached_mihomo() {
  mkdir -p "$CACHE_DIR"

  if [[ "$FORCE_REFRESH" == "0" ]] && cache_is_current; then
    echo "Reusing cached mihomo at $CACHE_BIN"
    return 0
  fi

  echo "Downloading $DOWNLOAD_URL"
  if ! curl \
    -L \
    --fail \
    --silent \
    --show-error \
    --retry 3 \
    --retry-delay 2 \
    --connect-timeout 15 \
    --max-time 600 \
    "$DOWNLOAD_URL" \
    -o "$TMP_DIR/$ASSET_NAME"; then
    echo "Failed to download mihomo. You can set MIHOMO_DOWNLOAD_URL to a reachable mirror or local asset URL." >&2
    exit 1
  fi

  gunzip -c "$TMP_DIR/$ASSET_NAME" > "$TMP_DIR/mihomo"
  chmod +x "$TMP_DIR/mihomo"
  mv "$TMP_DIR/mihomo" "$CACHE_BIN"
  write_cache_metadata "$CACHE_METADATA"

  echo "Installed mihomo cache at $CACHE_BIN"
}

install_from_cache() {
  local target_dir="$1"
  local target_bin="$target_dir/mihomo"
  local target_dir_abs
  local cache_dir_abs

  mkdir -p "$target_dir"
  target_dir_abs="$(cd "$target_dir" && pwd)"
  cache_dir_abs="$(cd "$CACHE_DIR" && pwd)"

  if [[ "$target_dir_abs" == "$cache_dir_abs" ]]; then
    echo "mihomo ready at $CACHE_BIN"
    return 0
  fi

  cp "$CACHE_BIN" "$target_bin"
  chmod +x "$target_bin"
  echo "Installed mihomo to $target_bin (from cache)"
}

ensure_cached_mihomo
install_from_cache "$DEST_DIR"
