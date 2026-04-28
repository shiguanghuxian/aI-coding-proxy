#!/usr/bin/env bash

CODEX_PROXY_SWIFT_TOOLCHAIN_VERSION="${CODEX_PROXY_SWIFT_TOOLCHAIN_VERSION:-6.3.1}"
CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_URL="${CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_URL:-https://download.swift.org/swift-6.3.1-release/static-sdk/swift-6.3.1-RELEASE/swift-6.3.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz}"
CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_BUNDLE_NAME="${CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_BUNDLE_NAME:-swift-6.3.1-RELEASE_static-linux-0.1.0}"
CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_CHECKSUM="${CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_CHECKSUM:-fac05271c1f7d060bd203240ce5251d5ca902d30ac899f553765dbb3a88b97ad}"
CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_X86_64="${CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_X86_64:-x86_64-swift-linux-musl}"
CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_ARM64="${CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_ARM64:-aarch64-swift-linux-musl}"

codex_proxy_swiftly_home_dir() {
  printf '%s\n' "${SWIFTLY_HOME_DIR:-$HOME/.swiftly}"
}

codex_proxy_swiftly_bin() {
  printf '%s/bin/swiftly\n' "$(codex_proxy_swiftly_home_dir)"
}

codex_proxy_swift_bin() {
  printf '%s/bin/swift\n' "$(codex_proxy_swiftly_home_dir)"
}

codex_proxy_print_swift_toolchain_help() {
  cat >&2 <<EOF
Swift.org toolchain ${CODEX_PROXY_SWIFT_TOOLCHAIN_VERSION} is required to build bundled Linux deployment packages without Docker.

Install Swiftly first:
  curl -O https://download.swift.org/swiftly/darwin/swiftly.pkg && \\
  installer -pkg swiftly.pkg -target CurrentUserHomeDirectory && \\
  ~/.swiftly/bin/swiftly init --quiet-shell-followup && \\
  . "\${SWIFTLY_HOME_DIR:-\$HOME/.swiftly}/env.sh" && \\
  hash -r

Then install and use the pinned toolchain:
  ~/.swiftly/bin/swiftly install --use ${CODEX_PROXY_SWIFT_TOOLCHAIN_VERSION}

If you already have a matching Swift.org toolchain elsewhere, rerun with:
  SWIFT_EXEC=/absolute/path/to/swift ./Scripts/build-linux-artifacts.sh
EOF
}

codex_proxy_resolve_swift_exec() {
  if [[ -n "${SWIFT_EXEC:-}" ]]; then
    printf '%s\n' "$SWIFT_EXEC"
    return 0
  fi

  local swiftly_bin swift_bin
  swiftly_bin="$(codex_proxy_swiftly_bin)"
  swift_bin="$(codex_proxy_swift_bin)"

  if [[ -x "$swiftly_bin" ]]; then
    "$swiftly_bin" install --use "$CODEX_PROXY_SWIFT_TOOLCHAIN_VERSION" >/dev/null
    printf '%s\n' "$swift_bin"
    return 0
  fi

  if command -v swift >/dev/null 2>&1; then
    local resolved
    resolved="$(command -v swift)"
    if [[ "$resolved" == *"/.swiftly/bin/swift" ]]; then
      printf '%s\n' "$resolved"
      return 0
    fi
  fi

  codex_proxy_print_swift_toolchain_help
  return 1
}

codex_proxy_validate_swift_exec() {
  local swift_exec="$1"

  if [[ "$swift_exec" != */* ]]; then
    swift_exec="$(command -v "$swift_exec")"
  fi
  [[ -x "$swift_exec" ]]

  local version_output
  version_output="$("$swift_exec" --version 2>&1)"
  if [[ "$version_output" != *"${CODEX_PROXY_SWIFT_TOOLCHAIN_VERSION}"* ]]; then
    cat >&2 <<EOF
Expected Swift.org toolchain ${CODEX_PROXY_SWIFT_TOOLCHAIN_VERSION}, but got:
$version_output
EOF
    return 1
  fi

  if [[ -z "${SWIFT_EXEC:-}" && "$swift_exec" != *"/.swiftly/bin/swift" ]]; then
    cat >&2 <<EOF
Resolved swift binary is not managed by Swiftly:
  $swift_exec

Set SWIFT_EXEC to a matching Swift.org toolchain binary, or install Swiftly first.
EOF
    return 1
  fi
}

codex_proxy_ensure_static_linux_sdk() {
  local swift_exec="$1"
  local sdk_list
  sdk_list="$("$swift_exec" sdk list 2>/dev/null || true)"

  if [[ "$sdk_list" == *"$CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_BUNDLE_NAME"* ]]; then
    return 0
  fi

  if [[ "$sdk_list" == *"$CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_X86_64"* && "$sdk_list" == *"$CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_ARM64"* ]]; then
    return 0
  fi

  echo "Installing Swift Static Linux SDK for ${CODEX_PROXY_SWIFT_TOOLCHAIN_VERSION}..." >&2
  "$swift_exec" sdk install \
    "$CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_URL" \
    --checksum "$CODEX_PROXY_SWIFT_STATIC_LINUX_SDK_CHECKSUM" >&2
}

codex_proxy_require_swift_toolchain() {
  local swift_exec
  swift_exec="$(codex_proxy_resolve_swift_exec)" || return 1
  codex_proxy_validate_swift_exec "$swift_exec" || return 1
  printf '%s\n' "$swift_exec"
}

codex_proxy_prepare_swift_static_linux_sdk() {
  local swift_exec
  swift_exec="$(codex_proxy_require_swift_toolchain)" || return 1
  codex_proxy_ensure_static_linux_sdk "$swift_exec" || return 1
  printf '%s\n' "$swift_exec"
}
