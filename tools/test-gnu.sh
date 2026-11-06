#!/bin/bash
# LongCut / windows-gnu 单元测试入口。所有路径都在项目内，不写 C 盘。
#
#   bash tools/test-gnu.sh              # batch-a（纯逻辑 crate，默认）
#   bash tools/test-gnu.sh batch-b      # native / FFI crate
#   LONGCUT_TEST_THREADS=0 bash tools/test-gnu.sh all
#
# 三个必须内联的环境细节，缺一个就会得到假红：
# 1. 运行时 DLL：测试二进制生成在 target-gnu/.../debug/deps/ 下，旁边没有
#    FFmpeg/MinGW DLL。直接跑会 0xc0000135 STATUS_DLL_NOT_FOUND。把已验证的
#    便携包目录放进 PATH（与 release 同目录加载不同，测试必须靠 PATH）。
# 2. TMP/TEMP：上游测试用 std::env::temp_dir() 写临时 mp4。指回项目内，
#    既满足「不写 C 盘」，也避免跨机器路径差异。
# 3. --test-threads：concat-export 的若干预览测试在默认并行度下会互相干扰
#    （见 docs/TEST-REPORT-2026-11-06.md §2，串行 30/30、并行 29/31）。
#    默认串行；LONGCUT_TEST_THREADS=0 可恢复 libtest 默认并行做诊断。
set -eo pipefail

PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
P="$(cygpath -u "$PRJ")"
MODE="${1:-batch-a}"
THREADS="${LONGCUT_TEST_THREADS:-1}"
LOGDIR="$P/tools/_tmp/test-logs"
mkdir -p "$LOGDIR"

export CARGO_HOME="$PRJ/.cargo"
export RUSTUP_HOME="$PRJ/.rustup"
export RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-gnu
export CARGO_TARGET_DIR="$PRJ/src/target-gnu"
export CC="$PRJ/tools/mingw/mingw64/bin/gcc.exe"
export CXX="$PRJ/tools/mingw/mingw64/bin/g++.exe"
# .cargo/config.toml 的 target linker 是构建机绝对路径（Cargo 不支持
# config 内变量插值）。换机 / 换目录 / GH runner 上必须覆盖，否则 cargo
# 会去调一个根本不存在的 gcc.exe；与 build-gnu.sh 的判定保持一致。
CFG_LINKER=$(sed -n 's/^linker = "\(.*\)"/\1/p' "$PRJ/.cargo/config.toml" 2>/dev/null | head -1)
if [ -n "$CFG_LINKER" ] && [ "$CFG_LINKER" != "$CC" ]; then
  export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="$CC"
  echo "[test] linker override: config=$CFG_LINKER -> $CC"
else
  echo "[test] linker from config: ${CFG_LINKER:-<unset>}"
fi
export FFMPEG_DIR="$(cat "$PRJ/tools/ffmpeg/FFMPEG_DIR.txt" 2>/dev/null)"
MW="$PRJ/tools/mingw/mingw64"
export BINDGEN_EXTRA_CLANG_ARGS="--target=x86_64-w64-windows-gnu -I$MW/x86_64-w64-mingw32/include -I$MW/include"
export LIBCLANG_PATH="$PRJ/tools/llvm/bin"
# 与 build-gnu.sh 完全一致：RUSTFLAGS 是 fingerprint 的一部分，改动会全量重编。
# dlltool 必须由 $PRJ 推导（config 里那台机器的路径在别处无效）；save-temps
# 只为绕 360 删除拦截，CI runner 没有 360，可置 0 省下十几 GB 中间文件。
DLLTOOL_FLAG="-C dlltool=$PRJ/tools/mingw/mingw64/bin/dlltool.exe"
if [ "${LONGCUT_SAVE_TEMPS:-1}" = "1" ]; then
  export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }$DLLTOOL_FLAG -C save-temps"
else
  export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }$DLLTOOL_FLAG"
fi
export PATH="$P/dist/LongCut-win64-gnu:$P/.cargo/bin:$P/tools/mingw/mingw64/bin:$(cygpath -u "$PRJ/tools/cmake-dist/cmake-3.30.5-windows-x86_64/bin"):$(cygpath -u "$PRJ/tools/llvm/bin"):$PATH"
export TMP="$PRJ/tools/_tmp" TEMP="$PRJ/tools/_tmp" TMPDIR="$P/tools/_tmp"

BATCH_A=(concat-core concat-project concat-effects concat-text concat-api concat-mcp concat-export)
# 移动端 crate（concat-mobile / concat-android）是平台特定代码，windows-gnu
# 上多数测试被 cfg 排除；主 GUI crate concat 由 --smoke 端到端覆盖。
BATCH_B=(concat-media concat-host concat-vision concat-speech concat-render concat-server concat-cli)

case "$MODE" in
  batch-a) CRATES=("${BATCH_A[@]}") ;;
  batch-b) CRATES=("${BATCH_B[@]}") ;;
  all)     CRATES=("${BATCH_A[@]}" "${BATCH_B[@]}") ;;
  *) echo "[test] unknown mode: $MODE (batch-a | batch-b | all)" >&2; exit 2 ;;
esac

ARGS=()
for c in "${CRATES[@]}"; do ARGS+=(-p "$c"); done
HARNESS=()
if [ "$THREADS" != "0" ]; then HARNESS=(-- --test-threads="$THREADS"); fi

LOG="$LOGDIR/${MODE}-$(date -u +%Y%m%dT%H%M%SZ).log"
echo "[test] mode=$MODE crates=${#CRATES[@]} threads=$THREADS log=$LOG"
cd "$PRJ/src"
set +e
"$CARGO_HOME/bin/cargo.exe" test --target x86_64-pc-windows-gnu -j 2 --no-fail-fast \
  "${ARGS[@]}" "${HARNESS[@]}" 2>&1 | tee "$LOG"
RC=${PIPESTATUS[0]}
set -e
echo "[test] summary ($MODE):"
grep -E '^test result:' "$LOG" | sed 's/^/  /' || true
# segment 的推理测试在缺 ONNX Runtime 时会 guard-skip（计入 PASS 但并未
# 真正推理）。libtest 默认捕获 eprintln，cargo 日志里通常看不到那行，
# 所以先用日志、再用与 ort 等价的「加载 + OrtGetApiBase 符号」探测兜底。
# 不把「全绿」误读成 AI 分割已验证，这一点必须显式写进每次汇总。
case "$MODE" in
  batch-b|all)
    SKIPS=$(grep -c 'skipped inference: ONNX Runtime dylib unavailable' "$LOG" 2>/dev/null || true)
    if [ "${SKIPS:-0}" = "0" ]; then
      ORT=$(python -c 'import ctypes; lib=ctypes.WinDLL("onnxruntime.dll"); getattr(lib,"OrtGetApiBase"); print("available")' 2>/dev/null || echo unavailable)
      [ "$ORT" = "available" ] || SKIPS=1
    fi
    echo "[test] guard-skips (no usable onnxruntime.dll): ${SKIPS:-0}"
    ;;
  *)
    echo "[test] guard-skips: n/a ($MODE has no concat-vision tests)"
    ;;
esac
echo "[test] RC=$RC end $(date -u +%Y-%m-%dT%H:%M:%SZ)"
exit "$RC"
