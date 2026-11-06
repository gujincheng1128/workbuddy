#!/bin/bash
# 持久重试下载 BtbN FFmpeg 共享开发库 (include+lib+dll) 到 tools/ffmpeg。
# 沙箱代理对大文件间歇 502，故用外层 bash 循环多试。
set -eo pipefail
PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
FF="$PRJ/tools/ffmpeg"
ZIP="$FF/ffmpeg.zip"
mkdir -p "$FF"; cd "$FF"
URL="https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl-shared.zip"

# 不用 -C - 断点续传：代理偶发返回 9 字节错误页，续传会把错误页追加进包体，
# 得到一个「大小够但内容坏」的 zip。每次重新完整下载，再验大小 + PK 魔数。
ok=0
for i in $(seq 1 30); do
  echo "[ffmpeg] attempt $i ..."
  if curl -sSL --max-time 600 --retry 3 --retry-delay 5 -o "$ZIP" "$URL"; then
    SZ=$(stat -c%s "$ZIP" 2>/dev/null || echo 0)
    MAGIC=$(python3 -c "import sys; print(open(sys.argv[1],'rb').read(4).hex())" "$ZIP" 2>/dev/null || echo "")
    echo "[ffmpeg]   bytes=$SZ magic=$MAGIC"
    if [ "$SZ" -gt 40000000 ] && [ "$MAGIC" = "504b0304" ]; then
      ok=1
      break
    fi
  fi
  echo "[ffmpeg]   invalid payload, retry after 15s"
  sleep 15
done

if [ "$ok" -ne 1 ]; then
  echo "[ffmpeg] FATAL: 30 次重试后仍未取得有效 zip，停止（不再解压损坏包）" >&2
  exit 1
fi

echo "[ffmpeg] extracting ..."
python3 - "$FF" <<'PY'
import os, sys, zipfile
ff = sys.argv[1]
z = zipfile.ZipFile(os.path.join(ff, "ffmpeg.zip"))
z.extractall(ff)
root = None
for dp, _, _ in os.walk(ff):
    if os.path.exists(os.path.join(dp, "include", "libavcodec", "avcodec.h")):
        root = dp
        break
print("[ffmpeg] root:", root)
if root and os.path.abspath(root) != os.path.abspath(ff):
    for e in os.listdir(root):
        s = os.path.join(root, e)
        d = os.path.join(ff, e)
        if not os.path.exists(d):
            os.rename(s, d)
    try:
        os.rmdir(root)
    except OSError:
        pass
ok = os.path.exists(os.path.join(ff, "include", "libavcodec", "avcodec.h"))
print("[ffmpeg] FFMPEG_DIR valid:", ok)
if not ok:
    sys.exit(2)
with open(os.path.join(ff, "FFMPEG_DIR.txt"), "w") as f:
    f.write(os.path.abspath(ff).replace("\\", "/"))
print("[ffmpeg] wrote FFMPEG_DIR.txt ->", os.path.abspath(ff).replace("\\", "/"))
PY

if [ ! -f "$FF/include/libavcodec/avcodec.h" ]; then
  echo "[ffmpeg] FATAL: 解压后未找到 avcodec.h" >&2
  exit 1
fi
echo "[ffmpeg] OK avcodec.h present"
echo "[ffmpeg] done"
