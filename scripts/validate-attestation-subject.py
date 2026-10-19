#!/usr/bin/env python3
"""Validate a protected-workspace JSON subject before GitHub attestation."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import stat
from pathlib import Path, PurePosixPath


KINDS = {
    "urn:locallingo:attestation:preflight:v2": "preflight",
    "urn:locallingo:attestation:criteria:v2": "criteria",
    "urn:locallingo:attestation:corpus-manifest:v2": "corpus-manifest",
    "urn:locallingo:attestation:device-registry:v1": None,
    "urn:locallingo:attestation:ios-build:v1": "ios-build",
    "urn:locallingo:attestation:backend-provenance:v1": "backend-provenance",
    "urn:locallingo:attestation:backend-sbom:v1": "backend-sbom",
    "urn:locallingo:attestation:vulnerability-scan:v1": "vulnerability-scan",
    "urn:locallingo:attestation:secret-scan:v1": "secret-scan",
    "urn:locallingo:attestation:environment-policy:v1": "environment-policy",
    "urn:locallingo:attestation:terraform-plan:v2": "terraform-plan",
    "urn:locallingo:attestation:deployment-receipt:v1": "deployment-receipt",
    "urn:locallingo:attestation:device-run:v2": "device-run",
    "urn:locallingo:attestation:release-candidate:v2": None,
    "urn:locallingo:attestation:approval:v1": None,
    "urn:locallingo:attestation:release-decision:v2": None,
}
SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def strict_json_loads(contents: bytes) -> object:
    def pairs(rows):
        result = {}
        for key, value in rows:
            if key in result:
                raise ValueError(f"duplicate JSON key {key!r}")
            result[key] = value
        return result

    def constant(value):
        raise ValueError(f"non-finite JSON value {value}")

    value = json.loads(contents.decode("utf-8", errors="strict"), object_pairs_hook=pairs, parse_constant=constant)
    stack = [(value, 0)]
    nodes = 0
    while stack:
        current, depth = stack.pop()
        nodes += 1
        if nodes > 1_000_000 or depth > 128:
            raise ValueError("JSON nesting/node bound exceeded")
        if isinstance(current, str):
            current.encode("utf-8", errors="strict")
        elif isinstance(current, dict):
            stack.extend((item, depth + 1) for item in current.values())
        elif isinstance(current, list):
            stack.extend((item, depth + 1) for item in current)
    return value


def validated_relative_path(value: str, label: str) -> PurePosixPath:
    relative = PurePosixPath(value)
    if (
        not value or len(value) > 1024 or relative.is_absolute() or str(relative) != value
        or any(part in {"", ".", ".."} or SAFE_COMPONENT.fullmatch(part) is None for part in relative.parts)
        or "\\" in value or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValueError(f"{label} must be a normalized relative path using safe filename characters")
    return relative


def open_beneath(root: Path, relative: PurePosixPath) -> int:
    current = os.open(root, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    try:
        for component in relative.parts[:-1]:
            following = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=current,
            )
            os.close(current)
            current = following
        descriptor = os.open(
            relative.parts[-1], os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            dir_fd=current,
        )
        return descriptor
    finally:
        os.close(current)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--subject", required=True)
    parser.add_argument("--predicate-type", choices=tuple(KINDS), required=True)
    parser.add_argument("--allow", action="append", required=True)
    parser.add_argument("--snapshot-directory", type=Path, required=True)
    args = parser.parse_args()
    if args.predicate_type not in args.allow:
        parser.error("predicate type is not authorized for this protected workflow")
    try:
        relative = validated_relative_path(args.subject, "subject")
    except ValueError as exc:
        parser.error(str(exc))
    try:
        descriptor = open_beneath(args.artifact_root, relative)
    except OSError as exc:
        parser.error(f"unable to open subject beneath artifact root: {exc}")
    try:
        metadata = os.fstat(descriptor)
        if not stat.S_ISREG(metadata.st_mode) or metadata.st_nlink != 1 or not 1 <= metadata.st_size <= 16 * 1024 * 1024:
            parser.error("subject must be a bounded regular single-link JSON file")
        with os.fdopen(os.dup(descriptor), "rb", closefd=True) as handle:
            contents = handle.read()
        after = os.fstat(descriptor)
        before_identity = (metadata.st_dev, metadata.st_ino, metadata.st_mode, metadata.st_nlink, metadata.st_size, metadata.st_mtime_ns, metadata.st_ctime_ns)
        after_identity = (after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
        if before_identity != after_identity or len(contents) != metadata.st_size:
            parser.error("subject changed during validation")
    finally:
        os.close(descriptor)
    try:
        document = strict_json_loads(contents)
    except (UnicodeError, json.JSONDecodeError, ValueError, RecursionError):
        parser.error("subject must be valid UTF-8 JSON")
    if not isinstance(document, dict):
        parser.error("subject JSON must be an object")
    expected_kind = KINDS[args.predicate_type]
    if expected_kind is not None and document.get("kind") != expected_kind:
        parser.error(f"subject kind must be {expected_kind}")
    snapshot_directory = args.snapshot_directory.resolve(strict=True)
    if not snapshot_directory.is_dir() or snapshot_directory.is_symlink():
        parser.error("snapshot directory must be a real directory")
    snapshot_root = snapshot_directory / f"locallingo-attestation-{hashlib.sha256(contents).hexdigest()}"
    os.mkdir(snapshot_root, 0o700)
    snapshot = snapshot_root / relative.name
    output = os.open(snapshot, os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0), 0o600)
    try:
        with os.fdopen(output, "wb", closefd=False) as handle:
            handle.write(contents)
            handle.flush()
            os.fsync(handle.fileno())
    finally:
        os.close(output)
    print(snapshot)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
