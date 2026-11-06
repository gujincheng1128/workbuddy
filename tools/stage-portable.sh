#!/bin/bash
# 把已验证的 longcut.exe 组装成「解压即用」的便携发行目录。
# 只收集非系统 DLL（其余 30+ 项由 Windows 自身提供），因此目录可整体搬移。
# 用法： bash tools/stage-portable.sh                        (dev/debug)
#       LONGCUT_PROFILE_DIR=app bash tools/stage-portable.sh (ship/app)
# 产物： dist/LongCut-win64-gnu/
set -eo pipefail
PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
PROFILE_DIR="${LONGCUT_PROFILE_DIR:-debug}"
OUT="$PRJ/src/target-gnu/x86_64-pc-windows-gnu/$PROFILE_DIR"
FF="$PRJ/tools/ffmpeg/ffmpeg-master-latest-win64-gpl-shared/bin"
MW="$PRJ/tools/mingw/mingw64/bin"
STAGE="$PRJ/dist/LongCut-win64-gnu"

for required in "$OUT/longcut.exe" "$OUT/LICENSE" "$OUT/THIRD_PARTY_NOTICES.md" "$OUT/BUILD_INFO.txt"; do
  if [ ! -f "$required" ]; then
    echo "[stage] FATAL: missing build artifact: $required (profile=$PROFILE_DIR)" >&2
    echo "[stage]        先跑 LONGCUT_SAVE_TEMPS=1 LONGCUT_PROFILE_DIR=$PROFILE_DIR bash tools/build-gnu.sh --profile app -p concat --bin longcut" >&2
    exit 1
  fi
done
if [ ! -f "$FF/avcodec-63.dll" ] || [ ! -f "$MW/libstdc++-6.dll" ]; then
  echo "[stage] FATAL: runtime DLL sources not found (tools/ffmpeg/.../bin or tools/mingw/.../bin)" >&2
  exit 1
fi

mkdir -p "$STAGE"
FF_DLLS=(avcodec-63.dll avdevice-63.dll avfilter-12.dll avformat-63.dll
         avutil-61.dll swresample-7.dll swscale-10.dll)
MW_DLLS=(libstdc++-6.dll libgcc_s_seh-1.dll libwinpthread-1.dll libgomp-1.dll)

for d in "${FF_DLLS[@]}"; do cp -f "$FF/$d" "$STAGE/$d"; done
for d in "${MW_DLLS[@]}"; do cp -f "$MW/$d" "$STAGE/$d"; done
cp -f "$OUT/longcut.exe" "$STAGE/longcut.exe"
cp -f "$OUT/LICENSE" "$OUT/THIRD_PARTY_NOTICES.md" "$OUT/BUILD_INFO.txt" "$STAGE/"
cp -f "$PRJ/docs/RUNTIME-DEPENDENCIES.md" "$STAGE/"
cp -f "$PRJ/tools/portable/run-longcut.bat" "$PRJ/tools/portable/README.txt" "$STAGE/"

# build-gnu.sh 写入的 BUILD_INFO.txt 里 exe= 是构建机上的绝对路径
# (…/src/target-gnu/<target>/<profile>/longcut.exe)。留在便携包里会让用户
# 误以为目录不可搬移，也把本机路径散进发行物。OUT 目录中的原件保留作构建
# 溯源，只把 stage 副本的这一行改写成包内相对路径。
if grep -q '^exe=' "$STAGE/BUILD_INFO.txt"; then
  sed -i 's|^exe=.*|exe=longcut.exe|' "$STAGE/BUILD_INFO.txt"
fi

# 逐项复核，避免「脚本跑完了但少拷一个 DLL」。
for d in "${FF_DLLS[@]}" "${MW_DLLS[@]}"; do
  [ -s "$STAGE/$d" ] || { echo "[stage] FATAL: $d missing/empty after copy" >&2; exit 1; }
done
for f in longcut.exe LICENSE THIRD_PARTY_NOTICES.md BUILD_INFO.txt \
         RUNTIME-DEPENDENCIES.md run-longcut.bat README.txt; do
  [ -s "$STAGE/$f" ] || { echo "[stage] FATAL: $f missing/empty after copy" >&2; exit 1; }
done

# 防回归：包内 key=value 形式的元数据不得再带回任何构建机绝对路径。
# 只匹配行首 key= 的值，避免把 THIRD_PARTY_NOTICES.md 里的 https:// 误判。
LEAK=$(grep -nE '^[a-z_]+=.*[A-Za-z]:[\\/]' "$STAGE/BUILD_INFO.txt" 2>/dev/null || true)
if [ -n "$LEAK" ]; then
  echo "[stage] FATAL: machine-specific absolute path in bundle metadata:" >&2
  echo "$LEAK" >&2
  exit 1
fi

echo "[stage] OK -> $STAGE"
echo "[stage] $(find "$STAGE" -maxdepth 1 -type f | wc -l) files, $(du -sh "$STAGE" | cut -f1)"
echo "[stage] verify: run-longcut.bat --version / --smoke / --whisper-cpu"
