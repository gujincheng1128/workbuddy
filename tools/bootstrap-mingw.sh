#!/bin/bash
# 下载 niXman MinGW-w64 (GCC, 自包含: 头文件+crt+Windows导入库) 到 tools/mingw。
# 用于 windows-gnu 目标，绕开 MSVC/WinSDK（沙箱代理拦 MS 组件 CDN）。
set -eo pipefail
PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
MW="$PRJ/tools/mingw"
ARC="$MW/mingw.7z"
mkdir -p "$MW"; cd "$MW"
URL="https://github.com/niXman/mingw-builds-binaries/releases/download/16.2.0-rt_v14-rev1/x86_64-16.2.0-release-posix-seh-msvcrt-rt_v14-rev1.7z"

# 不用 -C - 断点续传（同 bootstrap-ffmpeg-retry.sh 的理由）：每次完整下载，
# 校验大小 + 7z 魔数 37 7a bc af 27 1c，失败绝不进入解压。
ok=0
for i in $(seq 1 25); do
  echo "[mingw] attempt $i ..."
  if curl -sSL --max-time 600 --retry 3 --retry-delay 5 -o "$ARC" "$URL"; then
    SZ=$(stat -c%s "$ARC" 2>/dev/null || echo 0)
    MAGIC=$(python3 -c "import sys; print(open(sys.argv[1],'rb').read(6).hex())" "$ARC" 2>/dev/null || echo "")
    echo "[mingw]   bytes=$SZ magic=$MAGIC"
    if [ "$SZ" -gt 80000000 ] && [ "$MAGIC" = "377abcaf271c" ]; then
      ok=1
      break
    fi
  fi
  echo "[mingw]   invalid payload, retry after 15s"
  sleep 15
done

if [ "$ok" -ne 1 ]; then
  echo "[mingw] FATAL: 25 次重试后仍未取得有效 7z，停止" >&2
  exit 1
fi

echo "[mingw] extracting ..."
python3 - "$MW" <<'PY'
import os, sys, py7zr
mw = sys.argv[1]
with py7zr.SevenZipFile(os.path.join(mw, "mingw.7z"), 'r') as z:
    z.extractall(path=mw)
for cand in ["mingw64", "mingw", "x86_64-w64-mingw32"]:
    b = os.path.join(mw, cand, "bin")
    if os.path.isdir(b):
        with open(os.path.join(mw, "MINGW_BIN.txt"), "w") as f:
            f.write(os.path.abspath(b).replace("\\", "/"))
        print("[mingw] bin dir:", os.path.abspath(b))
        break
PY

if [ ! -f "$MW/mingw64/bin/gcc.exe" ]; then
  echo "[mingw] FATAL: 解压后未找到 mingw64/bin/gcc.exe" >&2
  exit 1
fi
"$MW/mingw64/bin/gcc.exe" --version | head -1
cat "$MW/MINGW_BIN.txt"
echo "[mingw] done"
