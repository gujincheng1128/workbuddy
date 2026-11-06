#!/usr/bin/env bash
# LongCut 0.2.10 - one-command 15-second vertical short film.
# Everything is generated inside the project directory from in-repo assets.
set -eo pipefail
# A single POSIX path for cd; the Python script derives ROOT from __file__,
# so it never needs a Windows-style path passed in.
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$HERE" || exit 1
python "tools/make_15s_short.py"
PRJ="$(pwd -W 2>/dev/null || pwd)"
echo "[short] project root: $PRJ"
echo "[short] output: $PRJ/dist/media/LongCut-0.2.10-15s.mp4"
