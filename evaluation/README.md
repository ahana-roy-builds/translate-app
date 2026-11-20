# Bilingual evaluation harness

This directory provides a dependency-free JSONL corpus validator and reference-based scorer. The included English↔Spanish and English↔Japanese cases are short, original travel scenarios authored for these starter fixtures and marked `CC0-1.0`; they contain no copied dialogue, benchmark, or user conversation. They have not been certified by professional bilingual reviewers and are not sufficient for a launch decision.

## Layout

- `schema/case.schema.json`: formal corpus record shape, including optional consented-audio metadata.
- `schema/prediction.schema.json`: model/run output shape.
- `fixtures/starter.en-es.jsonl` and `fixtures/starter.en-ja.jsonl`: 20 original bidirectional travel turns per language pair, with critical phrase checks.
- `fixtures/safety-medications.jsonl`: focused multilingual medication-preservation regressions; it is not release-coverage evidence.
- `fixtures/predictions.example.jsonl` and `fixtures/predictions.en-ja.example.jsonl`: matching exact-reference smoke-test outputs.
- `acceptance-criteria.json`: executable starter thresholds plus human, speech, device, mode, privacy, and security release gates.
- `scripts/validate_corpus.py`: standard-library structural and provenance validation.
- `scripts/make_prediction_template.py`: creates one blank run record per case.
- `scripts/score_predictions.py`: chrF2, token F1, exact match, critical checks, latency, mode breakdown, and supported automated gates.
- `schema/release-evidence.schema.json`: machine-readable shape for production evidence manifests.
- `schema/category-report.schema.json`: common envelope for typed, scoped evidence reports.
- `schema/device-tier-registry.schema.json`: exact physical-device/OS registry shape.
- `scripts/validate_release_evidence.py`: artifact- and live-input-verifying decision across every direction, route, device tier, and TestFlight/production environment.

## Run the smoke test

From the repository root, run both pairs through the convenience target:

```sh
make -C evaluation smoke
```

Or run one pair directly:

```sh
python3 evaluation/scripts/validate_corpus.py evaluation/fixtures/starter.en-es.jsonl
python3 evaluation/scripts/score_predictions.py \
  evaluation/fixtures/starter.en-es.jsonl \
  evaluation/fixtures/predictions.example.jsonl \
  --criteria evaluation/acceptance-criteria.json \
  --profile starter_fixture
```

For Japanese, substitute `starter.en-ja.jsonl` and `predictions.en-ja.example.jsonl`. The Makefile sets `PYTHONDONTWRITEBYTECODE=1` so evaluation runs do not create repository artifacts.

The scorer exits zero only when records are valid and every supported automated
text gate passes. Its report always carries `release_decision: false`: a text
component pass is never a production approval. Omit `--criteria` for an
informational report. Use `--summary-only` in CI to omit per-case output.

To start a real run:

```sh
python3 evaluation/scripts/make_prediction_template.py \
  evaluation/fixtures/starter.en-es.jsonl \
  --processing-mode local_only \
  --output /tmp/predictions.jsonl
```

Fill every `prediction`, `latency_ms`, `model_build`, and `device`. Run local,
Online Quality, Auto-local, and Auto-online paths as separate artifacts even when
they share cases. Release scoring additionally requires a distinct run-identity
JSON for every direction × route × device × environment cell. It binds the app
commit/version/build, bundle and API domain, exact device/OS build, engine build,
and deployment environment. The release scorer verifies every referenced PCM
WAV byte/digest/duration and emits the only accepted `automated_text` report;
the final validator independently reopens the corpus and predictions and
recomputes its metrics.

## Growing the corpus safely

- Use one stable case ID forever. Correct a bad case with a reviewed change and record the corpus version; do not silently reuse an ID for a new meaning.
- Keep development, hidden release, and rolling challenge sets disjoint. Never commit the hidden set to a client-accessible artifact.
- Add bilingual human review and multiple acceptable references. Critical checks are regression tripwires, not semantic proof.
- Store audio only with explicit evaluation consent and documented rights. Use pseudonymous speaker IDs, a relative path, digest, duration, environment, and an external consent-record identifier; do not put a person's name/contact details in JSONL.
- Encrypt restricted audio at rest, narrowly control access, define deletion, and do not ship evaluation audio in the app.
- Balance domains and report accent/dialect, noise, speed, length, device, and other relevant strata without using tiny groups in a way that re-identifies speakers.
- Add negative tests for silence, non-speech, wrong language, prompt-like audio, overlap, truncation, and corrupted inputs. Those may use a sibling schema because they expect retry/rejection rather than a translation.

Reference-based scores are useful for regression detection, but bilingual adequacy and safety review remain mandatory. Apply the release gates independently to each direction and processing path; an online average cannot hide a Local Only failure or vice versa.

## Production release evidence

Create a private artifact directory and copy `device-tiers.example.json` to a
concrete registry inside it. The registry must name three distinct physical
iPhones, exact model identifiers, memory, OS version, and OS build; placeholders
are rejected. Generate an exhaustive non-passing manifest template:

```sh
make -C evaluation release-template OUTPUT=/secure/release-evidence.json
```

Fill every matrix cell with a different typed JSON report. Reports and every
attachment use normalized paths relative to an explicit artifact root. Absolute
paths, URI schemes, traversal, symlinks, nonexistent files, reused cell reports,
and digest mismatches are rejected. Cell reports bind their exact direction,
route, physical-device tier, criteria digest, device-registry digest, release
identity digest, and a real corpus file/digest. The validator independently
enforces the configured automated, corpus-coverage, human, speech, runtime,
privacy/security, and stability thresholds.

Global reports bind the same release identity and must contain every boolean
check named by `release_matrix.global_checks`, plus at least one real hashed
attachment. In particular, `release_build` is evidence for a signed distribution
archive and provisioning/signature inspection. The repository's unsigned
`ios-testflight-compile` and `ios-release-compile` targets are only compiler
sanity checks and cannot satisfy that category.

Supporting attachments cannot be reused between evidence reports, four approval
roles require distinct identities, and evidence older than 45 days is rejected.
Release prediction rows carry the bound `run_id`; every cell has a unique run
identity, and all routes/devices/environments for one language direction use the
same canonical corpus. Reusing audio bytes inside that corpus cannot inflate
speaker or duration coverage.
Non-automated reports remain human attestations protected by the private release
workflow; names and hashes are not cryptographic proof of the physical, legal,
signing, or bilingual work. Use access-controlled, append-only artifact storage
and independently authenticated approvals.

The manifest embeds the exact SHA-256 of `acceptance-criteria.json`, the resolved
iOS config and physical-device registry, backend build metadata and image
digests, and the reviewed Terraform plans, variable files, and backend configs.
`make release-preflight` consumes resolved configs emitted from the protected
build environment (not ignored local xcconfig files), requires a clean Git
checkout, reads the actual commit and Xcode version, hashes
the plan, uses `terraform show -json` to bind the deployed image/backend Apple
contract/API domain, and rejects any mismatch. Run it on the signing/release host:

```sh
make release-preflight \
  RELEASE_MANIFEST=/secure/release/release-evidence.json \
  ARTIFACT_ROOT=/secure/release \
  DEVICE_REGISTRY=inputs/device-tiers.json \
  IOS_RESOLVED_CONFIG=inputs/resolved-ios-config.json \
  TESTFLIGHT_IOS_RESOLVED_CONFIG=inputs/testflight-resolved-ios-config.json \
  TERRAFORM_PLAN=inputs/service.tfplan \
  TESTFLIGHT_TERRAFORM_PLAN=inputs/testflight-service.tfplan \
  TERRAFORM_BACKEND_CONFIG=inputs/production-backend.hcl \
  TESTFLIGHT_TERRAFORM_BACKEND_CONFIG=inputs/testflight-backend.hcl \
  TERRAFORM_VARIABLES=inputs/production.tfvars \
  TESTFLIGHT_TERRAFORM_VARIABLES=inputs/testflight.tfvars \
  TERRAFORM_PLAN_PROVENANCE=inputs/service.tfplan.provenance.json \
  TESTFLIGHT_PLAN_PROVENANCE=inputs/testflight-service.tfplan.provenance.json \
  BACKEND_BUILD_METADATA=inputs/backend-build-metadata.json \
  BACKEND_BASE_IMAGE='node:22-bookworm-slim@sha256:REVIEWED_DIGEST'
```

This v1 result always says `release_decision: false`. Production approval exists
only when `make release-finalize` verifies a signed v2 decision. The v2 chain
uses distinct protected attestation wrappers for build, hidden corpus, physical-
device lab, infrastructure/deployment, candidate assembly, four role approvals,
and final decision. Authenticated external producer jobs must first build/sign,
scan/publish, run devices, deploy, and query the control plane; the wrappers do
not perform those tasks. The finalizer parses every signed predicate, pins the
immutable GitHub repository/owner and workflow identities, checks trusted
signing-time order, verifies the complete 96-cell matrix, reopens the exact inner
BuildKit and Terraform provenance, and cross-binds source, iOS archive identity,
build ID, OCI index/runnable subject, canonical per-environment registry
manifests, Cloud Run control-plane revision, environment policy, and device
outputs. Local cells have null backend content-request fields and require zero
conversation-content egress; a content-free availability check outside the turn
is not misrepresented as content upload.

The JSON Schemas document transport shapes; the standard-library validators are
authoritative and fail closed. Missing hardware, cloud deployments, protected
environments, authenticated reviewers, or Sigstore bundles cannot be replaced
with example artifacts or self-authored production evidence.

See the canonical [decision log](../docs/decision-log.md) and
[release-trust contract](../docs/release-trust.md) for signer roles, producer
prerequisites, and the go/no-go boundary.

## Continuous speech on iPhone

The opt-in `ContinuousSpeechMatrixTests` feeds the checked-in synthetic WAV files at microphone speed. Build the LocalLingo scheme with `build-for-testing` for iOS, then run `python3 evaluation/scripts/run_continuous_matrix.py <xctestrun> <device-UDID> <result.xcresult>` from the repo root. The recordings and SHA-256 manifest are in the unit-test bundle. Use an unlocked development iPhone with the translation packs installed. The test downloads missing listening assets and rotates its own reservations while preserving the initial reservation set.

Use `--pairs en-US_es-ES,en-US_fr-FR` for the short comparison, `--shared` for the analyzer shared across turns, `--auto-speak` for the playback check, and `--reverse-primary --lifecycle` for a rapid reply, Pause, Resume and Stop with the participants swapped. Add `--bridge` for the Spanish station-near-the-bridge recording. Test output prefixed with `MATRIX` records source, target, both candidates, transcript, translation, participant, boundary-to-commit timing, review and replay outcome. Semantic grading requires comparing the stored message against the fixture's intended meaning.

Score a full device log with `python3 evaluation/scripts/score_continuous_matrix.py <log> --baseline <reviewed-baseline.json> --review <verification.json>`. The scorer reports newly observed text for review, missing turns, speaker and playback accuracy, and how many baseline successes were retained.
