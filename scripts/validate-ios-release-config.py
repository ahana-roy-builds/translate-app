#!/usr/bin/env python3
"""Validate resolved iOS deployment configuration and App Store metadata."""

from __future__ import annotations

import argparse
import json
import os
import plistlib
import re
import struct
import sys
from pathlib import Path
from urllib.parse import urlsplit


ASSIGNMENT_RE = re.compile(r"^([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
INCLUDE_RE = re.compile(r'^#include(\?)?\s+"([^"]+)"\s*$')
VARIABLE_RE = re.compile(r"\$\(([^)]*)\)")
PLACEHOLDER_RE = re.compile(
    r"(?:example|replace|placeholder|todo|tbd|localhost|127\.0\.0\.1|\.(?:invalid|test)(?:/|$))",
    re.IGNORECASE,
)
COMMON_REQUIRED = {
    "APP_BUNDLE_IDENTIFIER",
    "DEVELOPMENT_TEAM",
    "APP_RUNTIME_ENVIRONMENT",
    "LOCAL_LLM_EXPERIMENT",
    "MARKETING_VERSION",
    "MICROPHONE_USAGE_DESCRIPTION",
    "CURRENT_PROJECT_VERSION",
    "RELEASE_BUILD_ID",
    "SWIFT_ACTIVE_COMPILATION_CONDITIONS",
}
ONLINE_DEPLOYMENT_REQUIRED = {
    "APP_ATTEST_ENVIRONMENT",
    "API_BASE_URL",
    "STOREKIT_MONTHLY_PRODUCT_ID",
    "STOREKIT_ANNUAL_PRODUCT_ID",
    "PRIVACY_POLICY_URL",
    "TERMS_URL",
    "SUPPORT_URL",
}
PRIVATE_BETA_REQUIRED = {
    "ONLINE_FEATURES_ENABLED",
    "FACE_TO_FACE_ENABLED",
    "PRIVACY_POLICY_URL",
}
ONLINE_COLLECTED_DATA_TYPES = {
    "NSPrivacyCollectedDataTypeAudioData",
    "NSPrivacyCollectedDataTypeOtherUserContent",
    "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypePurchaseHistory",
}
COMMERCE_REQUIRED = {
    "ACCOUNTS_ENABLED", "SUBSCRIPTIONS_ENABLED", "TRANSLATION_ACCESS_REQUIRED",
    "ONLINE_FEATURES_ENABLED", "FACE_TO_FACE_ENABLED", "GOOGLE_REVERSED_CLIENT_ID",
    "STOREKIT_MONTHLY_PRODUCT_ID", "PRIVACY_POLICY_URL", "TERMS_URL", "SUPPORT_URL",
}
ACCOUNT_COLLECTED_DATA_TYPES = {
    "NSPrivacyCollectedDataTypeName", "NSPrivacyCollectedDataTypeEmailAddress",
    "NSPrivacyCollectedDataTypeUserID",
}
BUILD_ENVIRONMENT_KEYS = COMMON_REQUIRED | ONLINE_DEPLOYMENT_REQUIRED | PRIVATE_BETA_REQUIRED | COMMERCE_REQUIRED | {
    "OTHER_SWIFT_FLAGS"
}
LOCAL_OVERRIDE_ALLOWED = {
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
    "LOCAL_LLM_EXPERIMENT",
    "RELEASE_BUILD_ID",
    "MARKETING_VERSION",
    "CURRENT_PROJECT_VERSION",
    "GOOGLE_REVERSED_CLIENT_ID",
}


def read_xcconfig(
    path: Path,
    values: dict[str, str],
    seen: set[Path],
    errors: list[str],
    *,
    config_root: Path,
) -> None:
    path = path.resolve()
    if path in seen:
        errors.append(f"{path}: recursive xcconfig include")
        return
    seen.add(path)
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except OSError as exc:
        errors.append(f"{path}: unable to read: {exc}")
        return
    for number, line in enumerate(lines, start=1):
        stripped = line.strip()
        if not stripped or stripped.startswith("//"):
            continue
        include = INCLUDE_RE.fullmatch(stripped)
        if include:
            if path.name.endswith(".local.xcconfig"):
                errors.append(f"{path}:{number}: deployment local xcconfig files may not include other files")
                continue
            target = path.parent / include.group(2)
            if not target.exists() and include.group(1):
                continue
            try:
                target.resolve().relative_to(config_root)
            except (OSError, ValueError):
                errors.append(f"{path}:{number}: xcconfig include escapes the configuration directory")
                continue
            read_xcconfig(target, values, seen, errors, config_root=config_root)
            continue
        assignment = ASSIGNMENT_RE.fullmatch(stripped)
        if assignment:
            key = assignment.group(1)
            if path.name.endswith(".local.xcconfig") and key not in LOCAL_OVERRIDE_ALLOWED:
                errors.append(f"{path}:{number}: deployment local xcconfig may not set build-affecting key {key}")
                continue
            values[key] = assignment.group(2)
            continue
        errors.append(f"{path}:{number}: unsupported xcconfig statement")
    seen.remove(path)


def resolve(values: dict[str, str]) -> dict[str, str]:
    resolved = dict(values)
    for _ in range(20):
        changed = False
        for key, value in list(resolved.items()):
            replacement = VARIABLE_RE.sub(
                lambda match: "" if match.group(1) in {"", "inherited"} else resolved.get(match.group(1), match.group(0)),
                value,
            )
            replacement = replacement.strip()
            if replacement != value:
                resolved[key] = replacement
                changed = True
        if not changed:
            break
    return resolved


def png_metadata(path: Path) -> tuple[int, int, int, bool] | None:
    try:
        contents = path.read_bytes()
    except OSError:
        return None
    header = contents[:26]
    if len(header) != 26 or header[:8] != b"\x89PNG\r\n\x1a\n" or header[12:16] != b"IHDR":
        return None
    width, height = struct.unpack(">II", header[16:24])
    return width, height, header[25], b"tRNS" in contents


def validate_icon(contents_path: Path, errors: list[str]) -> None:
    try:
        contents = json.loads(contents_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        errors.append(f"{contents_path}: invalid AppIcon Contents.json: {exc}")
        return
    images = contents.get("images") if isinstance(contents, dict) else None
    if not isinstance(images, list) or not images:
        errors.append(f"{contents_path}: AppIcon has no image entries")
        return
    found_1024 = False
    for index, image in enumerate(images):
        if not isinstance(image, dict):
            errors.append(f"{contents_path}: images[{index}] must be an object")
            continue
        filename = image.get("filename")
        if not isinstance(filename, str) or not filename:
            continue
        image_path = contents_path.parent / filename
        metadata = png_metadata(image_path)
        if metadata is None:
            errors.append(f"{image_path}: missing or not a PNG")
            continue
        width, height, color_type, has_transparency_chunk = metadata
        if color_type != 2 or has_transparency_chunk:
            errors.append(f"{image_path}: App Store icon must be opaque RGB without an alpha/transparency channel")
        if image.get("size") == "1024x1024":
            found_1024 = True
            if (width, height) != (1024, 1024):
                errors.append(f"{image_path}: declared 1024x1024 but is {width}x{height}")
    if not found_1024:
        errors.append(f"{contents_path}: a named 1024x1024 marketing icon is required")


def read_plist(path: Path, description: str, errors: list[str]) -> dict | None:
    try:
        contents = plistlib.loads(path.read_bytes())
    except (OSError, plistlib.InvalidFileException) as exc:
        errors.append(f"{path}: invalid {description}: {exc}")
        return None
    if not isinstance(contents, dict):
        errors.append(f"{path}: {description} root must be a dictionary")
        return None
    return contents


def validate_info_plist(path: Path, errors: list[str]) -> None:
    contents = read_plist(path, "Info.plist", errors)
    if contents is None:
        return
    for key in ("NSMicrophoneUsageDescription", "NSSpeechRecognitionUsageDescription"):
        value = contents.get(key)
        if not isinstance(value, str) or not value.strip():
            errors.append(f"{path}: {key} must be a non-empty string")
        elif PLACEHOLDER_RE.search(value):
            errors.append(f"{path}: {key} contains a placeholder value")
    expected_build_values = {
        "CFBundleIdentifier": "$(PRODUCT_BUNDLE_IDENTIFIER)",
        "CFBundleShortVersionString": "$(MARKETING_VERSION)",
        "CFBundleVersion": "$(CURRENT_PROJECT_VERSION)",
        "NSMicrophoneUsageDescription": "$(MICROPHONE_USAGE_DESCRIPTION)",
    }
    for key, expected in expected_build_values.items():
        if contents.get(key) != expected:
            errors.append(f"{path}: {key} must be sourced from {expected}")


def validate_privacy_manifest(path: Path, errors: list[str], *, offline_only: bool,
                              required_types: set[str] | None = None) -> None:
    contents = read_plist(path, "privacy manifest", errors)
    if contents is None:
        return
    if contents.get("NSPrivacyTracking") is not False:
        errors.append(f"{path}: NSPrivacyTracking must be false")
    tracking_domains = contents.get("NSPrivacyTrackingDomains")
    if not isinstance(tracking_domains, list) or tracking_domains:
        errors.append(f"{path}: NSPrivacyTrackingDomains must be an empty array")
    collected_rows = contents.get("NSPrivacyCollectedDataTypes")
    if not isinstance(collected_rows, list):
        errors.append(f"{path}: NSPrivacyCollectedDataTypes must be an array")
    elif offline_only and collected_rows:
        errors.append(f"{path}: PrivateBeta must not declare collected data")
    elif not offline_only:
        collected = {
            row.get("NSPrivacyCollectedDataType")
            for row in collected_rows
            if isinstance(row, dict)
        }
        expected_types = ONLINE_COLLECTED_DATA_TYPES if required_types is None else required_types
        missing = sorted(expected_types - collected)
        if missing:
            errors.append(f"{path}: online privacy manifest is missing: {', '.join(missing)}")
        for row in collected_rows:
            if not isinstance(row, dict):
                errors.append(f"{path}: collected data entries must be dictionaries")
                continue
            if row.get("NSPrivacyCollectedDataType") in expected_types:
                if row.get("NSPrivacyCollectedDataTypeLinked") is not True:
                    errors.append(f"{path}: online collected data must be linked")
                if row.get("NSPrivacyCollectedDataTypeTracking") is not False:
                    errors.append(f"{path}: online collected data must not be used for tracking")
    accessed_rows = contents.get("NSPrivacyAccessedAPITypes")
    if not isinstance(accessed_rows, list):
        errors.append(f"{path}: NSPrivacyAccessedAPITypes must be an array")
    else:
        user_defaults_reasons = {
            reason
            for row in accessed_rows
            if isinstance(row, dict)
            and row.get("NSPrivacyAccessedAPIType") == "NSPrivacyAccessedAPICategoryUserDefaults"
            for reason in row.get("NSPrivacyAccessedAPITypeReasons", [])
        }
        if "CA92.1" not in user_defaults_reasons:
            errors.append(f"{path}: UserDefaults required-reason declaration must include CA92.1")


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    root = Path(__file__).resolve().parents[1]
    parser.add_argument("--config", type=Path, default=root / "ios" / "Config" / "Release.xcconfig")
    parser.add_argument(
        "--app-icon",
        type=Path,
        default=root / "ios" / "Resources" / "Assets.xcassets" / "AppIcon.appiconset" / "Contents.json",
    )
    parser.add_argument("--info-plist", type=Path, default=root / "ios" / "Config" / "Info.plist")
    parser.add_argument(
        "--privacy-manifest",
        type=Path,
        help="Override the configuration-specific privacy manifest path.",
    )
    parser.add_argument(
        "--build-environment",
        action="store_true",
        help="Validate resolved Xcode build-setting environment variables instead of parsing xcconfig.",
    )
    parser.add_argument("--configuration", choices=("PrivateBeta", "Staging", "TestFlight", "Release", "Commerce"))
    parser.add_argument(
        "--emit-resolved-config",
        type=Path,
        help="After a passing check, write the canonical non-secret resolved configuration JSON.",
    )
    return parser.parse_args()


def validate_https_url(name: str, value: str, errors: list[str], *, api_base: bool) -> str | None:
    try:
        parsed = urlsplit(value)
        _ = parsed.port
    except ValueError as exc:
        errors.append(f"{name}: malformed URL: {exc}")
        return None
    if parsed.scheme != "https" or not parsed.hostname:
        errors.append(f"{name} must be an absolute HTTPS URL with a hostname")
        return None
    if parsed.username is not None or parsed.password is not None or parsed.query or parsed.fragment:
        errors.append(f"{name} must not contain userinfo, a query, or a fragment")
    if parsed.port not in (None, 443):
        errors.append(f"{name} must use the default HTTPS port")
    if api_base and parsed.path not in ("", "/"):
        errors.append("API_BASE_URL must not contain a path; API routes are appended by the client")
    return parsed.hostname


def main() -> int:
    args = parse_args()
    errors: list[str] = []
    configuration = args.configuration or (
        "Commerce" if args.config.name.startswith("Commerce") else
        "PrivateBeta" if args.config.name.startswith("PrivateBeta")
        else "Staging" if args.config.name.startswith("Staging")
        else "TestFlight" if args.config.name.startswith("TestFlight")
        else "Release"
    )
    if configuration == "Commerce":
        return validate_commerce(args, errors)
    resource_root = Path(__file__).resolve().parents[1] / "ios" / "Resources"
    privacy_manifest = args.privacy_manifest or resource_root / (
        "PrivateBeta/PrivacyInfo.xcprivacy"
        if configuration == "PrivateBeta"
        else "Online/PrivacyInfo.xcprivacy"
    )
    required = COMMON_REQUIRED | (PRIVATE_BETA_REQUIRED if configuration == "PrivateBeta" else ONLINE_DEPLOYMENT_REQUIRED)
    if args.build_environment:
        values = {name: os.environ.get(name, "") for name in BUILD_ENVIRONMENT_KEYS}
    else:
        values = {}
        read_xcconfig(
            args.config,
            values,
            set(),
            errors,
            config_root=args.config.resolve().parent,
        )
        values = resolve(values)
    missing = sorted(name for name in required if not values.get(name))
    if missing:
        errors.append(f"{configuration} xcconfig is missing: {', '.join(missing)}")
    for name in sorted(required):
        value = values.get(name, "")
        if PLACEHOLDER_RE.search(value):
            errors.append(f"{name}: contains a placeholder value")
    if configuration != "PrivateBeta":
        expected_attestation = "development" if configuration == "Staging" else "production"
        if values.get("APP_ATTEST_ENVIRONMENT") != expected_attestation:
            errors.append(f"APP_ATTEST_ENVIRONMENT must be {expected_attestation} for {configuration}")
    expected_runtime = {
        "PrivateBeta": "private-beta",
        "Staging": "staging",
        "TestFlight": "testflight",
        "Release": "production",
    }[configuration]
    if values.get("APP_RUNTIME_ENVIRONMENT") != expected_runtime:
        errors.append(f"APP_RUNTIME_ENVIRONMENT must be {expected_runtime} for {configuration}")
    if values.get("LOCAL_LLM_EXPERIMENT") != "0":
        errors.append(f"LOCAL_LLM_EXPERIMENT must be 0 in {configuration}")
    microphone_disclosure = values.get("MICROPHONE_USAGE_DESCRIPTION", "")
    if configuration == "PrivateBeta":
        if "on-device" not in microphone_disclosure or "not sent off this iPhone" not in microphone_disclosure:
            errors.append("PrivateBeta microphone disclosure must describe on-device-only processing")
    elif "Online Quality" not in microphone_disclosure or "Google" not in microphone_disclosure:
        errors.append(f"{configuration} microphone disclosure must describe Online Quality and Google processing")
    if configuration == "PrivateBeta":
        for name in ("ONLINE_FEATURES_ENABLED", "FACE_TO_FACE_ENABLED"):
            if values.get(name) != "NO":
                errors.append(f"{name} must be NO in PrivateBeta")
    if not re.fullmatch(r"[A-Z0-9]{10}", values.get("DEVELOPMENT_TEAM", "")):
        errors.append("DEVELOPMENT_TEAM must be a 10-character Apple Team ID")
    bundle_id = values.get("APP_BUNDLE_IDENTIFIER", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        errors.append("APP_BUNDLE_IDENTIFIER must be a reverse-DNS identifier")
    api_host: str | None = None
    monthly = ""
    annual = ""
    if configuration != "PrivateBeta":
        api_host = validate_https_url("API_BASE_URL", values.get("API_BASE_URL", ""), errors, api_base=True)
        for name in ("PRIVACY_POLICY_URL", "TERMS_URL", "SUPPORT_URL"):
            validate_https_url(name, values.get(name, ""), errors, api_base=False)
        monthly = values.get("STOREKIT_MONTHLY_PRODUCT_ID", "")
        annual = values.get("STOREKIT_ANNUAL_PRODUCT_ID", "")
        if monthly == annual:
            errors.append("Monthly and annual StoreKit product IDs must differ")
        for name, product in (("STOREKIT_MONTHLY_PRODUCT_ID", monthly), ("STOREKIT_ANNUAL_PRODUCT_ID", annual)):
            if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", product) or not product.startswith(f"{bundle_id}."):
                errors.append(f"{name} must be a reverse-DNS identifier owned by APP_BUNDLE_IDENTIFIER")
    else:
        validate_https_url("PRIVACY_POLICY_URL", values.get("PRIVACY_POLICY_URL", ""), errors, api_base=False)
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", values.get("MARKETING_VERSION", "")):
        errors.append("MARKETING_VERSION must use major.minor.patch")
    if not re.fullmatch(r"[1-9][0-9]*", values.get("CURRENT_PROJECT_VERSION", "")):
        errors.append("CURRENT_PROJECT_VERSION must be a positive integer")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{15,127}", values.get("RELEASE_BUILD_ID", "")):
        errors.append("RELEASE_BUILD_ID must be a 16-128 character immutable candidate identifier")
    conditions = values.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split()
    if "LOCAL_LLM_EXPERIMENT" in conditions:
        errors.append("Release/Staging SWIFT_ACTIVE_COMPILATION_CONDITIONS must not enable LOCAL_LLM_EXPERIMENT")
    other_swift_flags = values.get("OTHER_SWIFT_FLAGS", "")
    if re.search(r"(?:^|\s)-D(?:\s+)?LOCAL_LLM_EXPERIMENT(?:\s|$)", other_swift_flags):
        errors.append("OTHER_SWIFT_FLAGS must not define LOCAL_LLM_EXPERIMENT in deployment builds")
    validate_icon(args.app_icon, errors)
    validate_info_plist(args.info_plist, errors)
    validate_privacy_manifest(privacy_manifest, errors, offline_only=configuration == "PrivateBeta")
    if errors:
        for error in errors:
            print(error, file=sys.stderr)
        print(f"IOS {configuration.upper()} BLOCKED: {len(errors)} error(s).", file=sys.stderr)
        return 1
    if args.emit_resolved_config:
        if configuration != "PrivateBeta" and api_host is None:
            print("API_BASE_URL did not produce a valid host", file=sys.stderr)
            return 1
        output = {"schema_version": "1.0", "configuration": configuration}
        output.update({name: values[name] for name in sorted(required)})
        output["OTHER_SWIFT_FLAGS"] = other_swift_flags
        if configuration != "PrivateBeta":
            output["backend_contract"] = {
                "APPLE_BUNDLE_ID": bundle_id,
                "APPLE_TEAM_ID": values["DEVELOPMENT_TEAM"],
                "APP_ATTEST_ENVIRONMENT": values["APP_ATTEST_ENVIRONMENT"],
                "ALLOWED_PRODUCT_IDS": f"{monthly},{annual}",
                "ALLOWED_APP_BUNDLE_VERSIONS": values["CURRENT_PROJECT_VERSION"],
                "API_DOMAIN": api_host,
            }
        try:
            with args.emit_resolved_config.open("x", encoding="utf-8") as handle:
                handle.write(json.dumps(output, indent=2, sort_keys=True) + "\n")
        except OSError as exc:
            print(f"Unable to write resolved config: {exc}", file=sys.stderr)
            return 2
    print(f"iOS {configuration} configuration and AppIcon passed preflight.")
    return 0


def validate_commerce(args: argparse.Namespace, errors: list[str]) -> int:
    """Validate offline paid distribution independently of the cloud backend."""
    required = COMMON_REQUIRED | COMMERCE_REQUIRED
    if args.build_environment:
        values = {name: os.environ.get(name, "") for name in BUILD_ENVIRONMENT_KEYS}
    else:
        values: dict[str, str] = {}
        read_xcconfig(args.config, values, set(), errors, config_root=args.config.parent.resolve())
        values = resolve(values)
    for name in sorted(required):
        if not values.get(name) or PLACEHOLDER_RE.search(values.get(name, "")):
            errors.append(f"{name}: missing or placeholder Commerce value")
    for name in ("ACCOUNTS_ENABLED", "SUBSCRIPTIONS_ENABLED", "TRANSLATION_ACCESS_REQUIRED"):
        if values.get(name) != "YES": errors.append(f"{name} must be YES in Commerce")
    for name in ("ONLINE_FEATURES_ENABLED", "FACE_TO_FACE_ENABLED"):
        if values.get(name) != "NO": errors.append(f"{name} must be NO in Commerce")
    if values.get("API_BASE_URL") or values.get("STOREKIT_ANNUAL_PRODUCT_ID"):
        errors.append("Commerce has no online API or annual product")
    if values.get("APP_RUNTIME_ENVIRONMENT") != "commerce" or values.get("LOCAL_LLM_EXPERIMENT") != "0":
        errors.append("Commerce must use its offline runtime with the LLM experiment disabled")
    bundle_id = values.get("APP_BUNDLE_IDENTIFIER", "")
    if not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", bundle_id):
        errors.append("APP_BUNDLE_IDENTIFIER must be a reverse-DNS identifier")
    product_id = values.get("STOREKIT_MONTHLY_PRODUCT_ID", "")
    if not product_id.startswith(bundle_id + ".") or not re.fullmatch(r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+", product_id):
        errors.append("The monthly product ID must be owned by APP_BUNDLE_IDENTIFIER")
    if not re.fullmatch(r"[A-Z0-9]{10}", values.get("DEVELOPMENT_TEAM", "")):
        errors.append("DEVELOPMENT_TEAM must be a 10-character Apple Team ID")
    for name in ("PRIVACY_POLICY_URL", "TERMS_URL", "SUPPORT_URL"):
        validate_https_url(name, values.get(name, ""), errors, api_base=False)
    if not re.fullmatch(r"[1-9][0-9]*", values.get("CURRENT_PROJECT_VERSION", "")):
        errors.append("CURRENT_PROJECT_VERSION must be a positive integer")
    if not re.fullmatch(r"[0-9]+\.[0-9]+\.[0-9]+", values.get("MARKETING_VERSION", "")):
        errors.append("MARKETING_VERSION must use major.minor.patch")
    if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{15,127}", values.get("RELEASE_BUILD_ID", "")):
        errors.append("RELEASE_BUILD_ID must be an immutable 16-128 character identifier")
    if "LOCAL_LLM_EXPERIMENT" in values.get("SWIFT_ACTIVE_COMPILATION_CONDITIONS", "").split():
        errors.append("Commerce must not compile the LLM experiment")
    if re.search(r"(?:^|\s)-D(?:\s+)?LOCAL_LLM_EXPERIMENT(?:\s|$)", values.get("OTHER_SWIFT_FLAGS", "")):
        errors.append("Commerce must not compile the LLM experiment")
    disclosure = values.get("MICROPHONE_USAGE_DESCRIPTION", "")
    if "on-device" not in disclosure or "not sent off this iPhone" not in disclosure:
        errors.append("Commerce microphone disclosure must describe on-device-only processing")
    project = Path(__file__).resolve().parents[1] / "ios"
    firebase = read_plist(project / "Resources" / "GoogleService-Info.plist", "Firebase configuration", errors)
    if firebase is not None:
        if firebase.get("BUNDLE_ID") != bundle_id:
            errors.append("Firebase BUNDLE_ID must match APP_BUNDLE_IDENTIFIER")
        if firebase.get("REVERSED_CLIENT_ID") != values.get("GOOGLE_REVERSED_CLIENT_ID"):
            errors.append("Google callback scheme must match the Firebase configuration")
        for key in ("API_KEY", "GOOGLE_APP_ID", "PROJECT_ID", "CLIENT_ID"):
            if not firebase.get(key) or PLACEHOLDER_RE.search(str(firebase.get(key, ""))):
                errors.append(f"Firebase configuration is missing {key}")
    validate_icon(args.app_icon, errors)
    validate_info_plist(args.info_plist, errors)
    validate_privacy_manifest(args.privacy_manifest or project / "Resources" / "Commerce" / "PrivacyInfo.xcprivacy",
                              errors, offline_only=False, required_types=ACCOUNT_COLLECTED_DATA_TYPES)
    if errors:
        for error in errors: print(error, file=sys.stderr)
        print(f"IOS COMMERCE BLOCKED: {len(errors)} error(s).", file=sys.stderr)
        return 1
    if args.emit_resolved_config:
        output = {"schema_version": "1.0", "configuration": "Commerce"}
        output.update({name: values[name] for name in sorted(required)})
        with args.emit_resolved_config.open("x", encoding="utf-8") as handle:
            handle.write(json.dumps(output, indent=2, sort_keys=True) + "\n")
    print("iOS Commerce configuration, Firebase identity, and AppIcon passed preflight.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
