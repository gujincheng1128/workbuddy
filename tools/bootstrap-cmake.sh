#!/bin/bash
# 龙儿剪辑 LongCut —— 获取 cmake，供 whisper-rs-sys 编译 ggml (C++) 使用。
#
# [已废弃实现] 旧版本直接下载到 tools/cmake 并用 `cp -r` 半途拷贝，
# 存在三个问题：
#   1. `curl -C - --retry-all-errors` 会把代理偶发返回的 9 字节错误页当续传文件；
#   2. `tar -xzf` 解 zip 必失败，PowerShell 回退的 `cp -r` 一旦被打断就只留下
#      bin/doc，缺 share/cmake-3.30 -> `Could not find CMAKE_ROOT`；
#   3. `if [ -f "$DEST/bin/cmake.exe" ]` 会让破损目录被判定为"已安装"而永久跳过修复。
#
# 现在统一委托给 bootstrap-cmake-v2.sh：完整下载 + 大小/魔数校验 +
# 解压到 tools/cmake-dist/ 并保留 bin/share/doc 相对结构。
# 用脚本自身所在目录定位，不再写死 D:/... 绝对路径（换目录即失效）。
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec bash "$HERE/bootstrap-cmake-v2.sh" "$@"
