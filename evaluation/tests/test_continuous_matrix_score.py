import json
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
from score_continuous_matrix import compare, quality_issues, reviewed_labels


class MatrixScoreTests(unittest.TestCase):
    def setUp(self):
        self.baseline = {
            "fixtures": [{"code": "en-US", "idx": "0", "text": "Hello"},
                         {"code": "es-ES", "idx": "0", "text": "Hola"}],
            "fixedLanguage": [], "cleanText": [], "spoken": [],
        }
        for source, target, text, output in [
            ("en-US", "es-ES", "Hello", "Hola"), ("es-ES", "en-US", "Hola", "Hello"),
            ("en-US", "hi-IN", "Hello", "नमस्ते"),
        ]:
            self.baseline["spoken"].append({
                "expected": source, "intended": target, "idx": "0", "asr": text, "output": output,
                "reviewedOutcome": {"correctSpeaker": True, "transcriptMeaning": True, "outputMeaning": True},
            })
        self.rows = [
            {"kind": "spoken", "expected": row["expected"], "intended": row["intended"], "idx": "0",
             "ref": row["asr"], "pair": "en-US_es-ES", "count": "1", "asr": row["asr"],
             "output": row["output"], "savedSource": row["expected"], "savedTarget": row["intended"],
             "side": "traveler" if row["expected"] == "en-US" else "local"}
            for row in self.baseline["spoken"][:2]
        ]

    def score(self):
        with tempfile.TemporaryDirectory() as tmp:
            log = Path(tmp) / "xcode.log"
            log.write_text("".join("MATRIX " + json.dumps(row) + "\n" for row in self.rows))
            return compare(log, self.baseline, reviewed_labels([], self.baseline), ["en-US_es-ES"])

    def test_partial_run_checks_only_selected_pair_but_requires_both_directions(self):
        self.assertFalse(quality_issues(self.score()))
        self.rows.pop()
        self.assertEqual(self.score()["missing"], [("es-ES", "en-US", "0")])
        self.rows.append(self.rows[0])
        with self.assertRaisesRegex(ValueError, "Duplicate"):
            self.score()

    def test_new_paraphrase_requires_review_and_known_loss_is_a_regression(self):
        self.rows[0]["output"] = "Buenos días"
        self.assertTrue(self.score()["needsReview"])
        self.assertFalse(self.score()["regressions"])
        self.baseline["cleanText"].append({"idx": "0", "target": "es-ES", "out": "Buenos días", "meaning": False})
        self.assertTrue(self.score()["regressions"])
        self.assertFalse(self.score()["needsReview"])

    def test_wrong_side_and_wrong_target_voice_fail_and_only_unresolved_speakers_skip_replay(self):
        self.rows[0]["side"] = "local"
        self.rows[0].update(autoVoice="en_US", lastSynthesizedText="Hola")
        replay = {"kind": "replay", "pair": "en-US_es-ES", "expected": "en-US", "error": "ineligible"}
        self.rows.extend([replay, dict(replay, entityMismatch="true"), dict(replay, unresolvedSpeaker="true")])
        result = self.score()
        self.assertEqual(len(result["routingErrors"]), 1)
        self.assertEqual(len(result["wrongPlayback"]), 3)
        self.assertTrue(quality_issues(result))
