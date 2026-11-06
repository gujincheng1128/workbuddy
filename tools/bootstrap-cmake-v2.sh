#!/bin/bash
# 龙儿剪辑 LongCut —— 重新下载并「完整」解压 CMake。
#
# 背景：旧 tools/cmake/ 是半截拷贝（只有 bin/doc，缺 share/cmake-3.30），
#       cmake.exe 报 "Could not find CMAKE_ROOT"。且 rm -rf 该目录会触发
#       沙箱的安全删除确认（文件数超阈值），所以这里用一个全新的干净目录
#       tools/cmake-dist/，保留 zip 内完整的 bin/share/doc 相对结构。
#
# 关键点：
#  1. 不用 -C - 断点续传（代理偶发返回 9 字节错误页时会把错误页当文件续传）；
#  2. 下载后校验大小 > 30MB 且头 4 字节为 PK\x03\x04；
#  3. 直接解压到 cmake-dist/，不 cp -r、不移动，保证 CMAKE_ROOT 相对路径成立。
set -eo pipefail
PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
VER="3.30.5"
INNER="cmake-$VER-windows-x86_64"
ZIPNAME="$INNER.zip"
URL="https://github.com/Kitware/CMake/releases/download/v$VER/$ZIPNAME"
DIST="$PRJ/tools/cmake-dist"
TMP="$PRJ/tools/_tmp"
ZIP="$TMP/cmake.zip"

mkdir -p "$DIST" "$TMP"
echo "[cmake] target : $DIST/$INNER"
echo "[cmake] source : $URL"

ok=0
for i in 1 2 3 4 5; do
  # 不 rm：360 会拦对已存在文件的删除；curl -o 直接覆盖即可。
  echo "[cmake] download attempt $i ..."
  if curl -sL --max-time 400 --retry 3 --retry-delay 2 -o "$ZIP" "$URL"; then
    SZ=$(stat -c%s "$ZIP" 2>/dev/null || echo 0)
    # od 是 coreutils 自带，不依赖 xxd（缺 xxd 时 MAGIC 为空会导致 5 次全失败）。
    MAGIC=$(od -An -tx1 -N4 "$ZIP" 2>/dev/null | tr -d ' \n')
    echo "[cmake]   bytes=$SZ magic=$MAGIC"
    if [ "$SZ" -gt 30000000 ] && [ "$MAGIC" = "504b0304" ]; then
      ok=1
      break
    fi
    echo "[cmake]   invalid payload (proxy short response?), retry"
  fi
  sleep 2
done

if [ "$ok" -ne 1 ]; then
  echo "[cmake] FATAL: failed to obtain a valid zip after 5 attempts"
  exit 1
fi

echo "[cmake] extracting (full tree: bin + share + doc) ..."
unzip -o -q "$ZIP" -d "$DIST"

BIN="$DIST/$INNER/bin/cmake.exe"
if [ ! -f "$BIN" ]; then
  echo "[cmake] FATAL: cmake.exe not found at $BIN"
  exit 1
fi

echo "[cmake] verifying CMAKE_ROOT ..."
"$BIN" --version | head -1 || { echo "[cmake] FATAL: --version failed (CMAKE_ROOT missing?)"; exit 1; }

echo "$DIST/$INNER/bin" > "$DIST/CMAKE_BIN.txt"
# 保留 zip 作为缓存/取证，不做删除（360 删除拦截会在这里误报失败）。
echo "[cmake] cached zip kept: $ZIP"
echo "[cmake] OK -> $BIN"
echo "[cmake] CMAKE_BIN.txt -> $DIST/CMAKE_BIN.txt"
