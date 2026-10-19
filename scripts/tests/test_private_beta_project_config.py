from __future__ import annotations

import plistlib
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class PrivateBetaProjectConfigTests(unittest.TestCase):
    def test_private_beta_is_release_optimized_and_has_a_shared_archive_scheme(self) -> None:
        project = (ROOT / "ios" / "project.yml").read_text(encoding="utf-8")

        self.assertIn("  PrivateBeta: release", project)
        self.assertEqual(project.count("PrivateBeta: Config/PrivateBeta.xcconfig"), 2)
        self.assertIn("CODE_SIGN_ENTITLEMENTS: Config/LocalLingo.PrivateBeta.entitlements", project)
        self.assertIn("  LocalLingo Private Beta:", project)
        self.assertIn("    archive:\n      config: PrivateBeta", project)

    def test_private_beta_locks_deferred_surfaces_after_signing_override(self) -> None:
        config = (ROOT / "ios" / "Config" / "PrivateBeta.xcconfig").read_text(encoding="utf-8")
        override = config.index('#include? "PrivateBeta.local.xcconfig"')

        self.assertIn("APP_RUNTIME_ENVIRONMENT = private-beta", config)
        self.assertNotIn("APP_ATTEST_ENVIRONMENT", config)
        self.assertIn("PRIVACY_POLICY_URL = https:/$()/REPLACE_PRIVATE_BETA_PRIVACY_POLICY_URL", config)
        for assignment in (
            "ONLINE_FEATURES_ENABLED = NO",
            "FACE_TO_FACE_ENABLED = NO",
            "LOCAL_LLM_EXPERIMENT = 0",
        ):
            self.assertGreater(config.rfind(assignment), override)

    def test_private_beta_has_no_capability_entitlements(self) -> None:
        path = ROOT / "ios" / "Config" / "LocalLingo.PrivateBeta.entitlements"
        self.assertEqual(plistlib.loads(path.read_bytes()), {})

    def test_private_beta_example_fails_closed_on_privacy_policy(self) -> None:
        example = (
            ROOT / "ios" / "Config" / "PrivateBeta.local.xcconfig.example"
        ).read_text(encoding="utf-8")

        self.assertIn(
            "PRIVACY_POLICY_URL = https:/$()/REPLACE.tld/locallingo/privacy",
            example,
        )
        self.assertIn("APP_BUNDLE_IDENTIFIER = org.REPLACE.locallingo", example)
        self.assertNotIn("APP_BUNDLE_IDENTIFIER = org.REPLACE.locallingo.privatebeta", example)

    def test_configurations_select_exactly_one_privacy_manifest(self) -> None:
        project = (ROOT / "ios" / "project.yml").read_text(encoding="utf-8")
        offline_exclusion = (
            'EXCLUDED_SOURCE_FILE_NAMES: "$(inherited) '
            '$(SRCROOT)/Resources/Online/PrivacyInfo.xcprivacy"'
        )
        online_exclusion = (
            'EXCLUDED_SOURCE_FILE_NAMES: "$(inherited) '
            '$(SRCROOT)/Resources/PrivateBeta/PrivacyInfo.xcprivacy"'
        )

        self.assertEqual(project.count(offline_exclusion), 2)
        self.assertEqual(project.count(online_exclusion), 3)

        private_beta = plistlib.loads(
            (ROOT / "ios" / "Resources" / "PrivateBeta" / "PrivacyInfo.xcprivacy").read_bytes()
        )
        online = plistlib.loads(
            (ROOT / "ios" / "Resources" / "Online" / "PrivacyInfo.xcprivacy").read_bytes()
        )
        self.assertEqual(private_beta["NSPrivacyCollectedDataTypes"], [])
        self.assertGreater(len(online["NSPrivacyCollectedDataTypes"]), 0)


if __name__ == "__main__":
    unittest.main()
