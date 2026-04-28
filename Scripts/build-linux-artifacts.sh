#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
FETCH_MIHOMO_SCRIPT="$ROOT_DIR/Scripts/fetch-mihomo.sh"
FORCE_REFRESH=0
POSITIONAL_ARGS=()
source "$ROOT_DIR/Scripts/swift-static-linux-common.sh"

usage() {
  cat >&2 <<'EOF'
Usage: build-linux-artifacts.sh [--force-refresh] [output_root]
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

if [[ ${#POSITIONAL_ARGS[@]} -gt 1 ]]; then
  usage
  exit 1
fi

OUTPUT_ROOT="${POSITIONAL_ARGS[0]:-$ROOT_DIR/Artifacts}"

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "This script only builds bundled Linux deployment packages on macOS with Swift Static Linux SDK." >&2
  exit 1
fi

mkdir -p "$OUTPUT_ROOT"
OUTPUT_ROOT="$(cd "$OUTPUT_ROOT" && pwd)"
SWIFT_EXEC="$(codex_proxy_prepare_swift_static_linux_sdk)"

build_artifact() {
  local sdk_id="$1"
  local target_name="$2"
  local requested_arch="$3"
  local output_dir="$OUTPUT_ROOT/$target_name"

  mkdir -p "$output_dir"

  "$SWIFT_EXEC" build -c release --swift-sdk "$sdk_id" --product codex-proxyd
  local build_dir
  build_dir="$("$SWIFT_EXEC" build -c release --swift-sdk "$sdk_id" --show-bin-path)"

  cp "$build_dir/codex-proxyd" "$output_dir/codex-proxyd"
  chmod +x "$output_dir/codex-proxyd"
  if [[ "$FORCE_REFRESH" == "1" ]]; then
    "$FETCH_MIHOMO_SCRIPT" --force-refresh "$output_dir" "$requested_arch" "linux"
  else
    "$FETCH_MIHOMO_SCRIPT" "$output_dir" "$requested_arch" "linux"
  fi
  if [[ ! -x "$output_dir/codex-proxyd" || ! -x "$output_dir/mihomo" ]]; then
    echo "Incomplete Linux deployment package generated at $output_dir" >&2
    exit 1
  fi
  echo "Built Linux deployment package ($sdk_id): $output_dir"
}

build_artifact "$CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_X86_64" "linux-amd64" "x86_64"
build_artifact "$CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_ARM64" "linux-arm64" "arm64"
