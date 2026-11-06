#!/usr/bin/env python3
"""Validate LongCut template manifests against the local JSON-Schema subset.

Pure stdlib on purpose: jsonschema is not installed on the build machine, and
adding a pip dependency just to check four small JSON files would make the
build gate fragile. The subset below is exactly the vocabulary used by
assets/templates/schema/template.manifest.schema.json (draft 2020-12).

It also runs negative fixtures: a validator that only ever sees valid input
does not prove that rateDen=0 (division by zero in the timeline) or an unknown
top-level key would actually be rejected. Those boundary cases are the point.

Exit code 0 = everything passed; 1 = at least one check failed.
"""

from __future__ import annotations

import copy
import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SCHEMA = ROOT / "assets/templates/schema/template.manifest.schema.json"
SAMPLES = sorted((ROOT / "assets/templates/samples").glob("*/template.json"))
LIBRARY = ROOT / "assets/templates/library.json"


def type_matches(value: object, want: str) -> bool:
    return {
        "object": isinstance(value, dict),
        "array": isinstance(value, list),
        "string": isinstance(value, str),
        "number": isinstance(value, (int, float)) and not isinstance(value, bool),
        "integer": isinstance(value, int) and not isinstance(value, bool),
        "boolean": isinstance(value, bool),
        "null": value is None,
    }.get(want, True)


def validate(value: object, schema: dict, path: str = "$", errors: list | None = None) -> list[str]:
    """Return a list of human-readable violations; empty means valid."""
    if errors is None:
        errors = []

    declared = schema.get("type")
    if declared:
        allowed = declared if isinstance(declared, list) else [declared]
        if not any(type_matches(value, t) for t in allowed):
            errors.append(f"{path}: expected type {declared}, got {type(value).__name__}")
            return errors

    if "enum" in schema and value not in schema["enum"]:
        errors.append(f"{path}: {value!r} is not in enum")

    if isinstance(value, str):
        if "minLength" in schema and len(value) < schema["minLength"]:
            errors.append(f"{path}: shorter than minLength={schema['minLength']}")
        if "pattern" in schema and not re.search(schema["pattern"], value):
            errors.append(f"{path}: does not match pattern {schema['pattern']!r}")

    if isinstance(value, (int, float)) and not isinstance(value, bool):
        if "minimum" in schema and value < schema["minimum"]:
            errors.append(f"{path}: {value} < minimum {schema['minimum']}")
        if "exclusiveMinimum" in schema and value <= schema["exclusiveMinimum"]:
            errors.append(f"{path}: {value} <= exclusiveMinimum {schema['exclusiveMinimum']}")
        if "maximum" in schema and value > schema["maximum"]:
            errors.append(f"{path}: {value} > maximum {schema['maximum']}")

    if isinstance(value, list):
        if "minItems" in schema and len(value) < schema["minItems"]:
            errors.append(f"{path}: shorter than minItems={schema['minItems']}")
        if "items" in schema:
            for i, item in enumerate(value):
                validate(item, schema["items"], f"{path}[{i}]", errors)

    if isinstance(value, dict):
        for required in schema.get("required", []):
            if required not in value:
                errors.append(f"{path}: missing required '{required}'")
        props = schema.get("properties", {})
        if schema.get("additionalProperties") is False:
            for key in value:
                if key not in props:
                    errors.append(f"{path}: unexpected key '{key}'")
        for key, item in value.items():
            if key in props:
                validate(item, props[key], f"{path}.{key}", errors)

    return errors


def load(path: Path):
    with path.open(encoding="utf-8") as fh:
        return json.load(fh)


def main() -> int:
    failures: list[str] = []
    schema = load(SCHEMA)

    if not SAMPLES:
        failures.append("no sample templates found under assets/templates/samples/")

    for sample in SAMPLES:
        errors = validate(load(sample), schema)
        rel = sample.relative_to(ROOT).as_posix()
        if errors:
            failures.append(f"{rel}: " + "; ".join(errors[:5]))
            print(f"FAIL {rel}")
            for e in errors[:5]:
                print(f"     {e}")
        else:
            print(f"PASS {rel} (conforms to schema)")

    # The library index must point at files that actually exist, otherwise a
    # template panel would show an entry that cannot be instantiated.
    library = load(LIBRARY)
    for entry in library.get("templates", []):
        target = ROOT / "assets/templates" / entry["path"]
        if target.exists():
            print(f"PASS library.json -> {entry['id']}")
        else:
            failures.append(f"library.json -> {entry['id']}: missing {entry['path']}")

    # Negative fixtures: each mutation MUST be rejected. If one slips through,
    # the schema boundary is not doing its job.
    base = load(SAMPLES[0]) if SAMPLES else {}
    negatives: list[tuple[str, object]] = []

    def mutated(name: str, fn) -> None:
        doc = copy.deepcopy(base)
        fn(doc)
        negatives.append((name, doc))

    mutated("rateDen=0 (division by zero)", lambda d: d["blueprint"]["video"].update(rateDen=0))
    mutated("unknown top-level key", lambda d: d.update(typo_key=True))
    mutated("missing manifest.id", lambda d: d["manifest"].pop("id", None))
    mutated("opacity > 1", lambda d: d["blueprint"]["clips"][0].update(opacity=1.5))
    mutated("empty slots", lambda d: d["manifest"].update(slots=[]))
    mutated("transition_in.duration=0", lambda d: d["blueprint"]["clips"][0].update(
        transition_in={"id": "fade", "duration": 0}))
    mutated("start is negative", lambda d: d["blueprint"]["clips"][0].update(start=-1))

    for name, doc in negatives:
        errors = validate(doc, schema)
        if errors:
            print(f"PASS negative fixture: {name} -> rejected")
        else:
            failures.append(f"negative fixture NOT rejected: {name}")
            print(f"FAIL negative fixture: {name} -> accepted")

    print(f"\n{len(SAMPLES)} samples, {len(negatives)} negative fixtures, "
          f"{len(failures)} failure(s)")
    return 1 if failures else 0


if __name__ == "__main__":
    sys.exit(main())
