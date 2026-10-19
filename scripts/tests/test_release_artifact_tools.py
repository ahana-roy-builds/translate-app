from __future__ import annotations

import importlib.util
import tempfile
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


def load(name: str, relative: str):
    spec = importlib.util.spec_from_file_location(name, ROOT / relative)
    assert spec and spec.loader
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


SUBJECT = load("validate_attestation_subject", "scripts/validate-attestation-subject.py")
PUBLISH = load("publish_release_artifact", "scripts/publish-release-artifact.py")


class ReleaseArtifactPathTests(unittest.TestCase):
    def test_reviewed_nested_paths_are_accepted(self) -> None:
        for module in (SUBJECT, PUBLISH):
            self.assertEqual(
                str(module.validated_relative_path("release/v1.2.3/decision_bundle-01.json", "path")),
                "release/v1.2.3/decision_bundle-01.json",
            )

    def test_control_and_output_injection_paths_are_rejected(self) -> None:
        attacks = (
            "release/decision.json\nforged=value",
            "release/decision.json\rforged=value",
            "release/decision.json\x00bundle",
            "release/decision.json\x7fbundle",
            "release/decision json",
        )
        for module in (SUBJECT, PUBLISH):
            for attack in attacks:
                with self.subTest(module=module.__name__, attack=repr(attack)):
                    with self.assertRaises(ValueError):
                        module.validated_relative_path(attack, "path")

    def test_traversal_and_oversized_components_are_rejected(self) -> None:
        for module in (SUBJECT, PUBLISH):
            for attack in ("../decision.json", "release//decision.json", "a" * 129 + "/x.json"):
                with self.assertRaises(ValueError):
                    module.validated_relative_path(attack, "path")

    def test_intermediate_symlink_cannot_redirect_subject_or_publication(self) -> None:
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            outside = root / "outside"
            artifacts = root / "artifacts"
            outside.mkdir()
            artifacts.mkdir()
            (outside / "subject.json").write_text("{}", encoding="utf-8")
            (artifacts / "redirect").symlink_to(outside, target_is_directory=True)
            relative = SUBJECT.validated_relative_path("redirect/subject.json", "subject")
            with self.assertRaises(OSError):
                descriptor = SUBJECT.open_beneath(artifacts, relative)
                __import__("os").close(descriptor)
            source = root / "source.bundle"
            source.write_bytes(b"bundle")
            with self.assertRaises(OSError):
                PUBLISH.publish(artifacts, source, PUBLISH.validated_relative_path("redirect/new.bundle", "destination"))
            self.assertFalse((outside / "new.bundle").exists())


if __name__ == "__main__":
    unittest.main()
