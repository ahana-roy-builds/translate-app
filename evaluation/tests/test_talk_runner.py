import contextlib
import io
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "scripts"))
import run_talk_tests as runner


class TalkRunnerTests(unittest.TestCase):
    def test_skipped_device_check_leaves_a_failed_report_even_when_xcode_succeeds(self):
        with tempfile.TemporaryDirectory() as tmp:
            args = ["run_talk_tests.py", "device", "--device", "fixture", "--output", tmp]

            def run_tests(command, log, env):
                self.assertTrue(all("-only-testing:" + name in command for name in runner.DEVICE))
                self.assertNotIn("TEST_RUNNER_SPEAK_DUET_LIVE_MIC", env)
                Path(command[command.index("-resultBundlePath") + 1]).mkdir()
                return 0

            def tool(command, **kwargs):
                output = json.dumps({"passedTests": 2, "failedTests": 0, "skippedTests": 1}) if command[0] == "xcrun" else ""
                return subprocess.CompletedProcess(command, 0, stdout=output)

            with patch.dict(runner.os.environ, {"TEST_RUNNER_SPEAK_DUET_LIVE_MIC": "1"}, clear=True), \
                 patch.object(sys, "argv", args), patch.object(runner, "run_logged", run_tests), \
                 patch.object(subprocess, "run", side_effect=tool), contextlib.redirect_stdout(io.StringIO()):
                self.assertEqual(runner.main(), 1)
            report = json.loads(next(Path(tmp).glob("device-*/summary.json")).read_text())
            self.assertEqual(report["result"], "failed")
            self.assertEqual(report["xctest"]["skippedTests"], 1)
