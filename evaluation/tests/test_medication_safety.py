from __future__ import annotations

import sys
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "scripts"))
from score_predictions import score_cases  # noqa: E402
from validate_corpus import load_and_validate  # noqa: E402


class MedicationSafetyFixtureTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.cases, errors = load_and_validate([ROOT / "fixtures" / "safety-medications.jsonl"])
        if errors:
            raise AssertionError(errors)

    def predictions(self, text_for) -> list[dict]:
        return [{"id": case["id"], "prediction": text_for(case), "latency_ms": 1,
            "model_build": "safety-test", "device": "iPhone16,1", "processing_mode": "local_only"}
            for case in self.cases]

    def test_preserved_common_medications_pass_required_checks(self) -> None:
        rows, missing, extra = score_cases(self.cases, self.predictions(lambda case: case["references"][0]))
        self.assertEqual((missing, extra), ([], []))
        self.assertTrue(all(row["critical_checks_passed"] == row["critical_checks_total"] for row in rows))

    def test_substituted_medication_fails_required_check(self) -> None:
        rows, _, _ = score_cases(self.cases, self.predictions(lambda _case: "water only"))
        self.assertTrue(all(row["critical_checks_passed"] < row["critical_checks_total"] for row in rows))

    def test_omitted_medication_fails_required_check(self) -> None:
        rows, _, _ = score_cases(self.cases, self.predictions(lambda _case: "I took it earlier"))
        self.assertTrue(all(row["critical_checks_passed"] < row["critical_checks_total"] for row in rows))


if __name__ == "__main__":
    unittest.main()
