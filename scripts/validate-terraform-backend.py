#!/usr/bin/env python3
"""Parse the reviewed literal GCS backend and optionally verify initialized state."""

from __future__ import annotations

import argparse
import json
import re
from pathlib import Path


def parse_backend(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for number, raw in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r'(bucket|prefix)\s*=\s*"([^"\n]+)"', line)
        if not match or match.group(1) in result:
            raise ValueError(f"{path}:{number}: only one literal bucket and prefix are allowed")
        key, value = match.groups()
        if any(marker in value.lower() for marker in ("replace", "example", "placeholder", ".invalid")):
            raise ValueError(f"{path}:{number}: backend setting contains a placeholder")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,254}", value) or "//" in value or ".." in value:
            raise ValueError(f"{path}:{number}: backend setting contains unsafe characters")
        result[key] = value
    if set(result) != {"bucket", "prefix"}:
        raise ValueError(f"{path}: exactly one bucket and one prefix are required")
    return result


def verify_initialized(state_path: Path, expected: dict[str, str]) -> None:
    state = json.loads(state_path.read_text(encoding="utf-8"))
    backend = state.get("backend")
    if not isinstance(backend, dict) or backend.get("type") != "gcs":
        raise ValueError("initialized Terraform backend is not GCS")
    config = backend.get("config")
    if not isinstance(config, dict):
        raise ValueError("initialized Terraform backend lacks configuration")
    actual = {name: config.get(name) for name in ("bucket", "prefix")}
    if actual != expected:
        raise ValueError(f"initialized Terraform backend mismatch: expected {expected}, got {actual}")
    if config.get("storage_custom_endpoint") not in (None, "", "https://storage.googleapis.com"):
        raise ValueError("initialized Terraform backend uses a forbidden custom storage endpoint")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("backend", type=Path)
    parser.add_argument("--initialized-state", type=Path)
    args = parser.parse_args()
    try:
        expected = parse_backend(args.backend)
        if args.initialized_state is not None:
            verify_initialized(args.initialized_state, expected)
    except (OSError, UnicodeDecodeError, json.JSONDecodeError, ValueError) as exc:
        parser.error(str(exc))
    print(json.dumps(expected, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
