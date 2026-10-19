from __future__ import annotations

import plistlib
import re
import struct
import unittest
from html.parser import HTMLParser
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
SITE_ROOT = ROOT / "distribution" / "locallingo-privacy"
POLICY = SITE_ROOT / "index.html"
ICON = SITE_ROOT / "assets" / "app-icon.png"
ISSUE_TEMPLATE = SITE_ROOT / ".github" / "ISSUE_TEMPLATE" / "privacy-question.yml"
CANONICAL_URL = "https://sivaramankh.github.io/locallingo-privacy/"
ISSUE_URL = (
    "https://github.com/sivaramankh/locallingo-privacy/issues/new"
    "?template=privacy-question.yml"
)


class PolicyHTMLParser(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.canonical_urls: list[str] = []
        self.links: list[str] = []
        self.text: list[str] = []

    def handle_starttag(self, tag: str, attrs: list[tuple[str, str | None]]) -> None:
        attributes = dict(attrs)
        if tag == "link" and attributes.get("rel") == "canonical":
            if href := attributes.get("href"):
                self.canonical_urls.append(href)
        if tag == "a" and (href := attributes.get("href")):
            self.links.append(href)

    def handle_data(self, data: str) -> None:
        self.text.append(data)


class PublicPrivacyPolicyTests(unittest.TestCase):
    def setUp(self) -> None:
        self.contents = POLICY.read_text(encoding="utf-8")
        self.parser = PolicyHTMLParser()
        self.parser.feed(self.contents)
        self.visible_text = re.sub(r"\s+", " ", " ".join(self.parser.text)).strip()

    def test_policy_has_stable_public_url_and_valid_links(self) -> None:
        self.assertEqual(self.parser.canonical_urls, [CANONICAL_URL])
        self.assertTrue(self.parser.links)
        self.assertTrue(all(url.startswith("https://") for url in self.parser.links))
        self.assertIn(ISSUE_URL, self.parser.links)

    def test_policy_uses_self_contained_app_icon_with_stable_dimensions(self) -> None:
        self.assertIn(
            'src="assets/app-icon.png" width="72" height="72"',
            self.contents,
        )
        header = ICON.read_bytes()[:24]
        self.assertEqual(header[:8], b"\x89PNG\r\n\x1a\n")
        self.assertEqual(struct.unpack(">II", header[16:24]), (192, 192))

    def test_policy_does_not_publish_contact_information(self) -> None:
        email_pattern = re.compile(r"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}", re.IGNORECASE)
        expected_files = {
            ".github/ISSUE_TEMPLATE/privacy-question.yml",
            ".nojekyll",
            "README.md",
            "assets/app-icon.png",
            "index.html",
        }
        actual_files = {
            path.relative_to(SITE_ROOT).as_posix()
            for path in SITE_ROOT.rglob("*")
            if path.is_file()
        }
        self.assertEqual(actual_files, expected_files)

        for path in actual_files - {"assets/app-icon.png"}:
            public_text = (SITE_ROOT / path).read_text(encoding="utf-8")
            self.assertIsNone(email_pattern.search(public_text), path)
            self.assertNotIn("mailto:", public_text.lower(), path)
        self.assertIn("Send Beta Feedback", self.visible_text)
        self.assertIn("GitHub issues are public", self.visible_text)

    def test_policy_discloses_beta_data_boundaries(self) -> None:
        for disclosure in (
            "offline-only LocalLingo Private Beta",
            "on-device speech recognition, translation, and speech playback",
            "does not send conversation audio, transcripts, translations, or saved history",
            "Raw microphone audio is not saved",
            "This setting is off by default",
            "excluded from device backups",
            "Apple also operates TestFlight",
            "share saved text using the iOS share sheet",
            "Do not post names, contact details, conversation content, screenshots, crash logs",
        ):
            self.assertIn(disclosure, self.visible_text)

    def test_policy_matches_private_beta_enforcement(self) -> None:
        config = (ROOT / "ios" / "Config" / "PrivateBeta.xcconfig").read_text(
            encoding="utf-8"
        )
        local_override = config.rfind('#include? "PrivateBeta.local.xcconfig"')
        for flag in (
            "ONLINE_FEATURES_ENABLED = NO",
            "FACE_TO_FACE_ENABLED = NO",
            "LOCAL_LLM_EXPERIMENT = 0",
        ):
            self.assertGreater(config.rfind(flag), local_override)

        manifest = plistlib.loads(
            (ROOT / "ios" / "Resources" / "PrivateBeta" / "PrivacyInfo.xcprivacy").read_bytes()
        )
        self.assertEqual(manifest["NSPrivacyCollectedDataTypes"], [])
        self.assertFalse(manifest["NSPrivacyTracking"])
        self.assertEqual(manifest["NSPrivacyTrackingDomains"], [])


if __name__ == "__main__":
    unittest.main()
