#!/usr/bin/env python3
"""Parse and sanity-check LongCut's build configuration files.

Kept as a real script (rather than `python -c "..."`) because PowerShell 5.1
strips inner double quotes when passing a string to a native executable; an
inline one-liner silently turns tomllib.load(open(p, "rb")) into
open(p, rb) and fails with a NameError.

Exit code 0 = every config file is valid; 1 = at least one problem.
"""

from __future__ import annotations

import sys
import tomllib
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
TOML_FILES = [
    ".cargo/config.toml",
    "src/.cargo/config.toml",
    "src/Cargo.toml",
    "src/crates/concat/Cargo.toml",
    "src/rust-toolchain.toml",
]
failures: list[str] = []

for rel in TOML_FILES:
    path = ROOT / rel
    try:
        with path.open("rb") as fh:
            tomllib.load(fh)
        print(f"PASS TOML {rel}")
    except Exception as exc:  # noqa: BLE001 - report every file, do not stop early
        failures.append(f"TOML {rel}: {exc}")
        print(f"FAIL TOML {rel}: {exc}")

wxs = ROOT / "assets/windows/concat.wxs"
try:
    ET.parse(wxs)
    print("PASS XML  assets/windows/concat.wxs")
except Exception as exc:  # noqa: BLE001
    failures.append(f"XML assets/windows/concat.wxs: {exc}")
    print(f"FAIL XML  assets/windows/concat.wxs: {exc}")

# The gnu lane depends on these three settings. A mirror-only config (which
# the old setup script used to overwrite the file with) breaks the linker.
cfg = (ROOT / ".cargo/config.toml").read_text(encoding="utf-8")
for needle in ("x86_64-pc-windows-gnu", "dlltool", "rsproxy-sparse"):
    if needle in cfg:
        print(f"PASS config contains '{needle}'")
    else:
        failures.append(f".cargo/config.toml missing '{needle}'")
        print(f"FAIL config contains '{needle}'")

# The binary target must be longcut, and the package must stay concat: setup
# scripts select it with `-p concat --bin longcut`.
concat_manifest = (ROOT / "src/crates/concat/Cargo.toml").read_text(encoding="utf-8")
if "name = \"longcut\"" in concat_manifest:
    print("PASS bin target is named longcut")
else:
    failures.append("src/crates/concat/Cargo.toml no longer declares bin longcut")
    print("FAIL bin target is named longcut")

print(f"\n{len(TOML_FILES)} TOML + 1 XML + config invariants, {len(failures)} failure(s)")
sys.exit(1 if failures else 0)
