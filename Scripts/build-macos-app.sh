#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SCRIPT="$ROOT_DIR/Scripts/render-app-icon.sh"
FETCH_MIHOMO_SCRIPT="$ROOT_DIR/Scripts/fetch-mihomo.sh"
BUILD_LINUX_ARTIFACTS_SCRIPT="$ROOT_DIR/Scripts/build-linux-artifacts.sh"
THIRD_PARTY_NOTICE="$ROOT_DIR/Packaging/macOS/mihomo-third-party-notice.txt"
REMOTE_ARTIFACTS_DIR="${CODEX_PROXY_REMOTE_ARTIFACTS_DIR:-$ROOT_DIR/Artifacts}"
FORCE_REFRESH=0
POSITIONAL_ARGS=()
source "$ROOT_DIR/Scripts/swift-static-linux-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: build-macos-app.sh [--force-refresh] [configuration] [arch] [output_dir] [bundle_profile]
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

if [[ ${#POSITIONAL_ARGS[@]} -gt 4 ]]; then
  usage
  exit 1
fi

CONFIGURATION="${POSITIONAL_ARGS[0]:-release}"
REQUESTED_ARCH="${POSITIONAL_ARGS[1]:-$(uname -m)}"
OUTPUT_DIR="${POSITIONAL_ARGS[2]:-$ROOT_DIR/Dist}"
BUNDLE_PROFILE="${POSITIONAL_ARGS[3]:-full}"

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

normalize_bundle_profile() {
  case "$1" in
    full|local-only)
      echo "$1"
      ;;
    *)
      echo "Unsupported bundle profile: $1 (expected: full or local-only)" >&2
      exit 1
      ;;
  esac
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only builds the macOS app bundle." >&2
  exit 1
fi

TARGET_ARCH="$(normalize_target_arch "$REQUESTED_ARCH")"
BUNDLE_PROFILE="$(normalize_bundle_profile "$BUNDLE_PROFILE")"
SWIFT_EXEC="$(codex_proxy_require_swift_toolchain)"
case "$TARGET_ARCH" in
  arm64)
    MIHOMO_ARCH="arm64"
    ;;
  x86_64)
    MIHOMO_ARCH="amd64"
    ;;
esac

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_DIR="$OUTPUT_DIR/AI Coding Proxy.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
REMOTE_RESOURCES_DIR="$RESOURCES_DIR/RemoteArtifacts"

if [[ "$BUNDLE_PROFILE" == "full" && "${CODEX_PROXY_SKIP_REMOTE_ARTIFACT_PREPARE:-0}" != "1" ]]; then
  if [[ "$FORCE_REFRESH" == "1" ]]; then
    "$BUILD_LINUX_ARTIFACTS_SCRIPT" --force-refresh "$REMOTE_ARTIFACTS_DIR"
  else
    "$BUILD_LINUX_ARTIFACTS_SCRIPT" "$REMOTE_ARTIFACTS_DIR"
  fi
fi

"$SWIFT_EXEC" build -c "$CONFIGURATION" --arch "$TARGET_ARCH"
BUILD_DIR="$("$SWIFT_EXEC" build -c "$CONFIGURATION" --arch "$TARGET_ARCH" --show-bin-path)"
"$ICON_SCRIPT"
if [[ "$FORCE_REFRESH" == "1" ]]; then
  "$FETCH_MIHOMO_SCRIPT" --force-refresh "$ROOT_DIR/ThirdParty/mihomo/$MIHOMO_ARCH" "$TARGET_ARCH"
else
  "$FETCH_MIHOMO_SCRIPT" "$ROOT_DIR/ThirdParty/mihomo/$MIHOMO_ARCH" "$TARGET_ARCH"
fi

MIHOMO_BINARY="$ROOT_DIR/ThirdParty/mihomo/$MIHOMO_ARCH/mihomo"
if [[ ! -x "$MIHOMO_BINARY" ]]; then
  echo "mihomo binary not found: $MIHOMO_BINARY" >&2
  exit 1
fi
if [[ ! -x "$BUILD_DIR/CodexProxyDesktop" ]]; then
  echo "Desktop app binary not found: $BUILD_DIR/CodexProxyDesktop" >&2
  exit 1
fi
if [[ ! -x "$BUILD_DIR/codex-proxyd" ]]; then
  echo "Daemon binary not found: $BUILD_DIR/codex-proxyd" >&2
  exit 1
fi
if [[ "$BUNDLE_PROFILE" == "full" ]]; then
  for REMOTE_ARCH in linux-amd64 linux-arm64; do
    if [[ ! -x "$REMOTE_ARTIFACTS_DIR/$REMOTE_ARCH/codex-proxyd" ]]; then
      echo "Bundled Linux deployment package is missing codex-proxyd: $REMOTE_ARTIFACTS_DIR/$REMOTE_ARCH/codex-proxyd" >&2
      exit 1
    fi
    if [[ ! -x "$REMOTE_ARTIFACTS_DIR/$REMOTE_ARCH/mihomo" ]]; then
      echo "Bundled Linux deployment package is missing mihomo: $REMOTE_ARTIFACTS_DIR/$REMOTE_ARCH/mihomo" >&2
      exit 1
    fi
  done
fi

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"
if [[ "$BUNDLE_PROFILE" == "full" ]]; then
  mkdir -p "$REMOTE_RESOURCES_DIR"
fi

cp "$ROOT_DIR/Packaging/macOS/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Packaging/macOS/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$BUILD_DIR/CodexProxyDesktop" "$MACOS_DIR/CodexProxyDesktop"
cp "$BUILD_DIR/codex-proxyd" "$MACOS_DIR/codex-proxyd"
cp "$MIHOMO_BINARY" "$MACOS_DIR/mihomo"
chmod +x "$MACOS_DIR/CodexProxyDesktop" "$MACOS_DIR/codex-proxyd" "$MACOS_DIR/mihomo"
if [[ "$BUNDLE_PROFILE" == "full" ]]; then
  cp -R "$REMOTE_ARTIFACTS_DIR/linux-amd64" "$REMOTE_RESOURCES_DIR/linux-amd64"
  cp -R "$REMOTE_ARTIFACTS_DIR/linux-arm64" "$REMOTE_RESOURCES_DIR/linux-arm64"
  chmod +x \
    "$REMOTE_RESOURCES_DIR/linux-amd64/codex-proxyd" \
    "$REMOTE_RESOURCES_DIR/linux-amd64/mihomo" \
    "$REMOTE_RESOURCES_DIR/linux-arm64/codex-proxyd" \
    "$REMOTE_RESOURCES_DIR/linux-arm64/mihomo"
fi

cp "$BUILD_DIR/codex-proxyd" "$OUTPUT_DIR/codex-proxyd-macos"
chmod +x "$OUTPUT_DIR/codex-proxyd-macos"
cp "$MIHOMO_BINARY" "$OUTPUT_DIR/mihomo-macos"
chmod +x "$OUTPUT_DIR/mihomo-macos"

if [[ -f "$THIRD_PARTY_NOTICE" ]]; then
  cp "$THIRD_PARTY_NOTICE" "$RESOURCES_DIR/mihomo-third-party-notice.txt"
fi

if command -v codesign >/dev/null 2>&1; then
  codesign --force --deep --sign - "$APP_DIR" >/dev/null 2>&1 || true
fi

echo "Built app bundle ($TARGET_ARCH, $BUNDLE_PROFILE): $APP_DIR"
echo "Built daemon ($TARGET_ARCH): $OUTPUT_DIR/codex-proxyd-macos"
echo "Built mihomo ($TARGET_ARCH): $OUTPUT_DIR/mihomo-macos"
if [[ "$BUNDLE_PROFILE" == "full" ]]; then
  echo "Bundled Linux deployment packages: $REMOTE_RESOURCES_DIR"
else
  echo "Bundled Linux deployment packages: not included (local-only profile)"
fi
