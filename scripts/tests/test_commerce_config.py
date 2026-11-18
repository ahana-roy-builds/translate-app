from __future__ import annotations

import contextlib
import importlib.util
import io
import os
from pathlib import Path
from types import SimpleNamespace
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("commerce_validator", ROOT / "scripts" / "validate-ios-release-config.py")
validator = importlib.util.module_from_spec(spec)
spec.loader.exec_module(validator)


class CommerceConfigTests(unittest.TestCase):
    def validate(self, **overrides):
        values = dict(
            APP_BUNDLE_IDENTIFIER="com.acme.speakduet", DEVELOPMENT_TEAM="ABCDE12345",
            APP_RUNTIME_ENVIRONMENT="commerce", RELEASE_BUILD_ID="commerce-build-0001",
            LOCAL_LLM_EXPERIMENT="0", MARKETING_VERSION="0.2.0", CURRENT_PROJECT_VERSION="2",
            SWIFT_ACTIVE_COMPILATION_CONDITIONS="COMMERCE", OTHER_SWIFT_FLAGS="",
            MICROPHONE_USAGE_DESCRIPTION="Audio is processed on-device and is not sent off this iPhone.",
            ACCOUNTS_ENABLED="YES", SUBSCRIPTIONS_ENABLED="YES", TRANSLATION_ACCESS_REQUIRED="YES",
            ONLINE_FEATURES_ENABLED="NO", FACE_TO_FACE_ENABLED="NO",
            GOOGLE_REVERSED_CLIENT_ID="com.googleusercontent.apps.123456",
            STOREKIT_MONTHLY_PRODUCT_ID="com.acme.speakduet.monthly",
            PRIVACY_POLICY_URL="https://acme.dev/privacy", TERMS_URL="https://acme.dev/terms",
            SUPPORT_URL="https://acme.dev/support",
        )
        values.update(overrides)
        firebase = dict(BUNDLE_ID="com.acme.speakduet", REVERSED_CLIENT_ID="com.googleusercontent.apps.123456",
                        API_KEY="configured-api-key", GOOGLE_APP_ID="1:123456:ios:abc123",
                        PROJECT_ID="speakduet-config-test", CLIENT_ID="123456.apps.googleusercontent.com")
        original_read = validator.read_plist
        def read(path, name, errors):
            return firebase if name == "Firebase configuration" else original_read(path, name, errors)
        args = SimpleNamespace(build_environment=True, config=ROOT / "ios/Config/Commerce.xcconfig",
                               privacy_manifest=None, emit_resolved_config=None,
                               app_icon=ROOT / "ios/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json",
                               info_plist=ROOT / "ios/Config/Info.plist")
        errors = []
        with patch.dict(os.environ, values, clear=True), patch.object(validator, "read_plist", side_effect=read), contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
            result = validator.validate_commerce(args, errors)
        return result, errors

    def test_offline_monthly_commerce_needs_no_online_backend(self):
        result, errors = self.validate()
        self.assertEqual(result, 0, errors)

    def test_online_routing_and_missing_legal_or_identity_values_block_distribution(self):
        for override in (
            dict(ONLINE_FEATURES_ENABLED="YES"), dict(TRANSLATION_ACCESS_REQUIRED="NO"),
            dict(PRIVACY_POLICY_URL="https://example.invalid/privacy"),
            dict(STOREKIT_MONTHLY_PRODUCT_ID="com.someoneelse.monthly"),
            dict(GOOGLE_REVERSED_CLIENT_ID="com.googleusercontent.apps.other"),
            dict(APP_BUNDLE_IDENTIFIER="com.other.app"),
            dict(STOREKIT_ANNUAL_PRODUCT_ID="com.acme.speakduet.annual"),
        ):
            with self.subTest(override=override):
                result, errors = self.validate(**override)
                self.assertEqual(result, 1)
                self.assertTrue(errors)


if __name__ == "__main__":
    unittest.main()
