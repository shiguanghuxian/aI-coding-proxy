#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
source "$ROOT_DIR/Scripts/swift-static-linux-common.sh"

SWIFT_EXEC="$(codex_proxy_prepare_swift_static_linux_sdk)"
echo "Using Swift toolchain: $SWIFT_EXEC"
"$SWIFT_EXEC" --version
"$SWIFT_EXEC" sdk list | grep -E "${CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_BUNDLE_NAME}|x86_64-swift-linux-musl|aarch64-swift-linux-musl" || true
