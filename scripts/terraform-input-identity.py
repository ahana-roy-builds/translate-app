#!/usr/bin/env python3
"""Hash the exact clean Terraform planning/apply inputs for pre/post comparison."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import subprocess
from pathlib import Path


def safe_bytes(path: Path) -> bytes:
    descriptor = os.open(path, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise ValueError(f"unsafe Terraform input: {path}")
        with os.fdopen(os.dup(descriptor), "rb", closefd=True) as handle:
            value = handle.read()
        after = os.fstat(descriptor)
        identity = lambda row: (row.st_dev, row.st_ino, row.st_mode, row.st_nlink, row.st_size, row.st_mtime_ns, row.st_ctime_ns)
        if identity(before) != identity(after) or len(value) != before.st_size:
            raise ValueError(f"Terraform input changed while being hashed: {path}")
        return value
    finally:
        os.close(descriptor)


def capture(root: Path, stack: str, backend: Path, variables: Path | None) -> dict[str, str]:
    git_environment = {key: value for key, value in os.environ.items() if not key.startswith("GIT_")}
    git_environment.update({
        "PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "GIT_CONFIG_NOSYSTEM": "1",
        "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_NO_REPLACE_OBJECTS": "1", "LC_ALL": "C",
    })
    status = subprocess.run(
        ["/usr/bin/git", "status", "--porcelain", "--untracked-files=all"], cwd=root,
        check=True, capture_output=True, text=True, env=git_environment,
    ).stdout.strip()
    if status:
        raise ValueError("Terraform release planning/apply requires a completely clean Git checkout")
    flags = subprocess.run(
        ["/usr/bin/git", "ls-files", "-v"], cwd=root, check=True, capture_output=True, text=True, env=git_environment,
    ).stdout.splitlines()
    if any(row and not row.startswith("H ") for row in flags):
        raise ValueError("Terraform release inputs contain forbidden Git index flags")
    commit = subprocess.run(
        ["/usr/bin/git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True, env=git_environment,
    ).stdout.strip()
    stack_root = root / "infra" / stack
    auto_variables = (
        list(stack_root.glob("terraform.tfvars")) + list(stack_root.glob("terraform.tfvars.json"))
        + list(stack_root.glob("*.auto.tfvars")) + list(stack_root.glob("*.auto.tfvars.json"))
    )
    if auto_variables:
        raise ValueError("Terraform stack may not contain auto-loaded tfvars; use only the explicit reviewed -var-file")
    files = sorted(set(stack_root.glob("*.tf")) | set(stack_root.glob("*.tf.json"))) + [stack_root / ".terraform.lock.hcl"]
    stage_output = subprocess.run(
        ["/usr/bin/git", "ls-files", "--stage", "--", f"infra/{stack}"], cwd=root,
        check=True, capture_output=True, text=True, env=git_environment,
    ).stdout.splitlines()
    indexed: dict[str, tuple[str, str]] = {}
    for row in stage_output:
        metadata, separator, name = row.partition("\t")
        pieces = metadata.split()
        if not separator or len(pieces) != 3 or pieces[2] != "0":
            raise ValueError(f"invalid/non-stage-zero Terraform index entry: {row}")
        if name.endswith(".tf") or name.endswith(".tf.json") or name.endswith("/.terraform.lock.hcl"):
            indexed[name] = (pieces[0], pieces[1])
    actual_names = {path.relative_to(root).as_posix() for path in files}
    if set(indexed) != actual_names:
        raise ValueError("every Terraform config and provider lock must be tracked, with no ignored/untracked override files")
    configuration = hashlib.sha256()
    for path in files:
        relative = path.relative_to(root).as_posix()
        mode, blob = indexed[relative]
        if mode != "100644":
            raise ValueError(f"Terraform input must be a regular non-executable tracked file: {relative}")
        contents = safe_bytes(path)
        current_blob = subprocess.run(
            ["/usr/bin/git", "hash-object", "--no-filters", "--stdin"], cwd=root, env=git_environment,
            input=contents, check=True, capture_output=True,
        ).stdout.decode("ascii").strip()
        if current_blob != blob:
            raise ValueError(f"Terraform input does not match its reviewed index blob: {relative}")
        configuration.update(relative.encode() + b"\0" + contents + b"\0")
    result = {
        "source_commit": commit,
        "configuration_sha256": configuration.hexdigest(),
        "backend_config_sha256": hashlib.sha256(safe_bytes(backend)).hexdigest(),
    }
    if variables is not None:
        result["variables_sha256"] = hashlib.sha256(safe_bytes(variables)).hexdigest()
    return result


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, required=True)
    parser.add_argument("--stack", choices=("bootstrap", "service"), required=True)
    parser.add_argument("--backend", type=Path, required=True)
    parser.add_argument("--variables", type=Path)
    args = parser.parse_args()
    try:
        value = capture(args.root.resolve(strict=True), args.stack, args.backend.resolve(strict=True), args.variables.resolve(strict=True) if args.variables else None)
    except (OSError, ValueError, subprocess.CalledProcessError) as exc:
        parser.error(str(exc))
    print(json.dumps(value, sort_keys=True, separators=(",", ":")))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
