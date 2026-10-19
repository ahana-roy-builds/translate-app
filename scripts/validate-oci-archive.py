#!/usr/bin/env python3
"""Validate an attested OCI image-layout tar and return its linux/amd64 manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import tarfile
from pathlib import PurePosixPath, Path
from typing import Any


DIGEST = re.compile(r"^sha256:([a-f0-9]{64})$")
MAX_MEMBERS = 10_000
MAX_TOTAL_BYTES = 10 * 1024**3
MAX_METADATA_BYTES = 16 * 1024**2


def digest_hex(value: Any, label: str) -> str:
    if not isinstance(value, str) or (match := DIGEST.fullmatch(value)) is None:
        raise ValueError(f"{label} must be a sha256 OCI digest")
    return match.group(1)


def validate_archive(path: Path, expected_digest: str) -> str:
    expected_hash = digest_hex(expected_digest, "expected digest")
    if path.is_symlink() or not path.is_file() or path.stat().st_nlink != 1:
        raise ValueError("OCI archive must be a regular single-link file")
    try:
        archive = tarfile.open(path, mode="r:")
    except tarfile.TarError as exc:
        raise ValueError(f"OCI archive must be an uncompressed tar: {exc}") from exc
    with archive:
        members = archive.getmembers()
        if not 1 <= len(members) <= MAX_MEMBERS:
            raise ValueError("OCI archive member count is outside the reviewed bound")
        seen: set[str] = set()
        files: dict[str, tarfile.TarInfo] = {}
        total = 0
        for member in members:
            name = member.name
            relative = PurePosixPath(name)
            if relative.is_absolute() or str(relative) != name or any(part in {"", ".", ".."} for part in relative.parts):
                raise ValueError(f"OCI archive contains noncanonical path {name!r}")
            if name in seen:
                raise ValueError(f"OCI archive contains duplicate member {name}")
            seen.add(name)
            if member.isdir():
                continue
            if not member.isreg():
                raise ValueError(f"OCI archive contains link or special member {name}")
            if member.size < 0 or member.size > MAX_TOTAL_BYTES:
                raise ValueError(f"OCI archive member {name} exceeds size policy")
            total += member.size
            if total > MAX_TOTAL_BYTES:
                raise ValueError("OCI archive expanded size exceeds 10 GiB")
            files[name] = member
        if set(files) - {"oci-layout", "index.json"} - {name for name in files if re.fullmatch(r"blobs/sha256/[a-f0-9]{64}", name)}:
            raise ValueError("OCI archive contains files outside the image-layout allowlist")

        def bytes_for(name: str, limit: int = MAX_METADATA_BYTES) -> bytes:
            member = files.get(name)
            if member is None or member.size > limit:
                raise ValueError(f"OCI archive is missing bounded metadata {name}")
            handle = archive.extractfile(member)
            if handle is None:
                raise ValueError(f"OCI archive cannot read {name}")
            contents = handle.read(limit + 1)
            if len(contents) != member.size:
                raise ValueError(f"OCI archive member {name} changed/truncated")
            return contents

        def json_for(name: str) -> dict[str, Any]:
            try:
                value = json.loads(bytes_for(name))
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ValueError(f"OCI metadata {name} is invalid JSON") from exc
            if not isinstance(value, dict):
                raise ValueError(f"OCI metadata {name} must be an object")
            return value

        if json_for("oci-layout") != {"imageLayoutVersion": "1.0.0"}:
            raise ValueError("OCI layout version must be exactly 1.0.0")
        index_bytes = bytes_for("index.json")
        index_hash = hashlib.sha256(index_bytes).hexdigest()
        if index_hash != expected_hash:
            raise ValueError("OCI root index digest does not match BuildKit metadata")
        index = json_for("index.json")
        if set(index) - {"schemaVersion", "mediaType", "manifests", "annotations"}:
            raise ValueError("OCI index contains unsupported fields")
        manifests = index.get("manifests")
        if index.get("schemaVersion") != 2 or not isinstance(manifests, list) or not manifests:
            raise ValueError("OCI index must contain image and attestation descriptors")
        if index.get("mediaType") not in {None, "application/vnd.oci.image.index.v1+json"}:
            raise ValueError("OCI index media type is invalid")

        reachable: set[str] = set()

        def descriptor_bytes(descriptor: Any, label: str, *, metadata: bool = False) -> tuple[str, bytes | None]:
            if not isinstance(descriptor, dict):
                raise ValueError(f"{label} must be an OCI descriptor")
            if set(descriptor) - {"mediaType", "digest", "size", "platform", "annotations"}:
                raise ValueError(f"{label} contains unsupported descriptor fields")
            blob_hash = digest_hex(descriptor.get("digest"), f"{label} digest")
            size_value = descriptor.get("size")
            if isinstance(size_value, bool) or not isinstance(size_value, int) or size_value < 1:
                raise ValueError(f"{label} size must be a positive integer")
            blob_name = f"blobs/sha256/{blob_hash}"
            member = files.get(blob_name)
            if member is None or member.size != size_value:
                raise ValueError(f"{label} has no size-matched blob")
            handle = archive.extractfile(member)
            if handle is None:
                raise ValueError(f"{label} cannot be read")
            hasher = hashlib.sha256()
            size = 0
            captured = bytearray() if metadata else None
            for chunk in iter(lambda: handle.read(1024 * 1024), b""):
                hasher.update(chunk)
                size += len(chunk)
                if captured is not None:
                    if size > MAX_METADATA_BYTES:
                        raise ValueError(f"{label} exceeds metadata size policy")
                    captured.extend(chunk)
            if size != member.size or hasher.hexdigest() != blob_hash:
                raise ValueError(f"{label} does not match blob bytes")
            reachable.add(blob_name)
            return blob_hash, bytes(captured) if captured is not None else None

        def descriptor_json(descriptor: Any, label: str) -> tuple[str, dict[str, Any]]:
            blob_hash, contents = descriptor_bytes(descriptor, label, metadata=True)
            try:
                value = json.loads(contents or b"")
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ValueError(f"{label} blob is invalid JSON") from exc
            if not isinstance(value, dict):
                raise ValueError(f"{label} blob must be a JSON object")
            return blob_hash, value

        runnable_descriptors: list[dict[str, Any]] = []
        attestation_descriptors: list[dict[str, Any]] = []
        root_digests: set[str] = set()
        for number, descriptor in enumerate(manifests):
            if not isinstance(descriptor, dict):
                raise ValueError(f"OCI root descriptor {number} is invalid")
            current_hash = digest_hex(descriptor.get("digest"), f"OCI root descriptor {number} digest")
            if current_hash in root_digests:
                raise ValueError("OCI index contains a duplicate root descriptor")
            root_digests.add(current_hash)
            platform = descriptor.get("platform")
            if platform == {"architecture": "amd64", "os": "linux"}:
                runnable_descriptors.append(descriptor)
            elif platform == {"architecture": "unknown", "os": "unknown"}:
                annotations = descriptor.get("annotations")
                if not isinstance(annotations, dict) or any(
                    not isinstance(key, str) or not isinstance(value, str) for key, value in annotations.items()
                ):
                    raise ValueError("OCI attestation descriptor annotations are invalid")
                if annotations.get("vnd.docker.reference.type") != "attestation-manifest":
                    raise ValueError("OCI unknown/unknown descriptor is not a BuildKit attestation")
                attestation_descriptors.append(descriptor)
            else:
                raise ValueError("OCI index contains an unexpected runnable or unknown platform")
        if len(runnable_descriptors) != 1:
            raise ValueError("OCI index must contain exactly one linux/amd64 runnable image")
        if not attestation_descriptors:
            raise ValueError("OCI index must contain BuildKit provenance/SBOM attestations")

        runnable_descriptor = runnable_descriptors[0]
        if runnable_descriptor.get("mediaType") != "application/vnd.oci.image.manifest.v1+json":
            raise ValueError("OCI runnable descriptor media type is invalid")
        runnable_hash, runnable_manifest = descriptor_json(runnable_descriptor, "OCI runnable manifest")
        if set(runnable_manifest) - {"schemaVersion", "mediaType", "config", "layers", "annotations"}:
            raise ValueError("OCI runnable manifest contains unsupported fields")
        if runnable_manifest.get("schemaVersion") != 2 or runnable_manifest.get("mediaType") not in {
            None, "application/vnd.oci.image.manifest.v1+json"
        }:
            raise ValueError("OCI runnable image manifest is invalid")
        runnable_layers = runnable_manifest.get("layers")
        if not isinstance(runnable_layers, list) or not runnable_layers:
            raise ValueError("OCI runnable manifest must contain at least one layer")
        config_descriptor = runnable_manifest.get("config")
        if not isinstance(config_descriptor, dict) or config_descriptor.get("mediaType") != "application/vnd.oci.image.config.v1+json":
            raise ValueError("OCI runnable config descriptor is invalid")
        _config_hash, config_json = descriptor_json(config_descriptor, "OCI runnable config")
        if config_json.get("architecture") != "amd64" or config_json.get("os") != "linux":
            raise ValueError("OCI runnable config must identify linux/amd64")
        runnable_member_digests: set[str] = set()
        for number, layer in enumerate(runnable_layers):
            if not isinstance(layer, dict) or not isinstance(layer.get("mediaType"), str) or "layer" not in layer["mediaType"]:
                raise ValueError(f"OCI runnable layer {number} descriptor is invalid")
            layer_hash, _ = descriptor_bytes(layer, f"OCI runnable layer {number}")
            if layer_hash in runnable_member_digests:
                raise ValueError("OCI runnable manifest reuses a layer blob")
            runnable_member_digests.add(layer_hash)

        predicate_types: set[str] = set()
        for number, descriptor in enumerate(attestation_descriptors):
            annotations = descriptor["annotations"]
            if annotations.get("vnd.docker.reference.digest") != f"sha256:{runnable_hash}":
                raise ValueError("OCI attestation descriptor does not reference the runnable manifest")
            if descriptor.get("mediaType") != "application/vnd.oci.image.manifest.v1+json":
                raise ValueError("OCI attestation descriptor media type is invalid")
            _attestation_hash, attestation_manifest = descriptor_json(
                descriptor, f"OCI attestation manifest {number}"
            )
            if set(attestation_manifest) - {"schemaVersion", "mediaType", "config", "layers", "annotations"}:
                raise ValueError("OCI attestation manifest contains unsupported fields")
            if attestation_manifest.get("schemaVersion") != 2 or attestation_manifest.get("mediaType") not in {
                None, "application/vnd.oci.image.manifest.v1+json"
            }:
                raise ValueError("OCI attestation manifest is invalid")
            attestation_config = attestation_manifest.get("config")
            if not isinstance(attestation_config, dict) or attestation_config.get("mediaType") != "application/vnd.oci.image.config.v1+json":
                raise ValueError("OCI attestation config descriptor is invalid")
            descriptor_json(attestation_config, f"OCI attestation config {number}")
            layers = attestation_manifest.get("layers")
            if not isinstance(layers, list) or not layers:
                raise ValueError("OCI attestation manifest must contain statement layers")
            for layer_number, layer in enumerate(layers):
                label = f"OCI attestation {number} statement {layer_number}"
                if not isinstance(layer, dict) or layer.get("mediaType") != "application/vnd.in-toto+json":
                    raise ValueError(f"{label} media type is invalid")
                layer_annotations = layer.get("annotations")
                predicate_type = layer_annotations.get("in-toto.io/predicate-type") if isinstance(layer_annotations, dict) else None
                if not isinstance(predicate_type, str) or not predicate_type:
                    raise ValueError(f"{label} lacks a predicate-type annotation")
                _statement_hash, statement = descriptor_json(layer, label)
                subjects = statement.get("subject")
                bound = isinstance(subjects, list) and any(
                    isinstance(subject, dict)
                    and isinstance(subject.get("digest"), dict)
                    and subject["digest"].get("sha256") == runnable_hash
                    for subject in subjects
                )
                if (
                    statement.get("_type") not in {
                        "https://in-toto.io/Statement/v0.1", "https://in-toto.io/Statement/v1"
                    }
                    or statement.get("predicateType") != predicate_type
                    or not isinstance(statement.get("predicate"), dict)
                    or not bound
                ):
                    raise ValueError(f"{label} is not structurally bound to the runnable manifest")
                if predicate_type in predicate_types:
                    raise ValueError("OCI archive contains duplicate attestation predicate types")
                predicate_types.add(predicate_type)
        if predicate_types != {
            "https://spdx.dev/Document", "https://slsa.dev/provenance/v0.2"
        }:
            raise ValueError("OCI archive must contain exactly the reviewed SPDX and SLSA v0.2 attestations")

        expected_files = {"oci-layout", "index.json"} | reachable
        if set(files) != expected_files:
            raise ValueError("OCI archive contains unreferenced blobs or omitted referenced content")
        return "sha256:" + runnable_hash


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--archive", type=Path, required=True)
    parser.add_argument("--expected-digest", required=True)
    args = parser.parse_args()
    print(validate_archive(args.archive, args.expected_digest))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
