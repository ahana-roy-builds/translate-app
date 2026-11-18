from __future__ import annotations

import os
import plistlib
import subprocess
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SCANNER = ROOT / "scripts" / "verify-no-sensitive-content.sh"


class SensitiveContentTests(unittest.TestCase):
    def scan(self, files: dict[str, str]) -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            for relative, contents in files.items():
                path = root / relative
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(contents, encoding="utf-8")
            environment = dict(os.environ, LOCALLINGO_SCAN_ROOT=str(root))
            return subprocess.run(
                ["bash", str(SCANNER)], text=True, capture_output=True,
                env=environment, check=False,
            )

    def test_json_escaped_private_key_is_rejected(self) -> None:
        escaped_pem = '{"private_key":"-----BEGIN ' + 'PRIVATE KEY-----\\' + 'nabc"}'
        result = self.scan({"config.json": escaped_pem})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("credential material", result.stderr)

    def test_nested_vendor_directory_is_still_scanned(self) -> None:
        access_key = "A" + "KIA" + "ABCDEFGHIJKLMNOP"
        result = self.scan({"ios/Sources/vendor/config.txt": access_key})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("ios/Sources/vendor/config.txt", result.stderr)

    def test_credential_filename_is_rejected(self) -> None:
        result = self.scan({"private/nested/service-account.json": "{}"})
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("credential/provisioning filename", result.stderr)

    def test_env_example_is_allowed_but_real_env_is_not(self) -> None:
        self.assertEqual(self.scan({"app/.env.example": "SAFE=value"}).returncode, 0)
        self.assertNotEqual(self.scan({"app/.env.production": "SAFE=value"}).returncode, 0)

    def test_nul_prefix_does_not_hide_token(self) -> None:
        token = "\0prefix" + "A" + "KIA" + "ABCDEFGHIJKLMNOP"
        result = self.scan({"opaque.bin": token})
        self.assertNotEqual(result.returncode, 0)

    def test_large_padding_does_not_hide_token(self) -> None:
        token = "A" + "KIA" + "ABCDEFGHIJKLMNOP"
        result = self.scan({"large.txt": ("x" * (33 * 1024 * 1024)) + token})
        self.assertNotEqual(result.returncode, 0)

    def test_symlink_is_rejected_not_skipped(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            (root / "safe.txt").write_text("safe", encoding="utf-8")
            (root / "link.txt").symlink_to("safe.txt")
            result = subprocess.run(
                ["bash", str(SCANNER)], text=True, capture_output=True,
                env=dict(os.environ, LOCALLINGO_SCAN_ROOT=str(root)), check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("symlinked file", result.stderr)

    def test_special_file_is_rejected_without_blocking(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            os.mkfifo(root / "named-pipe")
            result = subprocess.run(
                ["bash", str(SCANNER)], text=True, capture_output=True, timeout=5,
                env=dict(os.environ, LOCALLINGO_SCAN_ROOT=str(root)), check=False,
            )
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("special non-regular", result.stderr)

    def firebase_scan(self, *, ignored: bool = True, tracked: bool = False,
                      relative: str = "ios/Resources/GoogleService-Info.plist",
                      extra: dict | None = None, suffix: str = "") -> subprocess.CompletedProcess[str]:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            subprocess.run(["git", "init", "--quiet", str(root)], check=True)
            if ignored:
                (root / ".gitignore").write_text("GoogleService-Info.plist\n")
            contents = dict(
                API_KEY="AI" + "za" + "a" * 35, BUNDLE_ID="com.acme.speakduet",
                CLIENT_ID="123-abc.apps.googleusercontent.com",
                REVERSED_CLIENT_ID="com.googleusercontent.apps.123-abc",
                GOOGLE_APP_ID="1:123:ios:abc123", PROJECT_ID="speak-duet-test",
            )
            contents.update(extra or {})
            path = root / relative
            path.parent.mkdir(parents=True, exist_ok=True)
            path.write_bytes(plistlib.dumps(contents) + suffix.encode())
            if tracked:
                subprocess.run(["git", "-C", str(root), "add", "--force", "--", relative], check=True)
            return subprocess.run(
                ["bash", str(SCANNER)], text=True, capture_output=True,
                env=dict(os.environ, LOCALLINGO_SCAN_ROOT=str(root)), check=False,
            )

    def test_valid_local_firebase_config_must_be_ignored_and_untracked(self) -> None:
        self.assertEqual(self.firebase_scan().returncode, 0)
        for options in (dict(ignored=False), dict(tracked=True),
                        dict(relative="GoogleService-Info.plist")):
            with self.subTest(options=options):
                result = self.firebase_scan(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("credential/provisioning filename", result.stderr)

    def test_local_firebase_exception_rejects_unknown_fields_and_wrong_callback(self) -> None:
        for extra in (dict(private_key="private material"),
                      dict(REVERSED_CLIENT_ID="com.googleusercontent.apps.wrong")):
            with self.subTest(extra=extra):
                self.assertNotEqual(self.firebase_scan(extra=extra).returncode, 0)

    def test_local_firebase_still_scans_other_values_and_xml_comments(self) -> None:
        token = "A" + "KIA" + "ABCDEFGHIJKLMNOP"
        for options in (dict(extra=dict(STORAGE_BUCKET=token)),
                        dict(suffix="<!-- " + token + " -->")):
            with self.subTest(options=options):
                result = self.firebase_scan(**options)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn("credential material", result.stderr)


if __name__ == "__main__":
    unittest.main()
