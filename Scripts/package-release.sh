#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUILD_SCRIPT="$ROOT_DIR/Scripts/build-macos-app.sh"
LINUX_ARTIFACT_BUILD_SCRIPT="$ROOT_DIR/Scripts/build-linux-artifacts.sh"
DIST_DIR="$ROOT_DIR/Dist/remote-capable"
STAGING_DIR="$(mktemp -d)"
REMOTE_ARTIFACTS_DIR="$ROOT_DIR/Artifacts"
FORCE_REFRESH=0

usage() {
  cat >&2 <<'EOF'
Usage: package-release.sh [--force-refresh]
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
      echo "Unexpected argument: $1" >&2
      usage
      exit 1
      ;;
  esac
  shift
done

normalize_target_arch() {
  case "$1" in
    arm64|aarch64)
      echo "arm64"
      ;;
    x86_64|amd64)
      echo "x86_64"
      ;;
    *)
      echo "Unsupported macOS architecture: $1" >&2
      exit 1
      ;;
  esac
}

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

HOST_ARCH="$(normalize_target_arch "$(uname -m)")"
OTHER_ARCH="arm64"
if [[ "$HOST_ARCH" == "arm64" ]]; then
  OTHER_ARCH="x86_64"
fi

mkdir -p "$DIST_DIR"
if [[ "$FORCE_REFRESH" == "1" ]]; then
  "$LINUX_ARTIFACT_BUILD_SCRIPT" --force-refresh "$REMOTE_ARTIFACTS_DIR"
else
  "$LINUX_ARTIFACT_BUILD_SCRIPT" "$REMOTE_ARTIFACTS_DIR"
fi
export CODEX_PROXY_REMOTE_ARTIFACTS_DIR="$REMOTE_ARTIFACTS_DIR"
export CODEX_PROXY_SKIP_REMOTE_ARTIFACT_PREPARE=1

VERSION=""
for TARGET_ARCH in "$HOST_ARCH" "$OTHER_ARCH"; do
  OUTPUT_DIR="$DIST_DIR"
  if [[ "$TARGET_ARCH" != "$HOST_ARCH" ]]; then
    OUTPUT_DIR="$STAGING_DIR/$TARGET_ARCH"
  fi

  if [[ "$FORCE_REFRESH" == "1" ]]; then
    "$APP_BUILD_SCRIPT" --force-refresh release "$TARGET_ARCH" "$OUTPUT_DIR" full
  else
    "$APP_BUILD_SCRIPT" release "$TARGET_ARCH" "$OUTPUT_DIR" full
  fi

  if [[ -z "$VERSION" ]]; then
    VERSION="$("$OUTPUT_DIR/codex-proxyd-macos" --release-version)"
  fi

  ZIP_PATH="$DIST_DIR/AICodingProxy-macos-$TARGET_ARCH-$VERSION.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$OUTPUT_DIR/AI Coding Proxy.app" "$ZIP_PATH"

  echo "Packaged release zip ($TARGET_ARCH): $ZIP_PATH"
done
