from __future__ import annotations

import json
import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "scripts" / "validate-ios-release-config.py"


class IOSReleaseConfigTests(unittest.TestCase):
    def test_debug_mvp_capabilities_are_locked_after_local_overrides(self) -> None:
        config = (ROOT / "ios" / "Config" / "Debug.xcconfig").read_text(encoding="utf-8")
        last_include = config.rfind("#include?")
        online = config.rfind("ONLINE_FEATURES_ENABLED = NO")
        face_to_face = config.rfind("FACE_TO_FACE_ENABLED = NO")

        self.assertGreater(online, last_include)
        self.assertGreater(face_to_face, last_include)

        entitlements = plistlib.loads(
            (ROOT / "ios" / "Config" / "LocalLingo.Debug.entitlements").read_bytes()
        )
        self.assertNotIn("com.apple.developer.devicecheck.appattest-environment", entitlements)

    def config(self, **overrides: str) -> str:
        values = {
            "SWIFT_VERSION": "6.0",
            "MARKETING_VERSION": "1.2.3",
            "CURRENT_PROJECT_VERSION": "42",
            "RELEASE_BUILD_ID": "release-build-00000042",
            "APP_BUNDLE_IDENTIFIER": "org.acme.locallingo",
            "DEVELOPMENT_TEAM": "ABCDE12345",
            "APP_ATTEST_ENVIRONMENT": "production",
            "APP_RUNTIME_ENVIRONMENT": "production",
            "API_BASE_URL": "https:/$()/api.acme-domain.dev",
            "STOREKIT_MONTHLY_PRODUCT_ID": "org.acme.locallingo.pro.monthly",
            "STOREKIT_ANNUAL_PRODUCT_ID": "org.acme.locallingo.pro.annual",
            "PRIVACY_POLICY_URL": "https:/$()/acme-domain.dev/privacy",
            "TERMS_URL": "https:/$()/acme-domain.dev/terms",
            "SUPPORT_URL": "https:/$()/acme-domain.dev/support",
            "LOCAL_LLM_EXPERIMENT": "0",
            "MICROPHONE_USAGE_DESCRIPTION": "LocalLingo uses Local Only or Online Quality with Google processing.",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "RELEASE",
            "OTHER_SWIFT_FLAGS": "$(inherited)",
        }
        values.update(overrides)
        return "\n".join(f"{name} = {value}" for name, value in values.items()) + "\n"

    def run_config(
        self,
        *,
        extra_args: tuple[str, ...] = (),
        **overrides: str,
    ) -> tuple[subprocess.CompletedProcess[str], dict | None]:
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "Release.xcconfig"
            output = Path(temporary) / "resolved.json"
            config.write_text(self.config(**overrides), encoding="utf-8")
            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--config",
                    str(config),
                    "--configuration",
                    "Release",
                    "--emit-resolved-config",
                    str(output),
                    *extra_args,
                ],
                cwd=ROOT, text=True, capture_output=True, check=False,
            )
            resolved = json.loads(output.read_text(encoding="utf-8")) if output.exists() else None
            return result, resolved

    def private_beta_config(self, **overrides: str) -> str:
        values = {
            "SWIFT_VERSION": "6.0",
            "MARKETING_VERSION": "0.1.0",
            "CURRENT_PROJECT_VERSION": "1",
            "RELEASE_BUILD_ID": "private-beta-build-0001",
            "APP_BUNDLE_IDENTIFIER": "org.acme.locallingo.beta",
            "DEVELOPMENT_TEAM": "ABCDE12345",
            "APP_RUNTIME_ENVIRONMENT": "private-beta",
            "LOCAL_LLM_EXPERIMENT": "0",
            "MICROPHONE_USAGE_DESCRIPTION": "Audio is processed on-device and is not sent off this iPhone.",
            "ONLINE_FEATURES_ENABLED": "NO",
            "FACE_TO_FACE_ENABLED": "NO",
            "PRIVACY_POLICY_URL": "https:/$()/acme-domain.dev/locallingo/privacy",
            "SWIFT_ACTIVE_COMPILATION_CONDITIONS": "PRIVATE_BETA",
            "OTHER_SWIFT_FLAGS": "$(inherited)",
        }
        values.update(overrides)
        return "\n".join(f"{name} = {value}" for name, value in values.items()) + "\n"

    def run_private_beta(
        self,
        *,
        extra_args: tuple[str, ...] = (),
        build_environment: bool = False,
        **overrides: str,
    ) -> tuple[subprocess.CompletedProcess[str], dict | None]:
        with tempfile.TemporaryDirectory() as temporary:
            config = Path(temporary) / "PrivateBeta.xcconfig"
            output = Path(temporary) / "resolved.json"
            config.write_text(self.private_beta_config(**overrides), encoding="utf-8")
            command = [
                "python3",
                str(SCRIPT),
                "--configuration",
                "PrivateBeta",
                "--emit-resolved-config",
                str(output),
                *extra_args,
            ]
            environment = None
            if build_environment:
                command.append("--build-environment")
                environment = os.environ.copy()
                for line in self.private_beta_config(**overrides).splitlines():
                    name, value = line.split(" = ", 1)
                    environment[name] = "" if value == "$(inherited)" else value
            else:
                command.extend(("--config", str(config)))
            result = subprocess.run(
                command,
                cwd=ROOT,
                env=environment,
                text=True,
                capture_output=True,
                check=False,
            )
            resolved = json.loads(output.read_text(encoding="utf-8")) if output.exists() else None
            return result, resolved

    def test_valid_config_emits_cross_stack_contract(self) -> None:
        result, resolved = self.run_config()
        self.assertEqual(result.returncode, 0, result.stderr)
        assert resolved
        self.assertEqual(resolved["backend_contract"]["API_DOMAIN"], "api.acme-domain.dev")
        self.assertEqual(resolved["backend_contract"]["ALLOWED_APP_BUNDLE_VERSIONS"], "42")

    def test_malformed_https_url_is_rejected(self) -> None:
        result, _ = self.run_config(API_BASE_URL="https:/$()/")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("absolute HTTPS URL", result.stderr)

    def test_products_must_be_bundle_owned(self) -> None:
        result, _ = self.run_config(
            STOREKIT_MONTHLY_PRODUCT_ID="org.other.monthly",
        )
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("owned by APP_BUNDLE_IDENTIFIER", result.stderr)

    def test_resolved_config_has_no_cloudkit_contract(self) -> None:
        result, resolved = self.run_config()
        self.assertEqual(result.returncode, 0, result.stderr)
        assert resolved
        self.assertNotIn("CLOUDKIT_CONTAINER_IDENTIFIER", resolved)

    def test_experimental_swift_condition_is_rejected(self) -> None:
        result, _ = self.run_config(SWIFT_ACTIVE_COMPILATION_CONDITIONS="RELEASE LOCAL_LLM_EXPERIMENT")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must not enable LOCAL_LLM_EXPERIMENT", result.stderr)

    def test_release_and_runtime_identity_are_required(self) -> None:
        result, _ = self.run_config(RELEASE_BUILD_ID="short")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("immutable candidate identifier", result.stderr)
        result, _ = self.run_config(APP_RUNTIME_ENVIRONMENT="testflight")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("must be production", result.stderr)

    def test_experimental_other_swift_flag_is_rejected(self) -> None:
        result, _ = self.run_config(OTHER_SWIFT_FLAGS="$(inherited) -D LOCAL_LLM_EXPERIMENT")
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("OTHER_SWIFT_FLAGS must not define", result.stderr)

    def test_local_override_rejects_unknown_build_setting(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local = root / "Release.local.xcconfig"
            config = root / "Release.xcconfig"
            local.write_text("OTHER_SWIFT_FLAGS = -D LOCAL_LLM_EXPERIMENT\n", encoding="utf-8")
            config.write_text(self.config() + '#include "Release.local.xcconfig"\n', encoding="utf-8")
            result = subprocess.run(
                ["python3", str(SCRIPT), "--config", str(config), "--configuration", "Release"],
                cwd=ROOT, text=True, capture_output=True, check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("may not set build-affecting key OTHER_SWIFT_FLAGS", result.stderr)

    def test_private_beta_passes_without_online_service_configuration(self) -> None:
        result, resolved = self.run_private_beta()

        self.assertEqual(result.returncode, 0, result.stderr)
        assert resolved
        self.assertEqual(resolved["configuration"], "PrivateBeta")
        self.assertNotIn("backend_contract", resolved)
        for name in (
            "APP_ATTEST_ENVIRONMENT",
            "API_BASE_URL",
            "STOREKIT_MONTHLY_PRODUCT_ID",
            "STOREKIT_ANNUAL_PRODUCT_ID",
            "TERMS_URL",
            "SUPPORT_URL",
        ):
            self.assertNotIn(name, resolved)
        self.assertEqual(
            resolved["PRIVACY_POLICY_URL"],
            "https://acme-domain.dev/locallingo/privacy",
        )

    def test_private_beta_requires_a_public_privacy_policy_url(self) -> None:
        result, _ = self.run_private_beta(PRIVACY_POLICY_URL="")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PRIVACY_POLICY_URL", result.stderr)

    def test_private_beta_build_environment_reads_local_only_flags(self) -> None:
        result, _ = self.run_private_beta(build_environment=True, ONLINE_FEATURES_ENABLED="YES")

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ONLINE_FEATURES_ENABLED must be NO in PrivateBeta", result.stderr)

    def test_private_beta_fails_closed_when_deferred_features_are_enabled(self) -> None:
        cases = {
            "ONLINE_FEATURES_ENABLED": "YES",
            "FACE_TO_FACE_ENABLED": "YES",
            "LOCAL_LLM_EXPERIMENT": "1",
        }
        for name, value in cases.items():
            with self.subTest(name=name):
                result, _ = self.run_private_beta(**{name: value})
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(f"{name} must be", result.stderr)

    def test_private_beta_validates_distribution_identity_and_versions(self) -> None:
        cases = (
            ({"APP_BUNDLE_IDENTIFIER": "not-a-bundle"}, "reverse-DNS identifier"),
            ({"DEVELOPMENT_TEAM": "invalid"}, "10-character Apple Team ID"),
            ({"MARKETING_VERSION": "1.0"}, "major.minor.patch"),
            ({"CURRENT_PROJECT_VERSION": "0"}, "positive integer"),
            ({"RELEASE_BUILD_ID": "short"}, "immutable candidate identifier"),
        )
        for overrides, expected in cases:
            with self.subTest(overrides=overrides):
                result, _ = self.run_private_beta(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(expected, result.stderr)

    def test_private_beta_local_override_can_increment_testflight_versions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            local = root / "PrivateBeta.local.xcconfig"
            config = root / "PrivateBeta.xcconfig"
            local.write_text(
                "MARKETING_VERSION = 0.2.0\n"
                "CURRENT_PROJECT_VERSION = 2\n"
                "RELEASE_BUILD_ID = private-beta-build-0002\n",
                encoding="utf-8",
            )
            config.write_text(
                self.private_beta_config()
                + '#include "PrivateBeta.local.xcconfig"\n',
                encoding="utf-8",
            )

            result = subprocess.run(
                [
                    "python3",
                    str(SCRIPT),
                    "--config",
                    str(config),
                    "--configuration",
                    "PrivateBeta",
                ],
                cwd=ROOT,
                text=True,
                capture_output=True,
                check=False,
            )

        self.assertEqual(result.returncode, 0, result.stderr)

    def test_private_beta_validates_app_icon(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            contents = Path(temporary) / "Contents.json"
            contents.write_text('{"images": []}\n', encoding="utf-8")

            result, _ = self.run_private_beta(extra_args=("--app-icon", str(contents)))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("AppIcon has no image entries", result.stderr)

    def test_private_beta_validates_usage_descriptions(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            info_path = Path(temporary) / "Info.plist"
            info = plistlib.loads((ROOT / "ios" / "Config" / "Info.plist").read_bytes())
            info["NSMicrophoneUsageDescription"] = ""
            info_path.write_bytes(plistlib.dumps(info))

            result, _ = self.run_private_beta(extra_args=("--info-plist", str(info_path)))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NSMicrophoneUsageDescription must be a non-empty string", result.stderr)

    def test_private_beta_requires_an_offline_microphone_disclosure(self) -> None:
        result, _ = self.run_private_beta(
            MICROPHONE_USAGE_DESCRIPTION="Audio may be sent to an online service."
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("on-device-only processing", result.stderr)

    def test_private_beta_validates_privacy_manifest(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            privacy_path = Path(temporary) / "PrivacyInfo.xcprivacy"
            privacy = plistlib.loads(
                (ROOT / "ios" / "Resources" / "PrivateBeta" / "PrivacyInfo.xcprivacy").read_bytes()
            )
            privacy["NSPrivacyTracking"] = True
            privacy["NSPrivacyTrackingDomains"] = ["tracking.example.com"]
            privacy_path.write_bytes(plistlib.dumps(privacy))

            result, _ = self.run_private_beta(extra_args=("--privacy-manifest", str(privacy_path)))

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("NSPrivacyTracking must be false", result.stderr)
        self.assertIn("NSPrivacyTrackingDomains must be an empty array", result.stderr)

    def test_private_beta_rejects_online_collection_declarations(self) -> None:
        online_manifest = ROOT / "ios" / "Resources" / "Online" / "PrivacyInfo.xcprivacy"

        result, _ = self.run_private_beta(
            extra_args=("--privacy-manifest", str(online_manifest)),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PrivateBeta must not declare collected data", result.stderr)

    def test_online_deployment_requires_online_collection_declarations(self) -> None:
        private_beta_manifest = (
            ROOT / "ios" / "Resources" / "PrivateBeta" / "PrivacyInfo.xcprivacy"
        )

        result, _ = self.run_config(
            extra_args=("--privacy-manifest", str(private_beta_manifest)),
        )

        self.assertNotEqual(result.returncode, 0)
        self.assertIn("online privacy manifest is missing", result.stderr)


if __name__ == "__main__":
    unittest.main()
