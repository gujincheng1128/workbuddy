#!/bin/bash
# 龙儿剪辑 LongCut —— 用 MinGW-w64 (windows-gnu 目标) 构建，绕开 MSVC/WinSDK。
# 依赖全部落在项目目录内：.cargo / .rustup / tools/mingw / tools/ffmpeg
#                        / tools/cmake-dist / tools/llvm/bin/libclang.dll
# libclang.dll 已随项目携带；D:/LLM/LLVM 仅作旧环境兜底，不再是硬依赖。
# pipefail 必须有：rustup/cargo 的输出经 tail/tee 时，若失败不能被下游吞掉。
set -eo pipefail
# 项目根由脚本自身位置推导，不再写死 D:/... —— 换机/换目录/CI 直接可用。
# pwd -W 在 Git Bash 下返回 Windows 风格路径（D:/...），正是 cargo/rustc
# 期望的格式；LONGCUT_PROJECT_DIR 可用于特殊布局显式覆盖。
PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
# Git Bash 的 PATH 只认 POSIX 风格（/d/...）。用 D:/... 形式时
# `command -v gcc/dlltool/cmake` 全部为空 —— 这正是早期
# "error calling dlltool 'dlltool.exe': program not found" 的根因。
P="$(cygpath -u "$PRJ")"

export CARGO_HOME="$PRJ/.cargo"
export RUSTUP_HOME="$PRJ/.rustup"
# 强制使用 gnu 工具链作为 host+target。
# RUSTUP_TOOLCHAIN 优先级高于 src/rust-toolchain.toml，可绕开其锁定的
# 1.93.1-msvc（默认 host 是 msvc，会导致 host 端 build script 去调 link.exe）。
# 同时避免 minimal 版 gnu 工具链缺少 rustfmt/clippy 组件导致的报错
# （这两个组件只在 cargo fmt/clippy 时需要，普通 cargo build 不依赖）。
export RUSTUP_TOOLCHAIN=stable-x86_64-pc-windows-gnu

# CC/CXX 给 cc crate（Windows 原生进程）用 Windows 风格绝对路径。
export CC="$PRJ/tools/mingw/mingw64/bin/gcc.exe"
export CXX="$PRJ/tools/mingw/mingw64/bin/g++.exe"
# .cargo/config.toml 里 [target.x86_64-pc-windows-gnu] linker 是本机绝对路径
# （Cargo 不解析相对 linker、也不支持 config 内变量插值）。只有当配置里的值
# 与当前工作区推导出的 gcc 不一致时（换机/换目录/CI）才用同名环境变量覆盖。
# 本机两者相同 -> 不设该变量 -> 不改变 fingerprint、不会触发全量重编。
CFG_LINKER=$(sed -n 's/^linker = "\(.*\)"/\1/p' "$PRJ/.cargo/config.toml" 2>/dev/null | head -1)
if [ -n "$CFG_LINKER" ] && [ "$CFG_LINKER" != "$CC" ]; then
  export CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER="$CC"
  echo "[build] linker override: config=$CFG_LINKER -> $CC"
else
  echo "[build] linker from config: ${CFG_LINKER:-<unset>}"
fi
FF=$(cat "$PRJ/tools/ffmpeg/FFMPEG_DIR.txt" 2>/dev/null || echo "$PRJ/tools/ffmpeg/ffmpeg-master-latest-win64-gpl-shared")
export FFMPEG_DIR="$FF"

# bindgen 0.72 支持 BINDGEN_EXTRA_CLANG_ARGS（whitespace 分隔，自动附加到 clang args）。
# 官方 LLVM(MSVC build) 的 libclang 默认按 MSVC 目标找系统头，而 windows-gnu
# 构建需要 MinGW 的 stdlib.h / _mingw.h 等，否则报
#   channel_layout.h:26:10: fatal error: 'stdlib.h' file not found
#
# 重要：只加 MinGW 的 CRT 头目录（x86_64-w64-mingw32/include、include）。
# 千万不要加 gcc 内置的 lib/gcc/.../include —— 它的 stddef.h/stdarg.h 会与
# libclang 自带 resource dir 冲突，报
#   error: typedef redefinition with different types ('struct max_align_t' ...)
# stddef.h / stdarg.h / stdint.h 一律交给 libclang 自带的 clang/19/include 提供。
MW="$PRJ/tools/mingw/mingw64"
export BINDGEN_EXTRA_CLANG_ARGS="--target=x86_64-w64-windows-gnu -I$MW/x86_64-w64-mingw32/include -I$MW/include"

# ffmpeg-sys-the-third 的 bindgen 需要 libclang.dll（C 接口库）。
# llvm-mingw 各版本只提供 libclang-cpp.dll，clang-sys 用不了。
# 官方 LLVM 19.1.7 的 bin/libclang.dll 已收进项目（sha256 校验一致），
# 因此换机器/换目录不再依赖外部 D:/LLM/LLVM。
LLVM_BIN="$PRJ/tools/llvm/bin"
if [ ! -f "$LLVM_BIN/libclang.dll" ]; then
  echo "[build] WARN: project-local libclang not found, fallback to D:/LLM/LLVM/bin" >&2
  LLVM_BIN="D:/LLM/LLVM/bin"
fi
if [ ! -f "$LLVM_BIN/libclang.dll" ]; then
  echo "[build] FATAL: libclang.dll not found at $LLVM_BIN" >&2
  echo "[build]        请把官方 LLVM 的 bin/libclang.dll 放到 tools/llvm/bin/" >&2
  exit 1
fi
export LIBCLANG_PATH="$LLVM_BIN"

# whisper-rs-sys 用 cmake 编译 ggml (C++)，需要完整 cmake（bin+share）在 PATH。
# 旧 tools/cmake 缺 share 导致 CMAKE_ROOT 报错，改用 cmake-dist 完整解压版。
CMAKE_BIN="$PRJ/tools/cmake-dist/cmake-3.30.5-windows-x86_64/bin"

# PATH 一律 POSIX 风格；MSYS 在 exec 原生 Windows 进程时会自动转回 D:\... 形式。
export PATH="$P/.cargo/bin:$P/tools/mingw/mingw64/bin:$(cygpath -u "$CMAKE_BIN"):$(cygpath -u "$LLVM_BIN"):$PATH"

echo "[build] CARGO_HOME=$CARGO_HOME"
echo "[build] FFMPEG_DIR=$FF"
echo "[build] BINDGEN_EXTRA_CLANG_ARGS=$BINDGEN_EXTRA_CLANG_ARGS"
echo "[build] LIBCLANG_PATH=$LIBCLANG_PATH"
echo "[build] CMAKE_BIN=$CMAKE_BIN"
echo "[build] gcc     =$(command -v gcc)"
echo "[build] dlltool =$(command -v dlltool)"
echo "[build] cmake   =$(command -v cmake)"

# 360 文档保护/反勒索会拦截 rustc 删除编译结束时的临时 .o (os error 5)。
# 即便项目目录已加入 360 信任区：写入被放行，但「删除」动作仍被拦，
# 表现为 `failed to remove ...cgu.NN.rcgu.o: 拒绝访问`。
# LONGCUT_SAVE_TEMPS=1 让 rustc 保留中间文件、根本不发起删除；
# 同时换独立 target 目录，避免 RUSTFLAGS 变化与旧产物 fingerprint 混淆。
# 默认开启（本机 360 环境不开必失败）；显式置 0 可关闭。
# 用法： bash tools/build-gnu.sh -p concat --bin longcut -j 2
#       LONGCUT_PROFILE_DIR=app bash tools/build-gnu.sh --profile app -p concat --bin longcut
# 产物： src/target-gnu/x86_64-pc-windows-gnu/<debug|release|app>/longcut.exe
# 目标目录与 dlltool 覆盖始终生效：换机 / CI 时 config.toml 里那台机器的
# 绝对路径无效，而 workflow 的 cache key 也固定为 src/target-gnu。
# save-temps 只是 360「删除 .o」拦截的绕行，CI runner 没有 360，可单独
# 关掉（LONGCUT_SAVE_TEMPS=0）省下 fat LTO 的十几 GB 中间文件。
export CARGO_TARGET_DIR="$PRJ/src/target-gnu"
DLLTOOL_FLAG="-C dlltool=$PRJ/tools/mingw/mingw64/bin/dlltool.exe"
# RUSTFLAGS 环境变量会「完全替换」.cargo/config.toml 的 target rustflags。
# ${RUSTFLAGS:+$RUSTFLAGS } 不留前导空格：RUSTFLAGS 是 fingerprint 的一部分，
# 平白多一个空格会让 cargo 判定 flags 变了、把整个 workspace 重编一遍。
if [ "${LONGCUT_SAVE_TEMPS:-1}" = "1" ]; then
  export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }$DLLTOOL_FLAG -C save-temps"
  echo "[build] save-temps mode ON (360 删除拦截绕行)"
else
  export RUSTFLAGS="${RUSTFLAGS:+$RUSTFLAGS }$DLLTOOL_FLAG"
  echo "[build] save-temps mode OFF (CI runner: no 360)"
fi
echo "[build] CARGO_TARGET_DIR=$CARGO_TARGET_DIR"
echo "[build] RUSTFLAGS=$RUSTFLAGS"

cd "$PRJ/src"
# 统一用 gnu 工具链作为 host+target，避免 host 端 build script 去调 MSVC 的 link.exe。
# 已安装则跳过 install，避免每次重复联网 / rustup 文件占用 (os error 32)。
if [ ! -d "$RUSTUP_HOME/toolchains/stable-x86_64-pc-windows-gnu" ]; then
  "$CARGO_HOME/bin/rustup.exe" toolchain install stable-x86_64-pc-windows-gnu --profile minimal 2>&1 | tail -3
fi
"$CARGO_HOME/bin/rustup.exe" default stable-x86_64-pc-windows-gnu 2>&1
echo "[build] default host: $("$CARGO_HOME/bin/rustc.exe" -vV | grep -i host)"
echo "[build] starting cargo build (x86_64-pc-windows-gnu) $* ..."
# 用 if 包住：set -e 下直接写 `cmd; RC=$?` 会在失败时提前退出。
if "$CARGO_HOME/bin/cargo.exe" build --target x86_64-pc-windows-gnu "$@"; then
  # 构建溯源：本仓库无 .git，commit 记为 local。
  # profile 目录默认从 --profile 参数推断（cargo 把 dev 放在 debug/），
  # 也可由 LONGCUT_PROFILE_DIR 显式指定；release/app 构建不会错写到 debug/。
  PROFILE_DIR="${LONGCUT_PROFILE_DIR:-}"
  if [ -z "$PROFILE_DIR" ]; then
    PROFILE_DIR=debug
    prev=""
    for a in "$@"; do
      [ "$prev" = "--profile" ] && PROFILE_DIR="$a"
      case "$a" in --profile=*) PROFILE_DIR="${a#--profile=}";; esac
      prev="$a"
    done
    [ "$PROFILE_DIR" = "dev" ] && PROFILE_DIR=debug
  fi
  case "$PROFILE_DIR" in
    debug)   PNOTE="dev, debug symbols kept, not stripped" ;;
    app)     PNOTE="release inherits; fat LTO, panic=abort, strip=symbols" ;;
    release) PNOTE="release, thin LTO, symbols kept" ;;
    *)       PNOTE="custom profile" ;;
  esac
  OUT_DIR="${CARGO_TARGET_DIR:-$PRJ/src/target}/x86_64-pc-windows-gnu/$PROFILE_DIR"
  INFO="$OUT_DIR/BUILD_INFO.txt"
  mkdir -p "$OUT_DIR"
  # 合规文件随产物走：stage-portable.sh 要求 OUT 目录里就有这两份。
  for f in LICENSE THIRD_PARTY_NOTICES.md; do
    [ -f "$PRJ/$f" ] && cp -f "$PRJ/$f" "$OUT_DIR/$f"
  done
  VER=$(sed -n 's/^version = "\([^"]*\)"/\1/p' "$PRJ/src/Cargo.toml" | head -1)
  {
    echo "product=LongCut"
    echo "version=$VER"
    echo "built_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "rustc=$("$CARGO_HOME/bin/rustc.exe" -vV | head -1)"
    echo "toolchain=$RUSTUP_TOOLCHAIN"
    echo "target=x86_64-pc-windows-gnu"
    echo "profile=$PROFILE_DIR ($PNOTE)"
    echo "commit=local"
    echo "exe=$OUT_DIR/longcut.exe"
  } > "$INFO"
  echo "[build] wrote $INFO"
  exit 0
else
  RC=$?
  echo "[build] cargo build FAILED (exit $RC)" >&2
  exit "$RC"
fi
