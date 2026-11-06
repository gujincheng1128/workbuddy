#!/bin/bash
# [已证伪路线 · 请勿运行] gyan.dev 的 full_build-shared 在本网络被代理拦（502），
# 且同样用了 `curl -C -` 续传坑。保留仅为取证。
# 请改用 tools/bootstrap-ffmpeg-retry.sh（BtbN + 大小/魔数校验）。
echo "[deprecated] use tools/bootstrap-ffmpeg-retry.sh instead" >&2
exit 2
# --- 以下为历史实现，不会执行 ---
PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
FF="$PRJ/tools/ffmpeg"
mkdir -p "$FF"; cd "$FF"
echo "[ffmpeg] downloading gyan 8.1.2 shared (dev) build ..."
curl -sSL --retry 5 --retry-all-errors --retry-delay 2 -C - -o ffmpeg.7z "https://www.gyan.dev/ffmpeg/builds/ffmpeg-8.1.2-full_build-shared.7z"
echo "[ffmpeg] size: $(du -h ffmpeg.7z | cut -f1)"
echo "[ffmpeg] extracting with py7zr ..."
python3 - "$FF" <<'PY'
import os, sys
ff = sys.argv[1]
import py7zr
with py7zr.SevenZipFile(os.path.join(ff,"ffmpeg.7z"), 'r') as z:
    z.extractall(path=ff)
# find ffmpeg root with include/libavcodec/avcodec.h
root=None
for dp,_,_ in os.walk(ff):
    if os.path.exists(os.path.join(dp,"include","libavcodec","avcodec.h")):
        root=dp; break
print("[ffmpeg] root:", root)
if root and os.path.abspath(root)!=os.path.abspath(ff):
    for e in os.listdir(root):
        s=os.path.join(root,e); d=os.path.join(ff,e)
        if not os.path.exists(d): os.rename(s,d)
    try: os.rmdir(root)
    except OSError: pass
ok=os.path.exists(os.path.join(ff,"include","libavcodec","avcodec.h"))
print("[ffmpeg] FFMPEG_DIR valid:", ok)
with open(os.path.join(ff,"FFMPEG_DIR.txt"),"w") as f:
    f.write(os.path.abspath(ff).replace("\\","/"))
print("[ffmpeg] wrote FFMPEG_DIR.txt ->", os.path.abspath(ff).replace("\\","/"))
PY
ls -la "$FF/include/libavcodec/avcodec.h" && echo "OK avcodec.h present"
