#!/usr/bin/env python3
"""Static invariants for .github/workflows/longcut-windows-gnu.yml.

Deliberately zero third-party dependencies: PyYAML is not installed on the
Windows build host, and a release gate must not depend on an optional pip
package. These are structural checks (top-level keys, job env, step order,
shell pins, referenced files, no build-machine paths), not a full YAML parse.

    python scripts/ci/validate-workflow.py
Exit 0 only when every invariant holds.
"""

import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WF = os.path.join(ROOT, ".github", "workflows", "longcut-windows-gnu.yml")

fails = []
total = 0


def check(name, cond, detail=""):
    global total
    total += 1
    if cond:
        print("PASS " + name)
    else:
        print("FAIL " + name + ((" -> " + detail) if detail else ""))
        fails.append(name)


if not os.path.isfile(WF):
    print("FAIL workflow file missing: " + WF)
    sys.exit(1)

with open(WF, encoding="utf-8-sig") as fh:
    text = fh.read()
lines = text.splitlines()

# ---- 1. Basic YAML hygiene ----------------------------------------------
check("no tab indentation", not any("\t" in line[: len(line) - len(line.lstrip())] for line in lines))
check("no build-machine absolute path", not re.search(
    r"(?i)[A-Za-z]:[\\/](?:AiSof|Users|LLM|Program)", text))

top = [m.group(1) for line in lines
       if (m := re.match(r"^([A-Za-z_][A-Za-z0-9_-]*):", line))]
for key in ("name", "on", "concurrency", "jobs"):
    check("top-level key '%s'" % key, key in top)

# ---- 2. Job-level invariants --------------------------------------------
check("runs-on windows-latest", "runs-on: windows-latest" in text)
m = re.search(r"timeout-minutes:\s*(\d+)", text)
# The unit-test step adds a full debug build to the fat-LTO release.
check("timeout-minutes >= 300", bool(m) and int(m.group(1)) >= 300,
      "got %s" % (m.group(1) if m else "none"))

for var in ("CARGO_HOME", "RUSTUP_HOME", "NUGET_PACKAGES", "DOTNET_CLI_HOME"):
    check("env %s is project-local" % var,
          bool(re.search(r"%s:\s*\$\{\{\s*github\.workspace\s*\}\}" % var, text)))
# CI runners have no 360 deleting rustc's .o files; save-temps would leave
# ~12 GB of fat-LTO scratch. build-gnu.sh still sets dlltool + target dir.
check("env LONGCUT_SAVE_TEMPS=0 on the runner",
      bool(re.search(r"LONGCUT_SAVE_TEMPS:\s*'0'", text)))
check("env LONGCUT_PROFILE_DIR=app", bool(re.search(r"LONGCUT_PROFILE_DIR:\s*'app'", text)))
check("env RUSTUP_TOOLCHAIN is windows-gnu",
      "RUSTUP_TOOLCHAIN: stable-x86_64-pc-windows-gnu" in text)

# ---- 3. Split the steps block -------------------------------------------
start = None
for i, line in enumerate(lines):
    if re.match(r"^    steps:\s*$", line):
        start = i
        break
check("steps: block found", start is not None)

blocks = []
cur = []
if start is not None:
    for line in lines[start + 1:]:
        if not line.strip():
            if cur:
                cur.append(line)
            continue
        indent = len(line) - len(line.lstrip(" "))
        if indent <= 4:
            break
        if indent == 6 and re.match(r"^      -\s", line):
            if cur:
                blocks.append("\n".join(cur))
            cur = [line]
        else:
            cur.append(line)
    if cur:
        blocks.append("\n".join(cur))

check("at least 12 steps", len(blocks) >= 12, "got %d" % len(blocks))

# ---- 4. Required steps, in order ----------------------------------------
required = [
    ("checkout", "actions/checkout@v4"),
    ("runner preflight", "tools/ci-runner-preflight.sh"),
    ("cargo cache", "actions/cache@v4"),
    ("rustup gnu host", "rustup-init.sh"),
    ("rustfmt + clippy", "component add rustfmt clippy"),
    ("MinGW", "bootstrap-mingw.sh"),
    ("FFmpeg", "bootstrap-ffmpeg-retry.sh"),
    ("CMake", "bootstrap-cmake-v2.sh"),
    ("libclang.dll", "tools/llvm/bin/libclang.dll"),
    ("build --profile app", "build-gnu.sh --profile app"),
    ("stage portable", "bash tools/stage-portable.sh"),
    ("rust unit tests", "bash tools/test-gnu.sh all"),
    ("verification gate", "verify-longcut.ps1"),
    ("clean-PATH smoke", "smoke-windows.ps1"),
    ("WiX 4.0.5", "--version 4.0.5 wix"),
    ("build .msi", "build-installer.ps1"),
    ("upload artifact", "actions/upload-artifact@v4"),
]
positions = []
for label, needle in required:
    hit = next((i for i, b in enumerate(blocks) if needle in b), None)
    check("step: " + label, hit is not None, "not found: " + needle)
    positions.append(hit)
# Non-decreasing, not strictly increasing: one step may legitimately run
# several commands (rustup + rustfmt/clippy, the three bootstrap scripts).
ordered = all(positions[i] is not None and positions[i + 1] is not None
              and positions[i] <= positions[i + 1]
              for i in range(len(positions) - 1))
check("required steps are in pipeline order", ordered, str(positions))

# ---- 4b. First-run wiring ------------------------------------------------
def step_with(needle):
    return next((i for i, b in enumerate(blocks) if needle in b), None)


pre_pos = step_with("bash tools/ci-runner-preflight.sh")
rustup_pos = step_with("rustup-init.sh")
check("runner preflight runs before rustup",
      pre_pos is not None and rustup_pos is not None and pre_pos < rustup_pos,
      "pre=%s rustup=%s" % (pre_pos, rustup_pos))

stage_pos = step_with("bash tools/stage-portable.sh")
test_pos = step_with("bash tools/test-gnu.sh all")
# The test binaries sit in debug/deps without FFmpeg/MinGW DLLs beside them;
# test-gnu.sh puts the just-staged bundle on PATH. Reordering would bring back
# 0xc0000135 STATUS_DLL_NOT_FOUND.
check("unit tests run after portable staging",
      stage_pos is not None and test_pos is not None and stage_pos < test_pos,
      "stage=%s test=%s" % (stage_pos, test_pos))
test_block = blocks[test_pos] if test_pos is not None else ""
check("unit tests are serial", "LONGCUT_TEST_THREADS" in test_block
      and bool(re.search(r"LONGCUT_TEST_THREADS:\s*'1'", test_block)))
check("unit test step pins bash", bool(re.search(r"shell:\s*bash\s*$", test_block, re.M)))

preflight = os.path.join(ROOT, "tools", "ci-runner-preflight.sh")
pre_src = open(preflight, encoding="utf-8-sig").read() if os.path.isfile(preflight) else ""
check("preflight exports runner-local gnu linker",
      "CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER" in pre_src and "GITHUB_ENV" in pre_src)

# ---- 5. Every run: step pins a shell ------------------------------------
# Both block scalars (`run: |`) and one-liners (`run: bash ...`) must pin a
# shell; the two new steps are one-liners, so a `|`-only regex missed them.
run_blocks = [b for b in blocks if re.search(r"(?m)^\s+run:\s*\S", b)]
unpinned = [b.splitlines()[0].strip() for b in run_blocks
            if not re.search(r"(?m)^\s+shell:\s*(bash|pwsh)\s*$", b)]
check("all %d run: steps pin bash/pwsh" % len(run_blocks), not unpinned,
      ", ".join(unpinned))

# ---- 6. Referenced files exist ------------------------------------------
refs = [
    "tools/build-gnu.sh", "tools/stage-portable.sh", "tools/test-gnu.sh",
    "tools/ci-runner-preflight.sh",
    "scripts/ci/verify-longcut.ps1", "scripts/ci/smoke-windows.ps1",
    "scripts/ci/validate-workflow.py",
    "tools/build-installer.ps1", "tools/bootstrap-mingw.sh",
    "tools/bootstrap-ffmpeg-retry.sh", "tools/bootstrap-cmake-v2.sh",
    "assets/windows/concat.wxs", ".cargo/config.toml",
]
missing = [r for r in refs if not os.path.isfile(os.path.join(ROOT, r))]
check("all %d referenced files exist" % len(refs), not missing, ", ".join(missing))
check("artifact path: portable bundle", "dist/LongCut-win64-gnu/" in text)
check("artifact path: msi", "dist/*.msi" in text)

print("")
print("%d checks, %d failure(s)" % (total, len(fails)))
sys.exit(1 if fails else 0)
