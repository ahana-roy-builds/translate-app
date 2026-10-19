#!/usr/bin/env python3
"""Verify a signed LocalLingo v2 release decision and every bound subject."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import os
import re
import shutil
import stat
import subprocess
import sys
import tempfile
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))
from validate_release_evidence import (
    ArtifactStore,
    FIXED_RUNTIME_LIMITS,
    REVIEWED_SECRET_IDS,
    validate_manifest,
)
from strict_json import loads as strict_json_loads


SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
COMMIT_RE = re.compile(r"^[a-f0-9]{40}$")
ROLES = ("quality", "security", "privacy", "operations")
SIGNED_REF_KEYS = {"artifact", "bundle", "predicate_type"}
ARTIFACT_KEYS = {"path", "sha256", "size_bytes", "media_type"}
CANDIDATE_PREDICATE = "urn:locallingo:attestation:release-candidate:v2"
APPROVAL_PREDICATE = "urn:locallingo:attestation:approval:v1"
FINALIZER_PREDICATE = "urn:locallingo:attestation:release-decision:v2"
CANDIDATE_REF_TYPES = {
    "preflight": "urn:locallingo:attestation:preflight:v2",
    "criteria": "urn:locallingo:attestation:criteria:v2",
    "corpus": "urn:locallingo:attestation:corpus-manifest:v2",
    "device-registry": "urn:locallingo:attestation:device-registry:v1",
    "ios-release": "urn:locallingo:attestation:ios-build:v1",
    "ios-testflight": "urn:locallingo:attestation:ios-build:v1",
    "backend-provenance": "urn:locallingo:attestation:backend-provenance:v1",
    "backend-sbom": "urn:locallingo:attestation:backend-sbom:v1",
    "backend-vulnerability": "urn:locallingo:attestation:vulnerability-scan:v1",
    "backend-secret": "urn:locallingo:attestation:secret-scan:v1",
    "environment-policy": "urn:locallingo:attestation:environment-policy:v1",
    "terraform-plan": "urn:locallingo:attestation:terraform-plan:v2",
    "deployment": "urn:locallingo:attestation:deployment-receipt:v1",
    "device-run": "urn:locallingo:attestation:device-run:v2",
}
SIGNER_PREDICATES = {
    "build": {
        CANDIDATE_REF_TYPES["ios-release"], CANDIDATE_REF_TYPES["backend-provenance"],
        CANDIDATE_REF_TYPES["backend-sbom"], CANDIDATE_REF_TYPES["backend-vulnerability"],
        CANDIDATE_REF_TYPES["backend-secret"],
    },
    "corpus": {CANDIDATE_REF_TYPES["criteria"], CANDIDATE_REF_TYPES["corpus"]},
    "device": {CANDIDATE_REF_TYPES["device-run"], CANDIDATE_REF_TYPES["device-registry"]},
    "infrastructure": {
        CANDIDATE_REF_TYPES["environment-policy"], CANDIDATE_REF_TYPES["terraform-plan"],
        CANDIDATE_REF_TYPES["deployment"],
    },
    "candidate": {CANDIDATE_PREDICATE, CANDIDATE_REF_TYPES["preflight"]},
    "quality": {APPROVAL_PREDICATE},
    "security": {APPROVAL_PREDICATE},
    "privacy": {APPROVAL_PREDICATE},
    "operations": {APPROVAL_PREDICATE},
    "finalizer": {FINALIZER_PREDICATE},
}
NESTED_SIGNERS = {
    CANDIDATE_REF_TYPES["preflight"]: "candidate",
    CANDIDATE_REF_TYPES["criteria"]: "corpus",
    CANDIDATE_REF_TYPES["corpus"]: "corpus",
    CANDIDATE_REF_TYPES["ios-release"]: "build",
    CANDIDATE_REF_TYPES["backend-provenance"]: "build",
    CANDIDATE_REF_TYPES["backend-sbom"]: "build",
    CANDIDATE_REF_TYPES["backend-vulnerability"]: "build",
    CANDIDATE_REF_TYPES["backend-secret"]: "build",
    CANDIDATE_REF_TYPES["environment-policy"]: "infrastructure",
    CANDIDATE_REF_TYPES["terraform-plan"]: "infrastructure",
    CANDIDATE_REF_TYPES["deployment"]: "infrastructure",
    CANDIDATE_REF_TYPES["device-run"]: "device",
    CANDIDATE_REF_TYPES["device-registry"]: "device",
}


def exact(value: Any, keys: set[str], path: str, errors: list[str]) -> bool:
    if not isinstance(value, dict):
        errors.append(f"{path}: must be an object")
        return False
    missing = sorted(keys - set(value))
    unknown = sorted(set(value) - keys)
    if missing:
        errors.append(f"{path}: missing fields: {', '.join(missing)}")
    if unknown:
        errors.append(f"{path}: unknown fields: {', '.join(unknown)}")
    return not missing and not unknown


def safe_bytes(path: Path, label: str, errors: list[str], maximum: int = 16 * 1024 * 1024) -> bytes | None:
    flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
    try:
        descriptor = os.open(path, flags)
    except OSError as exc:
        errors.append(f"{label}: unable to open safely: {exc}")
        return None
    try:
        before = os.fstat(descriptor)
        if not stat.S_ISREG(before.st_mode) or before.st_nlink != 1 or before.st_size > maximum:
            errors.append(f"{label}: must be a bounded regular single-link file")
            return None
        with os.fdopen(os.dup(descriptor), "rb", closefd=True) as handle:
            contents = handle.read(maximum + 1)
        after = os.fstat(descriptor)
        identity = lambda value: (value.st_dev, value.st_ino, value.st_mode, value.st_nlink, value.st_size, value.st_mtime_ns, value.st_ctime_ns)
        if len(contents) != before.st_size or identity(before) != identity(after):
            errors.append(f"{label}: changed while it was being read")
            return None
        return contents
    except OSError as exc:
        errors.append(f"{label}: unable to read safely: {exc}")
        return None
    finally:
        os.close(descriptor)


def parse_time(value: Any, path: str, errors: list[str]) -> datetime | None:
    if not isinstance(value, str):
        errors.append(f"{path}: must be a timezone-qualified timestamp")
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
        if parsed.tzinfo is None:
            raise ValueError
        parsed = parsed.astimezone(timezone.utc)
        now = datetime.now(timezone.utc)
        if parsed > now.replace(microsecond=0) + timedelta(minutes=5):
            errors.append(f"{path}: cannot be more than five minutes in the future")
        if parsed < now - timedelta(days=45):
            errors.append(f"{path}: is older than the 45-day release window")
        return parsed
    except ValueError:
        errors.append(f"{path}: must be a timezone-qualified timestamp")
        return None


class TrustedStore:
    def __init__(self, root: Path, errors: list[str]) -> None:
        self.store = ArtifactStore(root, errors)
        self.errors = errors

    def artifact(self, value: Any, path: str) -> Path | None:
        if not exact(value, ARTIFACT_KEYS, path, self.errors):
            return None
        uri = value.get("path")
        digest = value.get("sha256")
        size = value.get("size_bytes")
        media = value.get("media_type")
        if not isinstance(digest, str) or not SHA256_RE.fullmatch(digest):
            self.errors.append(f"{path}.sha256: must be a lowercase SHA-256")
        if isinstance(size, bool) or not isinstance(size, int) or not 1 <= size <= 10 * 1024**3:
            self.errors.append(f"{path}.size_bytes: must be from 1 through 10 GiB")
        if not isinstance(media, str) or not media or len(media) > 200:
            self.errors.append(f"{path}.media_type: must be a non-empty bounded string")
        actual_digest = self.store.digest(uri, f"{path}.path", self.errors)
        snapshot = self.store.resolve(uri, f"{path}.path", self.errors)
        if actual_digest is not None and actual_digest != digest:
            self.errors.append(f"{path}.sha256: digest mismatch")
        if snapshot is not None and snapshot.stat().st_size != size:
            self.errors.append(f"{path}.size_bytes: size mismatch")
        return snapshot

    def signed(self, value: Any, path: str, expected_predicate: str) -> tuple[Path, Path] | None:
        if not exact(value, SIGNED_REF_KEYS, path, self.errors):
            return None
        if value.get("predicate_type") != expected_predicate:
            self.errors.append(f"{path}.predicate_type: must equal {expected_predicate}")
        artifact = self.artifact(value.get("artifact"), f"{path}.artifact")
        bundle = self.artifact(value.get("bundle"), f"{path}.bundle")
        return (artifact, bundle) if artifact is not None and bundle is not None else None

    def json(self, path: Path, label: str) -> Any | None:
        try:
            if path.stat().st_size > 16 * 1024 * 1024:
                raise ValueError("JSON exceeds 16 MiB")
            return strict_json_loads(path.read_bytes())
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
            self.errors.append(f"{label}: invalid JSON: {exc}")
            return None


def workflow_path(repository_root: Path, repository: str, workflow: str) -> Path | None:
    prefix = repository + "/"
    if not workflow.startswith(prefix):
        return None
    relative = workflow[len(prefix):]
    if not re.fullmatch(r"\.github/workflows/[A-Za-z0-9_.-]+\.yml", relative):
        return None
    return repository_root / relative


def protected_git_environment() -> dict[str, str]:
    return {
        "PATH": "/usr/bin:/bin", "HOME": "/nonexistent",
        "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null",
        "GIT_NO_REPLACE_OBJECTS": "1", "LC_ALL": "C",
    }


def verify_signer_policy(policy: dict[str, Any], repository_root: Path, errors: list[str]) -> None:
    if not exact(policy, {"schema_version", "repository", "repository_id", "repository_owner_id", "source_ref", "source_commit", "trusted_root", "signers"}, "trust_policy", errors):
        return
    if policy.get("schema_version") != "1.0":
        errors.append("trust_policy.schema_version: must equal 1.0")
    repository = policy.get("repository")
    if not isinstance(repository, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+", repository):
        errors.append("trust_policy.repository: invalid repository")
        return
    if not isinstance(policy.get("source_commit"), str) or not COMMIT_RE.fullmatch(policy["source_commit"]):
        errors.append("trust_policy.source_commit: must be a full SHA-1 commit")
    for field in ("repository_id", "repository_owner_id"):
        if not isinstance(policy.get(field), str) or not re.fullmatch(r"[1-9][0-9]*", policy[field]):
            errors.append(f"trust_policy.{field}: must be an immutable numeric GitHub ID")
    if not isinstance(policy.get("source_ref"), str) or not re.fullmatch(
        r"refs/tags/v[0-9]+\.[0-9]+\.[0-9]+(?:[-+][A-Za-z0-9.-]+)?", policy["source_ref"]
    ):
        errors.append("trust_policy.source_ref: must be a full semantic-version tag ref")
    try:
        top = subprocess.run(
            ["/usr/bin/git", "-c", "core.fsmonitor=false", "-C", str(repository_root), "rev-parse", "--show-toplevel"],
            check=True, capture_output=True, text=True, timeout=10, env=protected_git_environment(),
        ).stdout.strip()
        git_dir = subprocess.run(
            ["/usr/bin/git", "-c", "core.fsmonitor=false", "-C", str(repository_root), "rev-parse", "--absolute-git-dir"],
            check=True, capture_output=True, text=True, timeout=10, env=protected_git_environment(),
        ).stdout.strip()
        head = subprocess.run(
            ["/usr/bin/git", "-c", "core.fsmonitor=false", "-C", str(repository_root), "rev-parse", "HEAD"], check=True,
            capture_output=True, text=True, timeout=10, env=protected_git_environment(),
        ).stdout.strip()
        tagged = subprocess.run(
            ["/usr/bin/git", "-c", "core.fsmonitor=false", "-C", str(repository_root), "rev-parse", f"{policy.get('source_ref')}^{{commit}}"],
            check=True, capture_output=True, text=True, timeout=10, env=protected_git_environment(),
        ).stdout.strip()
        if Path(top).resolve() != repository_root.resolve() or Path(git_dir).resolve() != (repository_root / ".git").resolve() or head != policy.get("source_commit") or tagged != head:
            errors.append("trust_policy: local checkout, source commit, and immutable version tag must match")
    except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
        errors.append("trust_policy: unable to verify the local tagged Git checkout")
    signers = policy.get("signers")
    if not exact(signers, set(SIGNER_PREDICATES), "trust_policy.signers", errors):
        return
    for name, signer in signers.items():
        path = f"trust_policy.signers.{name}"
        if not exact(signer, {"workflow", "workflow_sha256", "predicate_types"}, path, errors):
            continue
        predicate_types = signer.get("predicate_types")
        if not isinstance(predicate_types, list) or set(predicate_types) != SIGNER_PREDICATES[name] or len(predicate_types) != len(SIGNER_PREDICATES[name]):
            errors.append(f"{path}.predicate_types: must exactly match the allowed signer predicates")
        local = workflow_path(repository_root, repository, signer.get("workflow", ""))
        if local is None or not local.is_file() or local.is_symlink():
            errors.append(f"{path}.workflow: must identify a tracked local workflow")
            continue
        workflow_bytes = safe_bytes(local, f"{path}.workflow", errors, maximum=1024 * 1024)
        if workflow_bytes is None:
            continue
        actual = hashlib.sha256(workflow_bytes).hexdigest()
        if signer.get("workflow_sha256") != actual:
            errors.append(f"{path}.workflow_sha256: does not match workflow bytes")


def gh_verify(
    *, gh: str, artifact: Path, bundle: Path, trusted_root: Path,
    policy: dict[str, Any], signer_name: str, predicate: str, errors: list[str],
) -> datetime | None:
    signer = policy["signers"][signer_name]
    command = [
        gh, "attestation", "verify", str(artifact),
        "--repo", policy["repository"],
        "--bundle", str(bundle),
        "--custom-trusted-root", str(trusted_root),
        "--cert-oidc-issuer", "https://token.actions.githubusercontent.com",
        "--signer-workflow", signer["workflow"],
        "--signer-digest", policy["source_commit"],
        "--source-digest", policy["source_commit"],
        "--source-ref", policy["source_ref"],
        "--predicate-type", predicate,
        "--format", "json",
    ]
    try:
        result = subprocess.run(command, check=False, capture_output=True, text=True, timeout=60)
    except (OSError, subprocess.TimeoutExpired) as exc:
        errors.append(f"{signer_name} attestation: gh verification failed to run: {exc}")
        return None
    if result.returncode != 0:
        errors.append(f"{signer_name} attestation: verification failed: {(result.stderr or result.stdout).strip()}")
        return None
    try:
        output = strict_json_loads(result.stdout)
        if not isinstance(output, list) or len(output) != 1 or not isinstance(output[0], dict):
            raise ValueError
    except (json.JSONDecodeError, ValueError, RecursionError, UnicodeError):
        errors.append(f"{signer_name} attestation: gh must return exactly one verified statement")
        return None
    verification = output[0].get("verificationResult")
    if not isinstance(verification, dict):
        errors.append(f"{signer_name} attestation: gh result lacks verificationResult")
        return None
    certificate = verification.get("signature", {}).get("certificate") if isinstance(verification.get("signature"), dict) else None
    expected_certificate = {
        "sourceRepositoryIdentifier": policy["repository_id"],
        "sourceRepositoryOwnerIdentifier": policy["repository_owner_id"],
    }
    if not isinstance(certificate, dict) or any(certificate.get(key) != value for key, value in expected_certificate.items()):
        errors.append(f"{signer_name} attestation: certificate source/signer identity mismatch")
        return None
    timestamps = verification.get("verifiedTimestamps")
    if not isinstance(timestamps, list) or not timestamps:
        errors.append(f"{signer_name} attestation: a cryptographically verified timestamp is required")
        return None
    parsed_timestamps: list[datetime] = []
    now = datetime.now(timezone.utc)
    for number, row in enumerate(timestamps):
        value = row.get("timestamp") if isinstance(row, dict) else None
        try:
            parsed = datetime.fromisoformat(str(value).replace("Z", "+00:00"))
            if parsed.tzinfo is None:
                raise ValueError
            parsed = parsed.astimezone(timezone.utc)
        except ValueError:
            errors.append(f"{signer_name} attestation: verifiedTimestamps[{number}] is invalid")
            continue
        if parsed > now + timedelta(minutes=5) or parsed < now - timedelta(days=45):
            errors.append(f"{signer_name} attestation: trusted signing time is outside the 45-day release window")
        parsed_timestamps.append(parsed)
    return min(parsed_timestamps) if parsed_timestamps else None


def validate_approval(value: Any, role: str, candidate_digest: str, preflight_digest: str, errors: list[str]) -> tuple[str, datetime] | None:
    path = f"approval.{role}"
    keys = {"schema_version", "role", "candidate_sha256", "preflight_sha256", "reviewer_login", "reviewer_id", "approved_at", "waivers"}
    if not exact(value, keys, path, errors):
        return None
    if value.get("schema_version") != "1.0" or value.get("role") != role:
        errors.append(f"{path}: schema/role mismatch")
    if value.get("candidate_sha256") != candidate_digest or value.get("preflight_sha256") != preflight_digest:
        errors.append(f"{path}: candidate/preflight binding mismatch")
    reviewer_id = value.get("reviewer_id")
    if not isinstance(reviewer_id, str) or not re.fullmatch(r"[1-9][0-9]*", reviewer_id):
        errors.append(f"{path}.reviewer_id: invalid authenticated actor ID")
        reviewer_id = ""
    if not isinstance(value.get("reviewer_login"), str) or not re.fullmatch(r"[A-Za-z0-9-]{1,39}", value["reviewer_login"]):
        errors.append(f"{path}.reviewer_login: invalid login")
    if value.get("waivers") != []:
        errors.append(f"{path}.waivers: v2 launch approval does not permit unauthenticated waivers")
    approved = parse_time(value.get("approved_at"), f"{path}.approved_at", errors)
    return (reviewer_id, approved) if approved is not None else None


def _sha(value: Any, path: str, errors: list[str], *, prefixed: bool = False) -> bool:
    pattern = r"sha256:[a-f0-9]{64}" if prefixed else r"[a-f0-9]{64}"
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        errors.append(f"{path}: invalid {'OCI ' if prefixed else ''}SHA-256")
        return False
    return True


def _canonical_digest(value: Any) -> str:
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode()).hexdigest()


def verification_result(candidate_digest: str, *, signed_final: bool) -> dict[str, Any]:
    if signed_final:
        return {
            "release_decision": "approved", "schema_version": "2.0",
            "candidate_sha256": candidate_digest, "verification": "signed-final",
        }
    return {
        "release_decision": False, "ready_to_sign": True, "schema_version": "2.0",
        "candidate_sha256": candidate_digest, "verification": "pre-attestation",
    }


def _nested_json(
    reference: Any, path: str, predicate: str, store: TrustedStore,
    policy: dict[str, Any], gh: str, trusted_root: Path, errors: list[str],
) -> tuple[dict[str, Any] | None, str, datetime | None]:
    pair = store.signed(reference, path, predicate)
    digest = reference.get("artifact", {}).get("sha256", "") if isinstance(reference, dict) else ""
    if pair is None:
        return None, digest, None
    signer = NESTED_SIGNERS[predicate]
    signed_at = gh_verify(
        gh=gh, artifact=pair[0], bundle=pair[1], trusted_root=trusted_root,
        policy=policy, signer_name=signer, predicate=predicate, errors=errors,
    )
    document = store.json(pair[0], path)
    if not isinstance(document, dict):
        errors.append(f"{path}: signed subject must contain a JSON object predicate")
        return None, digest, signed_at
    return document, digest, signed_at


def _artifact(value: Any, path: str, store: TrustedStore, errors: list[str]) -> str:
    store.artifact(value, path)
    return value.get("sha256", "") if isinstance(value, dict) else ""


def _validate_device_registry(value: Any, store: TrustedStore, errors: list[str]) -> dict[str, dict[str, Any]]:
    if not exact(value, {"schema_version", "generated_at", "tiers"}, "device_registry", errors):
        return {}
    if value.get("schema_version") != "1.0":
        errors.append("device_registry.schema_version: must equal 1.0")
    parse_time(value.get("generated_at"), "device_registry.generated_at", errors)
    tiers = value.get("tiers")
    expected = {
        "minimum": ("iPhone 15 Pro", "iPhone16,1"),
        "mid_tier": ("iPhone 16 Pro", "iPhone17,1"),
        "current": ("iPhone 17 Pro", "iPhone18,1"),
    }
    keys = {"marketing_name", "model_identifier", "soc", "memory_gib", "os_version", "os_build"}
    if not exact(tiers, set(expected), "device_registry.tiers", errors):
        return {}
    for tier, (marketing, identifier) in expected.items():
        row = tiers[tier]
        if not exact(row, keys, f"device_registry.tiers.{tier}", errors):
            continue
        if row.get("marketing_name") != marketing or row.get("model_identifier") != identifier:
            errors.append(f"device_registry.tiers.{tier}: must identify the locked physical release tier")
        if not isinstance(row.get("memory_gib"), (int, float)) or isinstance(row.get("memory_gib"), bool) or row["memory_gib"] < 8:
            errors.append(f"device_registry.tiers.{tier}.memory_gib: must reflect at least 8 GiB")
        if not isinstance(row.get("os_version"), str) or not re.fullmatch(r"26(?:\.[0-9]+){1,2}", row["os_version"]):
            errors.append(f"device_registry.tiers.{tier}.os_version: must be an exact iOS 26 version")
        for name in ("soc", "os_build"):
            if not isinstance(row.get(name), str) or not row[name].strip():
                errors.append(f"device_registry.tiers.{tier}.{name}: must be non-empty")
    return tiers


def validate_candidate(
    value: Any, digest: str, store: TrustedStore, policy: dict[str, Any], gh: str,
    trusted_root: Path, errors: list[str], *, candidate_signed_at: datetime | None = None,
) -> tuple[str, datetime] | None:
    del digest
    keys = {"schema_version", "candidate_id", "repository", "source_commit", "source_tree", "source_ref", "app_version", "build_number", "created_at", "preflight", "criteria", "corpus", "device_registry", "ios_builds", "backend", "environments", "device_runs"}
    if not exact(value, keys, "candidate", errors):
        return None
    expected = {"schema_version": "2.0", "repository": policy["repository"], "source_commit": policy["source_commit"], "source_ref": policy["source_ref"]}
    for name, expected_value in expected.items():
        if value.get(name) != expected_value:
            errors.append(f"candidate.{name}: trust-policy mismatch")
    candidate_id = value.get("candidate_id")
    source_tree = value.get("source_tree")
    app_version = value.get("app_version")
    build_number = value.get("build_number")
    if not isinstance(candidate_id, str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{15,127}", candidate_id):
        errors.append("candidate.candidate_id: invalid immutable build ID")
    if not isinstance(source_tree, str) or not re.fullmatch(r"[a-f0-9]{40,64}", source_tree):
        errors.append("candidate.source_tree: invalid tree digest")
    if not isinstance(app_version, str) or not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", app_version):
        errors.append("candidate.app_version: invalid semantic version")
    source_version = re.fullmatch(
        r"refs/tags/v([0-9]+\.[0-9]+\.[0-9]+)(?:[-+][A-Za-z0-9.-]+)?", str(value.get("source_ref", ""))
    )
    if source_version is None or source_version.group(1) != app_version:
        errors.append("candidate.source_ref: version tag must match candidate.app_version")
    if not isinstance(build_number, str) or not re.fullmatch(r"[1-9][0-9]*", build_number):
        errors.append("candidate.build_number: invalid build number")
    created = parse_time(value.get("created_at"), "candidate.created_at", errors)

    references: list[tuple[str, Any, str]] = [
        ("preflight", value.get("preflight"), CANDIDATE_REF_TYPES["preflight"]),
        ("criteria", value.get("criteria"), CANDIDATE_REF_TYPES["criteria"]),
        ("corpus", value.get("corpus"), CANDIDATE_REF_TYPES["corpus"]),
        ("device_registry", value.get("device_registry"), CANDIDATE_REF_TYPES["device-registry"]),
    ]
    ios = value.get("ios_builds")
    if exact(ios, {"release", "testflight"}, "candidate.ios_builds", errors):
        references.extend((
            ("ios_builds.release", ios["release"], CANDIDATE_REF_TYPES["ios-release"]),
            ("ios_builds.testflight", ios["testflight"], CANDIDATE_REF_TYPES["ios-testflight"]),
        ))
    backend = value.get("backend")
    backend_keys = {"image_name", "environment_image_names", "image_digest", "runnable_manifest_digest", "provenance", "sbom", "vulnerability_scan", "secret_scan"}
    if exact(backend, backend_keys, "candidate.backend", errors):
        if not isinstance(backend.get("image_name"), str) or "@" in backend["image_name"] or not backend["image_name"].strip():
            errors.append("candidate.backend.image_name: must be a nonempty digest-free registry name")
        _sha(backend.get("image_digest"), "candidate.backend.image_digest", errors, prefixed=True)
        _sha(backend.get("runnable_manifest_digest"), "candidate.backend.runnable_manifest_digest", errors, prefixed=True)
        if backend.get("runnable_manifest_digest") == backend.get("image_digest"):
            errors.append("candidate.backend.runnable_manifest_digest: must differ from the attested OCI index digest")
        environment_image_names = backend.get("environment_image_names")
        if exact(environment_image_names, {"production", "testflight"}, "candidate.backend.environment_image_names", errors):
            if environment_image_names.get("production") != backend.get("image_name"):
                errors.append("candidate.backend.image_name: must equal the production environment image name")
            if len(set(environment_image_names.values())) != 2:
                errors.append("candidate.backend.environment_image_names: production and TestFlight names must be distinct")
        references.extend((
            ("backend.provenance", backend["provenance"], CANDIDATE_REF_TYPES["backend-provenance"]),
            ("backend.sbom", backend["sbom"], CANDIDATE_REF_TYPES["backend-sbom"]),
            ("backend.vulnerability_scan", backend["vulnerability_scan"], CANDIDATE_REF_TYPES["backend-vulnerability"]),
            ("backend.secret_scan", backend["secret_scan"], CANDIDATE_REF_TYPES["backend-secret"]),
        ))
    environments = value.get("environments")
    if exact(environments, {"production", "testflight"}, "candidate.environments", errors):
        for environment in ("production", "testflight"):
            row = environments[environment]
            if exact(row, {"policy", "terraform_plan", "deployment_receipt"}, f"candidate.environments.{environment}", errors):
                references.extend((
                    (f"environments.{environment}.policy", row["policy"], CANDIDATE_REF_TYPES["environment-policy"]),
                    (f"environments.{environment}.terraform_plan", row["terraform_plan"], CANDIDATE_REF_TYPES["terraform-plan"]),
                    (f"environments.{environment}.deployment_receipt", row["deployment_receipt"], CANDIDATE_REF_TYPES["deployment"]),
                ))
    device_refs = value.get("device_runs")
    if not isinstance(device_refs, list) or len(device_refs) != 96:
        errors.append("candidate.device_runs: exactly 96 matrix-cell runs are required")
        device_refs = []
    references.extend((f"device_runs[{index}]", row, CANDIDATE_REF_TYPES["device-run"]) for index, row in enumerate(device_refs))

    bundle_digests = [
        reference.get("bundle", {}).get("sha256", "")
        for _, reference, _ in references if isinstance(reference, dict)
    ]
    if (
        len(bundle_digests) != len(references)
        or any(not isinstance(item, str) or not SHA256_RE.fullmatch(item) for item in bundle_digests)
        or len(set(bundle_digests)) != len(bundle_digests)
    ):
        errors.append("candidate: every signed evidence subject requires a distinct valid attestation bundle")

    documents: dict[str, dict[str, Any]] = {}
    digests: dict[str, str] = {}
    signing_times: dict[str, datetime] = {}
    for name, reference, predicate in references:
        document, artifact_digest, signed_at = _nested_json(reference, f"candidate.{name}", predicate, store, policy, gh, trusted_root, errors)
        if document is not None:
            documents[name] = document
        if signed_at is not None:
            signing_times[name] = signed_at
        digests[name] = artifact_digest
    if candidate_signed_at is not None:
        for name, signed_at in signing_times.items():
            if signed_at > candidate_signed_at + timedelta(minutes=5):
                errors.append(f"candidate.{name}: nested evidence was signed after the candidate")
        if created is not None and created > candidate_signed_at + timedelta(minutes=5):
            errors.append("candidate.created_at: cannot be after its trusted signing time")
    for name, signed_at in signing_times.items():
        document = documents.get(name, {})
        time_fields = [field for field in ("generated_at", "observed_at", "completed_at") if field in document]
        if not time_fields:
            errors.append(f"candidate.{name}: signed predicate lacks a claimed completion timestamp")
        for field in time_fields:
            claimed = parse_time(document.get(field), f"candidate.{name}.{field}", errors)
            if claimed is not None and claimed > signed_at + timedelta(minutes=5):
                errors.append(f"candidate.{name}.{field}: claimed event is after trusted signing time")
    if len({digests.get(f"device_runs[{index}]") for index in range(len(device_refs))}) != len(device_refs):
        errors.append("candidate.device_runs: every matrix cell requires unique signed bytes")

    preflight = documents.get("preflight")
    preflight_report: dict[str, Any] | None = None
    v1_manifest: dict[str, Any] | None = None
    resolved_config: dict[str, Any] | None = None
    testflight_resolved_config: dict[str, Any] | None = None
    v1_manifest_digest = ""
    resolved_config_digest = ""
    testflight_resolved_config_digest = ""
    preflight_time: datetime | None = None
    preflight_keys = {
        "kind", "schema_version", "candidate_id", "source_commit", "source_tree", "report",
        "release_manifest", "resolved_ios_config", "testflight_resolved_ios_config",
        "status", "release_decision", "generated_at",
    }
    if exact(preflight, preflight_keys, "preflight", errors):
        expected_preflight = {"kind": "preflight", "schema_version": "2.0", "candidate_id": candidate_id, "source_commit": value.get("source_commit"), "source_tree": source_tree, "status": "passed", "release_decision": False}
        for name, expected_value in expected_preflight.items():
            if preflight.get(name) != expected_value:
                errors.append(f"preflight.{name}: candidate binding mismatch")
        report_path = store.artifact(preflight.get("report"), "preflight.report")
        if report_path is not None:
            report = store.json(report_path, "preflight.report")
            report_keys = {"preflight_status", "release_decision", "schema_version", "release_identity_sha256", "criteria_sha256", "release_manifest_sha256", "release_build_id", "matrix_cells", "verified_reports"}
            if not exact(report, report_keys, "preflight.report", errors) or report.get("preflight_status") != "passed" or report.get("release_decision") is not False or report.get("schema_version") != "1.0" or report.get("matrix_cells") != 96 or report.get("release_build_id") != candidate_id:
                errors.append("preflight.report: must be a passing non-approving 96-cell v1 report")
            else:
                preflight_report = report
                for field in ("release_identity_sha256", "criteria_sha256", "release_manifest_sha256"):
                    _sha(report.get(field), f"preflight.report.{field}", errors)
                if not isinstance(report.get("verified_reports"), int) or isinstance(report.get("verified_reports"), bool) or report["verified_reports"] < 586:
                    errors.append("preflight.report.verified_reports: exhaustive v1 evidence count is required")
        for field, label in (
            ("release_manifest", "preflight.release_manifest"),
            ("resolved_ios_config", "preflight.resolved_ios_config"),
            ("testflight_resolved_ios_config", "preflight.testflight_resolved_ios_config"),
        ):
            artifact_path = store.artifact(preflight.get(field), label)
            artifact_digest = preflight.get(field, {}).get("sha256", "") if isinstance(preflight.get(field), dict) else ""
            artifact_json = store.json(artifact_path, label) if artifact_path is not None else None
            if not isinstance(artifact_json, dict):
                errors.append(f"{label}: must contain a JSON object")
                continue
            if field == "release_manifest":
                v1_manifest, v1_manifest_digest = artifact_json, artifact_digest
            elif field == "resolved_ios_config":
                resolved_config, resolved_config_digest = artifact_json, artifact_digest
            else:
                testflight_resolved_config, testflight_resolved_config_digest = artifact_json, artifact_digest
        preflight_time = parse_time(preflight.get("generated_at"), "preflight.generated_at", errors)
        if created is not None and preflight_time is not None and preflight_time < created:
            errors.append("preflight.generated_at: cannot predate candidate issuance")

    criteria = documents.get("criteria")
    criteria_json: dict[str, Any] | None = None
    criteria_digest = ""
    if exact(criteria, {"kind", "schema_version", "source_commit", "criteria", "generated_at"}, "criteria", errors):
        if criteria.get("kind") != "criteria" or criteria.get("schema_version") != "2.0" or criteria.get("source_commit") != value.get("source_commit"):
            errors.append("criteria: source/schema binding mismatch")
        criteria_path = store.artifact(criteria.get("criteria"), "criteria.criteria")
        criteria_digest = criteria.get("criteria", {}).get("sha256", "") if isinstance(criteria.get("criteria"), dict) else ""
        loaded_criteria = store.json(criteria_path, "criteria.criteria") if criteria_path is not None else None
        if isinstance(loaded_criteria, dict):
            criteria_json = loaded_criteria
        else:
            errors.append("criteria.criteria: must contain a JSON object")
        if preflight_report is not None and preflight_report.get("criteria_sha256") != criteria_digest:
            errors.append("preflight.report.criteria_sha256: signed criteria binding mismatch")
        parse_time(criteria.get("generated_at"), "criteria.generated_at", errors)

    corpus = documents.get("corpus")
    corpus_keys = {"kind", "schema_version", "corpus_id", "cases_sha256", "direction_corpora", "stimuli_sha256", "answers_sha256", "rights_manifest_sha256", "audio_validation_sha256", "vad_tool_digest", "fingerprint_tool_digest", "directions", "generated_at"}
    if exact(corpus, corpus_keys, "corpus", errors):
        if corpus.get("kind") != "corpus-manifest" or corpus.get("schema_version") != "2.0" or set(corpus.get("directions", [])) != {"en->es", "es->en", "en->ja", "ja->en"} or len(corpus.get("directions", [])) != 4:
            errors.append("corpus: schema/direction contract mismatch")
        for name in ("cases_sha256", "stimuli_sha256", "answers_sha256", "rights_manifest_sha256", "audio_validation_sha256"):
            _sha(corpus.get(name), f"corpus.{name}", errors)
        direction_corpora = corpus.get("direction_corpora")
        if exact(direction_corpora, {"en->es", "es->en", "en->ja", "ja->en"}, "corpus.direction_corpora", errors):
            for direction, corpus_digest in direction_corpora.items():
                _sha(corpus_digest, f"corpus.direction_corpora.{direction}", errors)
            if corpus.get("cases_sha256") != _canonical_digest(direction_corpora):
                errors.append("corpus.cases_sha256: must bind the exact direction corpus digest map")
        for name in ("vad_tool_digest", "fingerprint_tool_digest"):
            _sha(corpus.get(name), f"corpus.{name}", errors, prefixed=True)
        parse_time(corpus.get("generated_at"), "corpus.generated_at", errors)

    registry = documents.get("device_registry")
    tiers = _validate_device_registry(registry, store, errors) if registry is not None else {}

    v1_cells: dict[tuple[str, str, str, str], dict[str, Any]] = {}
    v1_direction_corpora: dict[str, str] = {}
    if (
        preflight_report is not None and v1_manifest is not None and criteria_json is not None
        and resolved_config is not None and testflight_resolved_config is not None
        and isinstance(registry, dict)
    ):
        if preflight_report.get("release_manifest_sha256") != v1_manifest_digest:
            errors.append("preflight.report.release_manifest_sha256: signed v1 manifest binding mismatch")
        if v1_manifest.get("criteria_sha256") != criteria_digest:
            errors.append("preflight.release_manifest.criteria_sha256: signed criteria binding mismatch")
        v1_release = v1_manifest.get("release")
        if not isinstance(v1_release, dict):
            errors.append("preflight.release_manifest.release: must be an object")
            v1_release = {}
        if preflight_report.get("release_identity_sha256") != _canonical_digest(v1_release):
            errors.append("preflight.report.release_identity_sha256: v1 manifest release binding mismatch")
        release_ios = documents.get("ios_builds.release", {})
        backend_provenance = documents.get("backend.provenance", {})
        production_plan = documents.get("environments.production.terraform_plan", {})
        testflight_plan = documents.get("environments.testflight.terraform_plan", {})
        base_image_name = str(v1_release.get("backend_base_image", "")).rsplit("@", 1)[0]
        expected_v1_release = {
            "app_commit": value.get("source_commit"),
            "app_version": app_version,
            "build_number": build_number,
            "release_build_id": candidate_id,
            "xcode_version": release_ios.get("xcode_version") if isinstance(release_ios, dict) else None,
            "backend_base_image": (
                f"{base_image_name}@{backend_provenance.get('base_image_digest')}"
                if isinstance(backend_provenance, dict) and base_image_name else None
            ),
            "backend_image": f"{backend.get('image_name')}@{backend.get('image_digest')}" if isinstance(backend, dict) else None,
            "backend_build_metadata_sha256": backend_provenance.get("v1_build_metadata", {}).get("sha256") if isinstance(backend_provenance, dict) else None,
            "terraform_plan_sha256": production_plan.get("binary_plan_sha256") if isinstance(production_plan, dict) else None,
            "testflight_terraform_plan_sha256": testflight_plan.get("binary_plan_sha256") if isinstance(testflight_plan, dict) else None,
            "terraform_backend_config_sha256": production_plan.get("backend_config_sha256") if isinstance(production_plan, dict) else None,
            "testflight_terraform_backend_config_sha256": testflight_plan.get("backend_config_sha256") if isinstance(testflight_plan, dict) else None,
            "terraform_variables_sha256": production_plan.get("variables_sha256") if isinstance(production_plan, dict) else None,
            "testflight_terraform_variables_sha256": testflight_plan.get("variables_sha256") if isinstance(testflight_plan, dict) else None,
            "terraform_plan_provenance_sha256": production_plan.get("v1_plan_provenance", {}).get("sha256") if isinstance(production_plan, dict) else None,
            "testflight_terraform_plan_provenance_sha256": testflight_plan.get("v1_plan_provenance", {}).get("sha256") if isinstance(testflight_plan, dict) else None,
            "ios_resolved_config_sha256": resolved_config_digest,
            "testflight_resolved_config_sha256": testflight_resolved_config_digest,
            "device_registry_sha256": digests.get("device_registry"),
            "configuration": "Release",
            "local_llm_experiment": False,
        }
        for field, expected_value in expected_v1_release.items():
            if v1_release.get(field) != expected_value:
                errors.append(f"preflight.release_manifest.release.{field}: candidate binding mismatch")
        v1_errors = validate_manifest(
            v1_manifest,
            criteria_json,
            criteria_digest,
            artifact_store=store.store,
            device_registry=registry,
            device_registry_sha256=digests.get("device_registry", ""),
            resolved_config=resolved_config,
            resolved_config_sha256=resolved_config_digest,
            testflight_resolved_config=testflight_resolved_config,
            testflight_resolved_config_sha256=testflight_resolved_config_digest,
            live_release=expected_v1_release,
        )
        errors.extend(f"bound v1 preflight: {error}" for error in v1_errors)

        matrix = v1_manifest.get("matrix")
        if isinstance(matrix, list):
            for index, row in enumerate(matrix):
                if not isinstance(row, dict):
                    continue
                cell = tuple(row.get(field) for field in ("direction", "route", "device_tier", "environment"))
                if len(cell) != 4 or any(not isinstance(part, str) for part in cell):
                    continue
                evidence = row.get("evidence")
                automated = evidence.get("automated_text") if isinstance(evidence, dict) else None
                if not isinstance(automated, dict):
                    errors.append(f"preflight.release_manifest.matrix[{index}].evidence.automated_text: missing")
                    continue
                report_ref = {"artifact_uri": automated.get("artifact_uri"), "sha256": automated.get("sha256")}
                automated_report = store.store.verify_ref(
                    report_ref,
                    f"preflight.release_manifest.matrix[{index}].evidence.automated_text",
                    errors,
                    load_json=True,
                )
                if not isinstance(automated_report, dict):
                    continue
                scope = automated_report.get("scope")
                expected_scope = {
                    "kind": "cell", "direction": cell[0], "route": cell[1],
                    "device_tier": cell[2], "environment": cell[3],
                }
                bindings = automated_report.get("bindings")
                attachments = automated_report.get("attachments")
                if (
                    automated_report.get("schema_version") != "1.0"
                    or automated_report.get("category") != "automated_text"
                    or automated_report.get("status") != "passed"
                    or scope != expected_scope
                    or not isinstance(bindings, dict)
                    or not isinstance(attachments, list)
                    or len(attachments) != 1
                    or not isinstance(attachments[0], dict)
                ):
                    errors.append(f"preflight.release_manifest.matrix[{index}]: malformed automated evidence binding")
                    continue
                corpus_ref = bindings.get("corpus")
                run_ref = bindings.get("run_identity")
                if not isinstance(corpus_ref, dict) or not isinstance(run_ref, dict):
                    errors.append(f"preflight.release_manifest.matrix[{index}]: automated evidence lacks corpus/run bindings")
                    continue
                corpus_digest = corpus_ref.get("sha256")
                previous_corpus = v1_direction_corpora.setdefault(str(cell[0]), str(corpus_digest))
                if previous_corpus != corpus_digest:
                    errors.append(f"preflight.release_manifest.matrix[{index}]: direction corpus binding changed")
                run_json = store.store.verify_ref(
                    run_ref,
                    f"preflight.release_manifest.matrix[{index}].automated_text.run_identity",
                    errors,
                    load_json=True,
                )
                if cell in v1_cells:
                    errors.append(f"preflight.release_manifest.matrix[{index}]: duplicate v1 matrix cell")
                    continue
                v1_cells[cell] = {
                    "report_sha256": automated.get("sha256"),
                    "corpus_sha256": corpus_ref.get("sha256"),
                    "run_identity_sha256": run_ref.get("sha256"),
                    "run_id": run_json.get("run_id") if isinstance(run_json, dict) else None,
                    "outputs": attachments[0],
                }
        else:
            errors.append("preflight.release_manifest.matrix: must be an array")
        if len(v1_cells) != 96:
            errors.append("preflight.release_manifest.matrix: exactly 96 bound automated-text cells are required")
        signed_direction_corpora = corpus.get("direction_corpora") if isinstance(corpus, dict) else None
        if signed_direction_corpora != v1_direction_corpora:
            errors.append("corpus.direction_corpora: signed v2 corpus must equal the fully validated v1 corpus map")

    ios_digests: dict[str, str] = {}
    ios_keys = {"kind", "schema_version", "configuration", "source_commit", "source_tree", "archive", "ipa", "executable_sha256", "code_directory_hash", "bundle_id", "app_version", "build_number", "embedded_build_id", "entitlements_sha256", "provisioning_profile_sha256", "provisioning_profile_uuid", "team_id", "application_identifier", "signing_certificate_sha256", "xcode_version", "sdk_version", "resolved_config_sha256", "generated_at"}
    bundle_ids: set[str] = set()
    binary_hashes: set[str] = set()
    ios_artifact_hashes: set[str] = set()
    for environment, configuration in (("production", "Release"), ("testflight", "TestFlight")):
        name = f"ios_builds.{environment if environment == 'testflight' else 'release'}"
        document = documents.get(name)
        if not exact(document, ios_keys, name, errors):
            continue
        expected_ios = {
            "kind": "ios-build", "schema_version": "1.0", "configuration": configuration,
            "source_commit": value.get("source_commit"), "source_tree": source_tree,
            "app_version": app_version, "build_number": build_number, "embedded_build_id": candidate_id,
            "resolved_config_sha256": (
                testflight_resolved_config_digest if environment == "testflight" else resolved_config_digest
            ),
        }
        for field, expected_value in expected_ios.items():
            if document.get(field) != expected_value:
                errors.append(f"{name}.{field}: candidate binding mismatch")
        for field in ("executable_sha256", "entitlements_sha256", "provisioning_profile_sha256", "signing_certificate_sha256", "resolved_config_sha256"):
            _sha(document.get(field), f"{name}.{field}", errors)
        if not isinstance(document.get("bundle_id"), str) or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", document["bundle_id"]):
            errors.append(f"{name}.bundle_id: invalid reverse-DNS identifier")
        if not isinstance(document.get("team_id"), str) or not re.fullmatch(r"[A-Z0-9]{10}", document["team_id"]):
            errors.append(f"{name}.team_id: invalid Apple team ID")
        if document.get("application_identifier") != f"{document.get('team_id')}.{document.get('bundle_id')}":
            errors.append(f"{name}.application_identifier: team/bundle binding mismatch")
        if not isinstance(document.get("code_directory_hash"), str) or not re.fullmatch(r"[A-Fa-f0-9]{40}|[A-Fa-f0-9]{64}", document["code_directory_hash"]):
            errors.append(f"{name}.code_directory_hash: invalid CodeDirectory digest")
        try:
            xcode = tuple(int(part) for part in str(document.get("xcode_version")).split("."))
        except ValueError:
            xcode = ()
        if xcode < (26, 4) or not re.fullmatch(r"26\.[0-9]+(?:\.[0-9]+)?", str(document.get("sdk_version"))):
            errors.append(f"{name}: Xcode must be >=26.4 and SDK must be an exact iOS 26 version")
        for artifact_name in ("archive", "ipa"):
            artifact_hash = _artifact(document.get(artifact_name), f"{name}.{artifact_name}", store, errors)
            if artifact_hash in ios_artifact_hashes:
                errors.append(f"{name}.{artifact_name}: Release/TestFlight archive and IPA artifacts must be distinct")
            ios_artifact_hashes.add(artifact_hash)
        bundle_ids.add(str(document.get("bundle_id")))
        binary_hashes.add(str(document.get("executable_sha256")))
        ios_digests[environment] = digests.get(name, "")
        parse_time(document.get("generated_at"), f"{name}.generated_at", errors)
    if len(bundle_ids) != 2 or len(binary_hashes) != 2:
        errors.append("candidate.ios_builds: Release and TestFlight require distinct bundle IDs and executables")

    image_digest = backend.get("image_digest") if isinstance(backend, dict) else None
    provenance = documents.get("backend.provenance")
    provenance_keys = {"kind", "schema_version", "source_commit", "source_tree", "image_name", "image_digest", "runnable_manifest_digest", "base_image_digest", "v1_build_metadata", "build_context_sha256", "dockerfile_sha256", "builder_id", "generated_at"}
    if exact(provenance, provenance_keys, "backend.provenance", errors):
        expected_backend = {"kind": "backend-provenance", "schema_version": "1.0", "source_commit": value.get("source_commit"), "source_tree": source_tree, "image_name": backend.get("image_name") if isinstance(backend, dict) else None, "image_digest": image_digest, "runnable_manifest_digest": backend.get("runnable_manifest_digest") if isinstance(backend, dict) else None}
        for field, expected_value in expected_backend.items():
            if provenance.get(field) != expected_value:
                errors.append(f"backend.provenance.{field}: candidate binding mismatch")
        for field in ("base_image_digest", "runnable_manifest_digest"):
            _sha(provenance.get(field), f"backend.provenance.{field}", errors, prefixed=True)
        for field in ("build_context_sha256", "dockerfile_sha256"):
            _sha(provenance.get(field), f"backend.provenance.{field}", errors)
        metadata_path = store.artifact(provenance.get("v1_build_metadata"), "backend.provenance.v1_build_metadata")
        metadata = store.json(metadata_path, "backend.provenance.v1_build_metadata") if metadata_path is not None else None
        release_binding = metadata.get("locallingo.release") if isinstance(metadata, dict) else None
        expected_metadata = {
            "schema_version": "1.0", "source_commit": value.get("source_commit"),
            "application_image_digest": image_digest, "oci_index_digest": image_digest,
            "runnable_manifest_digest": provenance.get("runnable_manifest_digest"),
            "platform": "linux/amd64", "backend_context_sha256": provenance.get("build_context_sha256"),
        }
        if not isinstance(metadata, dict) or metadata.get("containerimage.digest") != image_digest or not isinstance(metadata.get("buildx.build.provenance"), dict):
            errors.append("backend.provenance.v1_build_metadata: invalid BuildKit metadata identity")
        if not isinstance(release_binding, dict) or any(release_binding.get(key) != expected_value for key, expected_value in expected_metadata.items()):
            errors.append("backend.provenance.v1_build_metadata.locallingo.release: v2 provenance binding mismatch")
        if not isinstance(release_binding, dict) or not str(release_binding.get("base_image", "")).endswith("@" + str(provenance.get("base_image_digest"))):
            errors.append("backend.provenance.v1_build_metadata.locallingo.release.base_image: base digest mismatch")
        parse_time(provenance.get("generated_at"), "backend.provenance.generated_at", errors)
    sbom = documents.get("backend.sbom")
    if exact(sbom, {"kind", "schema_version", "image_digest", "document", "format", "generator_digest", "generated_at"}, "backend.sbom", errors):
        if sbom.get("kind") != "backend-sbom" or sbom.get("schema_version") != "1.0" or sbom.get("image_digest") != image_digest or sbom.get("format") not in {"SPDX-2.3", "CycloneDX-1.5"}:
            errors.append("backend.sbom: image/schema/format binding mismatch")
        sbom_path = store.artifact(sbom.get("document"), "backend.sbom.document")
        sbom_document = store.json(sbom_path, "backend.sbom.document") if sbom_path is not None else None
        if sbom.get("format") == "CycloneDX-1.5":
            if (
                not isinstance(sbom_document, dict)
                or sbom_document.get("bomFormat") != "CycloneDX"
                or sbom_document.get("specVersion") != "1.5"
                or not isinstance(sbom_document.get("components"), list)
            ):
                errors.append("backend.sbom.document: must be a parsed CycloneDX 1.5 document")
        elif sbom.get("format") == "SPDX-2.3" and (
            not isinstance(sbom_document, dict) or sbom_document.get("spdxVersion") != "SPDX-2.3"
        ):
            errors.append("backend.sbom.document: must be a parsed SPDX 2.3 document")
        _sha(sbom.get("generator_digest"), "backend.sbom.generator_digest", errors, prefixed=True)
        parse_time(sbom.get("generated_at"), "backend.sbom.generated_at", errors)
    scan_keys = {"kind", "schema_version", "image_digest", "report", "scanner_digest", "database_digest", "policy_sha256", "status", "generated_at"}
    for name, kind in (("backend.vulnerability_scan", "vulnerability-scan"), ("backend.secret_scan", "secret-scan")):
        scan = documents.get(name)
        if not exact(scan, scan_keys, name, errors):
            continue
        if scan.get("kind") != kind or scan.get("schema_version") != "1.0" or scan.get("image_digest") != image_digest or scan.get("status") != "passed":
            errors.append(f"{name}: image/schema/status binding mismatch")
        _artifact(scan.get("report"), f"{name}.report", store, errors)
        _sha(scan.get("scanner_digest"), f"{name}.scanner_digest", errors, prefixed=True)
        if name.endswith("vulnerability_scan"):
            _sha(scan.get("database_digest"), f"{name}.database_digest", errors, prefixed=True)
        elif scan.get("database_digest") is not None:
            errors.append(f"{name}.database_digest: must be null for the secret scanner")
        _sha(scan.get("policy_sha256"), f"{name}.policy_sha256", errors)
        parse_time(scan.get("generated_at"), f"{name}.generated_at", errors)

    receipts: dict[str, dict[str, Any]] = {}
    environment_policies: dict[str, dict[str, Any]] = {}
    policy_digests: set[str] = set()
    plan_nonces: set[str] = set()
    for environment in ("production", "testflight"):
        policy_name = f"environments.{environment}.policy"
        plan_name = f"environments.{environment}.terraform_plan"
        receipt_name = f"environments.{environment}.deployment_receipt"
        environment_policy = documents.get(policy_name)
        policy_keys = {"kind", "schema_version", "environment", "project_id", "project_number", "region", "state_bucket", "state_prefix", "registry_repository", "api_domain", "cloud_run_service", "runtime_service_account_email", "runtime_service_account_unique_id", "firestore_database", "firestore_location", "environment_variables", "secret_bindings", "environment_sha256", "secret_bindings_sha256", "bootstrap_outputs_sha256", "iam_policy_sha256", "generated_at"}
        if exact(environment_policy, policy_keys, policy_name, errors):
            if environment_policy.get("kind") != "environment-policy" or environment_policy.get("schema_version") != "1.0" or environment_policy.get("environment") != environment or environment_policy.get("region") != "us-central1" or environment_policy.get("firestore_location") != "us-central1":
                errors.append(f"{policy_name}: environment/schema/location mismatch")
            for field in ("environment_sha256", "secret_bindings_sha256", "bootstrap_outputs_sha256", "iam_policy_sha256"):
                _sha(environment_policy.get(field), f"{policy_name}.{field}", errors)
            project_id = environment_policy.get("project_id")
            canonical_repository = f"us-central1-docker.pkg.dev/{project_id}/locallingo"
            identity_checks = (
                (isinstance(project_id, str) and re.fullmatch(r"[a-z][a-z0-9-]{4,28}[a-z0-9]", project_id), "project_id"),
                (isinstance(environment_policy.get("project_number"), str) and re.fullmatch(r"[0-9]{6,30}", environment_policy["project_number"]), "project_number"),
                (environment_policy.get("registry_repository") == canonical_repository, "registry_repository"),
                (isinstance(environment_policy.get("state_bucket"), str) and re.fullmatch(r"[a-z0-9][a-z0-9._-]{2,62}", environment_policy["state_bucket"]), "state_bucket"),
                (isinstance(environment_policy.get("state_prefix"), str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._/-]{0,127}", environment_policy["state_prefix"]), "state_prefix"),
                (isinstance(environment_policy.get("cloud_run_service"), str) and re.fullmatch(r"[a-z][a-z0-9-]{1,62}", environment_policy["cloud_run_service"]), "cloud_run_service"),
                (isinstance(environment_policy.get("runtime_service_account_email"), str) and re.fullmatch(rf"[a-z][a-z0-9-]{{4,28}}@{re.escape(str(project_id))}\.iam\.gserviceaccount\.com", environment_policy["runtime_service_account_email"]), "runtime_service_account_email"),
                (isinstance(environment_policy.get("runtime_service_account_unique_id"), str) and re.fullmatch(r"[0-9]{10,30}", environment_policy["runtime_service_account_unique_id"]), "runtime_service_account_unique_id"),
                (environment_policy.get("firestore_database") == "(default)", "firestore_database"),
            )
            for valid, field in identity_checks:
                if not valid:
                    errors.append(f"{policy_name}.{field}: invalid canonical environment identity")
            environment_image_names = backend.get("environment_image_names", {}) if isinstance(backend, dict) else {}
            environment_image_name = environment_image_names.get(environment) if isinstance(environment_image_names, dict) else None
            if not isinstance(environment_image_name, str) or not re.fullmatch(re.escape(canonical_repository) + r"/[a-z][a-z0-9._/-]{0,127}", environment_image_name):
                errors.append(f"candidate.backend.environment_image_names.{environment}: must be under the canonical environment repository")
            environment_variables = environment_policy.get("environment_variables")
            required_environment = {
                "ALLOWED_APP_BUNDLE_VERSIONS", "ALLOWED_PRODUCT_IDS", "APPLE_APP_ID_PREFIX",
                "APPLE_APP_STORE_ID", "APPLE_BUNDLE_ID", "APPLE_IAP_ISSUER_ID", "APPLE_IAP_KEY_ID",
                "APPLE_STOREKIT_ENVIRONMENT", "APP_ATTEST_ENVIRONMENT", "APPLE_TEAM_ID",
                "FIRESTORE_DATABASE", "FIRESTORE_PROJECT", "GOOGLE_CLOUD_PROJECT", "GOOGLE_STT_LOCATION",
                "GOOGLE_TRANSLATION_LOCATION", "ONLINE_ENABLED", "RUNTIME_MODE", "RELEASE_BUILD_ID",
                "BACKEND_OCI_DIGEST",
            } | set(FIXED_RUNTIME_LIMITS)
            if not exact(environment_variables, required_environment, f"{policy_name}.environment_variables", errors):
                environment_variables = {}
            expected_environment = {
                **FIXED_RUNTIME_LIMITS,
                "APP_ATTEST_ENVIRONMENT": "production",
                "APPLE_STOREKIT_ENVIRONMENT": "Production" if environment == "production" else "Sandbox",
                "FIRESTORE_DATABASE": environment_policy.get("firestore_database"),
                "FIRESTORE_PROJECT": environment_policy.get("project_id"),
                "GOOGLE_CLOUD_PROJECT": environment_policy.get("project_id"),
                "GOOGLE_STT_LOCATION": "us", "GOOGLE_TRANSLATION_LOCATION": "us-central1",
                "ONLINE_ENABLED": "true", "RUNTIME_MODE": environment,
                "RELEASE_BUILD_ID": candidate_id, "BACKEND_OCI_DIGEST": image_digest,
            }
            for field, expected_value in expected_environment.items():
                if environment_variables.get(field) != expected_value:
                    errors.append(f"{policy_name}.environment_variables.{field}: reviewed deployment value mismatch")
            for field in required_environment - set(expected_environment):
                if not isinstance(environment_variables.get(field), str) or not environment_variables[field].strip():
                    errors.append(f"{policy_name}.environment_variables.{field}: must be nonempty")
            selected_config = testflight_resolved_config if environment == "testflight" else resolved_config
            selected_ios_name = "ios_builds.testflight" if environment == "testflight" else "ios_builds.release"
            selected_ios = documents.get(selected_ios_name)
            if not isinstance(selected_config, dict) or not isinstance(selected_ios, dict):
                errors.append(f"{policy_name}: resolved iOS configuration and signed build are required")
            else:
                contract = selected_config.get("backend_contract")
                if not isinstance(contract, dict):
                    contract = {}
                reviewed_ios_environment = {
                    "APPLE_APP_ID_PREFIX": selected_ios.get("team_id"),
                    "APPLE_BUNDLE_ID": selected_config.get("APP_BUNDLE_IDENTIFIER"),
                    "APPLE_TEAM_ID": selected_config.get("DEVELOPMENT_TEAM"),
                    "APP_ATTEST_ENVIRONMENT": selected_config.get("APP_ATTEST_ENVIRONMENT"),
                    "ALLOWED_PRODUCT_IDS": contract.get("ALLOWED_PRODUCT_IDS"),
                    "ALLOWED_APP_BUNDLE_VERSIONS": contract.get("ALLOWED_APP_BUNDLE_VERSIONS"),
                }
                for field, expected_value in reviewed_ios_environment.items():
                    if environment_variables.get(field) != expected_value:
                        errors.append(f"{policy_name}.environment_variables.{field}: resolved iOS binding mismatch")
                if selected_ios.get("bundle_id") != selected_config.get("APP_BUNDLE_IDENTIFIER"):
                    errors.append(f"{selected_ios_name}.bundle_id: resolved iOS configuration binding mismatch")
                if selected_ios.get("team_id") != selected_config.get("DEVELOPMENT_TEAM"):
                    errors.append(f"{selected_ios_name}.team_id: resolved iOS configuration binding mismatch")
                try:
                    config_api_domain = urlsplit(str(selected_config.get("API_BASE_URL", ""))).hostname
                except ValueError:
                    config_api_domain = None
                if (
                    environment_policy.get("api_domain") != config_api_domain
                    or contract.get("API_DOMAIN") != config_api_domain
                ):
                    errors.append(f"{policy_name}.api_domain: resolved iOS/backend contract binding mismatch")
            if environment_policy.get("environment_sha256") != _canonical_digest(environment_variables):
                errors.append(f"{policy_name}.environment_sha256: environment map digest mismatch")
            secret_bindings = environment_policy.get("secret_bindings")
            if not exact(secret_bindings, set(REVIEWED_SECRET_IDS), f"{policy_name}.secret_bindings", errors):
                secret_bindings = {}
            for field, secret_id in REVIEWED_SECRET_IDS.items():
                binding = secret_bindings.get(field)
                binding_path = f"{policy_name}.secret_bindings.{field}"
                if not exact(binding, {"resource", "version", "value_sha256"}, binding_path, errors):
                    continue
                expected_resource = f"projects/{environment_policy.get('project_id')}/secrets/{secret_id}"
                if binding.get("resource") != expected_resource or not re.fullmatch(r"[1-9][0-9]*", str(binding.get("version", ""))):
                    errors.append(f"{binding_path}: exact secret resource and numeric version are required")
                _sha(binding.get("value_sha256"), f"{binding_path}.value_sha256", errors)
            if environment_policy.get("secret_bindings_sha256") != _canonical_digest(secret_bindings):
                errors.append(f"{policy_name}.secret_bindings_sha256: secret map digest mismatch")
            parse_time(environment_policy.get("generated_at"), f"{policy_name}.generated_at", errors)
            environment_policies[environment] = environment_policy
        policy_digest = digests.get(policy_name, "")
        policy_digests.add(policy_digest)
        plan = documents.get(plan_name)
        plan_keys = {"kind", "schema_version", "environment", "source_commit", "source_tree", "terraform_version", "provider_lock_sha256", "configuration_sha256", "backend_config_sha256", "variables_sha256", "binary_plan_sha256", "plan_json_sha256", "v1_plan_provenance", "image_name", "image_digest", "runnable_manifest_digest", "state_bucket", "state_prefix", "state_lineage", "state_serial", "state_object_generation", "state_sha256", "environment_policy_sha256", "project_id", "region", "nonce", "generated_at"}
        if exact(plan, plan_keys, plan_name, errors):
            environment_image_names = backend.get("environment_image_names", {}) if isinstance(backend, dict) else {}
            expected_plan = {"kind": "terraform-plan", "schema_version": "2.0", "environment": environment, "source_commit": value.get("source_commit"), "source_tree": source_tree, "terraform_version": "1.15.7", "environment_policy_sha256": policy_digest, "project_id": environment_policy.get("project_id") if isinstance(environment_policy, dict) else None, "region": "us-central1", "state_bucket": environment_policy.get("state_bucket") if isinstance(environment_policy, dict) else None, "state_prefix": environment_policy.get("state_prefix") if isinstance(environment_policy, dict) else None, "image_name": environment_image_names.get(environment) if isinstance(environment_image_names, dict) else None, "image_digest": image_digest, "runnable_manifest_digest": backend.get("runnable_manifest_digest") if isinstance(backend, dict) else None}
            for field, expected_value in expected_plan.items():
                if plan.get(field) != expected_value:
                    errors.append(f"{plan_name}.{field}: policy/candidate binding mismatch")
            for field in ("provider_lock_sha256", "configuration_sha256", "backend_config_sha256", "variables_sha256", "binary_plan_sha256", "plan_json_sha256", "state_sha256"):
                _sha(plan.get(field), f"{plan_name}.{field}", errors)
            nonce = plan.get("nonce")
            if not isinstance(nonce, str) or not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", nonce) or nonce in plan_nonces:
                errors.append(f"{plan_name}.nonce: must be a unique 32-128 character plan nonce")
            else:
                plan_nonces.add(nonce)
            v1_plan_path = store.artifact(plan.get("v1_plan_provenance"), f"{plan_name}.v1_plan_provenance")
            v1_plan = store.json(v1_plan_path, f"{plan_name}.v1_plan_provenance") if v1_plan_path is not None else None
            expected_v1_plan = {
                "schema_version": "1.0", "stack": "service", "app_commit": value.get("source_commit"),
                "terraform_version": "1.15.7", "configuration_sha256": plan.get("configuration_sha256"),
                "backend_config_sha256": plan.get("backend_config_sha256"),
                "variables_sha256": plan.get("variables_sha256"), "plan_sha256": plan.get("binary_plan_sha256"),
                "project_id": plan.get("project_id"), "environment": environment,
            }
            if not isinstance(v1_plan, dict) or any(v1_plan.get(key) != expected_value for key, expected_value in expected_v1_plan.items()):
                errors.append(f"{plan_name}.v1_plan_provenance: v1/v2 plan identity mismatch")
            if not isinstance(v1_plan, dict) or set(v1_plan) != set(expected_v1_plan) | {"generated_at"}:
                errors.append(f"{plan_name}.v1_plan_provenance: exact schema-v1 provenance fields are required")
            if not isinstance(plan.get("state_lineage"), str) or len(plan["state_lineage"]) < 8 or not isinstance(plan.get("state_serial"), int) or isinstance(plan.get("state_serial"), bool) or plan["state_serial"] < 0 or not re.fullmatch(r"[0-9]+", str(plan.get("state_object_generation", ""))):
                errors.append(f"{plan_name}: invalid immutable state lineage/serial/generation")
            parse_time(plan.get("generated_at"), f"{plan_name}.generated_at", errors)
        receipt = documents.get(receipt_name)
        receipt_keys = {"kind", "schema_version", "environment", "plan_sha256", "environment_policy_sha256", "release_build_id", "cloud_run_revision", "image_digest", "traffic_percent", "runtime_service_account_unique_id", "iam_sha256", "firestore_sha256", "secret_bindings_sha256", "load_balancer_sha256", "api_domain", "registry_manifest", "control_plane", "availability", "observed_at"}
        if exact(receipt, receipt_keys, receipt_name, errors):
            expected_receipt = {"kind": "deployment-receipt", "schema_version": "1.0", "environment": environment, "plan_sha256": digests.get(plan_name), "environment_policy_sha256": policy_digest, "release_build_id": candidate_id, "image_digest": image_digest, "traffic_percent": 100, "runtime_service_account_unique_id": environment_policy.get("runtime_service_account_unique_id") if isinstance(environment_policy, dict) else None, "secret_bindings_sha256": environment_policy.get("secret_bindings_sha256") if isinstance(environment_policy, dict) else None, "api_domain": environment_policy.get("api_domain") if isinstance(environment_policy, dict) else None}
            for field, expected_value in expected_receipt.items():
                if receipt.get(field) != expected_value:
                    errors.append(f"{receipt_name}.{field}: deployment/policy/candidate binding mismatch")
            for field in ("iam_sha256", "firestore_sha256", "load_balancer_sha256"):
                _sha(receipt.get(field), f"{receipt_name}.{field}", errors)
            registry_path = store.artifact(receipt.get("registry_manifest"), f"{receipt_name}.registry_manifest")
            registry_manifest = store.json(registry_path, f"{receipt_name}.registry_manifest") if registry_path is not None else None
            environment_image_names = backend.get("environment_image_names", {}) if isinstance(backend, dict) else {}
            expected_registry = {
                "schema_version": "1.0",
                "image_name": environment_image_names.get(environment) if isinstance(environment_image_names, dict) else None,
                "oci_index_digest": image_digest,
                "runnable_manifest_digest": backend.get("runnable_manifest_digest") if isinstance(backend, dict) else None,
            }
            if registry_manifest != expected_registry:
                errors.append(f"{receipt_name}.registry_manifest: registry subject/runnable identity mismatch")
            if not isinstance(receipt.get("cloud_run_revision"), str) or not re.fullmatch(r"[a-z][a-z0-9-]{0,48}-[0-9]{5}-[a-z0-9]{3}", receipt["cloud_run_revision"]):
                errors.append(f"{receipt_name}.cloud_run_revision: invalid immutable Cloud Run revision")
            control_path = store.artifact(receipt.get("control_plane"), f"{receipt_name}.control_plane")
            if control_path is not None:
                control = store.json(control_path, f"{receipt_name}.control_plane")
                control_keys = {"project_id", "location", "service", "revision", "image_digest", "traffic_percent", "runtime_service_account_unique_id", "observed_at"}
                expected_control = {"project_id": environment_policy.get("project_id") if isinstance(environment_policy, dict) else None, "location": "us-central1", "service": environment_policy.get("cloud_run_service") if isinstance(environment_policy, dict) else None, "revision": receipt.get("cloud_run_revision"), "image_digest": image_digest, "traffic_percent": 100, "runtime_service_account_unique_id": receipt.get("runtime_service_account_unique_id"), "observed_at": receipt.get("observed_at")}
                if not exact(control, control_keys, f"{receipt_name}.control_plane", errors) or control != expected_control:
                    errors.append(f"{receipt_name}.control_plane: Cloud Run control-plane identity mismatch")
            availability_path = store.artifact(receipt.get("availability"), f"{receipt_name}.availability")
            if availability_path is not None:
                availability = store.json(availability_path, f"{receipt_name}.availability")
                expected_identity = {"releaseBuildID": candidate_id, "ociDigest": image_digest, "environment": environment, "revision": receipt.get("cloud_run_revision"), "assurance": "self-reported-diagnostic"}
                if not exact(availability, {"available", "buildIdentity"}, f"{receipt_name}.availability", errors) or availability.get("available") is not True or not exact(availability.get("buildIdentity"), set(expected_identity), f"{receipt_name}.availability.buildIdentity", errors):
                    errors.append(f"{receipt_name}.availability: readiness/build identity is invalid")
                elif availability["buildIdentity"] != expected_identity:
                    errors.append(f"{receipt_name}.availability.buildIdentity: deployment identity mismatch")
            observed = parse_time(receipt.get("observed_at"), f"{receipt_name}.observed_at", errors)
            if created is not None and observed is not None and observed < created:
                errors.append(f"{receipt_name}.observed_at: deployment cannot predate candidate issuance")
            receipts[environment] = receipt
    if len(policy_digests) != 2 or any(not SHA256_RE.fullmatch(item) for item in policy_digests):
        errors.append("candidate.environments: production and TestFlight policies must be distinct")
    if len(environment_policies) == 2:
        isolation_fields = ("project_id", "project_number", "registry_repository", "api_domain", "cloud_run_service", "runtime_service_account_email", "runtime_service_account_unique_id")
        for field in isolation_fields:
            if environment_policies["production"].get(field) == environment_policies["testflight"].get(field):
                errors.append(f"candidate.environments: production and TestFlight {field} must be distinct")
        production_state = (environment_policies["production"].get("state_bucket"), environment_policies["production"].get("state_prefix"))
        testflight_state = (environment_policies["testflight"].get("state_bucket"), environment_policies["testflight"].get("state_prefix"))
        if production_state == testflight_state:
            errors.append("candidate.environments: production and TestFlight state bucket/prefix must be distinct")

    expected_cells = set(itertools.product(
        ("en->es", "es->en", "en->ja", "ja->en"),
        ("local_only", "online_quality", "auto_local", "auto_online"),
        ("minimum", "mid_tier", "current"), ("testflight", "production"),
    ))
    actual_cells: set[tuple[str, str, str, str]] = set()
    run_ids: set[str] = set()
    nonces: set[str] = set()
    attest_ids: set[str] = set()
    output_digests: set[str] = set()
    tier_udids: dict[str, str] = {}
    device_keys = {
        "kind", "schema_version", "run_id", "nonce", "candidate_id", "corpus_sha256",
        "v1_corpus_sha256", "v1_run_identity_sha256", "v1_automated_report_sha256",
        "direction", "route", "device_tier", "environment", "device_registry_sha256",
        "device_identifier", "device_udid_sha256", "os_version", "os_build", "app_build_id",
        "ios_build_attestation_sha256", "backend_image_digest", "backend_revision", "api_domain",
        "app_attest_request_id", "outputs", "timings", "trace", "started_at", "completed_at",
    }
    for index in range(len(device_refs)):
        name = f"device_runs[{index}]"
        run = documents.get(name)
        if not exact(run, device_keys, name, errors):
            continue
        cell = (run.get("direction"), run.get("route"), run.get("device_tier"), run.get("environment"))
        actual_cells.add(cell)
        v1_cell = v1_cells.get(cell, {})
        environment = run.get("environment")
        tier = run.get("device_tier")
        receipt = receipts.get(environment, {})
        device = tiers.get(tier, {}) if isinstance(tiers, dict) else {}
        expected_run = {
            "kind": "device-run", "schema_version": "2.0", "candidate_id": candidate_id,
            "corpus_sha256": digests.get("corpus"),
            "v1_corpus_sha256": v1_cell.get("corpus_sha256"),
            "v1_run_identity_sha256": v1_cell.get("run_identity_sha256"),
            "v1_automated_report_sha256": v1_cell.get("report_sha256"),
            "device_registry_sha256": digests.get("device_registry"),
            "device_identifier": device.get("model_identifier"), "os_version": device.get("os_version"),
            "os_build": device.get("os_build"), "app_build_id": candidate_id,
            "ios_build_attestation_sha256": ios_digests.get(environment),
        }
        for field, expected_value in expected_run.items():
            if run.get(field) != expected_value:
                errors.append(f"{name}.{field}: candidate/device/deployment binding mismatch")
        for field, collection in (("run_id", run_ids), ("nonce", nonces)):
            current = run.get(field)
            if not isinstance(current, str) or len(current) < (32 if field == "nonce" else 8) or current in collection:
                errors.append(f"{name}.{field}: must be a unique bounded identifier")
            elif field == "nonce" and not re.fullmatch(r"[A-Za-z0-9_-]{32,128}", current):
                errors.append(f"{name}.{field}: invalid nonce")
            else:
                collection.add(current)
        if run.get("run_id") != v1_cell.get("run_id"):
            errors.append(f"{name}.run_id: must equal the bound v1 run identity")
        local_route = run.get("route") in {"local_only", "auto_local"}
        contact_fields = ("backend_image_digest", "backend_revision", "api_domain", "app_attest_request_id")
        if local_route:
            if any(run.get(field) is not None for field in contact_fields):
                errors.append(f"{name}: local route must not contain backend contact identity")
        else:
            expected_online = {"backend_image_digest": image_digest, "backend_revision": receipt.get("cloud_run_revision"), "api_domain": receipt.get("api_domain")}
            for field, expected_value in expected_online.items():
                if run.get(field) != expected_value:
                    errors.append(f"{name}.{field}: online deployment binding mismatch")
            request_id = run.get("app_attest_request_id")
            if not isinstance(request_id, str) or len(request_id) < 8 or request_id in attest_ids:
                errors.append(f"{name}.app_attest_request_id: online route requires a unique authenticated request")
            else:
                attest_ids.add(request_id)
        _sha(run.get("device_udid_sha256"), f"{name}.device_udid_sha256", errors)
        udid = run.get("device_udid_sha256")
        previous_udid = tier_udids.setdefault(str(tier), str(udid))
        if previous_udid != udid:
            errors.append(f"{name}.device_udid_sha256: every run in a tier must use the same physical device")
        trace_path: Path | None = None
        for field in ("outputs", "timings", "trace"):
            artifact_digest = _artifact(run.get(field), f"{name}.{field}", store, errors)
            if artifact_digest in output_digests:
                errors.append(f"{name}.{field}: device evidence artifact reuse is forbidden")
            output_digests.add(artifact_digest)
            if field == "trace":
                trace_path = store.artifact(run.get(field), f"{name}.{field}")
        outputs = run.get("outputs")
        v1_outputs = v1_cell.get("outputs")
        if (
            not isinstance(outputs, dict) or not isinstance(v1_outputs, dict)
            or outputs.get("path") != v1_outputs.get("artifact_uri")
            or outputs.get("sha256") != v1_outputs.get("sha256")
        ):
            errors.append(f"{name}.outputs: must equal the bound v1 automated predictions artifact")
        if local_route and trace_path is not None:
            trace = store.json(trace_path, f"{name}.trace")
            trace_keys = {"network_request_count", "conversation_content_egress_bytes", "capture_sha256", "tool_digest", "started_at", "completed_at"}
            if not exact(trace, trace_keys, f"{name}.trace", errors) or trace.get("network_request_count") != 0 or trace.get("conversation_content_egress_bytes") != 0:
                errors.append(f"{name}.trace: local route must prove zero network/content egress")
            else:
                _sha(trace.get("capture_sha256"), f"{name}.trace.capture_sha256", errors)
                _sha(trace.get("tool_digest"), f"{name}.trace.tool_digest", errors, prefixed=True)
        started = parse_time(run.get("started_at"), f"{name}.started_at", errors)
        completed = parse_time(run.get("completed_at"), f"{name}.completed_at", errors)
        if created is not None and started is not None and started < created:
            errors.append(f"{name}.started_at: run cannot predate candidate issuance")
        if started is not None and completed is not None and completed < started:
            errors.append(f"{name}: completed_at predates started_at")
    if actual_cells != expected_cells:
        errors.append("candidate.device_runs: signed device matrix is missing, duplicated, or contains unexpected cells")
    if len(tier_udids) != 3 or len(set(tier_udids.values())) != 3:
        errors.append("candidate.device_runs: each device tier requires one distinct physical-device UDID")

    preflight_digest = digests.get("preflight")
    approval_not_before = preflight_time or created
    return (preflight_digest, approval_not_before) if _sha(preflight_digest, "candidate.preflight.sha256", errors) and approval_not_before is not None else None


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--artifact-root", type=Path, required=True)
    decision = parser.add_mutually_exclusive_group(required=True)
    decision.add_argument("--decision", help="Decision path relative to artifact root")
    decision.add_argument("--decision-snapshot", type=Path, help="Protected absolute decision snapshot")
    parser.add_argument("--decision-bundle", help="Finalizer bundle path relative to artifact root")
    parser.add_argument("--finalizer-bundle", type=Path, help="Protected not-yet-published finalizer bundle")
    parser.add_argument("--trust-policy", type=Path, required=True)
    parser.add_argument("--trust-policy-sha256", required=True)
    parser.add_argument("--repository-root", type=Path, default=Path(__file__).resolve().parents[2])
    args = parser.parse_args(argv)
    if args.decision is not None and args.decision_bundle is None:
        parser.error("--decision requires --decision-bundle")
    if args.decision is not None and args.finalizer_bundle is not None:
        parser.error("--finalizer-bundle requires --decision-snapshot")
    if args.decision_snapshot is not None and args.decision_bundle is not None:
        parser.error("--decision-bundle is only valid with --decision")
    return args


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    errors: list[str] = []
    gh = "/usr/bin/gh"
    try:
        gh_stat = os.stat(gh, follow_symlinks=True)
        if not stat.S_ISREG(gh_stat.st_mode) or gh_stat.st_mode & 0o022:
            raise OSError("GitHub CLI is not a protected regular executable")
    except OSError as exc:
        errors.append(f"trusted GitHub CLI unavailable at /usr/bin/gh: {exc}")
    if not SHA256_RE.fullmatch(args.trust_policy_sha256):
        errors.append("--trust-policy-sha256 must be a lowercase SHA-256")
    try:
        policy_bytes = safe_bytes(args.trust_policy, "trust policy", errors)
        if policy_bytes is None or hashlib.sha256(policy_bytes).hexdigest() != args.trust_policy_sha256:
            raise ValueError
        policy = strict_json_loads(policy_bytes)
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError, RecursionError):
        policy = None
        errors.append("trust policy is missing, symlinked, invalid, or does not match its pinned digest")
    if not isinstance(policy, dict):
        for error in errors:
            print(error, file=sys.stderr)
        return 2
    verify_signer_policy(policy, args.repository_root, errors)
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        return 2
    store = TrustedStore(args.artifact_root, errors)
    trusted_root = store.artifact(policy.get("trusted_root"), "trust_policy.trusted_root")
    private_snapshots = tempfile.TemporaryDirectory(prefix="locallingo-finalizer-")
    if args.decision is not None:
        decision_path = store.store.resolve(args.decision, "decision", errors)
        decision_bytes = decision_path.read_bytes() if decision_path is not None else None
    else:
        decision_bytes = safe_bytes(args.decision_snapshot, "decision snapshot", errors)
        decision_path = None
        if decision_bytes is not None:
            decision_path = Path(private_snapshots.name) / "decision.json"
            decision_path.write_bytes(decision_bytes)
    bundle_path: Path | None = None
    if args.decision_bundle is not None:
        bundle_path = store.store.resolve(args.decision_bundle, "decision bundle", errors)
    elif args.finalizer_bundle is not None:
        bundle_bytes = safe_bytes(args.finalizer_bundle, "finalizer bundle", errors)
        if bundle_bytes is not None:
            bundle_path = Path(private_snapshots.name) / "finalizer.bundle"
            bundle_path.write_bytes(bundle_bytes)
    if decision_path is None or decision_bytes is None or trusted_root is None:
        for error in errors:
            print(error, file=sys.stderr)
        private_snapshots.cleanup()
        return 2
    finalizer_signed_at = None
    if bundle_path is not None:
        finalizer_signed_at = gh_verify(gh=gh, artifact=decision_path, bundle=bundle_path, trusted_root=trusted_root, policy=policy, signer_name="finalizer", predicate=FINALIZER_PREDICATE, errors=errors)
    try:
        decision = strict_json_loads(decision_bytes)
    except (UnicodeError, json.JSONDecodeError, ValueError, RecursionError):
        decision = None
        errors.append("decision: invalid UTF-8 JSON")
    candidate_digest = ""
    if not exact(decision, {"schema_version", "status", "candidate", "approvals", "finalized_at"}, "decision", errors):
        decision = None
    if isinstance(decision, dict):
        if decision.get("schema_version") != "2.0" or decision.get("status") != "approved":
            errors.append("decision: schema_version/status mismatch")
        finalized = parse_time(decision.get("finalized_at"), "decision.finalized_at", errors)
        if finalizer_signed_at is not None and finalized is not None and abs(finalized - finalizer_signed_at) > timedelta(minutes=10):
            errors.append("decision.finalized_at: must be within ten minutes of the trusted finalizer signing time")
        candidate_pair = store.signed(decision.get("candidate"), "decision.candidate", CANDIDATE_PREDICATE)
        candidate_digest = decision.get("candidate", {}).get("artifact", {}).get("sha256", "")
        candidate_result: tuple[str, datetime] | None = None
        candidate_signed_at: datetime | None = None
        if candidate_pair is not None:
            candidate_signed_at = gh_verify(gh=gh, artifact=candidate_pair[0], bundle=candidate_pair[1], trusted_root=trusted_root, policy=policy, signer_name="candidate", predicate=CANDIDATE_PREDICATE, errors=errors)
            candidate_value = store.json(candidate_pair[0], "candidate")
            candidate_result = validate_candidate(
                candidate_value, candidate_digest, store, policy, gh, trusted_root, errors,
                candidate_signed_at=candidate_signed_at,
            )
        approvals = decision.get("approvals")
        reviewer_ids: set[str] = set()
        if exact(approvals, set(ROLES), "decision.approvals", errors) and candidate_result is not None:
            preflight_digest, candidate_created = candidate_result
            approval_bundle_digests = [
                approvals[role].get("bundle", {}).get("sha256", "")
                for role in ROLES if isinstance(approvals.get(role), dict)
            ]
            if len(approval_bundle_digests) != 4 or any(not SHA256_RE.fullmatch(item) for item in approval_bundle_digests) or len(set(approval_bundle_digests)) != 4:
                errors.append("decision.approvals: every role requires a distinct valid attestation bundle")
            for role in ROLES:
                pair = store.signed(approvals[role], f"decision.approvals.{role}", APPROVAL_PREDICATE)
                if pair is None:
                    continue
                approval_signed_at = gh_verify(gh=gh, artifact=pair[0], bundle=pair[1], trusted_root=trusted_root, policy=policy, signer_name=role, predicate=APPROVAL_PREDICATE, errors=errors)
                approval = store.json(pair[0], f"approval.{role}")
                result = validate_approval(approval, role, candidate_digest, preflight_digest, errors)
                if result is not None:
                    reviewer_id, approved_at = result
                    if reviewer_id in reviewer_ids:
                        errors.append(f"approval.{role}: reviewer must be distinct")
                    reviewer_ids.add(reviewer_id)
                    if approved_at < candidate_created:
                        errors.append(f"approval.{role}: approval predates candidate")
                    if approval_signed_at is not None:
                        if abs(approved_at - approval_signed_at) > timedelta(minutes=10):
                            errors.append(f"approval.{role}.approved_at: must be within ten minutes of trusted signing time")
                        if candidate_signed_at is not None and approval_signed_at < candidate_signed_at:
                            errors.append(f"approval.{role}: trusted signing time predates candidate signing")
                        if finalizer_signed_at is not None and approval_signed_at > finalizer_signed_at:
                            errors.append(f"approval.{role}: trusted signing time is after finalizer signing")
                    if finalized is not None and approved_at > finalized:
                        errors.append(f"approval.{role}: approval is after finalization")
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"RELEASE BLOCKED: {len(errors)} trusted-evidence error(s).", file=sys.stderr)
        private_snapshots.cleanup()
        return 1
    print(json.dumps(verification_result(candidate_digest, signed_final=bundle_path is not None), sort_keys=True))
    private_snapshots.cleanup()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
