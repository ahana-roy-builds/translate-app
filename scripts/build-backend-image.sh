#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

: "${NODE_IMAGE:?NODE_IMAGE must be an approved node image pinned by sha256 digest}"
: "${BACKEND_IMAGE:?BACKEND_IMAGE must be the destination registry tag}"
: "${NODE_IMAGE_POLICY_FILE:?NODE_IMAGE_POLICY_FILE must list reviewed exact base-image references}"
: "${BACKEND_OCI_OUTPUT:?BACKEND_OCI_OUTPUT must be an absolute output path for the OCI image archive}"
: "${BUILD_METADATA:?BUILD_METADATA must be an absolute output path for BuildKit metadata/provenance}"
: "${SBOM_OUTPUT:?SBOM_OUTPUT must be an absolute output path for the CycloneDX dependency SBOM}"

if [[ ! "$NODE_IMAGE" =~ @sha256:[a-f0-9]{64}$ ]]; then
  echo "NODE_IMAGE must end in @sha256 followed by 64 lowercase hexadecimal characters" >&2
  exit 2
fi

if ! command -v docker >/dev/null; then
  echo "docker is required" >&2
  exit 2
fi

for output in "$BACKEND_OCI_OUTPUT" "$BUILD_METADATA" "$SBOM_OUTPUT"; do
  [[ "$output" = /* ]] || { echo "release outputs must use absolute paths" >&2; exit 2; }
  [[ ! -L "$output" ]] || { echo "release outputs may not be symlinks" >&2; exit 2; }
  [[ -d "$(dirname "$output")" ]] || { echo "release output parent directory is missing: $output" >&2; exit 2; }
  [[ ! -e "$output" ]] || { echo "release output already exists and will not be replaced: $output" >&2; exit 2; }
done

temporary_output="$(mktemp -d "${TMPDIR:-/tmp}/locallingo-backend-build.XXXXXXXX")"
trap 'rm -rf "$temporary_output"' EXIT
temporary_oci="$temporary_output/backend.oci"
temporary_metadata="$temporary_output/build-metadata.json"
temporary_sbom="$temporary_output/sbom.cdx.json"

[[ -f "$NODE_IMAGE_POLICY_FILE" && ! -L "$NODE_IMAGE_POLICY_FILE" ]] || {
  echo "NODE_IMAGE_POLICY_FILE must be a regular non-symlink file" >&2
  exit 2
}
rg -F -x -q "$NODE_IMAGE" "$NODE_IMAGE_POLICY_FILE" || {
  echo "NODE_IMAGE is digest-pinned but is not present in the reviewed policy file" >&2
  exit 2
}

docker buildx version >/dev/null || { echo "Docker Buildx is required" >&2; exit 2; }

build_identity="$(python3 - "$root" <<'PY'
import hashlib
import re
import subprocess
import sys
from pathlib import Path

root = Path(sys.argv[1])
backend = root / "backend"
fixed = [backend / name for name in (".dockerignore", "Dockerfile", "tsconfig.json", "scripts/apply-storekit-ocsp-patch.mjs")]
packages = sorted(backend.glob("package*.json"))
symlinks = [path for path in (backend / "src").rglob("*") if path.is_symlink()]
sources = [path for path in (backend / "src").rglob("*") if path.is_file() and not path.is_symlink()]
if any(not item.is_file() or item.is_symlink() for item in fixed):
    raise SystemExit("backend release context contains a missing or symlinked fixed build input")
if not (backend / "package.json").is_file() or not (backend / "package-lock.json").is_file():
    raise SystemExit("backend release context is missing package.json or package-lock.json")
if any(item.is_symlink() for item in packages):
    raise SystemExit("backend release context contains a symlinked package input")
if symlinks:
    raise SystemExit(f"backend release source contains a symlink: {symlinks[0]}")
expected_dockerignore = {
    "**", "!Dockerfile", "!package.json", "!package-lock.json", "!tsconfig.json",
    "!src/", "!src/**", "!scripts/", "!scripts/apply-storekit-ocsp-patch.mjs",
}
actual_dockerignore = {
    line.strip() for line in (backend / ".dockerignore").read_text(encoding="utf-8").splitlines()
    if line.strip() and not line.lstrip().startswith("#")
}
if actual_dockerignore != expected_dockerignore:
    raise SystemExit("backend/.dockerignore must be the reviewed deny-by-default allowlist")
dockerfile_lines = (backend / "Dockerfile").read_text(encoding="utf-8").splitlines()
bases = []
for raw in dockerfile_lines:
    line = raw.strip()
    if not line or line.startswith("#"):
        continue
    match = re.match(r"FROM(?:\s+--platform=\S+)?\s+(\S+)", line, re.IGNORECASE)
    if match:
        bases.append(match.group(1))
if not bases or any(base != "${NODE_IMAGE}" for base in bases):
    raise SystemExit("every backend Dockerfile stage must use the approved NODE_IMAGE argument")
hasher = hashlib.sha256()
for item in sorted(fixed + packages + sources, key=lambda value: value.relative_to(root).as_posix()):
    relative = item.relative_to(root).as_posix().encode("utf-8")
    hasher.update(relative + b"\0" + item.read_bytes() + b"\0")
commit = subprocess.run(
    ["git", "rev-parse", "HEAD"], cwd=root, check=True, capture_output=True, text=True
).stdout.strip()
if not re.fullmatch(r"[a-f0-9]{40}", commit):
    raise SystemExit("unable to bind backend build metadata to a full Git commit")
print(commit, hasher.hexdigest())
PY
)"
read -r build_commit build_context_sha256 <<<"$build_identity"

npm --prefix backend sbom --package-lock-only --sbom-format cyclonedx \
  | tee "$temporary_sbom" >/dev/null

python3 -I - "$temporary_sbom" <<'PY'
import json
import sys
from pathlib import Path

document = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
if (
    not isinstance(document, dict)
    or document.get("bomFormat") != "CycloneDX"
    or document.get("specVersion") != "1.5"
    or not isinstance(document.get("components"), list)
):
    raise SystemExit("npm release SBOM must be a CycloneDX 1.5 document with a component array")
PY

BUILDX_METADATA_PROVENANCE=max docker buildx build \
  --pull \
  --platform linux/amd64 \
  --build-arg "NODE_IMAGE=$NODE_IMAGE" \
  --tag "$BACKEND_IMAGE" \
  --provenance=mode=max \
  --sbom=true \
  --metadata-file "$temporary_metadata" \
  --output "type=oci,dest=$temporary_oci" \
  backend

python3 - "$temporary_metadata" "$NODE_IMAGE" "$root" "$build_commit" "$build_context_sha256" <<'PY'
import hashlib
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
node_image = sys.argv[2]
root = Path(sys.argv[3])
build_commit = sys.argv[4]
build_context_sha256 = sys.argv[5]
document = json.loads(path.read_text(encoding="utf-8"))
digest = document.get("containerimage.digest")
if not isinstance(digest, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
    raise SystemExit("BuildKit metadata is missing the immutable application image digest")
provenance = document.get("buildx.build.provenance")
if not isinstance(provenance, dict):
    raise SystemExit("BuildKit metadata is missing provenance; release builds require --provenance=mode=max")
base_hash = node_image.rsplit("@sha256:", 1)[-1]
materials = provenance.get("materials")
if not isinstance(materials, list):
    raise SystemExit("BuildKit provenance is missing the exact materials array")
matches = [
    material for material in materials
    if isinstance(material, dict)
    and isinstance(material.get("digest"), dict)
    and material["digest"].get("sha256") == base_hash
]
if len(matches) != 1:
    raise SystemExit("BuildKit provenance materials do not structurally bind the approved base-image digest")

backend = root / "backend"
fixed = [backend / name for name in (".dockerignore", "Dockerfile", "tsconfig.json", "scripts/apply-storekit-ocsp-patch.mjs")]
packages = sorted(backend.glob("package*.json"))
symlinks = [item for item in (backend / "src").rglob("*") if item.is_symlink()]
sources = [item for item in (backend / "src").rglob("*") if item.is_file() and not item.is_symlink()]
paths = fixed + packages + sources
if any(not item.is_file() or item.is_symlink() for item in fixed):
    raise SystemExit("backend release context contains a missing or symlinked fixed build input")
if not (backend / "package.json").is_file() or not (backend / "package-lock.json").is_file() or any(item.is_symlink() for item in packages) or symlinks:
    raise SystemExit("backend release context changed to an invalid shape during the build")
hasher = hashlib.sha256()
for item in sorted(paths, key=lambda value: value.relative_to(root).as_posix()):
    relative = item.relative_to(root).as_posix().encode("utf-8")
    hasher.update(relative + b"\0" + item.read_bytes() + b"\0")
if hasher.hexdigest() != build_context_sha256:
    raise SystemExit("backend build inputs changed while BuildKit was running")
document["locallingo.release"] = {
    "schema_version": "1.0",
    "source_commit": build_commit,
    "base_image": node_image,
    "application_image_digest": digest,
    "platform": "linux/amd64",
    "backend_context_sha256": build_context_sha256,
}
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
print(f"Built application image digest: {digest}")
PY

application_digest="$(python3 - "$temporary_metadata" <<'PY'
import json
import sys
print(json.load(open(sys.argv[1], encoding="utf-8"))["containerimage.digest"])
PY
)"
runnable_manifest_digest="$(python3 scripts/validate-oci-archive.py --archive "$temporary_oci" --expected-digest "$application_digest")"

python3 - "$temporary_metadata" "$application_digest" "$runnable_manifest_digest" <<'PY'
import json
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
index_digest, runnable_digest = sys.argv[2:]
if not all(re.fullmatch(r"sha256:[a-f0-9]{64}", value) for value in (index_digest, runnable_digest)):
    raise SystemExit("validated OCI identity contains an invalid digest")
if index_digest == runnable_digest:
    raise SystemExit("attested OCI index and runnable platform manifest must have distinct digests")
document = json.loads(path.read_text(encoding="utf-8"))
release = document.get("locallingo.release")
if not isinstance(release, dict) or document.get("containerimage.digest") != index_digest:
    raise SystemExit("BuildKit metadata changed before OCI identity binding")
release["oci_index_digest"] = index_digest
release["runnable_manifest_digest"] = runnable_digest
path.write_text(json.dumps(document, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY

python3 - "$temporary_oci" "$BACKEND_OCI_OUTPUT" "$temporary_metadata" "$BUILD_METADATA" "$temporary_sbom" "$SBOM_OUTPUT" <<'PY'
import os
import shutil
import stat
import sys
from pathlib import Path

pairs = list(zip(map(Path, sys.argv[1::2]), map(Path, sys.argv[2::2])))
created = []
try:
    for source, destination in pairs:
        source_stat = source.stat()
        if not stat.S_ISREG(source_stat.st_mode) or source.is_symlink() or source_stat.st_nlink != 1:
            raise OSError(f"unsafe generated release output: {source}")
        flags = os.O_WRONLY | os.O_CREAT | os.O_EXCL | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        descriptor = os.open(destination, flags, 0o600)
        created.append(destination)
        with os.fdopen(descriptor, "wb") as target, source.open("rb") as current:
            shutil.copyfileobj(current, target, 1024 * 1024)
            target.flush()
            os.fsync(target.fileno())
except Exception:
    for path in created:
        path.unlink(missing_ok=True)
    raise
PY
