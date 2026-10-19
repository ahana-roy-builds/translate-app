#!/usr/bin/env python3
"""Safely snapshot a regular single-link file to a new exclusive destination."""

from __future__ import annotations

import argparse
import os
import stat
from pathlib import Path


def _open_parent(destination: Path) -> tuple[int, str]:
    """Open and hold destination's parent without following directory symlinks."""

    if destination.name in {"", ".", ".."}:
        raise OSError("destination must name a file")

    directory_flags = os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    if destination.is_absolute():
        directory_fd = os.open("/", directory_flags)
        components = destination.parent.parts[1:]
    else:
        directory_fd = os.open(".", directory_flags)
        components = destination.parent.parts

    try:
        for component in components:
            if component in {"", "."}:
                continue
            if component == "..":
                raise OSError("destination parent may not contain '..'")
            next_fd = os.open(component, directory_flags, dir_fd=directory_fd)
            os.close(directory_fd)
            directory_fd = next_fd
        return directory_fd, destination.name
    except Exception:
        os.close(directory_fd)
        raise


def copy_exclusive(source: Path, destination: Path) -> None:
    source_fd = os.open(source, os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0))
    parent_fd: int | None = None
    destination_fd: int | None = None
    created = False
    try:
        before = os.fstat(source_fd)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1:
            raise OSError("source must be a regular single-link file")
        parent_fd, destination_name = _open_parent(destination)
        destination_fd = os.open(
            destination_name,
            os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
            0o600,
            dir_fd=parent_fd,
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
            raise OSError("source changed while it was being snapshotted")
    except Exception:
        if created and parent_fd is not None:
            try:
                os.unlink(destination_name, dir_fd=parent_fd)
            except FileNotFoundError:
                pass
        raise
    finally:
        if destination_fd is not None:
            os.close(destination_fd)
        if parent_fd is not None:
            os.fsync(parent_fd)
            os.close(parent_fd)
        os.close(source_fd)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    try:
        copy_exclusive(args.source, args.destination)
    except OSError as exc:
        parser.error(str(exc))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
