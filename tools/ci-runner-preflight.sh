#!/bin/bash
# LongCut / GH-hosted runner first-run preflight.
#
# Read-only on a developer machine. On GitHub Actions ($GITHUB_ENV is set)
# it also exports the windows-gnu linker override for every later cargo
# step, so a bare `cargo fmt` / `cargo test` does not call the gcc.exe of
# the machine whose absolute path is pinned in .cargo/config.toml.
#
# Run locally to rehearse the first workflow_dispatch:
#     bash tools/ci-runner-preflight.sh
# To exercise the Actions branch without a runner:
#     GITHUB_ENV=tools/_tmp/gh-env.txt bash tools/ci-runner-preflight.sh
set -uo pipefail

PRJ="${LONGCUT_PROJECT_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -W)}"
cd "$PRJ" || exit 1
GCC="$PRJ/tools/mingw/mingw64/bin/gcc.exe"
DLLTOOL="$PRJ/tools/mingw/mingw64/bin/dlltool.exe"
FAIL=0
WARN=0

say()  { echo "[preflight] $*"; }
bad()  { echo "[preflight] FATAL: $*" >&2; FAIL=$((FAIL + 1)); }
warn() { echo "[preflight] WARN:  $*" >&2; WARN=$((WARN + 1)); }

say "date=$(date -u +%Y-%m-%dT%H:%M:%SZ)"
say "workspace=$PRJ"
say "runner_os=${RUNNER_OS:-<local>}  github_workspace=${GITHUB_WORKSPACE:-<none>}"

# 1. Commands this lane cannot do without. cygpath in particular: both
#    build-gnu.sh and test-gnu.sh turn the workspace into a POSIX path for
#    Git Bash's PATH, and silently break without it.
for c in bash cygpath python git curl; do
  if command -v "$c" >/dev/null 2>&1; then
    say "tool $c = $(command -v "$c")"
  else
    bad "required tool missing: $c"
  fi
done
for c in dotnet cmake rustup; do
  if command -v "$c" >/dev/null 2>&1; then
    say "tool $c = $(command -v "$c")"
  else
    say "tool $c = absent (a later step installs or bootstraps it)"
  fi
done

# 2. Machine-specific paths in the committed cargo config.
CFG="$PRJ/.cargo/config.toml"
if [ ! -f "$CFG" ]; then
  bad ".cargo/config.toml missing"
else
  CFG_LINKER=$(sed -n 's/^linker = "\(.*\)"/\1/p' "$CFG" | head -1)
  # Only the rustflags array line; the comments above it contain a
  # `<...>/bin/dlltool.exe` placeholder that a loose match would pick up.
  CFG_DLLTOOL=$(sed -n 's/^[[:space:]]*"-C", "dlltool=\([^"]*\)".*/\1/p' "$CFG" | head -1)
  say "config linker  = ${CFG_LINKER:-<unset>}"
  say "config dlltool = ${CFG_DLLTOOL:-<unset>}"
  if [ -n "$CFG_LINKER" ] && [ "$CFG_LINKER" != "$GCC" ]; then
    warn "config linker is machine-specific; exporting override -> $GCC"
  fi
  if [ -n "$CFG_DLLTOOL" ] && [ "$CFG_DLLTOOL" != "$DLLTOOL" ]; then
    warn "config dlltool is machine-specific; build/test scripts set RUSTFLAGS from \$PRJ"
  fi
fi

# 3. Export for later steps, only when running inside Actions.
if [ -n "${GITHUB_ENV:-}" ]; then
  echo "CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=$GCC" >> "$GITHUB_ENV"
  say "wrote CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER to GITHUB_ENV"
else
  say "GITHUB_ENV unset: local dry-run, no files written"
fi

# 4. Vendored libclang.dll (ffmpeg-sys bindgen needs it).
LIBCLANG="$PRJ/tools/llvm/bin/libclang.dll"
if [ -s "$LIBCLANG" ]; then
  say "libclang.dll vendored ($(stat -c %s "$LIBCLANG") bytes)"
else
  warn "tools/llvm/bin/libclang.dll absent; the Resolve libclang.dll step must find one on the runner"
fi

# 5. FFMPEG_DIR.txt: bootstrap rewrites it every run, but a stale path
#    checked into a fresh clone is a first-run trip hazard.
FF="$PRJ/tools/ffmpeg/FFMPEG_DIR.txt"
if [ -f "$FF" ]; then
  FFDIR=$(cat "$FF")
  say "FFMPEG_DIR.txt = $FFDIR"
  case "$FFDIR" in
    "$PRJ"*) say "FFMPEG_DIR matches this workspace" ;;
    *) warn "FFMPEG_DIR.txt points outside this workspace; bootstrap-ffmpeg-retry.sh must rewrite it" ;;
  esac
else
  say "FFMPEG_DIR.txt absent (the Prerequisites step writes it)"
fi

# 6. A first push must not carry the local toolchain and built artifacts.
if [ -f "$PRJ/.gitignore" ]; then
  if grep -qE '^[[:space:]]*/?dist/?[[:space:]]*$|\.dll[[:space:]]*$' "$PRJ/.gitignore"; then
    say ".gitignore covers dist/ or *.dll"
  else
    warn ".gitignore excludes neither dist/ nor *.dll; a first push would carry libclang.dll (65 MB), the portable bundle and the .msi"
  fi
else
  warn ".gitignore missing"
fi

# 7. Every file the workflow calls must exist after checkout.
for f in tools/build-gnu.sh tools/test-gnu.sh tools/stage-portable.sh \
         tools/build-installer.ps1 tools/ci-runner-preflight.sh \
         scripts/ci/verify-longcut.ps1 scripts/ci/smoke-windows.ps1 \
         scripts/ci/validate-workflow.py assets/windows/concat.wxs \
         .cargo/config.toml src/Cargo.toml; do
  [ -f "$PRJ/$f" ] || bad "workflow referenced file missing: $f"
done
say "workflow referenced files: checked"

say "result: $FAIL fatal, $WARN warning(s)"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
