#!/usr/bin/env python3
"""Run Speak Duet conversation tests locally or in CI and retain the evidence."""
import argparse
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile

from score_continuous_matrix import compare, quality_issues, reviewed_labels, verification_runs

ROOT = Path(__file__).resolve().parents[2]
SCRIPTS = ROOT / "evaluation/scripts"
BASELINE = ROOT / "work/all-language-iphone-evidence-2026-11-19.json"
REVIEW = ROOT / "work/continuous-translation-verification-2026-11-19.json"
COORD = "LocalLingoTests/ContinuousConversationCoordinatorTests/"
UI = "LocalLingoUITests/OnboardingJourneyTests/"
SILENCE = COORD + "testInstalledHindiEnglishListenerPausesAndResumesAfterSilentAudio"
SPANISH = COORD + "testInstalledAppleModelsTranslateRecordedPausesOnDevice"
ACOUSTIC = COORD + "testHindiAndEnglishPhysicalMicrophoneReopensAfterAutoSpeak"
QUEUED = "LocalLingoTests/ContinuousSpeechRecognitionPolicyTests/testQueuedHindiAndEnglishTurnsUseSeparateSpeechContextsOnDevice"
MIXED = "LocalLingoTests/ContinuousSpeechRecognitionPolicyTests/testRecordedHindiTurnsKeepEmbeddedEnglishOnDevice"
SIMULATOR = [
    COORD.rstrip("/"), "LocalLingoTests/ContinuousTalkPresentationTests",
    "LocalLingoTests/ContinuousTranscriptPresentationTests", "LocalLingoTests/VoiceActivityBoundaryDetectorTests",
    "LocalLingoTests/ContinuousSpeechRecognitionPolicyTests", "LocalLingoTests/LanguagePackManagerTests",
    "LocalLingoTests/EntityIntegrityTests", "LocalLingoTests/PlaybackCallbackStateTests",
    UI + "testSplitLayoutCanSwitchAndExpiredAccessStillShowsPaywall",
    UI + "testMissingLanguagesKeepTalkVisibleUntilSetupIsRequested",
    UI + "testTranslationOnlyWarningIsRecheckedWhenTheMicIsTapped",
    UI + "testReopenLanguagePacksAndSpanishDetailsFromSettings",
    UI + "testDownloadAndReleaseHindiFromDetails",
]
MIXED_EXCHANGE = COORD + "testInstalledModelsTranslateMixedSpeechAtPauseOnDevice"
DEVICE = [SILENCE, SPANISH, QUEUED, MIXED, MIXED_EXCHANGE]
LIVE = [ACOUSTIC, "LocalLingoTests/AudioLifecycleTests/testDelayedNotificationsCannotStopReopenedPhysicalMicrophone",
        UI + "testRelayControlsDuringLiveConversation"]


def run_logged(command, log_path, env):
    print(f"Running {command[0]}. Log: {log_path}", flush=True)
    with log_path.open("w") as log, subprocess.Popen(
        command, cwd=ROOT, env=env, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
        text=True, errors="replace",
    ) as proc:
        for line in proc.stdout:
            log.write(line)
            if "LIVE_MIC_READY" in line:
                print(line.strip(), flush=True)
                # The microphone test asks the Mac to act as an external speaker.
                language = line.strip().split()[-1]
                if language in ("hi-IN", "en-US"):
                    subprocess.run(["afplay", ROOT / f"evaluation/fixtures/continuous-speech/{language}-0.wav"], check=True)
            elif line.startswith(("Test Suite", "MATRIX_PAIR", "** ")) or "error:" in line:
                print(line.rstrip(), flush=True)
        return proc.wait()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("suite", choices=["simulator", "device", "matrix", "live"])
    parser.add_argument("--device", help="UDID of an unlocked development iPhone")
    parser.add_argument("--simulator", default="platform=iOS Simulator,name=iPhone 17,OS=latest",
                        help="Xcode destination for the simulator suite")
    parser.add_argument("--output", type=Path, default=ROOT / "evaluation/results/talk",
                        help="Parent directory for unique run folders")
    parser.add_argument("--pairs", help="Matrix subset, for example en-US_es-ES,en-US_hi-IN")
    parser.add_argument("--auto-speak", action="store_true", help="Enable automatic playback in the matrix")
    args = parser.parse_args()
    if args.suite != "simulator" and not args.device:
        parser.error("Supply --device IPHONE_UDID for a physical run.")
    if args.suite == "simulator" and args.device:
        parser.error("--device selects a physical suite only.")
    if args.suite != "matrix" and (args.pairs or args.auto_speak):
        parser.error("--pairs and --auto-speak apply to the matrix suite.")
    if args.suite == "simulator" and not args.simulator.startswith("platform=iOS Simulator,"):
        parser.error("--simulator must be an iOS Simulator destination.")

    pairs = args.pairs.split(",") if args.pairs else None
    if args.suite == "matrix":
        baseline = json.loads(BASELINE.read_text())
        if pairs:
            unknown = set(pairs) - {row["pair"] for row in baseline["spoken"]}
            if unknown:
                parser.error(f"Unknown canonical fixture pairs: {', '.join(sorted(unknown))}")

    results = args.output.resolve()
    results.mkdir(parents=True, exist_ok=True)
    run = Path(tempfile.mkdtemp(prefix=args.suite + "-", dir=results))
    print(f"Results: {run}", flush=True)
    revision = subprocess.run(["git", "rev-parse", "HEAD"], cwd=ROOT, capture_output=True, text=True)
    tracked = subprocess.run(["git", "diff", "--quiet", "HEAD"], cwd=ROOT)
    source = {"commit": revision.stdout.strip() or None, "trackedChanges": tracked.returncode == 1}
    subprocess.run(["xcodegen", "generate"], cwd=ROOT / "ios", check=True)
    env = {key: value for key, value in os.environ.items()
           if not key.startswith(("TEST_RUNNER_SPEECH_", "TEST_RUNNER_SPEAK_DUET_LIVE_MIC"))}
    bundle = run / "tests.xcresult"
    log = run / "xcodebuild.log"
    destination = args.simulator if args.suite == "simulator" else f"platform=iOS,id={args.device}"
    if args.suite == "matrix":
        command = [sys.executable, SCRIPTS / "run_continuous_matrix.py", args.device, bundle]
        if args.pairs:
            command += ["--pairs", args.pairs]
        if args.auto_speak:
            command += ["--auto-speak"]
    else:
        tests = {"simulator": SIMULATOR, "device": DEVICE, "live": LIVE}[args.suite]
        command = ["xcodebuild", "-project", "ios/LocalLingo.xcodeproj", "-scheme", "Speak Duet",
                   "-configuration", "Debug", "-destination", destination, "-parallel-testing-enabled", "NO",
                   "-onlyUsePackageVersionsFromResolvedFile", "-resultBundlePath", bundle, "test"]
        command.extend("-only-testing:" + test for test in tests)
        if args.suite == "simulator":
            command.extend("-skip-testing:" + test for test in [*DEVICE, ACOUSTIC])
        if args.suite == "live":
            env["TEST_RUNNER_SPEAK_DUET_LIVE_MIC"] = "1"

    exit_code = run_logged(command, log, env)
    issues = []
    if exit_code:
        issues.append(f"Xcode command exited with status {exit_code}.")
    if args.suite == "matrix":
        try:
            labels = reviewed_labels(verification_runs(json.loads(REVIEW.read_text())), baseline)
            score = compare(log, baseline, labels, pairs=pairs)
            (run / "matrix-score.json").write_text(json.dumps(score, indent=2, ensure_ascii=False) + "\n")
            print(f"Scored {score['observedTurns']}/{score['expectedTurns']} turns.")
            issues.extend(quality_issues(score))
        except (KeyError, ValueError) as error:
            issues.append(f"Could not score device evidence: {error}")

    summary = {}
    if bundle.is_dir():
        report = subprocess.run(["xcrun", "xcresulttool", "get", "test-results", "summary", "--path", bundle],
                                capture_output=True, text=True)
        if report.returncode == 0:
            summary = json.loads(report.stdout)
    if not summary:
        issues.append("No XCTest summary available; see xcodebuild.log.")
    passed, failed, skipped = (summary.get(key, 0) for key in ("passedTests", "failedTests", "skippedTests"))
    expected = {"device": len(DEVICE), "live": len(LIVE), "matrix": 1}.get(args.suite)
    if not passed or failed or skipped or (expected is not None and passed != expected):
        issues.append("The selected checks did not all pass. Open tests.xcresult for failures and skip reasons.")

    verdict = "failed" if issues else "passed"
    result = {"suite": args.suite, "result": verdict, "destination": destination, "source": source,
              "pairs": pairs, "autoSpeak": args.auto_speak, "issues": issues, "xctest": summary}
    (run / "summary.json").write_text(json.dumps(result, indent=2) + "\n")
    message = f"Speak Duet {args.suite} {verdict}. XCTest: {passed} passed, {failed} failed, {skipped} skipped."
    print(message, *issues, sep="\n")
    if os.environ.get("GITHUB_STEP_SUMMARY"):
        with open(os.environ["GITHUB_STEP_SUMMARY"], "a") as f:
            print(message, *issues, sep="\n", file=f)
    return int(bool(issues))


if __name__ == "__main__":
    sys.exit(main())
