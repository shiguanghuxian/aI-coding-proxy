#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
MLX_ROOT="$ROOT_DIR/.build/checkouts/mlx-swift/Source/Cmlx/mlx"
KERNEL_DIR="$MLX_ROOT/mlx/backend/metal/kernels"
OUT_DIR="${CODEX_PROXY_MLX_METALLIB_DIR:-$ROOT_DIR/.build/codex-proxy-mlx-metallib}"
OUT_FILE="$OUT_DIR/mlx.metallib"
FINGERPRINT_FILE="$OUT_FILE.fingerprint"
MIN_MACOS_VERSION="14.0"
STAGING_DIR=""

cleanup() {
  if [[ -n "$STAGING_DIR" ]]; then
    rm -rf "$STAGING_DIR"
  fi
}
trap cleanup EXIT

fail_toolchain() {
  cat >&2 <<'MSG'
缺少 Apple Metal Toolchain，无法生成 mlx.metallib。
请运行：xcodebuild -downloadComponent MetalToolchain
如果这是 CI 环境，请先在构建机安装 Metal Toolchain，再重新打包 AI Coding Proxy。
MSG
  exit 1
}

version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    split(a, av, ".")
    split(b, bv, ".")
    for (i = 1; i <= 3; i++) {
      ai = av[i] == "" ? 0 : av[i] + 0
      bi = bv[i] == "" ? 0 : bv[i] + 0
      if (ai > bi) { exit 0 }
      if (ai < bi) { exit 1 }
    }
    exit 0
  }'
}

hash_kernel_inputs() {
  (
    cd "$MLX_ROOT"
    find mlx/backend/metal/kernels -type f \( -name '*.metal' -o -name '*.h' -o -name '*.hpp' \) -print |
      LC_ALL=C sort |
      while IFS= read -r file; do
        shasum -a 256 "$file"
      done
  ) | shasum -a 256 | awk '{print $1}'
}

if [[ "$(uname -s)" != "Darwin" ]]; then
  echo "MLX Metal library can only be built on macOS." >&2
  exit 1
fi

if [[ ! -d "$KERNEL_DIR" ]]; then
  echo "找不到 MLX Metal kernels：$KERNEL_DIR" >&2
  echo "请先运行 swift build，让 SwiftPM 拉取 mlx-swift 依赖。" >&2
  exit 1
fi

METAL_TOOL="$(/usr/bin/xcrun -sdk macosx -find metal 2>/dev/null)" || fail_toolchain
METALLIB_TOOL="$(/usr/bin/xcrun -sdk macosx -find metallib 2>/dev/null)" || fail_toolchain
/usr/bin/xcrun -sdk macosx metal -help >/dev/null 2>&1 || fail_toolchain
/usr/bin/xcrun -sdk macosx metallib -help >/dev/null 2>&1 || fail_toolchain

SDK_VERSION="$(/usr/bin/xcrun -sdk macosx --show-sdk-version)"
if ! version_ge "$SDK_VERSION" "$MIN_MACOS_VERSION"; then
  echo "MLX Metal 需要 macOS SDK >= $MIN_MACOS_VERSION，当前 SDK：$SDK_VERSION" >&2
  exit 1
fi

METAL_VERSION="$(printf '__METAL_VERSION__\n' | /usr/bin/xcrun -sdk macosx metal -mmacosx-version-min="$MIN_MACOS_VERSION" -E -x metal -P - | tail -1 | tr -d '\n[:space:]')"
if [[ ! "$METAL_VERSION" =~ ^[0-9]+$ ]]; then
  echo "无法检测 Metal 语言版本：$METAL_VERSION" >&2
  exit 1
fi

kernels=(
  "arg_reduce"
  "conv"
  "gemv"
  "layer_norm"
  "random"
  "rms_norm"
  "rope"
  "scaled_dot_product_attention"
)

if [[ "$METAL_VERSION" -ge 320 ]]; then
  kernels+=("fence")
fi

kernels+=(
  "arange"
  "binary"
  "binary_two"
  "copy"
  "fft"
  "reduce"
  "quantized"
  "fp_quantized"
  "scan"
  "softmax"
  "logsumexp"
  "sort"
  "ternary"
  "unary"
  "steel/conv/kernels/steel_conv"
  "steel/conv/kernels/steel_conv_3d"
  "steel/conv/kernels/steel_conv_general"
  "steel/gemm/kernels/steel_gemm_fused"
  "steel/gemm/kernels/steel_gemm_gather"
  "steel/gemm/kernels/steel_gemm_masked"
  "steel/gemm/kernels/steel_gemm_splitk"
  "steel/gemm/kernels/steel_gemm_segmented"
  "gemv_masked"
  "steel/attn/kernels/steel_attention"
)

if [[ "$METAL_VERSION" -ge 400 ]] && version_ge "$SDK_VERSION" "26.2"; then
  kernels+=(
    "steel/gemm/kernels/steel_gemm_fused_nax"
    "steel/gemm/kernels/steel_gemm_gather_nax"
    "steel/gemm/kernels/steel_gemm_splitk_nax"
    "quantized_nax"
    "fp_quantized_nax"
    "steel/attn/kernels/steel_attention_nax"
  )
fi

compile_flags=(
  "-x"
  "metal"
  "-Wall"
  "-Wextra"
  "-fno-fast-math"
  "-Wno-c++17-extensions"
  "-Wno-c++20-extensions"
  "-mmacosx-version-min=$MIN_MACOS_VERSION"
  "-c"
  "-I$MLX_ROOT"
)

MLX_REVISION="$(git -C "$ROOT_DIR/.build/checkouts/mlx-swift" rev-parse HEAD 2>/dev/null || echo "unknown")"
KERNEL_INPUT_HASH="$(hash_kernel_inputs)"
CURRENT_FINGERPRINT="$(
  {
    printf 'min_macos_version=%s\n' "$MIN_MACOS_VERSION"
    printf 'sdk_version=%s\n' "$SDK_VERSION"
    printf 'metal_version=%s\n' "$METAL_VERSION"
    printf 'metal_tool=%s\n' "$METAL_TOOL"
    printf 'metallib_tool=%s\n' "$METALLIB_TOOL"
    printf 'mlx_revision=%s\n' "$MLX_REVISION"
    printf 'kernel_input_hash=%s\n' "$KERNEL_INPUT_HASH"
    printf 'compile_flags:\n'
    printf '%s\n' "${compile_flags[@]}"
    printf 'kernels:\n'
    printf '%s\n' "${kernels[@]}"
  } | shasum -a 256 | awk '{print $1}'
)"

if [[ "${CODEX_PROXY_REBUILD_MLX_METALLIB:-0}" != "1" ]] &&
   [[ -s "$OUT_FILE" ]] &&
   [[ -f "$FINGERPRINT_FILE" ]] &&
   [[ "$(cat "$FINGERPRINT_FILE")" == "$CURRENT_FINGERPRINT" ]]; then
  echo "复用已缓存 MLX Metal library：$OUT_FILE"
  exit 0
fi

rm -rf "$OUT_DIR"
mkdir -p "$OUT_DIR"
STAGING_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codex-proxy-mlx-metallib.XXXXXX")"
AIR_DIR="$STAGING_DIR/air"
STAGING_OUT_FILE="$STAGING_DIR/mlx.metallib"
mkdir -p "$AIR_DIR"

air_files=()
for kernel in "${kernels[@]}"; do
  src="$KERNEL_DIR/$kernel.metal"
  if [[ ! -f "$src" ]]; then
    echo "缺少 MLX Metal kernel：$src" >&2
    exit 1
  fi
  target="${kernel//\//_}"
  air="$AIR_DIR/$target.air"
  echo "编译 Metal kernel：$kernel"
  /usr/bin/xcrun -sdk macosx metal \
    "${compile_flags[@]}" \
    "$src" \
    -o "$air"
  air_files+=("$air")
done

/usr/bin/xcrun -sdk macosx metallib "${air_files[@]}" -o "$STAGING_OUT_FILE"
cp "$STAGING_OUT_FILE" "$OUT_FILE"
printf '%s\n' "$CURRENT_FINGERPRINT" > "$FINGERPRINT_FILE"
echo "已生成 $OUT_FILE"
