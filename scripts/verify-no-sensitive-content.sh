#!/usr/bin/env bash
set -euo pipefail

root="${LOCALLINGO_SCAN_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
[[ -d "$root" ]] || { echo "scan root is not a directory: $root" >&2; exit 2; }

python3 - "$root" <<'PY'
from __future__ import annotations

import os
import re
import sys
from pathlib import Path

root = Path(sys.argv[1]).resolve(strict=True)
excluded_roots = {
    ".git",
    "backend/node_modules",
    "backend/dist",
    "backend/coverage",
    "infra/bootstrap/.terraform",
    "infra/service/.terraform",
}
excluded_file = "scripts/verify-no-sensitive-content.sh"
forbidden_names = {
    "GoogleService-Info.plist",
    "credentials.json",
    "service-account.json",
    "service_account.json",
    "id_rsa",
    "id_ed25519",
}
secret_patterns = [
    re.compile(rb"-----BEGIN (?:ENCRYPTED |RSA |EC |OPENSSH )?PRIVATE KEY-----"),
    re.compile(rb"-----BEGIN (?:ENCRYPTED |RSA |EC |OPENSSH )?PRIVATE KEY-----\\(?:r)?n"),
    re.compile(rb"AIza[0-9A-Za-z_-]{30,}"),
    re.compile(rb"gh[pousr]_[0-9A-Za-z]{30,}"),
    re.compile(rb"github_pat_[0-9A-Za-z_]{40,}"),
    re.compile(rb"AKIA[0-9A-Z]{16}"),
    re.compile(rb"xox[baprs]-[0-9A-Za-z-]{20,}"),
    re.compile(rb'"type"\s*:\s*"service_account".{0,4096}"private_key"\s*:', re.DOTALL),
]

errors: list[str] = []
for directory, names, files in os.walk(root, topdown=True, followlinks=False):
    directory_path = Path(directory)
    relative_directory = directory_path.relative_to(root).as_posix()
    kept = []
    for name in names:
        candidate = directory_path / name
        relative = candidate.relative_to(root).as_posix()
        if candidate.is_symlink():
            errors.append(f"{relative}: symlinked directory is forbidden")
            continue
        if relative in excluded_roots or any(relative.startswith(prefix + "/") for prefix in excluded_roots):
            continue
        kept.append(name)
    names[:] = kept
    for name in files:
        path = directory_path / name
        relative = path.relative_to(root).as_posix()
        if relative == excluded_file:
            continue
        if path.is_symlink():
            errors.append(f"{relative}: symlinked file is forbidden")
            continue
        try:
            if not path.is_file():
                errors.append(f"{relative}: special non-regular file is forbidden")
                continue
        except OSError as exc:
            errors.append(f"{relative}: unable to inspect: {exc}")
            continue
        lower = name.lower()
        if (lower == ".env" or (lower.startswith(".env.") and lower != ".env.example")):
            errors.append(f"{relative}: forbidden .env variant")
        if name in forbidden_names or lower.endswith((".p8", ".p12", ".mobileprovision")):
            errors.append(f"{relative}: forbidden credential/provisioning filename")
        try:
            matched = False
            overlap = b""
            with path.open("rb") as handle:
                for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                    window = overlap + chunk
                    if any(pattern.search(window) for pattern in secret_patterns):
                        matched = True
                        break
                    overlap = window[-8192:]
        except OSError as exc:
            errors.append(f"{relative}: unable to scan: {exc}")
            continue
        if matched:
            errors.append(f"{relative}: potential credential material")

if errors:
    for error in sorted(set(errors)):
        print(error, file=sys.stderr)
    print(f"Sensitive-content scan failed with {len(set(errors))} finding(s).", file=sys.stderr)
    raise SystemExit(1)
print("Sensitive-content scan passed.")
PY
