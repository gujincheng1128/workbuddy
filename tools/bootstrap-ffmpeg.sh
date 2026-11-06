#!/bin/bash
# [已证伪路线 · 请勿运行] 用 `curl -C -` 续传，代理偶发返回的短错误页会被
# 追加进包体，得到「大小够但内容坏」的 zip；且无魔数校验。保留仅为取证。
# 请改用 tools/bootstrap-ffmpeg-retry.sh（完整下载 + 大小/魔数校验）。
echo "[deprecated] use tools/bootstrap-ffmpeg-retry.sh instead" >&2
exit 2
# --- 以下为历史实现，不会执行 ---
PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
FF="$PRJ/tools/ffmpeg"
mkdir -p "$FF"
cd "$FF"
echo "[ffmpeg] downloading shared dev build ..."
curl -sSL --retry 5 --retry-all-errors --retry-delay 2 -C - -o ffmpeg.zip "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl-shared.zip"
echo "[ffmpeg] extracting ..."
python3 - <<'PY'
import zipfile, os
z = zipfile.ZipFile("ffmpeg.zip")
names = z.namelist()
top = os.path.commonprefix(names).rstrip('/')
z.extractall(".")
print("[ffmpeg] extracted top folder:", top)
# 找到含 include/libavcodec/avcodec.h 的目录，把其内容提升到 $FF 根，使 FFMPEG_DIR=$FF
root = None
for dirpath, dirs, files in os.walk("."):
    if os.path.exists(os.path.join(dirpath, "include", "libavcodec", "avcodec.h")):
        root = dirpath
        break
if root and root != ".":
    print("[ffmpeg] found ffmpeg root:", root)
    for entry in os.listdir(root):
        src = os.path.join(root, entry)
        dst = os.path.join(".", entry)
        if os.path.exists(dst):
            continue
        os.rename(src, dst)
    # 移除空的中间目录
    try:
        os.rmdir(root)
    except OSError:
        pass
# 校验
ok = os.path.exists(os.path.join(".", "include", "libavcodec", "avcodec.h"))
print("[ffmpeg] FFMPEG_DIR valid:", ok)
with open("FFMPEG_DIR.txt", "w") as f:
    f.write(os.path.abspath(".").replace("\\", "/"))
print("[ffmpeg] wrote FFMPEG_DIR.txt ->", os.path.abspath(".").replace("\\", "/"))
PY
echo "[ffmpeg] done."
ls -la "$FF/include/libavcodec/avcodec.h" 2>/dev/null && echo "OK avcodec.h present"
