#!/usr/bin/env python3
"""Create a private immutable Terraform config/backend/tfvars snapshot and emit identity."""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path


HERE = Path(__file__).resolve().parent


def load(name: str, path: Path):
    spec = importlib.util.spec_from_file_location(name, path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"unable to load {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


IDENTITY = load("terraform_input_identity_snapshot", HERE / "terraform-input-identity.py")
COPY = load("copy_exclusive_snapshot", HERE / "copy-exclusive-file.py")


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--stack", choices=("bootstrap", "service"), required=True)
    parser.add_argument("--backend", type=Path, required=True)
    parser.add_argument("--variables", type=Path, required=True)
    parser.add_argument("--destination", type=Path, required=True)
    args = parser.parse_args()
    root = args.root.resolve(strict=True)
    backend = args.backend.resolve(strict=True)
    variables = args.variables.resolve(strict=True)
    initial = IDENTITY.capture(root, args.stack, backend, variables)
    destination = args.destination
    destination.mkdir(mode=0o700)
    stack_destination = destination / "stack"
    stack_destination.mkdir(mode=0o700)
    stack_root = root / "infra" / args.stack
    source_files = sorted(set(stack_root.glob("*.tf")) | set(stack_root.glob("*.tf.json"))) + [stack_root / ".terraform.lock.hcl"]
    for source in source_files:
        COPY.copy_exclusive(source, stack_destination / source.name)
    COPY.copy_exclusive(backend, destination / "backend.hcl")
    COPY.copy_exclusive(variables, destination / "variables.tfvars")
    final = IDENTITY.capture(root, args.stack, backend, variables)
    if initial != final:
        raise SystemExit("Terraform inputs changed while the private snapshot was created")
    config = hashlib.sha256()
    for source in source_files:
        snapshotted = stack_destination / source.name
        relative = source.relative_to(root).as_posix().encode()
        config.update(relative + b"\0" + snapshotted.read_bytes() + b"\0")
    snapshot_identity = {
        **initial,
        "configuration_sha256": config.hexdigest(),
        "backend_config_sha256": hashlib.sha256((destination / "backend.hcl").read_bytes()).hexdigest(),
        "variables_sha256": hashlib.sha256((destination / "variables.tfvars").read_bytes()).hexdigest(),
    }
    if snapshot_identity != initial:
        raise SystemExit("private Terraform snapshot does not match reviewed input identity")
    print(json.dumps(initial, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
