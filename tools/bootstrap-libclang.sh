#!/bin/bash
# 龙儿剪辑 LongCut —— 获取 libclang 供 ffmpeg-sys-the-third 的 bindgen 使用。
# 通过 mstorsjo/llvm-mingw（自带 libclang.dll + LLVM*.dll），经 ghproxy 国内可达。
# 仅解压出 bin/ 目录（libclang.dll 及其依赖），放到 tools/llvm-mingw/bin。
# [已证伪路线 · 请勿运行] llvm-mingw 各版本只有 libclang-cpp.dll，没有
# clang-sys 需要的独立 libclang.dll；官方 LLVM 的 libclang.dll 已收进
# tools/llvm/bin/，无需再跑本脚本。保留仅为取证。
echo "[deprecated] libclang.dll is already vendored at tools/llvm/bin/" >&2
exit 2
# --- 以下为历史实现，不会执行 ---
PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
DEST="$PRJ/tools/llvm-mingw"
VER="20240619"
ZIP="llvm-mingw-$VER-ucrt-x86_64.zip"
# 直连 github（带 -L 跟随 302 到 objects.githubusercontent.com）。
# 注意：ghproxy 对此大文件会返回 502，故走直连。
URL="https://github.com/mstorsjo/llvm-mingw/releases/download/$VER/$ZIP"
mkdir -p "$DEST"

if [ -f "$DEST/bin/libclang.dll" ]; then
  echo "[libclang] already present, skip download"
  exit 0
fi

echo "[libclang] downloading $URL"
for i in 1 2 3 4 5 6; do
  echo "[libclang] attempt $i ..."
  if curl -L --retry 5 --retry-all-errors --retry-delay 3 -C - -o "$DEST/$ZIP" "$URL"; then
    SIZE=$(stat -c%s "$DEST/$ZIP" 2>/dev/null || echo 0)
    echo "[libclang] downloaded bytes: $SIZE"
    if [ "$SIZE" -gt 100000000 ]; then
      echo "[libclang] download looks complete"
      break
    fi
  fi
  echo "[libclang] retry after short wait"
  sleep 2
done

echo "[libclang] extracting bin/ ..."
# 仅解压 bin 目录（含 libclang.dll 与 LLVM-*.dll 依赖）
tar -xzf "$DEST/$ZIP" -C "$DEST" --strip-components=1 "llvm-mingw-$VER-ucrt-x86_64/bin" 2>/dev/null \
  || unzip -j -o "$DEST/$ZIP" "llvm-mingw-$VER-ucrt-x86_64/bin/*" -d "$DEST/bin" 2>/dev/null \
  || (cd "$DEST" && powershell -Command "Expand-Archive -Force '$DEST/$ZIP' '$DEST/__tmp'" && cp -r "$DEST/__tmp/llvm-mingw-$VER-ucrt-x86_64/bin" "$DEST/" && rm -rf "$DEST/__tmp")

echo "[libclang] libclang.dll present?"
ls -la "$DEST/bin/libclang.dll" 2>&1 || echo "[libclang] WARNING: libclang.dll not found after extraction"
echo "[libclang] done"
