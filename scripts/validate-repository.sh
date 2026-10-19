#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root"

structural_only=false
if [[ "${1:-}" == "--structural-only" ]]; then
  structural_only=true
elif [[ $# -gt 0 ]]; then
  echo "usage: $0 [--structural-only]" >&2
  exit 2
fi

bash scripts/verify-no-sensitive-content.sh

python3 - <<'PY'
import hashlib
import json
import plistlib
import re
from pathlib import Path

for path in (
    Path("evaluation/acceptance-criteria.json"),
    Path("evaluation/schema/case.schema.json"),
    Path("evaluation/schema/prediction.schema.json"),
    Path("evaluation/schema/release-evidence.schema.json"),
    Path("evaluation/schema/device-tier-registry.schema.json"),
    Path("evaluation/schema/category-report.schema.json"),
    Path("evaluation/schema/run-identity.schema.json"),
    Path("evaluation/schema/trusted-artifact.schema.json"),
    Path("evaluation/schema/approval-v1.schema.json"),
    Path("evaluation/schema/attestation-predicates.schema.json"),
    Path("evaluation/schema/release-candidate-v2.schema.json"),
    Path("evaluation/schema/release-decision-v2.schema.json"),
    Path("evaluation/schema/trust-policy-v1.schema.json"),
    Path("ios/Resources/Assets.xcassets/AppIcon.appiconset/Contents.json"),
):
    json.loads(path.read_text(encoding="utf-8"))

for path in (
    Path("ios/Config/Info.plist"),
    Path("ios/Config/LocalLingo.Debug.entitlements"),
    Path("ios/Config/LocalLingo.Staging.entitlements"),
    Path("ios/Config/LocalLingo.PrivateBeta.entitlements"),
    Path("ios/Config/LocalLingo.TestFlight.entitlements"),
    Path("ios/Config/LocalLingo.Release.entitlements"),
    Path("ios/Resources/Online/PrivacyInfo.xcprivacy"),
    Path("ios/Resources/PrivateBeta/PrivacyInfo.xcprivacy"),
):
    with path.open("rb") as handle:
        plistlib.load(handle)

with Path("ios/Config/LocalLingo.Release.entitlements").open("rb") as handle:
    release_entitlements = plistlib.load(handle)
if release_entitlements.get("com.apple.developer.devicecheck.appattest-environment") != "production":
    raise SystemExit("Release entitlement must hard-code production App Attest")
with Path("ios/Config/LocalLingo.TestFlight.entitlements").open("rb") as handle:
    testflight_entitlements = plistlib.load(handle)
if testflight_entitlements.get("com.apple.developer.devicecheck.appattest-environment") != "production":
    raise SystemExit("TestFlight entitlement must hard-code production App Attest")
with Path("ios/Config/LocalLingo.PrivateBeta.entitlements").open("rb") as handle:
    private_beta_entitlements = plistlib.load(handle)
if private_beta_entitlements:
    raise SystemExit("PrivateBeta must not require App Attest or another capability")
for path in Path("ios/Config").glob("*.entitlements"):
    with path.open("rb") as handle:
        entitlements = plistlib.load(handle)
    forbidden = {
        "com.apple.developer.icloud-container-identifiers",
        "com.apple.developer.icloud-services",
        "com.apple.developer.ubiquity-container-identifiers",
        "com.apple.developer.ubiquity-kvstore-identifier",
    }
    if forbidden.intersection(entitlements):
        raise SystemExit(f"{path} must not contain an iCloud capability in local-history v1")

with Path("ios/Resources/Online/PrivacyInfo.xcprivacy").open("rb") as handle:
    privacy_manifest = plistlib.load(handle)
collected = {
    row.get("NSPrivacyCollectedDataType")
    for row in privacy_manifest.get("NSPrivacyCollectedDataTypes", [])
}
required_privacy_types = {
    "NSPrivacyCollectedDataTypeAudioData",
    "NSPrivacyCollectedDataTypeOtherUserContent",
    "NSPrivacyCollectedDataTypeDeviceID",
    "NSPrivacyCollectedDataTypePurchaseHistory",
}
if not required_privacy_types.issubset(collected):
    raise SystemExit("Privacy manifest must disclose online content, device identity, and purchase state")
for row in privacy_manifest.get("NSPrivacyCollectedDataTypes", []):
    if row.get("NSPrivacyCollectedDataType") in required_privacy_types and row.get("NSPrivacyCollectedDataTypeLinked") is not True:
        raise SystemExit("Online content/identity/purchase disclosures must reflect pseudonymous backend linkage")
with Path("ios/Resources/PrivateBeta/PrivacyInfo.xcprivacy").open("rb") as handle:
    private_beta_privacy_manifest = plistlib.load(handle)
if private_beta_privacy_manifest.get("NSPrivacyCollectedDataTypes") != []:
    raise SystemExit("PrivateBeta privacy manifest must not declare off-device collection")
if private_beta_privacy_manifest.get("NSPrivacyTracking") is not False:
    raise SystemExit("PrivateBeta privacy manifest must disable tracking")
if private_beta_privacy_manifest.get("NSPrivacyTrackingDomains") != []:
    raise SystemExit("PrivateBeta privacy manifest must not declare tracking domains")

project = Path("ios/project.yml").read_text(encoding="utf-8")
if 'TARGETED_DEVICE_FAMILY: "1"' not in project or '"1,2"' in project:
    raise SystemExit("ios/project.yml must target iPhone only")
if "LocalLingo.entitlements" in project:
    raise SystemExit("ios/project.yml references the unsafe legacy entitlement file")
for name in ("Debug", "Staging", "PrivateBeta", "TestFlight", "Release"):
    if f"{name}: Config/{name}.xcconfig" not in project:
        raise SystemExit(f"ios/project.yml is missing {name} xcconfig wiring")
if "validate-ios-release-config.py" not in project:
    raise SystemExit("Release build is missing the fail-closed preflight")
private_beta = Path("ios/Config/PrivateBeta.xcconfig").read_text(encoding="utf-8")
local_override = private_beta.rfind('#include? "PrivateBeta.local.xcconfig"')
if local_override < 0:
    raise SystemExit("PrivateBeta must support an ignored signing override")
for setting in ("ONLINE_FEATURES_ENABLED = NO", "FACE_TO_FACE_ENABLED = NO", "LOCAL_LLM_EXPERIMENT = 0"):
    if private_beta.rfind(setting) < local_override:
        raise SystemExit(f"PrivateBeta must lock {setting} after its local override")
if "LocalLingo Private Beta:" not in project or "config: PrivateBeta" not in project:
    raise SystemExit("ios/project.yml is missing the shared PrivateBeta archive scheme")
if "PRIVACY_POLICY_URL = https:/$()/REPLACE_PRIVATE_BETA_PRIVACY_POLICY_URL" not in private_beta:
    raise SystemExit("PrivateBeta must fail closed until a public privacy policy is configured")
offline_privacy_exclusion = (
    'EXCLUDED_SOURCE_FILE_NAMES: "$(inherited) '
    '$(SRCROOT)/Resources/Online/PrivacyInfo.xcprivacy"'
)
online_privacy_exclusion = (
    'EXCLUDED_SOURCE_FILE_NAMES: "$(inherited) '
    '$(SRCROOT)/Resources/PrivateBeta/PrivacyInfo.xcprivacy"'
)
if project.count(offline_privacy_exclusion) != 2:
    raise SystemExit("Debug and PrivateBeta must exclude the online privacy manifest")
if project.count(online_privacy_exclusion) != 3:
    raise SystemExit("Staging, TestFlight, and Release must exclude the PrivateBeta privacy manifest")
if "CLOUDKIT_CONTAINER_IDENTIFIER" in project or "iCloud." in project:
    raise SystemExit("local-history v1 project must not contain an iCloud identifier")

info = plistlib.loads(Path("ios/Config/Info.plist").read_bytes())
if info["NSMicrophoneUsageDescription"] != "$(MICROPHONE_USAGE_DESCRIPTION)":
    raise SystemExit("Microphone disclosure must be selected by build configuration")
base_config = Path("ios/Config/Base.xcconfig").read_text(encoding="utf-8")
if "MICROPHONE_USAGE_DESCRIPTION" not in base_config or "not sent off this iPhone" not in base_config:
    raise SystemExit("Offline configurations must disclose on-device-only microphone processing")
for path in (
    Path("ios/Config/Staging.xcconfig"),
    Path("ios/Config/TestFlight.xcconfig"),
    Path("ios/Config/Release.xcconfig"),
):
    config = path.read_text(encoding="utf-8")
    if "MICROPHONE_USAGE_DESCRIPTION" not in config or "Online Quality" not in config or "Google" not in config:
        raise SystemExit(f"{path} must disclose Online Quality and Google processing")

service = Path("infra/service/main.tf").read_text(encoding="utf-8")
for invariant in (
    'ingress             = "INGRESS_TRAFFIC_INTERNAL_LOAD_BALANCER"',
    'timeout                          = "20s"',
    'max_instance_request_concurrency = 8',
    'memory = "1Gi"',
    'version = env.value.version',
    'can(regex("@sha256:[a-f0-9]{64}$", var.container_image))',
    'min_tls_version = "TLS_1_2"',
    'expression = "request.query != \'\'"',
    '"ALLOWED_APP_BUNDLE_VERSIONS"',
    '"APPLE_IAP_SIGNING_KEY_P8"',
    'CHALLENGE_POOL_REQUESTS_PER_MINUTE',
    'SESSION_ATTEMPTS_PER_MINUTE',
    'STOREKIT_SESSION_CONCURRENCY',
    'STOREKIT_SESSION_MAXIMUM_OUTSTANDING',
    'STOREKIT_NOTIFICATION_CONCURRENCY',
    'STOREKIT_NOTIFICATION_MAXIMUM_OUTSTANDING',
    'name  = "RELEASE_BUILD_ID"',
    'name  = "BACKEND_OCI_DIGEST"',
    "'/v2/devices/replace-oldest'",
    'lookup(var.non_sensitive_env, "GOOGLE_STT_LOCATION", "") == "us"',
    'lookup(var.non_sensitive_env, "GOOGLE_TRANSLATION_LOCATION", "") == "us-central1"',
):
    if invariant not in service:
        raise SystemExit(f"infra/service lost production invariant: {invariant}")
if 'version = "latest"' in service or "INGRESS_TRAFFIC_ALL" in service:
    raise SystemExit("infra/service contains an unsafe secret version or ingress policy")

bootstrap = Path("infra/bootstrap/main.tf").read_text(encoding="utf-8")
for collection in (
    "app_attest_challenges",
    "app_attest_session_challenges",
    "challenge_pool_quotas",
    "online_quotas",
    "online_sessions",
    "session_attempt_quotas",
    "storekit_notification_deduplication",
):
    if f'"{collection}"' not in bootstrap:
        raise SystemExit(f"infra/bootstrap is missing TTL for {collection}")
bootstrap_variables = Path("infra/bootstrap/variables.tf").read_text(encoding="utf-8")
reviewed_secrets = {
    "apple-app-attest-root-ca-pem", "apple-iap-signing-key-p8", "apple-storekit-root-ca-pems",
}
for secret in reviewed_secrets:
    if bootstrap_variables.count(f'"{secret}"') != 2:
        raise SystemExit("bootstrap secret_ids must default to and validate the exact reviewed secret set")
if "condition = var.secret_ids == toset([" not in bootstrap_variables:
    raise SystemExit("bootstrap secret_ids must reject missing or additional secret access")

for stack in ("bootstrap", "service"):
    versions = Path(f"infra/{stack}/versions.tf").read_text(encoding="utf-8")
    if 'required_version = "= 1.15.7"' not in versions or 'version = "= 7.34.0"' not in versions:
        raise SystemExit(f"infra/{stack} must pin the reviewed Terraform/provider versions exactly")
    if 'backend "gcs" {}' not in versions:
        raise SystemExit(f"infra/{stack} must use the partial GCS backend")
    if not Path(f"infra/{stack}/.terraform.lock.hcl").is_file():
        raise SystemExit(f"infra/{stack} is missing its reviewed provider lock")

attest_sha = "actions/attest@59d89421af93a897026c735860bf21b6eb4f7b26"
helper_paths = {
    "scripts/validate-attestation-subject.py",
    "scripts/publish-release-artifact.py",
}
verifier_paths = {
    "evaluation/scripts/verify_trusted_release.py",
    "evaluation/scripts/validate_release_evidence.py",
    "evaluation/scripts/score_predictions.py",
    "evaluation/scripts/validate_corpus.py",
    "evaluation/scripts/strict_json.py",
}
semver_guard = r'^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+([-+][A-Za-z0-9.-]+)?$'
for name in ("release-build", "release-corpus", "release-device", "release-infrastructure", "release-candidate", "release-approval", "release-finalize"):
    path = Path(f".github/workflows/{name}.yml")
    contents = path.read_text(encoding="utf-8")
    if attest_sha not in contents or "workflow_dispatch:" not in contents or "environment:" not in contents:
        raise SystemExit(f"{path} must use the pinned attestation action behind a protected environment")
    if semver_guard not in contents or "/usr/bin/python3 -I" not in contents or "printf 'path=%s\\n'" not in contents:
        raise SystemExit(f"{path} must use the exact tag guard, isolated interpreter, and injection-safe output")
    required_pins = helper_paths | (verifier_paths if name == "release-finalize" else set())
    found = {script: digest for digest, script in re.findall(r"([a-f0-9]{64})  ([A-Za-z0-9_./-]+\.py)", contents)}
    for script in required_pins:
        expected = hashlib.sha256(Path(script).read_bytes()).hexdigest()
        if found.get(script) != expected:
            raise SystemExit(f"{path} does not pin current bytes for {script}")
    if "sha256sum -c -" not in contents and "/usr/bin/shasum -a 256 -c -" not in contents:
        raise SystemExit(f"{path} must verify script pins before execution")
finalizer = Path(".github/workflows/release-finalize.yml").read_text(encoding="utf-8")
ordered = [
    finalizer.index("Verify the complete graph before signing"),
    finalizer.index("uses: actions/attest@"),
    finalizer.index("Verify the new signature before publication"),
    finalizer.index("Preserve verified finalizer bundle"),
]
if ordered != sorted(ordered) or "make release-finalize" in finalizer:
    raise SystemExit("finalizer must pre-verify, sign, post-verify, then exclusively publish")
for wrapper in ("scripts/terraform-plan.sh", "scripts/terraform-apply.sh"):
    text = Path(wrapper).read_text(encoding="utf-8")
    if "TF_DATA_DIR" not in text or "validate-terraform-backend.py" not in text or "terraform-input-identity.py" not in text:
        raise SystemExit(f"{wrapper} must isolate Terraform data and bind exact backend/input identity")
if "release_decision: false" not in Path("evaluation/README.md").read_text(encoding="utf-8"):
    raise SystemExit("evaluation documentation must say unsigned preflight is non-approving")
PY

if [[ "$structural_only" == false && -d backend/node_modules ]]; then
  npm --prefix backend run check
  npm --prefix backend test
elif [[ "$structural_only" == false ]]; then
  echo "backend/node_modules is absent; run 'npm install' in backend for TypeScript validation." >&2
fi

if [[ "$structural_only" == false ]]; then
  make -C evaluation validate test smoke
fi

echo "Repository validation completed."
