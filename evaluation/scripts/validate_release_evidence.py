#!/usr/bin/env python3
"""Verify production release evidence, its artifacts, scope, and live build inputs."""

from __future__ import annotations

import argparse
import hashlib
import itertools
import json
import math
import os
import re
import stat
import subprocess
import sys
import tempfile
import wave
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path, PurePosixPath
from typing import Any
from urllib.parse import urlsplit

SCRIPT_DIRECTORY = Path(__file__).resolve().parent
if str(SCRIPT_DIRECTORY) not in sys.path:
    sys.path.insert(0, str(SCRIPT_DIRECTORY))
from score_predictions import _release_audio, load_predictions, score_cases, summarize_rows  # noqa: E402
from validate_corpus import load_and_validate  # noqa: E402
from strict_json import loads as strict_json_loads  # noqa: E402


SHA256_RE = re.compile(r"^[a-f0-9]{64}$")
COMMIT_RE = re.compile(r"^[a-f0-9]{40}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+$")
BUILD_RE = re.compile(r"^[1-9][0-9]*$")
DIGEST_IMAGE_RE = re.compile(r"^[^\s]+@sha256:[a-f0-9]{64}$")
PLACEHOLDER_RE = re.compile(r"(?:replace|example|placeholder|todo|tbd|\.invalid)", re.IGNORECASE)
SIGNOFFS = {"quality", "security", "privacy", "operations"}
ROOT_KEYS = {"schema_version", "criteria_sha256", "release", "signoffs", "global_evidence", "matrix"}
RELEASE_KEYS = {
    "app_commit",
    "app_version",
    "build_number",
    "release_build_id",
    "xcode_version",
    "backend_base_image",
    "backend_image",
    "backend_build_metadata_sha256",
    "terraform_plan_sha256",
    "testflight_terraform_plan_sha256",
    "terraform_backend_config_sha256",
    "testflight_terraform_backend_config_sha256",
    "terraform_variables_sha256",
    "testflight_terraform_variables_sha256",
    "terraform_plan_provenance_sha256",
    "testflight_terraform_plan_provenance_sha256",
    "ios_resolved_config_sha256",
    "testflight_resolved_config_sha256",
    "device_registry_sha256",
    "generated_at",
    "configuration",
    "local_llm_experiment",
}
EVIDENCE_KEYS = {"status", "artifact_uri", "sha256", "reviewed_by", "reviewed_at"}
MATRIX_KEYS = {"direction", "route", "device_tier", "environment", "evidence"}
REPORT_KEYS = {
    "schema_version",
    "category",
    "status",
    "scope",
    "bindings",
    "metrics",
    "checks",
    "attachments",
    "generated_at",
    "tool",
}
CELL_SCOPE_KEYS = {"kind", "direction", "route", "device_tier", "environment"}
GLOBAL_SCOPE_KEYS = {"kind"}
BINDING_KEYS = {"release_identity_sha256", "criteria_sha256", "device_registry_sha256", "corpus", "run_identity"}
ARTIFACT_REF_KEYS = {"artifact_uri", "sha256"}
RESOLVED_CONFIG_KEYS = {
    "schema_version",
    "configuration",
    "APP_BUNDLE_IDENTIFIER",
    "DEVELOPMENT_TEAM",
    "APP_ATTEST_ENVIRONMENT",
    "APP_RUNTIME_ENVIRONMENT",
    "API_BASE_URL",
    "STOREKIT_MONTHLY_PRODUCT_ID",
    "STOREKIT_ANNUAL_PRODUCT_ID",
    "PRIVACY_POLICY_URL",
    "TERMS_URL",
    "SUPPORT_URL",
    "MARKETING_VERSION",
    "CURRENT_PROJECT_VERSION",
    "RELEASE_BUILD_ID",
    "LOCAL_LLM_EXPERIMENT",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
    "OTHER_SWIFT_FLAGS",
    "backend_contract",
}
BACKEND_CONTRACT_KEYS = {
    "APPLE_BUNDLE_ID",
    "APPLE_TEAM_ID",
    "APP_ATTEST_ENVIRONMENT",
    "ALLOWED_PRODUCT_IDS",
    "ALLOWED_APP_BUNDLE_VERSIONS",
    "API_DOMAIN",
}
DEVICE_KEYS = {"marketing_name", "model_identifier", "soc", "memory_gib", "os_version", "os_build"}
RUN_IDENTITY_KEYS = {
    "schema_version", "run_id", "release_identity_sha256", "direction", "route",
    "device_tier", "deployment_environment", "app_commit", "app_version",
    "build_number", "app_bundle_id", "api_domain", "device_model_identifier",
    "device_os_version", "device_os_build", "engine_build", "generated_at",
}
MAX_JSON_REPORT_BYTES = 8 * 1024 * 1024
MAX_EVIDENCE_AGE = timedelta(days=45)
PLAN_PROVENANCE_KEYS = {
    "schema_version", "stack", "app_commit", "terraform_version",
    "configuration_sha256", "backend_config_sha256", "variables_sha256",
    "plan_sha256", "project_id", "environment", "generated_at",
}
BACKEND_BUILD_BINDING_KEYS = {
    "schema_version", "source_commit", "base_image", "application_image_digest",
    "oci_index_digest", "runnable_manifest_digest", "platform", "backend_context_sha256",
}
FIXED_RUNTIME_LIMITS = {
    "CHALLENGE_POOL_SIZE": "8",
    "CHALLENGE_POOL_REQUESTS_PER_MINUTE": "4",
    "CHALLENGE_TTL_MS": "120000",
    "ENTITLEMENT_RATE_PER_DAY": "500",
    "ENTITLEMENT_RATE_PER_MINUTE": "60",
    "INACTIVE_DEVICE_AFTER_MS": "2592000000",
    "INSTALLATION_RATE_PER_MINUTE": "30",
    "MAXIMUM_SUBSCRIPTION_DEVICES": "3",
    "MAX_AUDIO_BYTES": "960044",
    "MAX_TEXT_BYTES": "8192",
    "REQUEST_DEADLINE_MS": "18000",
    "SESSION_ATTEMPTS_PER_MINUTE": "6",
    "SESSION_TTL_MS": "900000",
    "SPEECH_TIMEOUT_MS": "10000",
    "STOREKIT_SESSION_CONCURRENCY": "2",
    "STOREKIT_SESSION_MAXIMUM_OUTSTANDING": "6",
    "STOREKIT_NOTIFICATION_CONCURRENCY": "1",
    "STOREKIT_NOTIFICATION_MAXIMUM_OUTSTANDING": "2",
    "TRANSLATION_TIMEOUT_MS": "5000",
}
REVIEWED_SECRET_IDS = {
    "APPLE_APP_ATTEST_ROOT_CA_PEM": "apple-app-attest-root-ca-pem",
    "APPLE_IAP_SIGNING_KEY_P8": "apple-iap-signing-key-p8",
    "APPLE_STOREKIT_ROOT_CA_PEMS": "apple-storekit-root-ca-pems",
}
EDGE_ALLOWED_PATHS = (
    "/livez",
    "/readyz",
    "/v2/availability",
    "/v2/app-attest/challenge",
    "/v2/app-attest/register",
    "/v2/session",
    "/v2/session/challenges",
    "/v2/translate-turn",
    "/v2/translate-text",
    "/v2/devices/current",
    "/v2/devices/replace-oldest",
    "/v2/storekit/notifications",
)

# Exact reviewed service-stack inventory. Terraform `for_each` instances share
# type/name in planned JSON, so the value is the required instance count.
SERVICE_RESOURCE_COUNTS = {
    ("data", "google_project", "current"): 1,
    ("data", "google_service_account", "runtime"): 1,
    ("data", "google_secret_manager_secret", "runtime"): 3,
    ("managed", "google_cloud_run_v2_service", "api"): 1,
    ("managed", "google_cloud_run_v2_service_iam_member", "public_edge"): 1,
    ("managed", "google_compute_region_network_endpoint_group", "api"): 1,
    ("managed", "google_compute_security_policy", "api"): 1,
    ("managed", "google_compute_backend_service", "api"): 1,
    ("managed", "google_compute_url_map", "api"): 1,
    ("managed", "google_compute_managed_ssl_certificate", "api"): 1,
    ("managed", "google_compute_ssl_policy", "api"): 1,
    ("managed", "google_compute_target_https_proxy", "api"): 1,
    ("managed", "google_compute_global_address", "api"): 1,
    ("managed", "google_compute_global_forwarding_rule", "https"): 1,
    ("managed", "google_compute_url_map", "redirect"): 1,
    ("managed", "google_compute_target_http_proxy", "redirect"): 1,
    ("managed", "google_compute_global_forwarding_rule", "http"): 1,
    ("managed", "google_logging_project_bucket_config", "default"): 1,
    ("managed", "google_logging_metric", "edge_query_rejections"): 1,
    ("managed", "google_logging_metric", "security_rejections"): 1,
    ("managed", "google_logging_metric", "unexpected_secret_access"): 1,
    ("managed", "google_logging_metric", "iam_changes"): 1,
    ("managed", "google_logging_project_exclusion", "query_strings"): 1,
    ("managed", "google_monitoring_alert_policy", "security_events"): 4,
    ("managed", "google_monitoring_uptime_check_config", "ready"): 1,
    ("managed", "google_monitoring_alert_policy", "uptime"): 1,
    ("managed", "google_monitoring_alert_policy", "server_errors"): 1,
    ("managed", "google_monitoring_alert_policy", "latency"): 1,
    ("managed", "google_monitoring_alert_policy", "memory"): 1,
    ("managed", "google_monitoring_alert_policy", "instance_saturation"): 1,
    ("managed", "google_billing_budget", "project"): 1,
}


def _exact_keys(value: Any, expected: set[str], path: str, errors: list[str]) -> bool:
    if not isinstance(value, dict):
        errors.append(f"{path}: must be an object")
        return False
    missing = sorted(expected - set(value))
    unknown = sorted(set(value) - expected)
    if missing:
        errors.append(f"{path}: missing fields: {', '.join(missing)}")
    if unknown:
        errors.append(f"{path}: unknown fields: {', '.join(unknown)}")
    return not missing and not unknown


def _timestamp(value: Any, path: str, errors: list[str]) -> datetime | None:
    if not isinstance(value, str):
        errors.append(f"{path}: must be an ISO-8601 timestamp with a timezone")
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        errors.append(f"{path}: must be an ISO-8601 timestamp with a timezone")
        return None
    if parsed.tzinfo is None:
        errors.append(f"{path}: must include a timezone")
        return None
    parsed = parsed.astimezone(timezone.utc)
    if parsed > datetime.now(timezone.utc) + timedelta(minutes=5):
        errors.append(f"{path}: cannot be more than five minutes in the future")
    if parsed < datetime.now(timezone.utc) - MAX_EVIDENCE_AGE:
        errors.append(f"{path}: is older than the 45-day release-evidence freshness window")
    return parsed


def _non_placeholder_string(value: Any, path: str, errors: list[str]) -> bool:
    if not isinstance(value, str) or not value.strip():
        errors.append(f"{path}: must be a non-empty string")
        return False
    if PLACEHOLDER_RE.search(value):
        errors.append(f"{path}: contains a placeholder marker")
        return False
    return True


def _number(value: Any, path: str, errors: list[str]) -> float | None:
    if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
        errors.append(f"{path}: must be a finite number")
        return None
    return float(value)


def _integer(value: Any, path: str, errors: list[str]) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        errors.append(f"{path}: must be an integer")
        return None
    return value


def _bounded(value: Any, minimum: float, maximum: float, path: str, errors: list[str]) -> None:
    actual = _number(value, path, errors)
    if actual is not None and not minimum <= actual <= maximum:
        errors.append(f"{path}: {actual} must be from {minimum} through {maximum}")


def _count(value: Any, path: str, errors: list[str]) -> None:
    actual = _integer(value, path, errors)
    if actual is not None and actual < 0:
        errors.append(f"{path}: must be nonnegative")


def _nonnegative(value: Any, path: str, errors: list[str]) -> None:
    actual = _number(value, path, errors)
    if actual is not None and actual < 0:
        errors.append(f"{path}: must be nonnegative")


def _at_least(value: Any, threshold: float, path: str, errors: list[str]) -> None:
    actual = _number(value, path, errors)
    if actual is not None and actual < threshold:
        errors.append(f"{path}: {actual} is below required minimum {threshold}")


def _at_most(value: Any, threshold: float, path: str, errors: list[str]) -> None:
    actual = _number(value, path, errors)
    if actual is not None and actual > threshold:
        errors.append(f"{path}: {actual} exceeds allowed maximum {threshold}")


def _canonical_digest(value: Any) -> str:
    encoded = json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return hashlib.sha256(encoded).hexdigest()


def _input_tree_digest(repository_root: Path, relative_paths: list[Path]) -> str:
    hasher = hashlib.sha256()
    for path in sorted(relative_paths, key=lambda item: item.as_posix()):
        relative = path.relative_to(repository_root).as_posix().encode("utf-8")
        hasher.update(relative + b"\0" + path.read_bytes() + b"\0")
    return hasher.hexdigest()


def _backend_context_digest(repository_root: Path) -> str:
    backend = repository_root / "backend"
    fixed = [backend / name for name in (".dockerignore", "Dockerfile", "tsconfig.json")]
    packages = sorted(backend.glob("package*.json"))
    sources = [path for path in (backend / "src").rglob("*") if path.is_file() and not path.is_symlink()]
    patch_script = backend / "scripts" / "apply-storekit-ocsp-patch.mjs"
    paths = fixed + packages + sources + [patch_script]
    missing = [path for path in fixed if not path.is_file() or path.is_symlink()]
    if not (backend / "package.json").is_file() or not (backend / "package-lock.json").is_file():
        missing.append(backend / "package.json")
    symlinked_sources = [path for path in (backend / "src").rglob("*") if path.is_symlink()]
    missing.extend(path for path in packages if path.is_symlink())
    missing.extend(symlinked_sources)
    if not patch_script.is_file() or patch_script.is_symlink():
        missing.append(patch_script)
    expected_dockerignore = {
        "**", "!Dockerfile", "!package.json", "!package-lock.json", "!tsconfig.json",
        "!src/", "!src/**", "!scripts/", "!scripts/apply-storekit-ocsp-patch.mjs",
    }
    dockerignore_lines = {
        line.strip() for line in (backend / ".dockerignore").read_text(encoding="utf-8").splitlines()
        if line.strip() and not line.lstrip().startswith("#")
    }
    if dockerignore_lines != expected_dockerignore:
        raise OSError("backend/.dockerignore must be the reviewed deny-by-default allowlist")
    if missing:
        raise OSError(f"backend build input is missing or symlinked: {missing[0]}")
    return _input_tree_digest(repository_root, paths)


def _backend_dockerfile_uses_only_approved_argument(repository_root: Path) -> bool:
    dockerfile = repository_root / "backend" / "Dockerfile"
    lines = dockerfile.read_text(encoding="utf-8").splitlines()
    bases: list[str] = []
    for raw in lines:
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        match = re.match(r"FROM(?:\s+--platform=\S+)?\s+(\S+)", line, re.IGNORECASE)
        if match:
            bases.append(match.group(1))
    return bool(bases) and all(base == "${NODE_IMAGE}" for base in bases)


class ArtifactStore:
    def __init__(self, root: Path, errors: list[str]) -> None:
        self.root = Path(os.path.abspath(root))
        try:
            self._root_fd = os.open(
                root, os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
            )
        except OSError as exc:
            errors.append(f"artifact root: unable to open safely: {exc}")
            self._root_fd = -1
        self._snapshots = tempfile.TemporaryDirectory(prefix="locallingo-release-snapshot-")
        self._snapshot_root = Path(self._snapshots.name)
        self._files: dict[str, tuple[Path, str, int]] = {}

    def close(self) -> None:
        snapshots = getattr(self, "_snapshots", None)
        if snapshots is not None:
            snapshots.cleanup()
            self._snapshots = None
        root_fd = getattr(self, "_root_fd", -1)
        if root_fd >= 0:
            os.close(root_fd)
            self._root_fd = -1

    def __enter__(self) -> "ArtifactStore":
        return self

    def __exit__(self, *_: object) -> None:
        self.close()

    def __del__(self) -> None:
        self.close()

    def _candidate(self, uri: Any, path: str, errors: list[str]) -> PurePosixPath | None:
        if not isinstance(uri, str) or not uri:
            errors.append(f"{path}: must be a non-empty relative artifact path")
            return None
        if "\\" in uri or urlsplit(uri).scheme:
            errors.append(f"{path}: URI schemes and backslashes are forbidden; use a relative path under artifact root")
            return None
        relative = PurePosixPath(uri)
        if relative.is_absolute() or str(relative) != uri or any(part in {"", ".", ".."} for part in relative.parts):
            errors.append(f"{path}: must be a normalized relative path without traversal")
            return None
        return relative

    def _open_relative(self, relative: PurePosixPath) -> int:
        if self._root_fd < 0:
            raise OSError("artifact root is unavailable")
        current = os.dup(self._root_fd)
        try:
            for component in relative.parts[:-1]:
                following = os.open(
                    component,
                    os.O_RDONLY | os.O_DIRECTORY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                    dir_fd=current,
                )
                os.close(current)
                current = following
            return os.open(
                relative.parts[-1],
                os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0),
                dir_fd=current,
            )
        finally:
            os.close(current)

    def _snapshot(self, uri: Any, path: str, errors: list[str]) -> tuple[Path, str, int] | None:
        relative = self._candidate(uri, path, errors)
        if relative is None:
            return None
        key = str(relative)
        if key in self._files:
            return self._files[key]
        flags = os.O_RDONLY | getattr(os, "O_CLOEXEC", 0) | getattr(os, "O_NOFOLLOW", 0)
        try:
            descriptor = self._open_relative(relative)
        except FileNotFoundError as exc:
            errors.append(f"{path}: artifact does not exist: {exc}")
            return None
        except OSError as exc:
            errors.append(f"{path}: unable to open artifact safely: {exc}")
            return None
        destination = self._snapshot_root / f"{len(self._files):08d}.artifact"
        hasher = hashlib.sha256()
        size = 0
        try:
            before = os.fstat(descriptor)
            if not stat.S_ISREG(before.st_mode):
                errors.append(f"{path}: artifact must be a regular file")
                return None
            if before.st_nlink != 1:
                errors.append(f"{path}: artifact hardlinks are forbidden")
                return None
            with os.fdopen(os.dup(descriptor), "rb", closefd=True) as source, destination.open("xb") as target:
                for chunk in iter(lambda: source.read(1024 * 1024), b""):
                    hasher.update(chunk)
                    target.write(chunk)
                    size += len(chunk)
            after = os.fstat(descriptor)
            identity_before = (before.st_dev, before.st_ino, before.st_mode, before.st_nlink, before.st_size, before.st_mtime_ns, before.st_ctime_ns)
            identity_after = (after.st_dev, after.st_ino, after.st_mode, after.st_nlink, after.st_size, after.st_mtime_ns, after.st_ctime_ns)
            if identity_after != identity_before or size != before.st_size:
                destination.unlink(missing_ok=True)
                errors.append(f"{path}: artifact changed while it was being snapshotted")
                return None
        except OSError as exc:
            destination.unlink(missing_ok=True)
            errors.append(f"{path}: unable to snapshot artifact: {exc}")
            return None
        finally:
            os.close(descriptor)
        value = (destination, hasher.hexdigest(), size)
        self._files[key] = value
        return value

    def resolve(self, uri: Any, path: str, errors: list[str]) -> Path | None:
        snapshot = self._snapshot(uri, path, errors)
        return snapshot[0] if snapshot else None

    def digest(self, uri: Any, path: str, errors: list[str]) -> str | None:
        snapshot = self._snapshot(uri, path, errors)
        return snapshot[1] if snapshot else None

    def verify_ref(self, value: Any, path: str, errors: list[str], *, load_json: bool = False) -> Any | None:
        if not _exact_keys(value, ARTIFACT_REF_KEYS, path, errors):
            return None
        expected = value["sha256"]
        if not isinstance(expected, str) or not SHA256_RE.fullmatch(expected):
            errors.append(f"{path}.sha256: must be a complete lowercase SHA-256 digest")
        actual = self.digest(value["artifact_uri"], f"{path}.artifact_uri", errors)
        if actual is None or actual != expected:
            if actual is not None:
                errors.append(f"{path}.sha256: digest mismatch; expected {expected}, calculated {actual}")
            return None
        if not load_json:
            return actual
        resolved = self.resolve(value["artifact_uri"], f"{path}.artifact_uri", errors)
        if resolved is None:
            return None
        try:
            if resolved.stat().st_size > MAX_JSON_REPORT_BYTES:
                errors.append(f"{path}: JSON report exceeds {MAX_JSON_REPORT_BYTES} bytes")
                return None
            return strict_json_loads(resolved.read_bytes())
        except (OSError, UnicodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
            errors.append(f"{path}: artifact is not valid UTF-8 JSON: {exc}")
            return None


def validate_device_registry(registry: Any, expected_tiers: set[str], errors: list[str]) -> None:
    if not _exact_keys(registry, {"schema_version", "generated_at", "tiers"}, "device_registry", errors):
        return
    if registry["schema_version"] != "1.0":
        errors.append("device_registry.schema_version: only 1.0 is supported")
    _timestamp(registry["generated_at"], "device_registry.generated_at", errors)
    tiers = registry["tiers"]
    if not _exact_keys(tiers, expected_tiers, "device_registry.tiers", errors):
        return
    identifiers: set[str] = set()
    release_devices = {
        "minimum": ("iPhone 15 Pro", "iPhone16,1"),
        "mid_tier": ("iPhone 16 Pro", "iPhone17,1"),
        "current": ("iPhone 17 Pro", "iPhone18,1"),
    }
    for tier in sorted(expected_tiers):
        device = tiers[tier]
        path = f"device_registry.tiers.{tier}"
        if not _exact_keys(device, DEVICE_KEYS, path, errors):
            continue
        for name in ("marketing_name", "model_identifier", "soc", "os_version", "os_build"):
            _non_placeholder_string(device[name], f"{path}.{name}", errors)
        if isinstance(device.get("model_identifier"), str) and not re.fullmatch(r"iPhone[0-9]+,[0-9]+", device["model_identifier"]):
            errors.append(f"{path}.model_identifier: must be a physical iPhone model identifier")
        if tier in release_devices and (
            device.get("marketing_name"), device.get("model_identifier")
        ) != release_devices[tier]:
            errors.append(f"{path}: must match the locked iPhone 15 Pro / 16 Pro / 17 Pro release tier")
        memory = _number(device.get("memory_gib"), f"{path}.memory_gib", errors)
        if memory is not None and memory <= 0:
            errors.append(f"{path}.memory_gib: must be positive")
        identifier = device.get("model_identifier")
        if isinstance(identifier, str):
            if identifier in identifiers:
                errors.append(f"{path}.model_identifier: each tier must use a distinct physical device")
            identifiers.add(identifier)


def validate_resolved_config(config: Any, errors: list[str], *, path: str = "ios_resolved_config", expected_configuration: str = "Release") -> None:
    if not _exact_keys(config, RESOLVED_CONFIG_KEYS, path, errors):
        return
    if config["schema_version"] != "1.0" or config["configuration"] != expected_configuration:
        errors.append(f"{path}: schema_version must be 1.0 and configuration must be {expected_configuration}")
    for name in RESOLVED_CONFIG_KEYS - {"schema_version", "backend_contract"}:
        if name in {"LOCAL_LLM_EXPERIMENT", "OTHER_SWIFT_FLAGS"}:
            continue
        _non_placeholder_string(config[name], f"{path}.{name}", errors)
    if config["LOCAL_LLM_EXPERIMENT"] != "0":
        errors.append(f"{path}.LOCAL_LLM_EXPERIMENT: must be 0")
    if not isinstance(config.get("RELEASE_BUILD_ID"), str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._-]{15,127}", config["RELEASE_BUILD_ID"]
    ):
        errors.append(f"{path}.RELEASE_BUILD_ID: invalid immutable candidate identifier")
    expected_runtime = {"Staging": "staging", "TestFlight": "testflight", "Release": "production"}[expected_configuration]
    if config.get("APP_RUNTIME_ENVIRONMENT") != expected_runtime:
        errors.append(f"{path}.APP_RUNTIME_ENVIRONMENT: must equal {expected_runtime}")
    if "LOCAL_LLM_EXPERIMENT" in str(config["SWIFT_ACTIVE_COMPILATION_CONDITIONS"]).split():
        errors.append(f"{path}.SWIFT_ACTIVE_COMPILATION_CONDITIONS: experimental condition is forbidden")
    if re.search(r"(?:^|\s)-D(?:\s+)?LOCAL_LLM_EXPERIMENT(?:\s|$)", str(config["OTHER_SWIFT_FLAGS"])):
        errors.append(f"{path}.OTHER_SWIFT_FLAGS: experimental condition is forbidden")
    contract = config["backend_contract"]
    if _exact_keys(contract, BACKEND_CONTRACT_KEYS, f"{path}.backend_contract", errors):
        for name in BACKEND_CONTRACT_KEYS:
            _non_placeholder_string(contract[name], f"{path}.backend_contract.{name}", errors)
        expected_contract = {
            "APPLE_BUNDLE_ID": config["APP_BUNDLE_IDENTIFIER"],
            "APPLE_TEAM_ID": config["DEVELOPMENT_TEAM"],
            "APP_ATTEST_ENVIRONMENT": config["APP_ATTEST_ENVIRONMENT"],
        }
        for name, expected in expected_contract.items():
            if contract.get(name) != expected:
                errors.append(f"{path}.backend_contract.{name}: does not match the resolved app configuration")
        expected_products = {
            config["STOREKIT_MONTHLY_PRODUCT_ID"],
            config["STOREKIT_ANNUAL_PRODUCT_ID"],
        }
        actual_products = {item.strip() for item in str(contract.get("ALLOWED_PRODUCT_IDS", "")).split(",") if item.strip()}
        if actual_products != expected_products:
            errors.append(f"{path}.backend_contract.ALLOWED_PRODUCT_IDS: must exactly contain the resolved StoreKit products")
        allowed_builds = {item.strip() for item in str(contract.get("ALLOWED_APP_BUNDLE_VERSIONS", "")).split(",") if item.strip()}
        if config["CURRENT_PROJECT_VERSION"] not in allowed_builds:
            errors.append(f"{path}.backend_contract.ALLOWED_APP_BUNDLE_VERSIONS: must include CURRENT_PROJECT_VERSION")
        try:
            api_domain = urlsplit(str(config["API_BASE_URL"])).hostname
        except ValueError:
            api_domain = None
        if contract.get("API_DOMAIN") != api_domain:
            errors.append(f"{path}.backend_contract.API_DOMAIN: does not match the resolved API_BASE_URL host")


def validate_environment_isolation(release: dict[str, Any], testflight: dict[str, Any], errors: list[str]) -> None:
    for name in ("DEVELOPMENT_TEAM", "MARKETING_VERSION", "CURRENT_PROJECT_VERSION", "RELEASE_BUILD_ID"):
        if release.get(name) != testflight.get(name):
            errors.append(f"cross-environment config: Release and TestFlight {name} must match")
    for name in (
        "APP_BUNDLE_IDENTIFIER",
        "API_BASE_URL",
        "STOREKIT_MONTHLY_PRODUCT_ID",
        "STOREKIT_ANNUAL_PRODUCT_ID",
    ):
        if release.get(name) == testflight.get(name):
            errors.append(f"cross-environment config: Release and TestFlight {name} must be distinct")


def _metrics_automated(metrics: Any, criteria: dict[str, Any], path: str, errors: list[str]) -> None:
    keys = {
        "case_count", "mean_chrf2", "critical_check_pass_rate", "missing_predictions", "extra_predictions",
        "speaker_count", "audio_minutes", "domains", "strata",
    }
    if not _exact_keys(metrics, keys, path, errors):
        return
    for name in ("case_count", "missing_predictions", "extra_predictions", "speaker_count"):
        _count(metrics[name], f"{path}.{name}", errors)
    for name in ("mean_chrf2", "critical_check_pass_rate"):
        _bounded(metrics[name], 0, 1, f"{path}.{name}", errors)
    _nonnegative(metrics["audio_minutes"], f"{path}.audio_minutes", errors)
    automated = criteria["automated_text"]
    _at_least(metrics["case_count"], automated["min_case_count"], f"{path}.case_count", errors)
    _at_least(metrics["mean_chrf2"], automated["min_mean_chrf2"], f"{path}.mean_chrf2", errors)
    _at_least(metrics["critical_check_pass_rate"], automated["min_critical_check_pass_rate"], f"{path}.critical_check_pass_rate", errors)
    _at_most(metrics["missing_predictions"], automated["max_missing_predictions"], f"{path}.missing_predictions", errors)
    _at_most(metrics["extra_predictions"], automated["max_extra_predictions"], f"{path}.extra_predictions", errors)
    coverage = criteria["corpus_coverage"]
    _at_least(metrics["speaker_count"], coverage["min_speakers"], f"{path}.speaker_count", errors)
    _at_least(metrics["audio_minutes"], coverage["min_audio_minutes"], f"{path}.audio_minutes", errors)
    for name, required in (("domains", coverage["required_domains"]), ("strata", coverage["required_strata"])):
        values = metrics[name]
        if not isinstance(values, list) or any(not isinstance(item, str) for item in values):
            errors.append(f"{path}.{name}: must be a string array")
        else:
            missing = sorted(set(required) - set(values))
            if missing:
                errors.append(f"{path}.{name}: missing required coverage: {', '.join(missing)}")


def _metrics_human(metrics: Any, criteria: dict[str, Any], path: str, errors: list[str]) -> None:
    keys = {"bilingual_raters_per_critical_case", "median_adequacy_1_to_5", "minimum_required_stratum_adequacy_1_to_5", "known_severity_1_meaning_inversions", "emergency_allergy_preservation_or_flag_rate"}
    if not _exact_keys(metrics, keys, path, errors):
        return
    _count(metrics["bilingual_raters_per_critical_case"], f"{path}.bilingual_raters_per_critical_case", errors)
    _bounded(metrics["median_adequacy_1_to_5"], 1, 5, f"{path}.median_adequacy_1_to_5", errors)
    _bounded(metrics["minimum_required_stratum_adequacy_1_to_5"], 1, 5, f"{path}.minimum_required_stratum_adequacy_1_to_5", errors)
    _count(metrics["known_severity_1_meaning_inversions"], f"{path}.known_severity_1_meaning_inversions", errors)
    _bounded(metrics["emergency_allergy_preservation_or_flag_rate"], 0, 1, f"{path}.emergency_allergy_preservation_or_flag_rate", errors)
    limits = criteria["human_quality"]
    _at_least(metrics["bilingual_raters_per_critical_case"], limits["min_bilingual_raters_per_critical_case"], f"{path}.bilingual_raters_per_critical_case", errors)
    _at_least(metrics["median_adequacy_1_to_5"], limits["min_median_adequacy_1_to_5"], f"{path}.median_adequacy_1_to_5", errors)
    _at_least(metrics["minimum_required_stratum_adequacy_1_to_5"], limits["min_required_stratum_adequacy_1_to_5"], f"{path}.minimum_required_stratum_adequacy_1_to_5", errors)
    _at_most(metrics["known_severity_1_meaning_inversions"], limits["max_known_severity_1_meaning_inversions"], f"{path}.known_severity_1_meaning_inversions", errors)
    _at_least(metrics["emergency_allergy_preservation_or_flag_rate"], limits["required_emergency_allergy_preservation_or_flag_rate"], f"{path}.emergency_allergy_preservation_or_flag_rate", errors)


def _metrics_speech(metrics: Any, criteria: dict[str, Any], direction: str, path: str, errors: list[str]) -> None:
    keys = {"asr_wer", "language_approved_cer", "critical_entity_deletion_rate", "silence_noise_hallucination_rate", "wrong_language_rate", "tts_bilingual_intelligibility_reviewed"}
    if not _exact_keys(metrics, keys, path, errors):
        return
    limits = criteria["speech_quality"]
    source = direction.split("->", 1)[0]
    selected = "language_approved_cer" if source == "ja" else "asr_wer"
    other = "asr_wer" if selected == "language_approved_cer" else "language_approved_cer"
    threshold = limits["max_language_approved_cer"] if selected == "language_approved_cer" else limits["max_asr_wer"]
    _bounded(metrics[selected], 0, 1, f"{path}.{selected}", errors)
    _at_most(metrics[selected], threshold, f"{path}.{selected}", errors)
    if metrics[other] is not None:
        errors.append(f"{path}.{other}: must be null when {selected} is the approved source-language metric")
    _at_most(metrics["critical_entity_deletion_rate"], limits["max_critical_entity_deletion_rate"], f"{path}.critical_entity_deletion_rate", errors)
    _at_most(metrics["silence_noise_hallucination_rate"], limits["max_silence_noise_hallucination_rate"], f"{path}.silence_noise_hallucination_rate", errors)
    _at_most(metrics["wrong_language_rate"], limits["max_wrong_language_rate"], f"{path}.wrong_language_rate", errors)
    for name in ("critical_entity_deletion_rate", "silence_noise_hallucination_rate", "wrong_language_rate"):
        _bounded(metrics[name], 0, 1, f"{path}.{name}", errors)
    if metrics["tts_bilingual_intelligibility_reviewed"] is not True:
        errors.append(f"{path}.tts_bilingual_intelligibility_reviewed: must be true")


def _metrics_runtime(metrics: Any, criteria: dict[str, Any], route: str, path: str, errors: list[str]) -> None:
    keys = {"endpoint_to_visible_p50_ms", "endpoint_to_visible_p95_ms", "conversation_content_egress_bytes", "provider_error_rate", "endpoint_allowlist_documented", "pre_turn_route_indicator_match_rate", "local_only_lock_violation_count", "fallback_race_failure_count"}
    if not _exact_keys(metrics, keys, path, errors):
        return
    _nonnegative(metrics["endpoint_to_visible_p50_ms"], f"{path}.endpoint_to_visible_p50_ms", errors)
    _nonnegative(metrics["endpoint_to_visible_p95_ms"], f"{path}.endpoint_to_visible_p95_ms", errors)
    p50 = _number(metrics["endpoint_to_visible_p50_ms"], f"{path}.endpoint_to_visible_p50_ms", [])
    p95 = _number(metrics["endpoint_to_visible_p95_ms"], f"{path}.endpoint_to_visible_p95_ms", [])
    if p50 is not None and p95 is not None and p50 > p95:
        errors.append(f"{path}: p50 latency cannot exceed p95 latency")
    resolved = "local_only" if route in {"local_only", "auto_local"} else "online_quality"
    limits = criteria["runtime_by_mode"][resolved]
    _at_most(metrics["endpoint_to_visible_p50_ms"], limits["max_warm_endpoint_to_visible_translation_p50_ms"], f"{path}.endpoint_to_visible_p50_ms", errors)
    _at_most(metrics["endpoint_to_visible_p95_ms"], limits["max_warm_endpoint_to_visible_translation_p95_ms"], f"{path}.endpoint_to_visible_p95_ms", errors)
    if resolved == "local_only":
        _nonnegative(metrics["conversation_content_egress_bytes"], f"{path}.conversation_content_egress_bytes", errors)
        _at_most(metrics["conversation_content_egress_bytes"], limits["conversation_content_egress_bytes"], f"{path}.conversation_content_egress_bytes", errors)
        if metrics["provider_error_rate"] is not None or metrics["endpoint_allowlist_documented"] is not None:
            errors.append(f"{path}: local route provider metrics must be null")
    else:
        _bounded(metrics["provider_error_rate"], 0, 1, f"{path}.provider_error_rate", errors)
        _at_most(metrics["provider_error_rate"], limits["max_provider_error_rate"], f"{path}.provider_error_rate", errors)
        if metrics["endpoint_allowlist_documented"] is not True:
            errors.append(f"{path}.endpoint_allowlist_documented: must be true")
        if metrics["conversation_content_egress_bytes"] is not None:
            errors.append(f"{path}.conversation_content_egress_bytes: online route value must be null")
    auto_names = ("pre_turn_route_indicator_match_rate", "local_only_lock_violation_count", "fallback_race_failure_count")
    if route.startswith("auto_"):
        auto = criteria["runtime_by_mode"]["auto"]
        _at_least(metrics[auto_names[0]], auto["pre_turn_route_indicator_match_rate"], f"{path}.{auto_names[0]}", errors)
        _at_most(metrics[auto_names[1]], auto["local_only_lock_violation_count"], f"{path}.{auto_names[1]}", errors)
        _at_most(metrics[auto_names[2]], auto["fallback_race_failure_count"], f"{path}.{auto_names[2]}", errors)
        _bounded(metrics[auto_names[0]], 0, 1, f"{path}.{auto_names[0]}", errors)
        _count(metrics[auto_names[1]], f"{path}.{auto_names[1]}", errors)
        _count(metrics[auto_names[2]], f"{path}.{auto_names[2]}", errors)
    elif any(metrics[name] is not None for name in auto_names):
        errors.append(f"{path}: non-Auto route Auto metrics must be null")


def _metrics_privacy(metrics: Any, criteria: dict[str, Any], path: str, errors: list[str]) -> None:
    limits = criteria["privacy_security"]
    if not _exact_keys(metrics, set(limits), path, errors):
        return
    for name, threshold in limits.items():
        _count(metrics[name], f"{path}.{name}", errors)
        _at_most(metrics[name], threshold, f"{path}.{name}", errors)


def _metrics_stability(metrics: Any, criteria: dict[str, Any], path: str, errors: list[str]) -> None:
    keys = {"crashes_or_watchdog_terminations_in_suite", "old_turn_playback_failures", "peak_memory_device_budget_passed", "thermal_energy_storage_budgets_passed"}
    if not _exact_keys(metrics, keys, path, errors):
        return
    limits = criteria["release_stability"]
    _at_most(metrics["crashes_or_watchdog_terminations_in_suite"], limits["crashes_or_watchdog_terminations_in_suite"], f"{path}.crashes_or_watchdog_terminations_in_suite", errors)
    _at_most(metrics["old_turn_playback_failures"], limits["old_turn_playback_failures"], f"{path}.old_turn_playback_failures", errors)
    _count(metrics["crashes_or_watchdog_terminations_in_suite"], f"{path}.crashes_or_watchdog_terminations_in_suite", errors)
    _count(metrics["old_turn_playback_failures"], f"{path}.old_turn_playback_failures", errors)
    for name in ("peak_memory_device_budget_passed", "thermal_energy_storage_budgets_passed"):
        if metrics[name] is not True:
            errors.append(f"{path}.{name}: must be true")


def validate_run_identity(
    run: Any,
    *,
    scope: tuple[str, str, str, str],
    release_identity_sha256: str,
    release: dict[str, Any],
    config: dict[str, Any],
    device_registry: dict[str, Any],
    path: str,
    errors: list[str],
) -> dict[str, Any] | None:
    if not _exact_keys(run, RUN_IDENTITY_KEYS, path, errors):
        return None
    direction, route, tier, environment = scope
    device = device_registry.get("tiers", {}).get(tier, {})
    expected = {
        "schema_version": "1.0",
        "release_identity_sha256": release_identity_sha256,
        "direction": direction,
        "route": route,
        "device_tier": tier,
        "deployment_environment": environment,
        "app_commit": release.get("app_commit"),
        "app_version": config.get("MARKETING_VERSION"),
        "build_number": config.get("CURRENT_PROJECT_VERSION"),
        "app_bundle_id": config.get("APP_BUNDLE_IDENTIFIER"),
        "api_domain": config.get("backend_contract", {}).get("API_DOMAIN"),
        "device_model_identifier": device.get("model_identifier"),
        "device_os_version": device.get("os_version"),
        "device_os_build": device.get("os_build"),
    }
    for name, value in expected.items():
        if run.get(name) != value:
            errors.append(f"{path}.{name}: does not match the bound release/config/device scope")
    if not isinstance(run.get("run_id"), str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{7,127}", run["run_id"]):
        errors.append(f"{path}.run_id: has an invalid format")
    _non_placeholder_string(run.get("engine_build"), f"{path}.engine_build", errors)
    _timestamp(run.get("generated_at"), f"{path}.generated_at", errors)
    return run


def validate_automated_source_artifacts(
    report: dict[str, Any],
    *,
    scope: tuple[str, str, str, str],
    run: dict[str, Any] | None,
    corpus_ref: dict[str, Any],
    prediction_ref: dict[str, Any] | None,
    store: ArtifactStore,
    path: str,
    errors: list[str],
) -> None:
    if run is None or prediction_ref is None:
        return
    corpus_path = store.resolve(corpus_ref.get("artifact_uri"), f"{path}.corpus", errors)
    prediction_path = store.resolve(prediction_ref.get("artifact_uri"), f"{path}.predictions", errors)
    if corpus_path is None or prediction_path is None:
        return
    cases, corpus_errors = load_and_validate([corpus_path])
    predictions, prediction_errors = load_predictions(prediction_path)
    errors.extend(f"{path}.corpus: {message}" for message in corpus_errors)
    errors.extend(f"{path}.predictions: {message}" for message in prediction_errors)
    if corpus_errors or prediction_errors:
        return
    direction, route, _tier, _environment = scope
    wrong_case_directions = sorted({
        f"{case['source_language']}->{case['target_language']}"
        for case in cases
        if f"{case['source_language']}->{case['target_language']}" != direction
    })
    if wrong_case_directions:
        errors.append(f"{path}.corpus: contains directions outside {direction}: {wrong_case_directions}")
    audio_uris: dict[str, str] = {}
    audio_digests: dict[str, str] = {}
    for case in cases:
        audio = case.get("audio")
        if not isinstance(audio, dict):
            continue
        case_id = str(case.get("id", "unknown"))
        uri = audio.get("path")
        digest = audio.get("sha256")
        if isinstance(uri, str):
            prior = audio_uris.setdefault(uri, case_id)
            if prior != case_id:
                errors.append(f"{path}.corpus: audio path {uri} is reused by cases {prior} and {case_id}")
        if isinstance(digest, str):
            prior = audio_digests.setdefault(digest, case_id)
            if prior != case_id:
                errors.append(f"{path}.corpus: audio bytes are reused by cases {prior} and {case_id}")
    for name, values in (
        ("processing mode", {row["processing_mode"] for row in predictions if row["processing_mode"] != route}),
        ("physical device", {row["device"] for row in predictions if row["device"] != run["device_model_identifier"]}),
        ("engine build", {row["model_build"] for row in predictions if row["model_build"] != run["engine_build"]}),
        ("run identity", {str(row.get("run_id")) for row in predictions if row.get("run_id") != run["run_id"]}),
    ):
        if values:
            errors.append(f"{path}.predictions: contains rows outside bound {name}: {sorted(values)}")
    audio_errors = _release_audio(cases, store.root)
    errors.extend(f"{path}.corpus: {message}" for message in audio_errors)
    if wrong_case_directions or audio_errors:
        return
    rows, missing, extra = score_cases(cases, predictions)
    summary = summarize_rows(rows)
    speakers = {case["audio"]["speaker_id"] for case in cases if isinstance(case.get("audio"), dict)}
    audio_minutes = sum(case["audio"]["duration_ms"] for case in cases if isinstance(case.get("audio"), dict)) / 60_000
    expected_metrics = {
        "case_count": summary["case_count"],
        "mean_chrf2": summary["mean_chrf2"],
        "critical_check_pass_rate": summary["critical_checks"]["pass_rate"],
        "missing_predictions": len(missing),
        "extra_predictions": len(extra),
        "speaker_count": len(speakers),
        "audio_minutes": round(audio_minutes, 6),
        "domains": sorted({case["domain"] for case in cases}),
        "strata": sorted({tag for case in cases for tag in case["tags"]}),
    }
    if report.get("metrics") != expected_metrics:
        errors.append(f"{path}.metrics: does not equal metrics independently recomputed from corpus/predictions")


def validate_category_report(
    report: Any,
    *,
    category: str,
    scope: tuple[str, str, str, str] | None,
    criteria_profile: dict[str, Any],
    global_checks: dict[str, list[str]],
    release_identity_sha256: str,
    criteria_sha256: str,
    device_registry_sha256: str,
    release: dict[str, Any],
    resolved_config: dict[str, Any],
    testflight_resolved_config: dict[str, Any],
    device_registry: dict[str, Any],
    store: ArtifactStore,
    scope_runs: dict[tuple[str, str, str, str], tuple[str, str]],
    run_scopes: dict[str, tuple[str, str, str, str]],
    run_ids: dict[str, tuple[tuple[str, str, str, str], str]],
    direction_corpora: dict[str, tuple[str, str]],
    used_attachments: dict[str, str],
    path: str,
    errors: list[str],
) -> datetime | None:
    if not _exact_keys(report, REPORT_KEYS, path, errors):
        return None
    if report["schema_version"] != "1.0" or report["category"] != category or report["status"] != "passed":
        errors.append(f"{path}: schema_version/category/status must be 1.0/{category}/passed")
    generated = _timestamp(report["generated_at"], f"{path}.generated_at", errors)
    if not isinstance(report["tool"], str) or not re.fullmatch(r"[a-z0-9][a-z0-9._-]*/[0-9]+(?:\.[0-9]+){1,2}", report["tool"]):
        errors.append(f"{path}.tool: must be a versioned lowercase tool identifier")
    if category == "automated_text" and report["tool"] != "locallingo-score-predictions/1.0":
        errors.append(f"{path}.tool: automated text evidence must come from locallingo-score-predictions/1.0")

    expected_scope = {"kind": "global"} if scope is None else {
        "kind": "cell", "direction": scope[0], "route": scope[1], "device_tier": scope[2], "environment": scope[3]
    }
    if _exact_keys(report["scope"], GLOBAL_SCOPE_KEYS if scope is None else CELL_SCOPE_KEYS, f"{path}.scope", errors):
        if report["scope"] != expected_scope:
            errors.append(f"{path}.scope: does not match the manifest evidence cell")

    bindings = report["bindings"]
    run: dict[str, Any] | None = None
    corpus: Any = None
    if _exact_keys(bindings, BINDING_KEYS, f"{path}.bindings", errors):
        expected = {
            "release_identity_sha256": release_identity_sha256,
            "criteria_sha256": criteria_sha256,
            "device_registry_sha256": device_registry_sha256,
        }
        for name, value in expected.items():
            if bindings[name] != value:
                errors.append(f"{path}.bindings.{name}: does not match the verified release input")
        if scope is None:
            if bindings["corpus"] is not None or bindings["run_identity"] is not None:
                errors.append(f"{path}.bindings: global evidence must use null corpus and run_identity")
        else:
            corpus = bindings["corpus"]
            store.verify_ref(corpus, f"{path}.bindings.corpus", errors)
            if isinstance(corpus, dict) and isinstance(corpus.get("artifact_uri"), str):
                bound_corpus = (corpus["artifact_uri"], corpus.get("sha256", ""))
                previous_corpus = direction_corpora.setdefault(scope[0], bound_corpus)
                if previous_corpus != bound_corpus:
                    errors.append(f"{path}.bindings.corpus: every route/device/environment for a direction must bind the same canonical corpus")
            run_ref = bindings["run_identity"]
            run_json = store.verify_ref(run_ref, f"{path}.bindings.run_identity", errors, load_json=True)
            if isinstance(run_ref, dict) and isinstance(run_ref.get("artifact_uri"), str):
                run_binding = (run_ref["artifact_uri"], run_ref.get("sha256", ""))
                previous_run = scope_runs.setdefault(scope, run_binding)
                if previous_run != run_binding:
                    errors.append(f"{path}.bindings.run_identity: every category in a cell must bind the same run")
                previous_scope = run_scopes.setdefault(run_ref["artifact_uri"], scope)
                if previous_scope != scope:
                    errors.append(f"{path}.bindings.run_identity: a run identity cannot be reused across matrix cells")
            selected_config = testflight_resolved_config if scope[3] == "testflight" else resolved_config
            run = validate_run_identity(
                run_json,
                scope=scope,
                release_identity_sha256=release_identity_sha256,
                release=release,
                config=selected_config,
                device_registry=device_registry,
                path=f"{path}.bindings.run_identity.report",
                errors=errors,
            )
            if isinstance(run, dict) and isinstance(run.get("run_id"), str):
                run_id = run["run_id"]
                prior = run_ids.setdefault(run_id, (scope, path))
                if prior[0] != scope:
                    errors.append(f"{path}.bindings.run_identity.report.run_id: {run_id} is already used by {prior[1]}; run IDs must be unique per matrix cell")

    attachments = report["attachments"]
    if not isinstance(attachments, list) or not attachments:
        errors.append(f"{path}.attachments: at least one hashed supporting artifact is required")
    else:
        seen: set[str] = set()
        for index, attachment in enumerate(attachments):
            attachment_path = f"{path}.attachments[{index}]"
            attachment_digest = store.verify_ref(attachment, attachment_path, errors)
            if isinstance(attachment, dict) and isinstance(attachment.get("artifact_uri"), str):
                if attachment["artifact_uri"] in seen:
                    errors.append(f"{attachment_path}.artifact_uri: duplicate attachment")
                seen.add(attachment["artifact_uri"])
                if isinstance(attachment_digest, str):
                    prior = used_attachments.setdefault(attachment_digest, attachment_path)
                    if prior != attachment_path:
                        errors.append(f"{attachment_path}.sha256: supporting attachment bytes must be unique per evidence report; already used by {prior}")

    if scope is None:
        if report["metrics"] != {}:
            errors.append(f"{path}.metrics: global evidence metrics must be an empty object")
        required = set(global_checks.get(category, []))
        if not required:
            errors.append(f"criteria.release_matrix.global_checks.{category}: no typed checks configured")
        elif _exact_keys(report["checks"], required, f"{path}.checks", errors):
            for name in sorted(required):
                if report["checks"][name] is not True:
                    errors.append(f"{path}.checks.{name}: must be true")
    else:
        if report["checks"] != {}:
            errors.append(f"{path}.checks: cell evidence checks must be an empty object")
        direction, route, _device, _environment = scope
        metric_path = f"{path}.metrics"
        validators = {
            "automated_text": lambda: _metrics_automated(report["metrics"], criteria_profile, metric_path, errors),
            "human_quality": lambda: _metrics_human(report["metrics"], criteria_profile, metric_path, errors),
            "speech_quality": lambda: _metrics_speech(report["metrics"], criteria_profile, direction, metric_path, errors),
            "runtime": lambda: _metrics_runtime(report["metrics"], criteria_profile, route, metric_path, errors),
            "privacy_security": lambda: _metrics_privacy(report["metrics"], criteria_profile, metric_path, errors),
            "stability": lambda: _metrics_stability(report["metrics"], criteria_profile, metric_path, errors),
        }
        validator = validators.get(category)
        if validator is None:
            errors.append(f"{path}.category: no typed validator exists for {category}")
        else:
            validator()
        if category == "automated_text":
            prediction_ref = attachments[0] if isinstance(attachments, list) and len(attachments) == 1 and isinstance(attachments[0], dict) else None
            if not isinstance(attachments, list) or len(attachments) != 1:
                errors.append(f"{path}.attachments: automated text evidence requires exactly one predictions artifact")
            validate_automated_source_artifacts(
                report,
                scope=scope,
                run=run,
                corpus_ref=corpus if isinstance(corpus, dict) else {},
                prediction_ref=prediction_ref,
                store=store,
                path=path,
                errors=errors,
            )
    return generated


def _xcode_is_supported(value: Any) -> bool:
    if not isinstance(value, str) or not re.fullmatch(r"[0-9]+(?:\.[0-9]+){1,2}", value):
        return False
    return tuple(int(piece) for piece in value.split(".")) >= (26, 4)


def validate_manifest(
    manifest: Any,
    criteria: Any,
    expected_criteria_sha256: str,
    *,
    artifact_store: ArtifactStore,
    device_registry: Any,
    device_registry_sha256: str,
    resolved_config: Any,
    resolved_config_sha256: str,
    testflight_resolved_config: Any,
    testflight_resolved_config_sha256: str,
    live_release: dict[str, Any],
) -> list[str]:
    errors: list[str] = []
    if not _exact_keys(manifest, ROOT_KEYS, "$", errors):
        return errors
    if manifest["schema_version"] != "1.0":
        errors.append("$.schema_version: only 1.0 is supported")
    if manifest["criteria_sha256"] != expected_criteria_sha256:
        errors.append("$.criteria_sha256: does not match the criteria file bytes")

    matrix_config = criteria.get("release_matrix") if isinstance(criteria, dict) else None
    matrix_keys = {"directions", "routes", "device_tiers", "environments", "required_evidence", "global_evidence", "global_checks"}
    if not _exact_keys(matrix_config, matrix_keys, "criteria.release_matrix", errors):
        return errors
    for key in ("directions", "routes", "device_tiers", "environments", "required_evidence", "global_evidence"):
        values = matrix_config[key]
        if not isinstance(values, list) or not values or any(not isinstance(item, str) or not item for item in values) or len(values) != len(set(values)):
            errors.append(f"criteria.release_matrix.{key}: must be a non-empty unique string array")
    profile = criteria.get("profiles", {}).get("release_language_direction") if isinstance(criteria, dict) else None
    if not isinstance(profile, dict):
        errors.append("criteria.profiles.release_language_direction: missing")
        return errors

    validate_device_registry(device_registry, set(matrix_config["device_tiers"]), errors)
    validate_resolved_config(resolved_config, errors)
    validate_resolved_config(testflight_resolved_config, errors, path="testflight_resolved_config", expected_configuration="TestFlight")
    if isinstance(resolved_config, dict) and isinstance(testflight_resolved_config, dict):
        validate_environment_isolation(resolved_config, testflight_resolved_config, errors)

    release = manifest["release"]
    release_generated: datetime | None = None
    if _exact_keys(release, RELEASE_KEYS, "$.release", errors):
        if not isinstance(release["app_commit"], str) or not COMMIT_RE.fullmatch(release["app_commit"]):
            errors.append("$.release.app_commit: must be a full 40-character commit")
        if not isinstance(release["app_version"], str) or not VERSION_RE.fullmatch(release["app_version"]):
            errors.append("$.release.app_version: must use major.minor.patch")
        if not isinstance(release["build_number"], str) or not BUILD_RE.fullmatch(release["build_number"]):
            errors.append("$.release.build_number: must be a positive integer string")
        if not isinstance(release["release_build_id"], str) or not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{15,127}", release["release_build_id"]):
            errors.append("$.release.release_build_id: must be the immutable candidate ID")
        if not _xcode_is_supported(release["xcode_version"]):
            errors.append("$.release.xcode_version: Xcode 26.4 or newer is required")
        for name in ("backend_base_image", "backend_image"):
            if not isinstance(release[name], str) or not DIGEST_IMAGE_RE.fullmatch(release[name]):
                errors.append(f"$.release.{name}: must be pinned by a full sha256 digest")
        for name in (
            "backend_build_metadata_sha256",
            "terraform_plan_sha256", "testflight_terraform_plan_sha256",
            "terraform_backend_config_sha256", "testflight_terraform_backend_config_sha256",
            "terraform_variables_sha256", "testflight_terraform_variables_sha256",
            "terraform_plan_provenance_sha256", "testflight_terraform_plan_provenance_sha256",
            "ios_resolved_config_sha256", "testflight_resolved_config_sha256", "device_registry_sha256",
        ):
            if not isinstance(release[name], str) or not SHA256_RE.fullmatch(release[name]):
                errors.append(f"$.release.{name}: must be a complete lowercase SHA-256 digest")
        if release["configuration"] != "Release" or release["local_llm_experiment"] is not False:
            errors.append("$.release: configuration must be Release and experimental local LLM must be disabled")
        release_generated = _timestamp(release["generated_at"], "$.release.generated_at", errors)
        if release["ios_resolved_config_sha256"] != resolved_config_sha256:
            errors.append("$.release.ios_resolved_config_sha256: does not match resolved iOS configuration")
        if release["testflight_resolved_config_sha256"] != testflight_resolved_config_sha256:
            errors.append("$.release.testflight_resolved_config_sha256: does not match resolved TestFlight configuration")
        if release["device_registry_sha256"] != device_registry_sha256:
            errors.append("$.release.device_registry_sha256: does not match physical-device registry")
        for name, expected in live_release.items():
            if name in release and release[name] != expected:
                errors.append(f"$.release.{name}: manifest value does not match live release input")

    release_identity = _canonical_digest(release)
    evidence_times: list[datetime] = []
    used_reports: dict[str, str] = {}
    used_attachments: dict[str, str] = {}
    scope_runs: dict[tuple[str, str, str, str], tuple[str, str]] = {}
    run_scopes: dict[str, tuple[str, str, str, str]] = {}
    run_ids: dict[str, tuple[tuple[str, str, str, str], str]] = {}
    direction_corpora: dict[str, tuple[str, str]] = {}

    def evidence(value: Any, path: str, category: str, scope: tuple[str, str, str, str] | None) -> None:
        if not _exact_keys(value, EVIDENCE_KEYS, path, errors):
            return
        if value["status"] != "passed":
            errors.append(f"{path}.status: must be passed")
        _non_placeholder_string(value["reviewed_by"], f"{path}.reviewed_by", errors)
        reviewed = _timestamp(value["reviewed_at"], f"{path}.reviewed_at", errors)
        uri = value["artifact_uri"]
        report = artifact_store.verify_ref(
            {"artifact_uri": uri, "sha256": value["sha256"]}, path, errors, load_json=True
        )
        if isinstance(value.get("sha256"), str) and SHA256_RE.fullmatch(value["sha256"]):
            prior = used_reports.setdefault(value["sha256"], path)
            if prior != path:
                errors.append(f"{path}.sha256: report bytes are already used by {prior}; every evidence slot requires a distinct scoped report")
        generated = None
        if report is not None:
            generated = validate_category_report(
                report,
                category=category,
                scope=scope,
                criteria_profile=profile,
                global_checks=matrix_config["global_checks"],
                release_identity_sha256=release_identity,
                criteria_sha256=expected_criteria_sha256,
                device_registry_sha256=device_registry_sha256,
                release=release if isinstance(release, dict) else {},
                resolved_config=resolved_config,
                testflight_resolved_config=testflight_resolved_config,
                device_registry=device_registry,
                store=artifact_store,
                scope_runs=scope_runs,
                run_scopes=run_scopes,
                run_ids=run_ids,
                direction_corpora=direction_corpora,
                used_attachments=used_attachments,
                path=f"{path}.report",
                errors=errors,
            )
        if reviewed is not None:
            evidence_times.append(reviewed)
        if generated is not None and reviewed is not None and reviewed < generated:
            errors.append(f"{path}.reviewed_at: review cannot predate report generation")
        if release_generated is not None and generated is not None:
            if generated < release_generated:
                errors.append(f"{path}.report.generated_at: report cannot predate the bound release")
            if generated > release_generated + timedelta(days=30):
                errors.append(f"{path}.report.generated_at: report is more than 30 days newer than the release")

    expected_global = set(matrix_config["global_evidence"])
    global_evidence = manifest["global_evidence"]
    if _exact_keys(global_evidence, expected_global, "$.global_evidence", errors):
        for name in sorted(expected_global):
            evidence(global_evidence[name], f"$.global_evidence.{name}", name, None)

    expected_combinations = set(itertools.product(matrix_config["directions"], matrix_config["routes"], matrix_config["device_tiers"], matrix_config["environments"]))
    required_evidence = set(matrix_config["required_evidence"])
    matrix = manifest["matrix"]
    seen: set[tuple[str, str, str, str]] = set()
    if not isinstance(matrix, list):
        errors.append("$.matrix: must be an array")
    else:
        for index, row in enumerate(matrix):
            path = f"$.matrix[{index}]"
            if not _exact_keys(row, MATRIX_KEYS, path, errors):
                continue
            if any(not isinstance(row[name], str) for name in ("direction", "route", "device_tier", "environment")):
                errors.append(f"{path}: direction, route, device_tier, and environment must be strings")
                continue
            key = (row["direction"], row["route"], row["device_tier"], row["environment"])
            if key not in expected_combinations:
                errors.append(f"{path}: unexpected direction/route/device/environment combination {key}")
            elif key in seen:
                errors.append(f"{path}: duplicate direction/route/device/environment combination {key}")
            seen.add(key)
            if _exact_keys(row["evidence"], required_evidence, f"{path}.evidence", errors):
                for name in sorted(required_evidence):
                    evidence(row["evidence"][name], f"{path}.evidence.{name}", name, key)
        for combination in sorted(expected_combinations - seen):
            errors.append(f"$.matrix: missing direction/route/device/environment combination {combination}")

    signoffs = manifest["signoffs"]
    signoff_times: list[datetime] = []
    if _exact_keys(signoffs, SIGNOFFS, "$.signoffs", errors):
        signoff_reviewers: set[str] = set()
        for role in sorted(SIGNOFFS):
            path = f"$.signoffs.{role}"
            value = signoffs[role]
            if _exact_keys(value, {"reviewer", "approved_at"}, path, errors):
                _non_placeholder_string(value["reviewer"], f"{path}.reviewer", errors)
                if isinstance(value["reviewer"], str):
                    if value["reviewer"] in signoff_reviewers:
                        errors.append(f"{path}.reviewer: each approval role requires a distinct accountable identity")
                    signoff_reviewers.add(value["reviewer"])
                approved = _timestamp(value["approved_at"], f"{path}.approved_at", errors)
                if approved is not None:
                    signoff_times.append(approved)
    if evidence_times and signoff_times and min(signoff_times) < max(evidence_times):
        errors.append("$.signoffs: every approval must be at or after the final evidence review")
    return errors


def _read_json(path: Path) -> tuple[Any | None, str | None]:
    try:
        return strict_json_loads(path.read_bytes()), None
    except (OSError, UnicodeError, json.JSONDecodeError, ValueError, RecursionError) as exc:
        return None, f"{path}: unable to read valid JSON: {exc}"


def _run(command: list[str], cwd: Path) -> tuple[str | None, str | None]:
    environment = None
    if command and command[0] in {"git", "/usr/bin/git"}:
        command[0] = "/usr/bin/git"
        environment = {
            "PATH": "/usr/bin:/bin", "HOME": "/nonexistent", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_NO_REPLACE_OBJECTS": "1", "LC_ALL": "C",
        }
    try:
        result = subprocess.run(command, cwd=cwd, check=False, capture_output=True, text=True, timeout=60, env=environment)
    except (OSError, subprocess.TimeoutExpired) as exc:
        return None, f"{' '.join(command)} failed: {exc}"
    if result.returncode != 0:
        return None, f"{' '.join(command)} failed: {(result.stderr or result.stdout).strip()}"
    return result.stdout.strip(), None


def _planned_resources(module: dict[str, Any]) -> list[dict[str, Any]]:
    resources = list(module.get("resources", [])) if isinstance(module.get("resources"), list) else []
    for child in module.get("child_modules", []) if isinstance(module.get("child_modules"), list) else []:
        if isinstance(child, dict):
            resources.extend(_planned_resources(child))
    return resources


def _one_resource(resources: list[dict[str, Any]], resource_type: str, name: str, label: str, errors: list[str]) -> dict[str, Any] | None:
    matches = [row.get("values") for row in resources if row.get("type") == resource_type and row.get("name") == name]
    if len(matches) != 1 or not isinstance(matches[0], dict):
        errors.append(f"{label} Terraform plan: requires exactly one {resource_type}.{name}")
        return None
    return matches[0]


def _plan_contract(plan: Any, *, label: str, expected_mode: str, errors: list[str]) -> dict[str, Any]:
    contract: dict[str, Any] = {"image": None, "environment": {}, "domain": None, "project": None, "service": None}
    if not isinstance(plan, dict):
        errors.append(f"{label} Terraform plan: root must be an object")
        return contract
    if plan.get("terraform_version") != "1.15.7":
        errors.append(f"{label} Terraform plan: must be created by Terraform 1.15.7")
    if plan.get("errored") is True:
        errors.append(f"{label} Terraform plan: errored plan is forbidden")
    changes = plan.get("resource_changes")
    if not isinstance(changes, list):
        errors.append(f"{label} Terraform plan: resource_changes is missing")
    else:
        for change in changes:
            actions = change.get("change", {}).get("actions", []) if isinstance(change, dict) else []
            if "delete" in actions:
                errors.append(f"{label} Terraform plan: destructive action is forbidden for {change.get('address', 'unknown resource')}")

    root = plan.get("planned_values", {}).get("root_module")
    if not isinstance(root, dict):
        errors.append(f"{label} Terraform plan: planned_values.root_module is missing")
        return contract
    resources = _planned_resources(root)
    inventory = Counter(
        (str(row.get("mode", "managed")), str(row.get("type", "")), str(row.get("name", "")))
        for row in resources if isinstance(row, dict)
    )
    for identity, required_count in SERVICE_RESOURCE_COUNTS.items():
        if inventory.get(identity, 0) != required_count:
            errors.append(
                f"{label} Terraform plan: inventory requires exactly {required_count} "
                f"{identity[0]} {identity[1]}.{identity[2]} instance(s)"
            )
    for identity, count in inventory.items():
        if identity not in SERVICE_RESOURCE_COUNTS:
            errors.append(
                f"{label} Terraform plan: unexpected {identity[0]} resource "
                f"{identity[1]}.{identity[2]} ({count} instance(s))"
            )
    cloud_run = _one_resource(resources, "google_cloud_run_v2_service", "api", label, errors)
    certificate = _one_resource(resources, "google_compute_managed_ssl_certificate", "api", label, errors)
    ssl_policy = _one_resource(resources, "google_compute_ssl_policy", "api", label, errors)
    armor_policy = _one_resource(resources, "google_compute_security_policy", "api", label, errors)
    query_exclusion = _one_resource(resources, "google_logging_project_exclusion", "query_strings", label, errors)
    backend_service = _one_resource(resources, "google_compute_backend_service", "api", label, errors)
    public_iam = _one_resource(resources, "google_cloud_run_v2_service_iam_member", "public_edge", label, errors)
    neg = _one_resource(resources, "google_compute_region_network_endpoint_group", "api", label, errors)
    https_map = _one_resource(resources, "google_compute_url_map", "api", label, errors)
    https_proxy = _one_resource(resources, "google_compute_target_https_proxy", "api", label, errors)
    address = _one_resource(resources, "google_compute_global_address", "api", label, errors)
    https_forward = _one_resource(resources, "google_compute_global_forwarding_rule", "https", label, errors)
    redirect_map = _one_resource(resources, "google_compute_url_map", "redirect", label, errors)
    http_proxy = _one_resource(resources, "google_compute_target_http_proxy", "redirect", label, errors)
    http_forward = _one_resource(resources, "google_compute_global_forwarding_rule", "http", label, errors)
    log_bucket = _one_resource(resources, "google_logging_project_bucket_config", "default", label, errors)
    uptime = _one_resource(resources, "google_monitoring_uptime_check_config", "ready", label, errors)
    budget = _one_resource(resources, "google_billing_budget", "project", label, errors)
    if cloud_run is None:
        return contract
    try:
        template = cloud_run["template"][0]
        container = template["containers"][0]
        scaling = template["scaling"][0]
        resources_block = container["resources"][0]
        image = container["image"]
        env_rows = container.get("env", [])
    except (KeyError, IndexError, TypeError):
        errors.append(f"{label} Terraform plan: unable to read Cloud Run template")
        return contract
    direct_env: dict[str, str] = {}
    secret_env: dict[str, tuple[str, str]] = {}
    env_names: set[str] = set()
    for row in env_rows if isinstance(env_rows, list) else []:
        if not isinstance(row, dict) or not isinstance(row.get("name"), str):
            continue
        if row["name"] in env_names:
            errors.append(f"{label} Terraform plan: duplicate Cloud Run environment name {row['name']}")
        env_names.add(row["name"])
        if isinstance(row.get("value"), str):
            direct_env[row["name"]] = row["value"]
        source = row.get("value_source")
        if isinstance(source, list) and source and isinstance(source[0], dict):
            refs = source[0].get("secret_key_ref")
            if isinstance(refs, list) and refs and isinstance(refs[0], dict):
                secret_env[row["name"]] = (
                    str(refs[0].get("secret", "")),
                    str(refs[0].get("version", "")),
                )
    required_direct = {
        "ALLOWED_APP_BUNDLE_VERSIONS", "ALLOWED_PRODUCT_IDS", "APPLE_APP_ID_PREFIX",
        "APPLE_APP_STORE_ID", "APPLE_BUNDLE_ID", "APPLE_IAP_ISSUER_ID", "APPLE_IAP_KEY_ID",
        "APPLE_STOREKIT_ENVIRONMENT", "APP_ATTEST_ENVIRONMENT", "APPLE_TEAM_ID",
        "FIRESTORE_DATABASE", "FIRESTORE_PROJECT", "GOOGLE_CLOUD_PROJECT", "GOOGLE_STT_LOCATION",
        "GOOGLE_TRANSLATION_LOCATION", "ONLINE_ENABLED", "RUNTIME_MODE",
        "RELEASE_BUILD_ID", "BACKEND_OCI_DIGEST",
    } | set(FIXED_RUNTIME_LIMITS)
    if set(direct_env) != required_direct:
        errors.append(f"{label} Terraform plan: Cloud Run direct environment does not exactly match reviewed keys")
    if set(secret_env) != set(REVIEWED_SECRET_IDS):
        errors.append(f"{label} Terraform plan: Cloud Run secret environment does not exactly match reviewed Apple secrets")
    if any(not re.fullmatch(r"[1-9][0-9]*", version) for _, version in secret_env.values()):
        errors.append(f"{label} Terraform plan: every secret must use an immutable numeric version")
    for name, expected_secret in REVIEWED_SECRET_IDS.items():
        if secret_env.get(name, (None, None))[0] != expected_secret:
            errors.append(f"{label} Terraform plan: {name} must bind reviewed secret ID {expected_secret}")
    for name, expected in FIXED_RUNTIME_LIMITS.items():
        if direct_env.get(name) != expected:
            errors.append(f"{label} Terraform plan: {name} must equal reviewed value {expected}")
    expected_storekit = "Production" if expected_mode == "production" else "Sandbox"
    expected_values = {
        "RUNTIME_MODE": expected_mode,
        "APP_ATTEST_ENVIRONMENT": "production",
        "APPLE_STOREKIT_ENVIRONMENT": expected_storekit,
        "ONLINE_ENABLED": "true",
        "GOOGLE_CLOUD_PROJECT": cloud_run.get("project"),
        "FIRESTORE_PROJECT": cloud_run.get("project"),
        "BACKEND_OCI_DIGEST": image.rsplit("@", 1)[-1] if isinstance(image, str) and "@" in image else None,
    }
    for name, expected in expected_values.items():
        if direct_env.get(name) != expected:
            errors.append(f"{label} Terraform plan: {name} must equal {expected}")
    expected_locations = {
        "GOOGLE_STT_LOCATION": "us",
        "GOOGLE_TRANSLATION_LOCATION": "us-central1",
    }
    for name, expected in expected_locations.items():
        if direct_env.get(name) != expected:
            errors.append(f"{label} Terraform plan: {name} must equal reviewed value {expected}")
    if not isinstance(direct_env.get("RELEASE_BUILD_ID"), str) or not re.fullmatch(
        r"[A-Za-z0-9][A-Za-z0-9._-]{15,127}", direct_env["RELEASE_BUILD_ID"]
    ):
        errors.append(f"{label} Terraform plan: RELEASE_BUILD_ID has an invalid immutable identifier")
    if cloud_run.get("ingress") != "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER" or cloud_run.get("deletion_protection") is not True:
        errors.append(f"{label} Terraform plan: Cloud Run ingress/deletion protection is unsafe")
    if cloud_run.get("location") != "us-central1":
        errors.append(f"{label} Terraform plan: Cloud Run location must equal us-central1")
    if template.get("timeout") != "20s" or template.get("max_instance_request_concurrency") != 8:
        errors.append(f"{label} Terraform plan: Cloud Run timeout/concurrency differs from reviewed policy")
    if not isinstance(scaling.get("max_instance_count"), (int, float)) or not 1 <= scaling["max_instance_count"] <= 3:
        errors.append(f"{label} Terraform plan: max instances must be from one through three")
    if expected_mode == "production" and (not isinstance(scaling.get("min_instance_count"), (int, float)) or scaling["min_instance_count"] < 1):
        errors.append(f"{label} Terraform plan: production requires a warm instance")
    limits = resources_block.get("limits", {}) if isinstance(resources_block, dict) else {}
    if limits.get("cpu") != "1" or limits.get("memory") != "1Gi":
        errors.append(f"{label} Terraform plan: Cloud Run CPU/memory limits differ from reviewed policy")
    project = cloud_run.get("project")
    service_account = template.get("service_account")
    if not isinstance(project, str) or not isinstance(service_account, str) or not service_account.endswith(f"@{project}.iam.gserviceaccount.com"):
        errors.append(f"{label} Terraform plan: runtime service account must belong to the environment project")
    if not isinstance(image, str) or not DIGEST_IMAGE_RE.fullmatch(image):
        errors.append(f"{label} Terraform plan: backend image must be pinned by sha256")
    startup = container.get("startup_probe")
    liveness = container.get("liveness_probe")
    try:
        startup_value = startup[0]
        startup_http = startup_value["http_get"][0]
        liveness_value = liveness[0]
        liveness_http = liveness_value["http_get"][0]
        if (
            startup_value.get("initial_delay_seconds") != 1
            or startup_value.get("timeout_seconds") != 2
            or startup_value.get("period_seconds") != 2
            or startup_value.get("failure_threshold") != 10
            or startup_http.get("path") != "/livez"
            or startup_http.get("port") != 8080
        ):
            raise ValueError
        if (
            liveness_value.get("timeout_seconds") != 2
            or liveness_value.get("period_seconds") != 10
            or liveness_value.get("failure_threshold") != 3
            or liveness_http.get("path") != "/livez"
            or liveness_http.get("port") != 8080
        ):
            raise ValueError
    except (KeyError, IndexError, TypeError, ValueError):
        errors.append(f"{label} Terraform plan: Cloud Run startup/liveness probes differ from reviewed policy")

    domain = None
    try:
        domain = certificate["managed"][0]["domains"][0] if certificate else None
    except (KeyError, IndexError, TypeError):
        pass
    if not isinstance(certificate, dict) or not isinstance(domain, str) or certificate.get("project") != project:
        errors.append(f"{label} Terraform plan: managed certificate/domain is missing or cross-project")
    if not isinstance(ssl_policy, dict) or ssl_policy.get("project") != project or ssl_policy.get("min_tls_version") != "TLS_1_2" or ssl_policy.get("profile") not in {"MODERN", "RESTRICTED"}:
        errors.append(f"{label} Terraform plan: HTTPS frontend must use an explicit MODERN/RESTRICTED TLS policy")
    armor_rules = armor_policy.get("rule", []) if isinstance(armor_policy, dict) else []
    required_armor = {100: "deny(400)", 200: "deny(404)", 1000: "rate_based_ban", 2000: "throttle", 2147483647: "allow"}
    actual_armor = {row.get("priority"): row.get("action") for row in armor_rules if isinstance(row, dict)}
    for priority, action in required_armor.items():
        if actual_armor.get(priority) != action:
            errors.append(f"{label} Terraform plan: Cloud Armor priority {priority} must use {action}")
    armor_by_priority = {row.get("priority"): row for row in armor_rules if isinstance(row, dict)}

    def armor_expression(priority: int) -> str | None:
        match = armor_by_priority.get(priority, {}).get("match")
        if not isinstance(match, list) or len(match) != 1 or not isinstance(match[0], dict):
            return None
        expr = match[0].get("expr")
        if not isinstance(expr, list) or len(expr) != 1 or not isinstance(expr[0], dict):
            return None
        value = expr[0].get("expression")
        return value if isinstance(value, str) else None

    expected_unknown_path = "!(" + " || ".join(f"request.path == '{path}'" for path in EDGE_ALLOWED_PATHS) + ")"
    if armor_expression(100) != "request.query != ''":
        errors.append(f"{label} Terraform plan: Cloud Armor priority 100 must reject every non-empty query")
    if armor_expression(200) != expected_unknown_path:
        errors.append(f"{label} Terraform plan: Cloud Armor priority 200 route allowlist differs from the reviewed API surface")
    try:
        registration = armor_by_priority[1000]
        registration_options = registration["rate_limit_options"][0]
        registration_threshold = registration_options["rate_limit_threshold"][0]
        registration_ban = registration_options["ban_threshold"][0]
        registration_expression = armor_expression(1000)
        if registration_expression != "request.path == '/v2/app-attest/challenge' || request.path == '/v2/app-attest/register'":
            raise ValueError
        registration_count = registration_threshold.get("count")
        if (
            registration_options.get("conform_action") != "allow"
            or registration_options.get("exceed_action") != "deny(429)"
            or registration_options.get("enforce_on_key") != "IP"
            or registration_threshold.get("interval_sec") != 60
            or not isinstance(registration_count, int)
            or not 1 <= registration_count <= 10_000
            or registration_options.get("ban_duration_sec") != 600
            or registration_ban.get("interval_sec") != 60
            or registration_ban.get("count") != registration_count * 2
        ):
            raise ValueError
        shared = armor_by_priority[2000]
        shared_options = shared["rate_limit_options"][0]
        shared_threshold = shared_options["rate_limit_threshold"][0]
        shared_match = shared["match"][0]
        shared_count = shared_threshold.get("count")
        if (
            shared_options.get("conform_action") != "allow"
            or shared_options.get("exceed_action") != "deny(429)"
            or shared_options.get("enforce_on_key") != "IP"
            or shared_threshold.get("interval_sec") != 60
            or not isinstance(shared_count, int)
            or not 60 <= shared_count <= 10_000
            or shared_match.get("versioned_expr") != "SRC_IPS_V1"
            or shared_match.get("config", [{}])[0].get("src_ip_ranges") != ["*"]
        ):
            raise ValueError
    except (AttributeError, KeyError, IndexError, TypeError, ValueError):
        errors.append(f"{label} Terraform plan: Cloud Armor rate-limit/ban semantics differ from reviewed policy")
    if not isinstance(armor_policy, dict) or armor_policy.get("project") != project:
        errors.append(f"{label} Terraform plan: Cloud Armor policy must belong to the environment project")
    if not isinstance(query_exclusion, dict) or query_exclusion.get("filter") != 'httpRequest.requestUrl =~ "[?].+"':
        errors.append(f"{label} Terraform plan: query-bearing request-log exclusion is missing")
    if not isinstance(backend_service, dict) or not backend_service.get("security_policy") or backend_service.get("timeout_sec") != 20:
        errors.append(f"{label} Terraform plan: backend service must bind Cloud Armor and 20-second timeout")
    if not isinstance(public_iam, dict) or public_iam.get("role") != "roles/run.invoker" or public_iam.get("member") != "allUsers":
        errors.append(f"{label} Terraform plan: edge invocation IAM binding is missing")
    alert_rows = [row.get("values") for row in resources if row.get("type") == "google_monitoring_alert_policy"]
    if not alert_rows or any(not isinstance(row, dict) or not row.get("notification_channels") for row in alert_rows):
        errors.append(f"{label} Terraform plan: every alert policy must route to a notification channel")
    if not isinstance(budget, dict) or budget.get("billing_account") in {None, ""}:
        errors.append(f"{label} Terraform plan: billing budget is missing")
    else:
        try:
            budget_projects = budget["budget_filter"][0]["projects"]
            specified = budget["amount"][0]["specified_amount"][0]
            thresholds = sorted(row.get("threshold_percent") for row in budget["threshold_rules"])
            update_rule = budget["all_updates_rule"][0]
            if (
                not isinstance(budget_projects, list)
                or len(budget_projects) != 1
                or not re.fullmatch(r"projects/[0-9]+", budget_projects[0])
                or specified.get("currency_code") != "USD"
                or not isinstance(specified.get("units"), str)
                or thresholds != [0.5, 0.9, 1.0]
                or not update_rule.get("monitoring_notification_channels")
            ):
                raise ValueError
        except (AttributeError, KeyError, IndexError, TypeError, ValueError):
            errors.append(f"{label} Terraform plan: project budget scope/amount/thresholds differ from reviewed policy")
    try:
        if neg.get("project") != project or neg.get("region") != cloud_run.get("location") or neg["cloud_run"][0].get("service") != cloud_run.get("name"):
            raise ValueError
        if backend_service["backend"][0].get("group") != neg.get("id") or backend_service.get("security_policy") != armor_policy.get("id"):
            raise ValueError
        if https_map.get("default_service") != backend_service.get("id"):
            raise ValueError
        if https_proxy.get("url_map") != https_map.get("id") or https_proxy.get("ssl_policy") != ssl_policy.get("id") or https_proxy.get("ssl_certificates") != [certificate.get("id")]:
            raise ValueError
        if https_forward.get("target") != https_proxy.get("id") or https_forward.get("ip_address") != address.get("address") or https_forward.get("port_range") != "443":
            raise ValueError
        redirect = redirect_map["default_url_redirect"][0]
        if redirect.get("https_redirect") is not True or redirect.get("strip_query") is not True:
            raise ValueError
        if http_proxy.get("url_map") != redirect_map.get("id") or http_forward.get("target") != http_proxy.get("id") or http_forward.get("ip_address") != address.get("address") or http_forward.get("port_range") != "80":
            raise ValueError
    except (AttributeError, KeyError, IndexError, TypeError, ValueError):
        errors.append(f"{label} Terraform plan: load-balancer reference graph differs from reviewed topology")
    if not isinstance(log_bucket, dict) or log_bucket.get("retention_days") != 30:
        errors.append(f"{label} Terraform plan: default log retention must equal 30 days")
    try:
        check = uptime["http_check"][0]
        monitored = uptime["monitored_resource"][0]
        if check.get("path") != "/readyz" or check.get("port") != 443 or check.get("use_ssl") is not True or check.get("validate_ssl") is not True:
            raise ValueError
        if monitored.get("type") != "uptime_url" or monitored.get("labels", {}).get("host") != domain:
            raise ValueError
    except (AttributeError, KeyError, IndexError, TypeError, ValueError):
        errors.append(f"{label} Terraform plan: HTTPS readiness uptime check differs from reviewed policy")
    contract.update({"image": image, "environment": direct_env, "domain": domain, "project": project, "service": cloud_run.get("name")})
    return contract


def _terraform_configuration_digest(repository_root: Path, stack: str = "service") -> str:
    stack_root = repository_root / "infra" / stack
    paths = sorted(set(stack_root.glob("*.tf")) | set(stack_root.glob("*.tf.json"))) + [stack_root / ".terraform.lock.hcl"]
    hasher = hashlib.sha256()
    for path in paths:
        relative = path.relative_to(repository_root).as_posix().encode("utf-8")
        hasher.update(relative + b"\0" + path.read_bytes() + b"\0")
    return hasher.hexdigest()


def _parse_backend_config(path: Path, label: str, errors: list[str]) -> dict[str, str]:
    result: dict[str, str] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        errors.append(f"{label} backend config: unable to read: {exc}")
        return result
    for number, raw in enumerate(lines, 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        match = re.fullmatch(r'(bucket|prefix)\s*=\s*"([^"\n]+)"', line)
        if not match or match.group(1) in result:
            errors.append(f"{label} backend config:{number}: only one literal bucket and prefix are allowed")
            continue
        result[match.group(1)] = match.group(2)
    if set(result) != {"bucket", "prefix"}:
        errors.append(f"{label} backend config: exactly one bucket and prefix are required")
    for value in result.values():
        if PLACEHOLDER_RE.search(value):
            errors.append(f"{label} backend config: placeholder values are forbidden")
    return result


def _validate_plan_provenance(
    provenance: Any,
    *,
    label: str,
    expected_mode: str,
    commit: str | None,
    configuration_sha256: str,
    backend_sha256: str,
    variables_sha256: str,
    plan_sha256: str | None,
    project_id: str | None,
    errors: list[str],
) -> None:
    path = f"{label} plan provenance"
    if not _exact_keys(provenance, PLAN_PROVENANCE_KEYS, path, errors):
        return
    expected = {
        "schema_version": "1.0", "stack": "service", "app_commit": commit,
        "terraform_version": "1.15.7", "configuration_sha256": configuration_sha256,
        "backend_config_sha256": backend_sha256, "plan_sha256": plan_sha256,
        "variables_sha256": variables_sha256, "project_id": project_id, "environment": expected_mode,
    }
    for name, value in expected.items():
        if provenance.get(name) != value:
            errors.append(f"{path}.{name}: does not match live release input")
    _timestamp(provenance.get("generated_at"), f"{path}.generated_at", errors)


def _provenance_binds_material(provenance: Any, image: str) -> bool:
    if not isinstance(provenance, dict):
        return False
    materials = provenance.get("materials")
    if not isinstance(materials, list):
        return False
    digest = image.rsplit("@sha256:", 1)[-1]
    matches = []
    for material in materials:
        if not isinstance(material, dict):
            continue
        digests = material.get("digest")
        uri = material.get("uri")
        if isinstance(digests, dict) and digests.get("sha256") == digest:
            matches.append(material)
        elif isinstance(uri, str) and uri == image and isinstance(digests, dict) and digests.get("sha256") == digest:
            matches.append(material)
    return len(matches) == 1


def _validate_backend_build_metadata(
    metadata: Any,
    *,
    commit: str | None,
    backend_base_image: str,
    backend_image: str | None,
    repository_root: Path,
    errors: list[str],
) -> None:
    path = "backend build metadata"
    if not isinstance(metadata, dict):
        errors.append(f"{path}: root must be an object")
        return
    digest = metadata.get("containerimage.digest")
    expected_digest = backend_image.rsplit("@", 1)[1] if isinstance(backend_image, str) and "@" in backend_image else None
    if not isinstance(digest, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", digest):
        errors.append(f"{path}: BuildKit containerimage.digest is missing")
    elif digest != expected_digest:
        errors.append(f"{path}: built application digest does not match both Terraform plans")
    provenance = metadata.get("buildx.build.provenance")
    if not isinstance(provenance, dict):
        errors.append(f"{path}: BuildKit max provenance is missing")
    elif not _provenance_binds_material(provenance, backend_base_image):
        errors.append(f"{path}: BuildKit provenance materials do not structurally bind the approved base-image digest")
    binding = metadata.get("locallingo.release")
    if not _exact_keys(binding, BACKEND_BUILD_BINDING_KEYS, f"{path}.locallingo.release", errors):
        return
    try:
        context_digest = _backend_context_digest(repository_root)
        if not _backend_dockerfile_uses_only_approved_argument(repository_root):
            errors.append(f"{path}: every Dockerfile stage must use the approved NODE_IMAGE argument")
    except OSError as exc:
        errors.append(f"{path}: unable to hash live backend context: {exc}")
        context_digest = None
    expected = {
        "schema_version": "1.0",
        "source_commit": commit,
        "base_image": backend_base_image,
        "application_image_digest": expected_digest,
        "oci_index_digest": expected_digest,
        "platform": "linux/amd64",
        "backend_context_sha256": context_digest,
    }
    for name, value in expected.items():
        if binding.get(name) != value:
            errors.append(f"{path}.locallingo.release.{name}: does not match the live reviewed build input")
    runnable_digest = binding.get("runnable_manifest_digest")
    if not isinstance(runnable_digest, str) or not re.fullmatch(r"sha256:[a-f0-9]{64}", runnable_digest):
        errors.append(f"{path}.locallingo.release.runnable_manifest_digest: invalid OCI platform manifest digest")
    elif runnable_digest == expected_digest:
        errors.append(f"{path}.locallingo.release.runnable_manifest_digest: must differ from the attested OCI index digest")


def _inspect_plan(
    *,
    store: ArtifactStore,
    uri: str,
    resolved_config: dict[str, Any],
    repository_root: Path,
    label: str,
    errors: list[str],
) -> tuple[str | None, dict[str, Any]]:
    digest = store.digest(uri, f"{label} Terraform plan", errors)
    plan_path = store.resolve(uri, f"{label} Terraform plan", errors)
    plan_contract: dict[str, Any] = {"image": None, "environment": {}, "domain": None, "project": None, "service": None}
    if plan_path is not None:
        plan_output, plan_error = _run(["terraform", "show", "-json", str(plan_path)], repository_root)
        if plan_error:
            errors.append(f"live release identity: {label}: {plan_error}")
        else:
            try:
                expected_mode = "production" if label == "production" else "testflight"
                plan_contract = _plan_contract(strict_json_loads(plan_output or "{}"), label=label, expected_mode=expected_mode, errors=errors)
            except (json.JSONDecodeError, ValueError, RecursionError, UnicodeError) as exc:
                errors.append(f"{label} Terraform plan: terraform show returned invalid JSON: {exc}")
    ios_contract = resolved_config.get("backend_contract", {})
    if isinstance(ios_contract, dict):
        for name in BACKEND_CONTRACT_KEYS - {"API_DOMAIN"}:
            if plan_contract["environment"].get(name) != ios_contract.get(name):
                errors.append(f"cross-stack contract: {label} Terraform {name} does not match resolved iOS configuration")
        if plan_contract["domain"] != ios_contract.get("API_DOMAIN"):
            errors.append(f"cross-stack contract: {label} Terraform API domain does not match resolved iOS API host")
    if plan_contract["environment"].get("RELEASE_BUILD_ID") != resolved_config.get("RELEASE_BUILD_ID"):
        errors.append(f"cross-stack contract: {label} Terraform RELEASE_BUILD_ID does not match the resolved iOS build")
    return digest, plan_contract


def _verify_clean_build_inputs(repository_root: Path, errors: list[str]) -> str | None:
    top, top_error = _run(["/usr/bin/git", "rev-parse", "--show-toplevel"], repository_root)
    git_dir, git_dir_error = _run(["/usr/bin/git", "rev-parse", "--absolute-git-dir"], repository_root)
    if top_error or git_dir_error or Path(top or "").resolve() != repository_root.resolve() or Path(git_dir or "").resolve() != (repository_root / ".git").resolve():
        errors.append("live release identity: Git checkout/root identity mismatch")
    commit, commit_error = _run(["git", "rev-parse", "HEAD"], repository_root)
    if commit_error:
        errors.append(f"live release identity: {commit_error}")
        return None
    dirty, dirty_error = _run(["git", "status", "--porcelain", "--untracked-files=no"], repository_root)
    if dirty_error:
        errors.append(f"live release identity: {dirty_error}")
    elif dirty:
        errors.append("live release identity: tracked checkout has uncommitted changes")
    flags_output, flags_error = _run(["git", "ls-files", "-v"], repository_root)
    if flags_error:
        errors.append(f"live release identity: {flags_error}")
    else:
        for row in (flags_output or "").splitlines():
            if not row:
                continue
            flag, _, name = row.partition(" ")
            if flag != "H":
                errors.append(f"live release identity: forbidden index flag {flag} on {name}")

    stage_output, stage_error = _run(["git", "ls-files", "--stage"], repository_root)
    if stage_error:
        errors.append(f"live release identity: {stage_error}")
        stage_rows: dict[str, tuple[str, str]] = {}
    else:
        stage_rows = {}
        for row in (stage_output or "").splitlines():
            metadata, separator, name = row.partition("\t")
            parts = metadata.split()
            if not separator or len(parts) != 3:
                errors.append(f"live release identity: malformed index entry: {row}")
                continue
            mode, blob, stage = parts
            if stage != "0":
                errors.append(f"live release identity: non-stage-zero index entry is forbidden: {name}")
                continue
            if mode not in {"100644", "100755"}:
                errors.append(f"live release identity: symlink, submodule, or unsupported tracked mode {mode}: {name}")
                continue
            stage_rows[name] = (mode, blob)

    tracked_output, tracked_error = _run(["git", "ls-files"], repository_root)
    if tracked_error:
        errors.append(f"live release identity: {tracked_error}")
        return commit
    tracked = set((tracked_output or "").splitlines())
    allowed_untracked: set[str] = set()
    roots = [".github", "backend", "evaluation", "infra", "ios/Config", "ios/Resources", "ios/Sources", "ios/Tests", "scripts"]
    excluded_roots = (
        "backend/node_modules/",
        "backend/dist/",
        "backend/coverage/",
        "evaluation/__pycache__/",
        "evaluation/scripts/__pycache__/",
        "evaluation/tests/__pycache__/",
        "infra/bootstrap/.terraform/",
        "infra/service/.terraform/",
    )
    for root_name in roots:
        root = repository_root / root_name
        if not root.exists():
            continue
        for candidate in root.rglob("*"):
            relative = candidate.relative_to(repository_root).as_posix()
            if any(relative.startswith(prefix) for prefix in excluded_roots):
                continue
            if candidate.is_symlink():
                errors.append(f"live release identity: build input symlink is forbidden: {relative}")
                continue
            if candidate.is_file() and relative not in tracked and relative not in allowed_untracked:
                errors.append(f"live release identity: untracked/ignored build input is forbidden: {relative}")
    for relative in ("Makefile", "backend/Dockerfile", "backend/package.json", "backend/package-lock.json", "backend/tsconfig.json", "ios/project.yml"):
        if relative not in tracked:
            errors.append(f"live release identity: required build input is not tracked: {relative}")
    for relative, (expected_mode, expected_blob) in stage_rows.items():
        if relative not in tracked or not any(relative == root or relative.startswith(root + "/") for root in roots):
            continue
        candidate = repository_root / relative
        if not candidate.is_file() or candidate.is_symlink():
            errors.append(f"live release identity: tracked build input is missing or not a regular file: {relative}")
            continue
        actual_mode = "100755" if candidate.stat().st_mode & 0o111 else "100644"
        if actual_mode != expected_mode:
            errors.append(f"live release identity: worktree mode differs from index for {relative}")
        actual_blob, blob_error = _run(["git", "hash-object", "--no-filters", "--", relative], repository_root)
        if blob_error:
            errors.append(f"live release identity: unable to hash {relative}: {blob_error}")
        elif actual_blob != expected_blob:
            errors.append(f"live release identity: worktree bytes differ from index for {relative}")
    return commit


def gather_live_release(
    *,
    repository_root: Path,
    store: ArtifactStore,
    terraform_plan_uri: str,
    testflight_terraform_plan_uri: str,
    terraform_backend: dict[str, str],
    terraform_backend_sha256: str,
    testflight_terraform_backend: dict[str, str],
    testflight_terraform_backend_sha256: str,
    terraform_variables_sha256: str,
    testflight_terraform_variables_sha256: str,
    terraform_plan_provenance: dict[str, Any],
    terraform_plan_provenance_sha256: str,
    testflight_plan_provenance: dict[str, Any],
    testflight_plan_provenance_sha256: str,
    backend_build_metadata: dict[str, Any],
    backend_build_metadata_sha256: str,
    resolved_config: dict[str, Any],
    resolved_config_sha256: str,
    testflight_resolved_config: dict[str, Any],
    testflight_resolved_config_sha256: str,
    device_registry_sha256: str,
    backend_base_image: str,
    errors: list[str],
) -> dict[str, Any]:
    commit = _verify_clean_build_inputs(repository_root, errors)

    xcode_output, xcode_error = _run(["xcodebuild", "-version"], repository_root)
    xcode_version = None
    if xcode_error:
        errors.append(f"live release identity: {xcode_error}")
    else:
        match = re.search(r"^Xcode\s+([0-9]+(?:\.[0-9]+){1,2})$", xcode_output or "", re.MULTILINE)
        if not match:
            errors.append("live release identity: unable to parse xcodebuild -version")
        else:
            xcode_version = match.group(1)

    plan_digest, production_contract = _inspect_plan(
        store=store, uri=terraform_plan_uri, resolved_config=resolved_config,
        repository_root=repository_root, label="production", errors=errors,
    )
    testflight_plan_digest, testflight_contract = _inspect_plan(
        store=store, uri=testflight_terraform_plan_uri, resolved_config=testflight_resolved_config,
        repository_root=repository_root, label="TestFlight", errors=errors,
    )
    backend_image = production_contract.get("image")
    testflight_image = testflight_contract.get("image")
    production_subject = backend_image.rsplit("@", 1)[-1] if isinstance(backend_image, str) and "@" in backend_image else None
    testflight_subject = testflight_image.rsplit("@", 1)[-1] if isinstance(testflight_image, str) and "@" in testflight_image else None
    if production_subject is None or testflight_subject != production_subject:
        errors.append("cross-stack contract: TestFlight and production must deploy the same backend image digest subject")
    elif backend_image == testflight_image:
        errors.append("cross-environment infrastructure: production and TestFlight must use isolated registry references for the shared image subject")
    for name in ("project", "service", "domain"):
        if production_contract.get(name) == testflight_contract.get(name):
            errors.append(f"cross-environment infrastructure: production and TestFlight {name} must be distinct")
    if plan_digest == testflight_plan_digest:
        errors.append("cross-environment infrastructure: production and TestFlight plans must be distinct")
    if terraform_backend == testflight_terraform_backend:
        errors.append("cross-environment infrastructure: production and TestFlight GCS bucket/prefix pairs must be distinct")
    if terraform_variables_sha256 == testflight_terraform_variables_sha256:
        errors.append("cross-environment infrastructure: production and TestFlight variable files must be distinct")
    if production_contract.get("environment", {}).get("RELEASE_BUILD_ID") != testflight_contract.get("environment", {}).get("RELEASE_BUILD_ID"):
        errors.append("cross-environment infrastructure: TestFlight and production must share one release candidate build ID")
    try:
        configuration_sha256 = _terraform_configuration_digest(repository_root)
    except OSError as exc:
        errors.append(f"live release identity: unable to hash Terraform configuration: {exc}")
        configuration_sha256 = ""
    _validate_plan_provenance(
        terraform_plan_provenance, label="production", expected_mode="production", commit=commit,
        configuration_sha256=configuration_sha256, backend_sha256=terraform_backend_sha256,
        variables_sha256=terraform_variables_sha256,
        plan_sha256=plan_digest, project_id=production_contract.get("project"), errors=errors,
    )
    _validate_plan_provenance(
        testflight_plan_provenance, label="TestFlight", expected_mode="testflight", commit=commit,
        configuration_sha256=configuration_sha256, backend_sha256=testflight_terraform_backend_sha256,
        variables_sha256=testflight_terraform_variables_sha256,
        plan_sha256=testflight_plan_digest, project_id=testflight_contract.get("project"), errors=errors,
    )
    if not DIGEST_IMAGE_RE.fullmatch(backend_base_image):
        errors.append("live release identity: --backend-base-image must be pinned by sha256")
    _validate_backend_build_metadata(
        backend_build_metadata,
        commit=commit,
        backend_base_image=backend_base_image,
        backend_image=backend_image,
        repository_root=repository_root,
        errors=errors,
    )
    return {
        "app_commit": commit,
        "app_version": resolved_config.get("MARKETING_VERSION"),
        "build_number": resolved_config.get("CURRENT_PROJECT_VERSION"),
        "release_build_id": resolved_config.get("RELEASE_BUILD_ID"),
        "xcode_version": xcode_version,
        "backend_base_image": backend_base_image,
        "backend_image": backend_image,
        "backend_build_metadata_sha256": backend_build_metadata_sha256,
        "terraform_plan_sha256": plan_digest,
        "testflight_terraform_plan_sha256": testflight_plan_digest,
        "terraform_backend_config_sha256": terraform_backend_sha256,
        "testflight_terraform_backend_config_sha256": testflight_terraform_backend_sha256,
        "terraform_variables_sha256": terraform_variables_sha256,
        "testflight_terraform_variables_sha256": testflight_terraform_variables_sha256,
        "terraform_plan_provenance_sha256": terraform_plan_provenance_sha256,
        "testflight_terraform_plan_provenance_sha256": testflight_plan_provenance_sha256,
        "ios_resolved_config_sha256": resolved_config_sha256,
        "testflight_resolved_config_sha256": testflight_resolved_config_sha256,
        "device_registry_sha256": device_registry_sha256,
        "configuration": "Release",
        "local_llm_experiment": False,
    }


def parse_args(argv: list[str]) -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[2]
    parser.add_argument("manifest", type=Path)
    parser.add_argument("--criteria", type=Path, default=root / "evaluation" / "acceptance-criteria.json")
    parser.add_argument("--artifact-root", type=Path, required=True)
    parser.add_argument("--device-registry", required=True, help="Relative path under artifact root.")
    parser.add_argument("--resolved-ios-config", required=True, help="Relative path under artifact root.")
    parser.add_argument("--testflight-resolved-ios-config", required=True, help="Relative path under artifact root.")
    parser.add_argument("--terraform-plan", required=True, help="Relative path under artifact root.")
    parser.add_argument("--testflight-terraform-plan", required=True, help="Relative path under artifact root.")
    parser.add_argument("--terraform-backend-config", required=True, help="Production partial GCS backend config under artifact root.")
    parser.add_argument("--testflight-terraform-backend-config", required=True, help="TestFlight partial GCS backend config under artifact root.")
    parser.add_argument("--terraform-variables", required=True, help="Production variables file under artifact root.")
    parser.add_argument("--testflight-terraform-variables", required=True, help="TestFlight variables file under artifact root.")
    parser.add_argument("--terraform-plan-provenance", required=True, help="Production plan provenance JSON under artifact root.")
    parser.add_argument("--testflight-plan-provenance", required=True, help="TestFlight plan provenance JSON under artifact root.")
    parser.add_argument("--backend-build-metadata", required=True, help="BuildKit metadata JSON under artifact root.")
    parser.add_argument("--backend-base-image", required=True)
    parser.add_argument("--repository-root", type=Path, default=root)
    return parser.parse_args(argv)


def main(argv: list[str] | None = None) -> int:
    args = parse_args(sys.argv[1:] if argv is None else argv)
    errors: list[str] = []
    store = ArtifactStore(args.artifact_root, errors)
    repository_store = ArtifactStore(args.repository_root, errors)
    manifest: Any = None
    criteria: Any = None
    criteria_path: Path | None = None
    try:
        canonical_criteria = (args.repository_root / "evaluation" / "acceptance-criteria.json").resolve(strict=True)
        if args.criteria.resolve(strict=True) != canonical_criteria or args.criteria.is_symlink():
            raise ValueError
        criteria_path = repository_store.resolve(
            "evaluation/acceptance-criteria.json", "release criteria", errors
        )
    except (OSError, ValueError):
        errors.append("release criteria must be the canonical tracked evaluation/acceptance-criteria.json")
    try:
        manifest_path = Path(os.path.abspath(args.manifest))
        manifest_relative = manifest_path.resolve(strict=True).relative_to(store.root).as_posix()
        if not manifest_path.is_file():
            raise OSError("not a regular file")
        manifest_path = store.resolve(manifest_relative, "release manifest", errors)
    except (OSError, ValueError):
        manifest_path = None
        errors.append("release manifest must be a real file inside the explicit artifact root")
    if manifest_path is not None:
        manifest, manifest_error = _read_json(manifest_path)
        if manifest_error:
            errors.append(manifest_error)
    if criteria_path is not None:
        criteria, criteria_error = _read_json(criteria_path)
        if criteria_error:
            errors.append(criteria_error)
    if not isinstance(manifest, dict) or not isinstance(criteria, dict):
        for error in errors:
            print(error, file=sys.stderr)
        store.close()
        repository_store.close()
        return 2
    device_ref = {"artifact_uri": args.device_registry, "sha256": store.digest(args.device_registry, "device registry", errors) or ""}
    config_ref = {"artifact_uri": args.resolved_ios_config, "sha256": store.digest(args.resolved_ios_config, "resolved iOS config", errors) or ""}
    testflight_config_ref = {"artifact_uri": args.testflight_resolved_ios_config, "sha256": store.digest(args.testflight_resolved_ios_config, "resolved TestFlight config", errors) or ""}
    backend_ref = {"artifact_uri": args.terraform_backend_config, "sha256": store.digest(args.terraform_backend_config, "production backend config", errors) or ""}
    testflight_backend_ref = {"artifact_uri": args.testflight_terraform_backend_config, "sha256": store.digest(args.testflight_terraform_backend_config, "TestFlight backend config", errors) or ""}
    variables_ref = {"artifact_uri": args.terraform_variables, "sha256": store.digest(args.terraform_variables, "production variables", errors) or ""}
    testflight_variables_ref = {"artifact_uri": args.testflight_terraform_variables, "sha256": store.digest(args.testflight_terraform_variables, "TestFlight variables", errors) or ""}
    provenance_ref = {"artifact_uri": args.terraform_plan_provenance, "sha256": store.digest(args.terraform_plan_provenance, "production plan provenance", errors) or ""}
    testflight_provenance_ref = {"artifact_uri": args.testflight_plan_provenance, "sha256": store.digest(args.testflight_plan_provenance, "TestFlight plan provenance", errors) or ""}
    build_metadata_ref = {"artifact_uri": args.backend_build_metadata, "sha256": store.digest(args.backend_build_metadata, "backend build metadata", errors) or ""}
    device_registry = store.verify_ref(device_ref, "device registry", errors, load_json=True)
    resolved_config = store.verify_ref(config_ref, "resolved iOS config", errors, load_json=True)
    testflight_resolved_config = store.verify_ref(testflight_config_ref, "resolved TestFlight config", errors, load_json=True)
    backend_path = store.resolve(args.terraform_backend_config, "production backend config", errors)
    testflight_backend_path = store.resolve(args.testflight_terraform_backend_config, "TestFlight backend config", errors)
    terraform_backend = _parse_backend_config(backend_path, "production", errors) if backend_path else {}
    testflight_terraform_backend = _parse_backend_config(testflight_backend_path, "TestFlight", errors) if testflight_backend_path else {}
    terraform_plan_provenance = store.verify_ref(provenance_ref, "production plan provenance", errors, load_json=True)
    testflight_plan_provenance = store.verify_ref(testflight_provenance_ref, "TestFlight plan provenance", errors, load_json=True)
    backend_build_metadata = store.verify_ref(build_metadata_ref, "backend build metadata", errors, load_json=True)
    try:
        criteria_bytes = criteria_path.read_bytes() if criteria_path is not None else b""
    except OSError as exc:
        print(f"{args.criteria}: unable to hash snapshotted criteria: {exc}", file=sys.stderr)
        store.close()
        repository_store.close()
        return 2
    if not isinstance(device_registry, dict) or not isinstance(resolved_config, dict) or not isinstance(testflight_resolved_config, dict) or not isinstance(terraform_plan_provenance, dict) or not isinstance(testflight_plan_provenance, dict) or not isinstance(backend_build_metadata, dict):
        for error in errors:
            print(error, file=sys.stderr)
        store.close()
        repository_store.close()
        return 2
    device_digest = device_ref["sha256"]
    config_digest = config_ref["sha256"]
    testflight_config_digest = testflight_config_ref["sha256"]
    live = gather_live_release(
        repository_root=args.repository_root,
        store=store,
        terraform_plan_uri=args.terraform_plan,
        testflight_terraform_plan_uri=args.testflight_terraform_plan,
        terraform_backend=terraform_backend,
        terraform_backend_sha256=backend_ref["sha256"],
        testflight_terraform_backend=testflight_terraform_backend,
        testflight_terraform_backend_sha256=testflight_backend_ref["sha256"],
        terraform_variables_sha256=variables_ref["sha256"],
        testflight_terraform_variables_sha256=testflight_variables_ref["sha256"],
        terraform_plan_provenance=terraform_plan_provenance,
        terraform_plan_provenance_sha256=provenance_ref["sha256"],
        testflight_plan_provenance=testflight_plan_provenance,
        testflight_plan_provenance_sha256=testflight_provenance_ref["sha256"],
        backend_build_metadata=backend_build_metadata,
        backend_build_metadata_sha256=build_metadata_ref["sha256"],
        resolved_config=resolved_config,
        resolved_config_sha256=config_digest,
        testflight_resolved_config=testflight_resolved_config,
        testflight_resolved_config_sha256=testflight_config_digest,
        device_registry_sha256=device_digest,
        backend_base_image=args.backend_base_image,
        errors=errors,
    )
    errors.extend(validate_manifest(
        manifest,
        criteria,
        hashlib.sha256(criteria_bytes).hexdigest(),
        artifact_store=store,
        device_registry=device_registry,
        device_registry_sha256=device_digest,
        resolved_config=resolved_config,
        resolved_config_sha256=config_digest,
        testflight_resolved_config=testflight_resolved_config,
        testflight_resolved_config_sha256=testflight_config_digest,
        live_release=live,
    ))
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"RELEASE BLOCKED: {len(errors)} evidence or live-input error(s).", file=sys.stderr)
        store.close()
        repository_store.close()
        return 1
    verified_reports = sum(len(row["evidence"]) for row in manifest["matrix"]) + len(manifest["global_evidence"])
    # Version-1 evidence is an unsigned structural preflight. It may prove that
    # all expected cells and local contracts were supplied, but it is not a
    # trusted release authorization. Only the version-2 signed finalizer may
    # emit an approved release decision.
    print(json.dumps({
        "preflight_status": "passed",
        "release_decision": False,
        "schema_version": "1.0",
        "release_identity_sha256": _canonical_digest(manifest["release"]),
        "criteria_sha256": hashlib.sha256(criteria_bytes).hexdigest(),
        "release_manifest_sha256": hashlib.sha256(manifest_path.read_bytes()).hexdigest(),
        "release_build_id": resolved_config["RELEASE_BUILD_ID"],
        "matrix_cells": len(manifest["matrix"]),
        "verified_reports": verified_reports,
    }, sort_keys=True))
    store.close()
    repository_store.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
