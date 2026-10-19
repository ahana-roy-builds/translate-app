from __future__ import annotations

import hashlib
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]


class ReleaseWorkflowContractTests(unittest.TestCase):
    def test_embedded_script_pins_match_current_bytes(self) -> None:
        helper_paths = {
            "scripts/validate-attestation-subject.py", "scripts/publish-release-artifact.py",
        }
        verifier_paths = {
            "evaluation/scripts/verify_trusted_release.py",
            "evaluation/scripts/validate_release_evidence.py",
            "evaluation/scripts/score_predictions.py", "evaluation/scripts/validate_corpus.py",
            "evaluation/scripts/strict_json.py",
        }
        for workflow in sorted((ROOT / ".github" / "workflows").glob("release-*.yml")):
            contents = workflow.read_text(encoding="utf-8")
            pins = {script: digest for digest, script in re.findall(
                r"([a-f0-9]{64})  ([A-Za-z0-9_./-]+\.py)", contents
            )}
            required = helper_paths | (verifier_paths if workflow.name == "release-finalize.yml" else set())
            for script in required:
                self.assertEqual(
                    pins.get(script), hashlib.sha256((ROOT / script).read_bytes()).hexdigest(),
                    f"{workflow} has a stale or missing pin for {script}",
                )

    def test_finalizer_verifies_before_signing_and_before_publication(self) -> None:
        contents = (ROOT / ".github" / "workflows" / "release-finalize.yml").read_text(encoding="utf-8")
        positions = [
            contents.index("Verify the complete graph before signing"),
            contents.index("uses: actions/attest@"),
            contents.index("Verify the new signature before publication"),
            contents.index("Preserve verified finalizer bundle"),
        ]
        self.assertEqual(positions, sorted(positions))
        self.assertNotIn("make release-finalize", contents)
        self.assertEqual(contents.count("evaluation/scripts/verify_trusted_release.py \\"), 2)


if __name__ == "__main__":
    unittest.main()
