#!/usr/bin/env python3
"""Publish one generated release artifact without following or replacing files."""

from __future__ import annotations

import argparse
import os
import re
import stat
from pathlib import Path, PurePosixPath


SAFE_COMPONENT = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$")


def validated_relative_path(value: str, label: str) -> PurePosixPath:
    relative = PurePosixPath(value)
    if (
        not value or len(value) > 1024 or relative.is_absolute() or str(relative) != value
        or any(part in {"", ".", ".."} or SAFE_COMPONENT.fullmatch(part) is None for part in relative.parts)
        or "\\" in value or any(ord(character) < 32 or ord(character) == 127 for character in value)
    ):
        raise ValueError(f"{label} must be a normalized relative path using safe filename characters")
    return relative


def _open_parent(root_fd: int, parts: tuple[str, ...]) -> int:
    current = os.dup(root_fd)
    try:
        for component in parts:
            following = os.open(
                component,
                os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=current,
            )
            os.close(current)
            current = following
        return current
    except Exception:
        os.close(current)
        raise


def publish(root: Path, source: Path, relative: PurePosixPath) -> None:
    root_fd = os.open(root, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    parent_fd: int | None = None
    destination_fd: int | None = None
    created = False
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise OSError("source must be a regular single-link file")
        parent_fd = _open_parent(root_fd, relative.parts[:-1])
        destination_fd = os.open(
            relative.parts[-1],
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            0o600, dir_fd=parent_fd,
        )
        created = True
        total = 0
        while True:
            chunk = os.read(source_fd, 1024 * 1024)
            if not chunk:
                break
            view = memoryview(chunk)
            while view:
                written = os.write(destination_fd, view)
                view = view[written:]
            total += len(chunk)
        os.fsync(destination_fd)
        after = os.fstat(source_fd)
        identity = lambda row: (row.st_dev, row.st_ino, row.st_mode, row.st_nlink, row.st_size, row.st_mtime_ns, row.st_ctime_ns)
        if identity(before) != identity(after) or total != before.st_size:
            raise OSError("source changed while it was being published")
        os.fsync(parent_fd)
    except Exception:
        if created and parent_fd is not None:
            os.unlink(relative.parts[-1], dir_fd=parent_fd)
            os.fsync(parent_fd)
        raise
    finally:
        if destination_fd is not None:
            os.close(destination_fd)
        if parent_fd is not None:
            os.close(parent_fd)
        os.close(source_fd)
        os.close(root_fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--destination", required=True)
    args = parser.parse_args()
    try:
        relative = validated_relative_path(args.destination, "destination")
    except ValueError as exc:
        parser.error(str(exc))
    try:
        publish(args.artifact_root, args.source, relative)
    except OSError as exc:
        parser.error(str(exc))
    print(args.artifact_root.joinpath(*relative.parts))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
