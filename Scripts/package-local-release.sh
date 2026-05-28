#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
APP_BUILD_SCRIPT="$ROOT_DIR/Scripts/build-macos-app.sh"
DIST_DIR="$ROOT_DIR/Dist/local-only"
STAGING_DIR="$(mktemp -d)"
FORCE_REFRESH=0
ARCH_SELECTION="all"

usage() {
  cat >&2 <<'EOF'
Usage: package-local-release.sh [--force-refresh] [--host-only] [--arch host|arm64|x86_64|all]
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force-refresh)
      FORCE_REFRESH=1
      ;;
    --host-only)
      ARCH_SELECTION="host"
      ;;
    --arch)
      if [[ $# -lt 2 ]]; then
        echo "--arch requires one of: host, arm64, x86_64, all" >&2
        usage
        exit 1
      fi
      ARCH_SELECTION="$2"
      shift
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

normalize_arch_selection() {
  case "$1" in
    all|host|arm64|x86_64)
      echo "$1"
      ;;
    *)
      echo "Unsupported --arch value: $1 (expected: host, arm64, x86_64, or all)" >&2
      exit 1
      ;;
  esac
}

release_notes_for_version() {
  if [[ -n "${CODEX_PROXY_RELEASE_NOTES:-}" ]]; then
    printf "%s" "$CODEX_PROXY_RELEASE_NOTES"
    return
  fi

  local notes_path="$ROOT_DIR/Packaging/release-notes/$VERSION.md"
  if [[ -f "$notes_path" ]]; then
    python3 - "$notes_path" <<'PY'
import pathlib
import sys

text = pathlib.Path(sys.argv[1]).read_text(encoding="utf-8").strip()
lines = text.splitlines()
if lines and lines[0].lstrip().startswith("#"):
    lines = lines[1:]
print("\n".join(lines).strip())
PY
    return
  fi

  printf "%s" "根据自己电脑CPU系统架构下载对应软件包"
}

cleanup() {
  rm -rf "$STAGING_DIR"
}

trap cleanup EXIT

HOST_ARCH="$(normalize_target_arch "$(uname -m)")"
ARCH_SELECTION="$(normalize_arch_selection "$ARCH_SELECTION")"
OTHER_ARCH="arm64"
if [[ "$HOST_ARCH" == "arm64" ]]; then
  OTHER_ARCH="x86_64"
fi

TARGET_ARCHES=()
case "$ARCH_SELECTION" in
  all)
    TARGET_ARCHES=("$HOST_ARCH" "$OTHER_ARCH")
    ;;
  host)
    TARGET_ARCHES=("$HOST_ARCH")
    ;;
  arm64|x86_64)
    TARGET_ARCHES=("$ARCH_SELECTION")
    ;;
esac

mkdir -p "$DIST_DIR"

VERSION=""
ARM64_ZIP_PATH=""
X86_64_ZIP_PATH=""
APPCAST_PATH="$DIST_DIR/appcast.json"
for TARGET_ARCH in "${TARGET_ARCHES[@]}"; do
  OUTPUT_DIR="$DIST_DIR"
  if [[ "$TARGET_ARCH" != "$HOST_ARCH" ]]; then
    OUTPUT_DIR="$STAGING_DIR/$TARGET_ARCH"
  fi

  if [[ "$FORCE_REFRESH" == "1" ]]; then
    "$APP_BUILD_SCRIPT" --force-refresh release "$TARGET_ARCH" "$OUTPUT_DIR" local-only
  else
    "$APP_BUILD_SCRIPT" release "$TARGET_ARCH" "$OUTPUT_DIR" local-only
  fi

  if [[ -z "$VERSION" ]]; then
    VERSION="$("$OUTPUT_DIR/codex-proxyd-macos" --release-version)"
  fi

  ZIP_PATH="$DIST_DIR/AICodingProxy-macos-$TARGET_ARCH-$VERSION-local.zip"
  rm -f "$ZIP_PATH"
  ditto -c -k --keepParent "$OUTPUT_DIR/AI Coding Proxy.app" "$ZIP_PATH"
  if [[ "$TARGET_ARCH" == "arm64" ]]; then
    ARM64_ZIP_PATH="$ZIP_PATH"
  else
    X86_64_ZIP_PATH="$ZIP_PATH"
  fi

  echo "Packaged local-only zip ($TARGET_ARCH): $ZIP_PATH"
done

if [[ "$ARCH_SELECTION" != "all" ]]; then
  rm -f "$APPCAST_PATH"
  echo "Skipped appcast generation for single-architecture local package (--arch $ARCH_SELECTION)."
  exit 0
fi

if [[ -z "$ARM64_ZIP_PATH" || -z "$X86_64_ZIP_PATH" ]]; then
  echo "Unable to create appcast.json because one or more macOS zips are missing." >&2
  exit 1
fi

RELEASE_TAG="${CODEX_PROXY_RELEASE_TAG:-$VERSION}"
RELEASE_BASE_URL="${CODEX_PROXY_RELEASE_BASE_URL:-https://github.com/shiguanghuxian/aI-coding-proxy/releases/download/$RELEASE_TAG}"
RELEASE_PAGE_URL="${CODEX_PROXY_RELEASE_PAGE_URL:-https://github.com/shiguanghuxian/aI-coding-proxy/releases/tag/$RELEASE_TAG}"
RELEASE_NOTES="$(release_notes_for_version)"
PUBLISHED_AT="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

APPCAST_PATH="$APPCAST_PATH" \
VERSION="$VERSION" \
RELEASE_TAG="$RELEASE_TAG" \
RELEASE_PAGE_URL="$RELEASE_PAGE_URL" \
RELEASE_BASE_URL="$RELEASE_BASE_URL" \
RELEASE_NOTES="$RELEASE_NOTES" \
PUBLISHED_AT="$PUBLISHED_AT" \
ARM64_ZIP_PATH="$ARM64_ZIP_PATH" \
X86_64_ZIP_PATH="$X86_64_ZIP_PATH" \
python3 <<'PY'
import json
import os
import pathlib
import subprocess

def sha256(path: pathlib.Path) -> str:
    output = subprocess.check_output(["shasum", "-a", "256", str(path)], text=True)
    return output.split()[0]

base_url = os.environ["RELEASE_BASE_URL"].rstrip("/")
assets = {}
for arch, env_key in (("arm64", "ARM64_ZIP_PATH"), ("x86_64", "X86_64_ZIP_PATH")):
    path = pathlib.Path(os.environ[env_key])
    name = path.name
    assets[arch] = {
        "name": name,
        "download_url": f"{base_url}/{name}",
        "size": path.stat().st_size,
        "sha256": sha256(path),
    }

payload = {
    "version": os.environ["VERSION"],
    "tag_name": os.environ["RELEASE_TAG"],
    "title": os.environ["VERSION"],
    "published_at": os.environ["PUBLISHED_AT"],
    "release_notes": os.environ["RELEASE_NOTES"],
    "html_url": os.environ["RELEASE_PAGE_URL"],
    "assets": assets,
}

pathlib.Path(os.environ["APPCAST_PATH"]).write_text(
    json.dumps(payload, ensure_ascii=False, indent=2, sort_keys=True) + "\n",
    encoding="utf-8",
)
PY

echo "Generated update manifest: $APPCAST_PATH"
