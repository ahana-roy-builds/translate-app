"""Run a locally built whisper.cpp adapter inside a disposable signed test host on iPhone."""
import argparse
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile

p = argparse.ArgumentParser(description=__doc__)
p.add_argument("xctestrun", type=Path)
p.add_argument("adapter", type=Path)
p.add_argument("device")
p.add_argument("identity", help="Apple Development signing identity for the existing Debug host")
p.add_argument("result", type=Path)
p.add_argument("--clean-up", action="store_true", help="Remove this trial's staged files after a successful benchmark")
args = p.parse_args()
original = args.xctestrun.resolve()
with tempfile.TemporaryDirectory(prefix="duet-hindi-") as scratch:
    root = Path(scratch)
    spec = plistlib.loads(original.read_bytes())
    target = spec["LocalLingoTests"]
    prefix = "__TESTROOT__/"
    host_path = target["TestHostPath"]
    if not host_path.startswith(prefix):
        p.error("Expected the generated device test specification with a relative test host")
    host = Path(host_path[len(prefix):])
    app = root / host
    app.parent.mkdir(parents=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", original.parent / host], check=True)
    subprocess.run(["ditto", original.parent / host, app], check=True)
    adapter = app / "Frameworks" / "libHindiModelTrial.dylib"
    adapter.parent.mkdir(exist_ok=True)
    shutil.copyfile(args.adapter, adapter)
    sign = ["codesign", "--force", "--timestamp=none", "--sign", args.identity]
    subprocess.run(sign + [adapter], check=True)
    subprocess.run(sign + ["--preserve-metadata=entitlements,identifier,requirements,flags", app], check=True)
    subprocess.run(["codesign", "--verify", "--deep", "--strict", app], check=True)
    target.setdefault("EnvironmentVariables", {})["HINDI_MODEL_TRIAL"] = "1"
    if args.clean_up:
        target["EnvironmentVariables"]["HINDI_MODEL_CLEANUP"] = "1"
    config = root / "Trial.xctestrun"
    config.write_bytes(plistlib.dumps(spec))
    subprocess.run(["xcodebuild", "test-without-building", "-xctestrun", config,
                    "-destination", f"platform=iOS,id={args.device}", "-parallel-testing-enabled", "NO",
                    "-only-testing:LocalLingoTests/HindiModelTrialTests/testMatchedHindiAudio",
                    "-resultBundlePath", args.result], check=True)
