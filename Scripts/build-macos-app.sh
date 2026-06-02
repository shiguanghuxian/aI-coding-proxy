#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ICON_SCRIPT="$ROOT_DIR/Scripts/render-app-icon.sh"
FETCH_MIHOMO_SCRIPT="$ROOT_DIR/Scripts/fetch-mihomo.sh"
BUILD_LINUX_ARTIFACTS_SCRIPT="$ROOT_DIR/Scripts/build-linux-artifacts.sh"
BUILD_MLX_METALLIB_SCRIPT="$ROOT_DIR/Scripts/build-mlx-metallib.sh"
THIRD_PARTY_NOTICE="$ROOT_DIR/Packaging/macOS/mihomo-third-party-notice.txt"
REMOTE_ARTIFACTS_DIR="${CODEX_PROXY_REMOTE_ARTIFACTS_DIR:-$ROOT_DIR/Artifacts}"
BUILD_CACHE_DIR="${CODEX_PROXY_BUILD_CACHE_DIR:-$ROOT_DIR/.build/codex-proxy-build-cache}"
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

SWIFT_BUILD_ARGS=(build -c "$CONFIGURATION" --arch "$TARGET_ARCH" --resolver-fingerprint-checking warn)
MLX_OCR_HELPER_CACHE_DIR="$BUILD_CACHE_DIR/mlx-ocr-helper/$TARGET_ARCH/$CONFIGURATION"
MLX_OCR_HELPER_CACHE_BIN="$MLX_OCR_HELPER_CACHE_DIR/CodexProxyMLXOCRServer"
MLX_OCR_HELPER_CACHE_FINGERPRINT="$MLX_OCR_HELPER_CACHE_DIR/CodexProxyMLXOCRServer.fingerprint"

clean_swiftpm_arch_build_cache() {
  echo "Cleaning SwiftPM $CONFIGURATION cache for $TARGET_ARCH before retry..." >&2
  rm -rf \
    "$ROOT_DIR/.build/$TARGET_ARCH-apple-macosx/$CONFIGURATION" \
    "$ROOT_DIR/.build/$CONFIGURATION.yaml" \
    "$ROOT_DIR/.build/build.db"
}

run_swift_build_for_bundle() {
  local log_file
  log_file="$(mktemp "${TMPDIR:-/tmp}/codex-proxy-swift-build.XXXXXX")"
  if "$SWIFT_EXEC" "${SWIFT_BUILD_ARGS[@]}" "$@" 2>&1 | tee "$log_file"; then
    rm -f "$log_file"
    return 0
  fi

  local status="${PIPESTATUS[0]}"
  if grep -q "missing required module '_NumericsShims'" "$log_file"; then
    echo "SwiftPM reported missing _NumericsShims; retrying once after clearing stale arch build cache." >&2
    rm -f "$log_file"
    clean_swiftpm_arch_build_cache
    "$SWIFT_EXEC" "${SWIFT_BUILD_ARGS[@]}" "$@"
    return $?
  fi

  rm -f "$log_file"
  return "$status"
}

hash_mlx_ocr_helper_inputs() {
  (
    cd "$ROOT_DIR"
    for file in Package.swift Package.resolved; do
      if [[ -f "$file" ]]; then
        shasum -a 256 "$file"
      fi
    done
    if [[ -d Sources/CodexProxyMLXOCRServer ]]; then
      find Sources/CodexProxyMLXOCRServer -type f -print |
        LC_ALL=C sort |
        while IFS= read -r file; do
          shasum -a 256 "$file"
        done
    fi
  ) | shasum -a 256 | awk '{print $1}'
}

hash_mlx_dependency_revisions() {
  (
    for checkout in mlx-swift mlx-swift-lm swift-transformers; do
      checkout_dir="$ROOT_DIR/.build/checkouts/$checkout"
      printf 'checkout=%s\n' "$checkout"
      if [[ -d "$checkout_dir/.git" ]]; then
        git -C "$checkout_dir" rev-parse HEAD 2>/dev/null || true
        git -C "$checkout_dir" status --porcelain 2>/dev/null || true
      else
        printf 'missing\n'
      fi
    done
  ) | shasum -a 256 | awk '{print $1}'
}

mlx_ocr_helper_fingerprint() {
  local swift_version sdk_version source_hash dependency_hash
  swift_version="$("$SWIFT_EXEC" --version 2>&1)"
  sdk_version="$(/usr/bin/xcrun -sdk macosx --show-sdk-version 2>/dev/null || echo "unknown")"
  source_hash="$(hash_mlx_ocr_helper_inputs)"
  dependency_hash="$(hash_mlx_dependency_revisions)"
  {
    printf 'target_arch=%s\n' "$TARGET_ARCH"
    printf 'configuration=%s\n' "$CONFIGURATION"
    printf 'sdk_version=%s\n' "$sdk_version"
    printf 'swift_exec=%s\n' "$SWIFT_EXEC"
    printf 'swift_version:\n%s\n' "$swift_version"
    printf 'source_hash=%s\n' "$source_hash"
    printf 'mlx_dependency_hash=%s\n' "$dependency_hash"
  } | shasum -a 256 | awk '{print $1}'
}

prepare_mlx_ocr_helper() {
  local build_dir="$1"
  local build_helper="$build_dir/CodexProxyMLXOCRServer"
  local current_fingerprint
  current_fingerprint="$(mlx_ocr_helper_fingerprint)"

  mkdir -p "$build_dir"
  if [[ "${CODEX_PROXY_REBUILD_MLX_OCR_HELPER:-0}" != "1" ]] &&
     [[ -x "$MLX_OCR_HELPER_CACHE_BIN" ]] &&
     [[ -f "$MLX_OCR_HELPER_CACHE_FINGERPRINT" ]] &&
     [[ "$(cat "$MLX_OCR_HELPER_CACHE_FINGERPRINT")" == "$current_fingerprint" ]]; then
    cp "$MLX_OCR_HELPER_CACHE_BIN" "$build_helper"
    chmod +x "$build_helper"
    echo "Reusing cached Local MLX OCR helper: $MLX_OCR_HELPER_CACHE_BIN"
    return 0
  fi

  if [[ "${CODEX_PROXY_REBUILD_MLX_OCR_HELPER:-0}" == "1" ]]; then
    echo "Rebuilding Local MLX OCR helper cache because CODEX_PROXY_REBUILD_MLX_OCR_HELPER=1"
  else
    echo "Building Local MLX OCR helper; cache miss for $TARGET_ARCH/$CONFIGURATION"
  fi

  run_swift_build_for_bundle --product CodexProxyMLXOCRServer
  if [[ ! -x "$build_helper" ]]; then
    echo "Local MLX OCR helper build output not found: $build_helper" >&2
    exit 1
  fi

  mkdir -p "$MLX_OCR_HELPER_CACHE_DIR"
  cp "$build_helper" "$MLX_OCR_HELPER_CACHE_BIN"
  chmod +x "$MLX_OCR_HELPER_CACHE_BIN"
  printf '%s\n' "$current_fingerprint" > "$MLX_OCR_HELPER_CACHE_FINGERPRINT"
  echo "Cached Local MLX OCR helper: $MLX_OCR_HELPER_CACHE_BIN"
}

resolve_swift_stdlib_tool() {
  local swift_exec_path swift_bin_dir tool
  if [[ "$SWIFT_EXEC" == */* ]]; then
    swift_exec_path="$SWIFT_EXEC"
  else
    swift_exec_path="$(command -v "$SWIFT_EXEC")"
  fi

  swift_bin_dir="$(cd "$(dirname "$swift_exec_path")" && pwd)"
  tool="$swift_bin_dir/swift-stdlib-tool"
  if [[ -x "$tool" ]]; then
    printf '%s\n' "$tool"
    return 0
  fi

  xcrun --find swift-stdlib-tool
}

swift_macos_runtime_library_path() {
  "$SWIFT_EXEC" -print-target-info | python3 -c '
import json
import sys

payload = json.load(sys.stdin)
for path in payload.get("paths", {}).get("runtimeLibraryPaths", []):
    if path != "/usr/lib/swift" and path.endswith("/macosx"):
        print(path)
        break
'
}

swift_rpaths_for_binary() {
  local binary="$1"
  otool -l "$binary" | awk '
    $1 == "cmd" && $2 == "LC_RPATH" { in_rpath = 1; next }
    in_rpath && $1 == "path" { print $2; in_rpath = 0 }
  '
}

is_external_swift_toolchain_rpath() {
  local rpath="$1"
  [[ "$rpath" == *".xctoolchain/usr/lib/swift"* ]]
}

embed_swift_runtime_libraries() {
  local frameworks_dir="$1"
  shift

  local swift_runtime_library_path swift_stdlib_tool
  swift_runtime_library_path="$(swift_macos_runtime_library_path)"
  if [[ -z "$swift_runtime_library_path" || ! -d "$swift_runtime_library_path" ]]; then
    echo "Unable to locate Swift macOS runtime libraries for $SWIFT_EXEC." >&2
    exit 1
  fi

  swift_stdlib_tool="$(resolve_swift_stdlib_tool)"
  "$swift_stdlib_tool" \
    --copy \
    --platform macosx \
    --destination "$frameworks_dir" \
    --source-libraries "$swift_runtime_library_path" \
    "$@"
}

prepare_embedded_swift_runtime() {
  local frameworks_dir="$1"
  shift

  local scan_args=()
  local binary rpath
  for binary in "$@"; do
    scan_args+=(--scan-executable "$binary")
  done

  embed_swift_runtime_libraries "$frameworks_dir" "${scan_args[@]}"

  for binary in "$@"; do
    install_name_tool -add_rpath "@loader_path/../Frameworks" "$binary" 2>/dev/null || true
    while IFS= read -r rpath; do
      if is_external_swift_toolchain_rpath "$rpath"; then
        install_name_tool -delete_rpath "$rpath" "$binary" 2>/dev/null || true
      fi
    done < <(swift_rpaths_for_binary "$binary")
  done

  for binary in "$@"; do
    while IFS= read -r rpath; do
      if is_external_swift_toolchain_rpath "$rpath"; then
        echo "Swift toolchain rpath remains in $binary: $rpath" >&2
        exit 1
      fi
    done < <(swift_rpaths_for_binary "$binary")
  done
}

mkdir -p "$OUTPUT_DIR"
OUTPUT_DIR="$(cd "$OUTPUT_DIR" && pwd)"
APP_DIR="$OUTPUT_DIR/AI Coding Proxy.app"
MACOS_DIR="$APP_DIR/Contents/MacOS"
HELPERS_DIR="$APP_DIR/Contents/Helpers"
FRAMEWORKS_DIR="$APP_DIR/Contents/Frameworks"
RESOURCES_DIR="$APP_DIR/Contents/Resources"
REMOTE_RESOURCES_DIR="$RESOURCES_DIR/RemoteArtifacts"

if [[ "$BUNDLE_PROFILE" == "full" && "${CODEX_PROXY_SKIP_REMOTE_ARTIFACT_PREPARE:-0}" != "1" ]]; then
  if [[ "$FORCE_REFRESH" == "1" ]]; then
    "$BUILD_LINUX_ARTIFACTS_SCRIPT" --force-refresh "$REMOTE_ARTIFACTS_DIR"
  else
    "$BUILD_LINUX_ARTIFACTS_SCRIPT" "$REMOTE_ARTIFACTS_DIR"
  fi
fi

run_swift_build_for_bundle --product CodexProxyDesktop
run_swift_build_for_bundle --product codex-proxyd
BUILD_DIR="$("$SWIFT_EXEC" "${SWIFT_BUILD_ARGS[@]}" --show-bin-path)"
prepare_mlx_ocr_helper "$BUILD_DIR"
"$BUILD_MLX_METALLIB_SCRIPT"
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
if [[ ! -x "$BUILD_DIR/CodexProxyMLXOCRServer" ]]; then
  echo "Local MLX OCR helper not found: $BUILD_DIR/CodexProxyMLXOCRServer" >&2
  exit 1
fi
MLX_METALLIB="$ROOT_DIR/.build/codex-proxy-mlx-metallib/mlx.metallib"
if [[ ! -f "$MLX_METALLIB" ]]; then
  echo "MLX Metal library not found: $MLX_METALLIB" >&2
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
mkdir -p "$MACOS_DIR" "$HELPERS_DIR" "$FRAMEWORKS_DIR" "$RESOURCES_DIR"
if [[ "$BUNDLE_PROFILE" == "full" ]]; then
  mkdir -p "$REMOTE_RESOURCES_DIR"
fi

cp "$ROOT_DIR/Packaging/macOS/Info.plist" "$APP_DIR/Contents/Info.plist"
cp "$ROOT_DIR/Packaging/macOS/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"
cp "$BUILD_DIR/CodexProxyDesktop" "$MACOS_DIR/CodexProxyDesktop"
cp "$BUILD_DIR/codex-proxyd" "$MACOS_DIR/codex-proxyd"
cp "$BUILD_DIR/CodexProxyMLXOCRServer" "$HELPERS_DIR/CodexProxyMLXOCRServer"
cp "$MLX_METALLIB" "$HELPERS_DIR/mlx.metallib"
cp "$MIHOMO_BINARY" "$MACOS_DIR/mihomo"
chmod +x \
  "$MACOS_DIR/CodexProxyDesktop" \
  "$MACOS_DIR/codex-proxyd" \
  "$MACOS_DIR/mihomo" \
  "$HELPERS_DIR/CodexProxyMLXOCRServer"
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

prepare_embedded_swift_runtime \
  "$FRAMEWORKS_DIR" \
  "$MACOS_DIR/CodexProxyDesktop" \
  "$MACOS_DIR/codex-proxyd" \
  "$HELPERS_DIR/CodexProxyMLXOCRServer"

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
