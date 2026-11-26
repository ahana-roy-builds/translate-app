#!/usr/bin/env python3
"""Run the opt-in XCTest matrix from source or an existing build-for-testing bundle."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile

parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("xctestrun", type=Path, nargs="?", help="Optional existing build-for-testing specification")
parser.add_argument("device")
parser.add_argument("result", type=Path)
parser.add_argument("--pairs", help="Comma-separated primary_secondary locale pairs")
parser.add_argument("--shared", action="store_true", help="Compare the shared analyzer")
parser.add_argument("--bridge", action="store_true", help="Use the Spanish bridge recording for the first Spanish turn")
parser.add_argument("--auto-speak", action="store_true")
parser.add_argument("--reverse-primary", action="store_true", help="Swap the participants after filtering pairs")
parser.add_argument("--lifecycle", action="store_true", help="Exercise a fast reply, Pause, Resume, and Stop")
args = parser.parse_args()
root = Path(__file__).resolve().parents[2]
if args.xctestrun:
    original = args.xctestrun.resolve()
    data = plistlib.loads(original.read_bytes())
    target = data["LocalLingoTests"]
    host = target["TestHostPath"].replace("__TESTROOT__", str(original.parent))
    test_bundle = Path(target["TestBundlePath"].replace("__TESTHOST__", host).replace("__TESTROOT__", str(original.parent)))
    fixtures = test_bundle / "continuous-speech"
else:
    fixtures = root / "evaluation/fixtures/continuous-speech"
manifest = json.loads((fixtures / "rows.json").read_text())
for row in manifest:
    recording = fixtures / f"{row['code']}-{row['idx']}.wav"
    if hashlib.sha256(recording.read_bytes()).hexdigest() != row["sha256"]:
        parser.error(f"Recording does not match the fixture manifest: {recording.name}")
env = {}
env["SPEECH_MATRIX"] = "1"
if args.pairs:
    env["SPEECH_PAIRS"] = args.pairs
if args.shared:
    env["SPEECH_ANALYZER"] = "shared"
if args.bridge:
    env["SPEECH_BRIDGE"] = "1"
if args.auto_speak:
    env["SPEECH_AUTO_PLAY"] = "1"
if args.reverse_primary:
    env["SPEECH_REVERSE_PRIMARY"] = "1"
if args.lifecycle:
    env["SPEECH_LIFECYCLE"] = "1"
common = ["-destination", f"platform=iOS,id={args.device}", "-parallel-testing-enabled", "NO",
          "-collect-test-diagnostics", "never",
          "-only-testing:LocalLingoTests/ContinuousSpeechMatrixTests/testRecordedConversations",
          "-resultBundlePath", os.fspath(args.result.resolve())]
if args.xctestrun:
    target.setdefault("EnvironmentVariables", {}).update(env)
    # Xcode resolves __TESTROOT__ relative to the run specification.
    with tempfile.NamedTemporaryFile(dir=original.parent, suffix=".xctestrun") as config:
        config.write(plistlib.dumps(data))
        config.flush()
        subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", config.name, *common], check=True)
else:
    environment = {**os.environ, **{"TEST_RUNNER_" + key: value for key, value in env.items()}}
    subprocess.run(["xcodebuild", "test", "-project", "ios/LocalLingo.xcodeproj", "-scheme", "LocalLingo",
                    "-configuration", "Debug", "-onlyUsePackageVersionsFromResolvedFile", *common],
                   cwd=root, env=environment, check=True)
