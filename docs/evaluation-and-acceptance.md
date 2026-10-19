# Evaluation and acceptance

The evaluation unit is a complete user turn, not only a model invocation. Measure capture, endpointing, ASR, translation, display, TTS, cancellation, and total time on release-qualification phones under realistic noise, accents, thermal state, and connectivity.

The starter English↔Spanish and English↔Japanese assets in [`evaluation/`](../evaluation/README.md) validate corpus plumbing and catch obvious text regressions. They are original synthetic examples, not a claim of production coverage or a replacement for expert review of regional Spanish and Japanese politeness/script behavior.

## Test-set design

Maintain three disjoint sets for every supported direction:

1. A versioned regression set available to developers.
2. A hidden release set scored by an evaluator or CI service to reduce tuning leakage.
3. A rolling field-challenge set sourced through explicit consent and rights review, or newly authored to represent observed failures without copying private conversation content.

Stratify by travel domain, utterance length, question/statement, politeness, names, numbers, time, currency, units, negation, code-switching, accent/dialect, speech rate, background noise, and speaker characteristics. Include adversarial prompt-like speech, repetition, silence, overlapping voices, wrong selected language, and out-of-support language. Never source text or audio merely because it is publicly reachable; document author, consent, permitted use, and retention.

Human raters should be bilingual in the tested variety. Use at least two independent ratings for safety-critical and hidden-release cases, adjudicate material disagreement, randomize/blind model identity, and record rater guidance. Ratings include meaning preservation, fluency, terminology, tone/politeness, and whether a traveler could safely act on the result.

## Metrics

- ASR: normalized word or character error rate by language, plus deletion of critical entities and hallucination on silence/noise.
- Translation: chrF or COMET as a trend signal, paired with bilingual adequacy ratings and targeted critical-token assertions. A single reference or aggregate metric cannot establish correctness.
- TTS: bilingual intelligibility/transcription accuracy, naturalness, pronunciation of names/numbers, time-to-first-audio, and audio glitches.
- End to end: successful-turn rate, source/translation review rate, cancellation correctness, time to stable source text, time to visible translation, time to first synthesized audio, peak memory, download/install footprint, battery, and thermal behavior.
- Robustness: crash-free turns, empty/low-confidence handling, offline completion, interrupted download recovery, and corrupted-pack rejection.
- Equity: report metrics by relevant accent/dialect/noise/device strata; an aggregate pass cannot hide a materially failing group.

## Release gates

The machine-readable criteria live in [`evaluation/acceptance-criteria.json`](../evaluation/acceptance-criteria.json). Apply them independently to English→Spanish, Spanish→English, English→Japanese, and Japanese→English, then independently to Local Only and Online Quality for every release-qualification device tier. Auto needs an additional routing/fallback suite. Require:

- at least 200 hidden text turns, 20 speakers, and 30 minutes of speech spanning all required strata;
- 100% preservation/flagging of the curated emergency/allergy set, a 100%
  automated critical-check pass rate on the broader release set, and zero known
  severity-1 meaning inversions;
- mean chrF2 of at least 0.72 as a regression floor, median bilingual adequacy of at least 4/5, and no required stratum below 3.5/5;
- ASR WER at or below 20% (or the language-approved CER equivalent) overall, with at most 5% critical-entity deletion;
- silence/noise hallucination at or below 0.5% and wrong-language output at or below 1%;
- warm end-to-end p50 at most 1.5 seconds and p95 at most 3 seconds for a short turn, measured from endpoint detection to visible translation on the minimum release-qualification tier;
- peak memory, thermal, energy, storage, and time-to-first-audio within the versioned device budget; no crash, watchdog termination, or old-turn playback in the release suite;
- Local Only completion with all Apple-managed assets installed and zero content egress in network-deny/allow tests; Online Quality calls only the documented Cloud Run/Google allowlist and meets provider error/quota gates; Auto never contradicts its pre-turn route indicator or records before its local fallback is ready; Release/TestFlight contain no custom-model downloader or activatable experiment.

The current 96-cell contract requires iPhone 15 Pro, iPhone 16 Pro, and iPhone
17 Pro as release-qualification tiers. A completed and accepted matrix provides
evidence for those devices; it is not an installation-time allowlist. Any iPhone
that can install the iOS 26 build may launch the app, but the selected pair's
on-device capability and installed readiness must gate continuous conversation
and locally resolved turns. If a required component is unavailable, acceptance
requires a clear unavailable state, no local recording, and no Local Only
network fallback. Explicit Online Quality turns remain governed by their own
entitlement, consent, service, and network gates. Claims that other iOS 26
iPhones meet the same quality and performance budgets require additional
physical-device evidence.

These values are initial product gates, not universal definitions of safe
translation. Tighten or specialize them with user research and bilingual expert
input. V2 currently permits no waiver: any unmet gate is a no-go. A future
waiver protocol would need a separately authenticated owner, reason, affected
cohort, mitigated UX, expiry, and required approvals before the verifier could
accept it.

Starter text scoring produces component evidence only and always reports
`release_decision: false`. For the `release_language_direction` profile the
scorer additionally requires one exact direction, processing mode, registered
physical-device tier, artifact root, corpus, predictions file, device registry,
and release-identity digest. Mixed rows and insufficient corpus coverage fail.

The version-1 release-evidence validator is a local structural preflight only.
Its matrix separately covers isolated TestFlight and production environments.
It safely snapshots and hashes every report, corpus, and attachment below the
explicit artifact root; parses each category's typed metrics/checks; binds every
direction × resolved route × device-tier × environment cell to the criteria,
device registry, corpus, and live release identity; verifies referenced PCM
audio; reruns the pinned scorer; and independently applies typed/range
thresholds. It also binds the clean Git index bytes/modes, resolved app
version/build/config, actual Xcode version, exact Terraform plans and inputs,
planned backend contract, OCI subject, BuildKit provenance/materials, and
reviewed base image. It can never approve a release.

A production decision comes only from the signed version-2 finalizer. It
re-verifies stored GitHub OIDC/Sigstore bundles against a digest-pinned trust
policy and trusted root; requires allowed protected workflow identities; parses
strict typed corpus, iOS archive, backend, environment, plan, deployment, and
device-run predicates; and cross-binds their candidate ID, source tree, app
version/build, bundle/environment, executable, OCI digest, service revision,
domain, device registry, and timestamps. Every one of the 96
direction × route × device-tier × environment cells must be unique and present.
Quality, security, privacy, and operations approvals must be from four distinct
authenticated actors and bind the exact candidate and preflight digests before
the finalizer can emit `release_decision: approved`. Missing, reused,
unreachable, traversal, link-swapped, forged-digest, wrong-signer, mis-scoped,
below-threshold, unsigned-build, incomplete-approval, or experimental-LLM
evidence blocks release. Non-automated physical, human, legal, and signing
reports remain authenticated process attestations, not facts Python can observe
directly; protected workflows and accountable reviewers make those assertions
auditable rather than magically proving them.

## Change policy

Re-run the full release suite when changing the app, Apple framework/OS runtime,
audio capture, compiler, voice, release-qualification device set, backend
provider, or operating-system major version. If a custom model is introduced,
model weights, quantization, tokenizer, prompt/template, decoder, preprocessing,
VAD, pack, and runtime changes also trigger the full suite. Compare against
production and store aggregate/per-stratum results, digests, configuration,
evaluator version, device/OS, date, and approver.

Automatic rollback or release-halt triggers include a confirmed severity-1
mistranslation regression, content egress outside consent, a crash loop, a
license/rights problem, or a material safety-stratum drop. Keep the prior
compatible app/backend release available. Pack-signature rollback applies only
to a future custom-model system; Apple-managed asset rollback remains subject to
OS capabilities.
