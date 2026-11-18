# Product and architecture decision record

This document records the main choices made for the LocalLingo launch baseline,
the alternatives considered, and the conditions that should cause each choice
to be revisited. It complements the architecture, privacy, threat-model, and
release documents: those describe the operating contract, while this document
explains why that contract exists.

The initial baseline was recorded on 2026-07-12, and this record includes later
amendments through 2026-08-15. A decision marked **Accepted** is the selected
product or architecture direction; it does not by itself assert that every
implementation and assurance obligation is complete. **Deferred** means the
option was considered but is intentionally outside the production build.
**Open** means product, legal, quality, or field evidence is still required.
This record is not release approval; the launch checklist and machine-readable
evidence gate remain authoritative for release readiness.

## Adversarial findings and remediation

The 2026-07-12 adversarial review materially changed the baseline. The findings
were remediated in source rather than recorded as accepted risk:

- **D-10/D-17:** the stale-device history-resurrection path was removed with
  the entire CloudKit implementation, setting, identifier, and entitlement.
  V1 history is bounded, paged, validated, protected, and on-device only.
- **D-11:** Careful Mode now recognizes multilingual medication and emergency
  concepts, treats entity-extraction overflow as confirmation-required, and
  displays an explicit medical/emergency limitation.
- **D-07/D-08:** live StoreKit observations are intervals, signed
  notifications are event points, and overlapping terminal evidence wins a
  commutative merge. Notification deduplication and entitlement/session/device
  effects are atomic and verification work uses separate bounded lanes.
- **D-15/D-19:** the unsigned version-1 validator is only a structural
  preflight and always emits `release_decision: false`. Production approval is
  reserved for a version-2 finalizer that verifies GitHub OIDC/Sigstore bundles,
  immutable repository/owner and workflow identities, trusted signing times,
  strict typed predicates, exact inner build/plan evidence, candidate/binary/
  image/registry/deployment/device bindings, the complete 96-cell matrix, and
  four distinct digest-bound reviewers.

The same remediation added shared text/turn/entity/history bounds, explicit
post-speech recovery, background/memory/thermal cancellation, bidirectional
local readiness, versioned online consent, the hardware gate recorded in D-18,
and app/backend release-identity matching. D-20 later replaced that gate with
capability-driven device eligibility. These controls do not constitute launch
approval: real signed archives, hidden corpus, physical-device runs, protected
GitHub environments, deployment receipts, and accountable approvals are still
required by the launch checklist.

## Decision summary

| ID | Status | Decision |
| --- | --- | --- |
| D-01 | Accepted | Start with half-duplex, one-speaker-at-a-time conversation turns. |
| D-02 | Accepted | Launch narrowly with English↔Spanish and English↔Japanese. |
| D-03 | Accepted | Use Apple-managed on-device Speech, Translation, and TTS as the production local path. |
| D-04 | Deferred | Keep the custom few-billion-parameter MLX/Qwen engine research-only. |
| D-05 | Accepted | Offer explicit Local Only, Online Quality, and consented Auto modes. |
| D-06 | Accepted | Put Google speech/translation behind a first-party Cloud Run backend; keep TTS on-device. |
| D-07 | Legacy configurations | Make local use free and gate Online Quality with StoreKit Pro; superseded by D-22 for Speak Duet. |
| D-08 | Accepted | Authenticate installations with App Attest and short-lived backend sessions. |
| D-09 | Accepted | Keep conversation content out of backend persistence and application logs. |
| D-10 | Superseded | The earlier separate local/CloudKit history design is replaced by D-17. |
| D-11 | Accepted | Use confirmation-oriented safety UX instead of silently “correcting” translations. |
| D-12 | Accepted | Use Firestore only for bounded security, entitlement, quota, and replay state. |
| D-13 | Accepted | Deploy through Terraform to a protected US Google Cloud service boundary. |
| D-14 | Accepted | Treat production and TestFlight as isolated environments with fail-closed configuration. |
| D-15 | Accepted | Require reproducible automated evidence plus human bilingual, privacy, security, and release review. |
| D-16 | Accepted | Target iPhone and iOS 26 initially rather than supporting older Apple platforms. |
| D-17 | Accepted | Keep v1 history protected and on-device only; remove CloudKit sync. |
| D-18 | Superseded | D-20 replaces the former iPhone 15 Pro runtime floor; 15 Pro, 16 Pro, and 17 Pro remain the current release-qualification tiers. |
| D-19 | Accepted | Anchor release evidence in GitHub OIDC/Sigstore attestations and digest-bound approvals. |
| D-20 | Accepted | Let any iPhone that can install iOS 26 launch, then gate continuous and locally resolved recording on selected-pair capability and readiness. |
| D-21 | Accepted | Expose English-Hindi only as `Hindi (Beta)` in Debug and the offline Private Beta; omit it from standard TestFlight and Release until physical-device gates pass. |
| D-22 | Accepted | Speak Duet gates all new translation after a device-local free period, with one monthly subscription and optional Apple/Google accounts. |

## Detailed decisions

### D-01 — Turn-based conversation instead of simultaneous interpretation

**Status:** Accepted

**Considered:** simultaneous full-duplex interpretation, automatic
speaker-switching, voice-activity endpointing, press-and-hold, and explicit
tap-to-start/tap-to-finish turns.

**Decision:** The launch interaction is half-duplex. The traveler or local
speaker selects their language-labelled microphone, speaks one bounded turn,
then the app transcribes, translates, displays, optionally confirms, and speaks
the result before the other person responds. Typed repair phrases remain
available.

**Why:** Turn ownership, source language, privacy route, cancellation, and the
text being spoken are unambiguous. This also avoids echo/feedback, overlapping
ASR, accidental old-turn playback, and the false impression of conference-grade
live interpretation.

**Tradeoff:** The exchange is slower and less natural than simultaneous speech.

**Revisit when:** physical-device research demonstrates reliable duplex audio,
speaker attribution, endpointing, interruption, and safety behavior across the
minimum device tier and realistic travel noise.

### D-02 — Narrow initial language scope

**Status:** Accepted

**Considered:** a broad language picker, English↔Spanish only, and two
bidirectional pairs covering both Latin and Japanese scripts.

**Decision:** The initial product supports English (US)↔Spanish (Spain) and
English (US)↔Japanese (Japan), evaluated as four independent directions.

**Why:** Each direction needs offline asset verification, speech and translation
quality data, bilingual review, politeness/script review, safety cases, and
device performance evidence. A short list makes those obligations achievable
and exposes script/tokenization assumptions early.

**Tradeoff:** Spanish regional varieties and many common travel languages are
not yet represented.

**Revisit when:** every new direction has an owned corpus, bilingual reviewers,
critical-entity tests, installed-asset behavior, latency/device results, and an
explicit product limitation statement.

### D-03 — Apple-managed models for the production local path

**Status:** Accepted

**Considered:** shipping a custom ASR/translation/TTS stack, using a bundled or
downloaded few-billion-parameter LLM, relying on cloud translation only, and
using Apple system frameworks.

**Decision:** Production Local Only uses SpeechAnalyzer/SpeechTranscriber,
TranslationSession with high fidelity for manual turns and a user-selected low
latency or high-fidelity strategy for continuous sessions, with system fallback
where necessary, and installed AVSpeech voices. Apple manages the model assets
and their lifecycle.

**Why:** This gives a genuine offline conversation-content path without adding
model redistribution, tokenizer/runtime compatibility, pack signing,
multi-gigabyte download, thermal, memory, and rollback systems to the first
release. It also provides OS-integrated permissions and asset management.

**Tradeoff:** Apple controls availability and updates, exact model parameter
counts are not disclosed, supported hardware/languages vary, and LocalLingo
cannot tune or independently roll back those models. The product must not claim
a specific “few-billion-parameter” model based on this path.

**Revisit when:** Apple availability is insufficient for a target pair, field
quality misses the release threshold, or an app-managed model has demonstrably
better quality with acceptable licensing, size, latency, memory, energy,
thermal, security, and rollback evidence.

### D-04 — Custom MLX/Qwen model remains an internal experiment

**Status:** Deferred

**Considered:** making a quantized Qwen-class model the launch USP, bundling it
in the app, downloading it from a public model host, or providing only a guarded
research seam.

**Decision:** The repository contains a compile-time-excluded verification and
adapter seam, but no runnable MLX dependency, tokenizer, weights, downloader,
prompt adapter, or production route. Release, TestFlight, and Staging explicitly
reject the experiment flag.

**Why:** A model name and approximate parameter count do not establish traveler
translation quality or commercial redistribution rights. Shipping it safely
requires an immutable artifact, license decision, signed manifest, bounded
runtime, cancellation, atomic activation, rollback, and physical-device
evidence that do not yet exist.

**Tradeoff:** The launch differentiator is private offline behavior and careful
conversation UX, not ownership of a named local LLM.

**Revisit when:** all promotion requirements in
[Experimental local LLM](experimental-local-llm.md) are complete and the custom
engine beats the Apple baseline for each supported direction without weakening
privacy, reliability, or minimum-device support.

### D-05 — Explicit processing modes and immutable per-turn routing

**Status:** Accepted

**Considered:** invisible best-engine routing, cloud-first with automatic local
fallback, a single offline switch, and three explicit modes.

**Decision:** Local Only is a hard conversation-content boundary. Online
Quality is explicit and requires Pro plus disclosure/consent. Auto may choose an
online route only when entitled, connected, healthy, and consented. The route is
resolved and displayed before recording and remains immutable for that turn.

**Why:** A user cannot give meaningful consent if the route changes after they
start speaking. Immutable turn context also makes cancellation and history
eligibility testable.

**Tradeoff:** Auto is less aggressive about recovering from failures, and users
see more routing state than in a conventional translator.

**Revisit when:** never silently. A new fallback policy requires updated
disclosure, state-machine tests, traffic-capture evidence, and privacy approval.

### D-06 — First-party backend in front of Google; TTS remains local

**Status:** Accepted

**Considered:** calling Google directly from the app, running all three speech
stages in the cloud, operating first-party models, and proxying only the two
input-dependent stages.

**Decision:** Online audio goes to LocalLingo’s Cloud Run service, which calls US
regional Google Speech-to-Text and Cloud Translation. Translated text returns to
the phone and is spoken with an installed system voice.

**Why:** The backend keeps provider credentials out of the app and enforces App
Attest, StoreKit, quotas, input bounds, region, deadlines, and content-free
logging. Local TTS reduces returned data and keeps both modes’ playback behavior
consistent.

**Tradeoff:** The backend adds latency, cost, operational responsibility, and a
subprocessor/data-transfer boundary.

**Revisit when:** provider quality, regional guarantees, retention/terms,
latency, cost, or availability no longer meet the documented contract.

### D-07 — Free local conversations and paid Online Quality

**Status:** Accepted

**Considered:** paid app, turn credits, subscription for all use, advertising,
and free offline use with a subscription-backed online tier.

**Decision:** Local conversations are unlimited and free. Monthly and annual
StoreKit subscriptions unlock Online Quality and Auto-online behavior. Family
Sharing is not accepted initially. A subscription may bind at most three active
attested installations, with explicit current-device removal and
least-recently-used replacement recovery.

**Why:** Cloud processing has recurring cost while offline usefulness should not
depend on a server or recurring payment. StoreKit provides signed purchase
evidence and familiar subscription management.

**Tradeoff:** Device binding and live StoreKit verification add support and
backend complexity. Pricing and final product identifiers remain release inputs.

**Revisit when:** unit economics, App Store policy, user research, support load,
or Family Sharing requirements justify a different entitlement model.

### D-08 — App Attest plus short-lived sessions

**Status:** Accepted

**Considered:** an embedded API key, anonymous public endpoints, user accounts,
DeviceCheck only, per-request App Attest, and App Attest-derived sessions.

**Decision:** A registered App Attest key proves the installation. One-use,
purpose-scoped challenges bind assertions to the exact method, path, body,
locales, key, and session. A live StoreKit check establishes a 15-minute opaque
session; request challenge pools amortize secure-enclave and network work.

**Why:** LocalLingo does not otherwise need an account, and an embedded secret
would be extractable. The design limits replay and cost abuse while keeping
conversation requests pseudonymous.

**Tradeoff:** App Attest requires real devices and Apple availability, recovery
is complex, and attestation is not proof that a device or subscriber is benign.

**Revisit when:** abuse evidence shows the controls are insufficient, Apple
changes App Attest semantics, or cross-device account features create a genuine
need for user authentication.

### D-09 — No durable backend conversation content

**Status:** Accepted

**Considered:** server conversation history, analytics samples, support replay,
provider-only transient processing, and a strict request-lifetime content model.

**Decision:** The backend does not persist audio, source text, or translations
and does not place them in application logs, metrics, Firestore, or error
responses. Content exists only for the bounded provider request.

**Why:** Server history is unnecessary for the core conversation flow and would
materially increase breach, retention, access-control, deletion, and legal risk.

**Tradeoff:** Support and quality investigations cannot inspect user turns
unless a separate, explicit, previewed, consented support feature is designed.

**Revisit when:** any support, abuse, or opt-in research feature proposes content
collection; it requires a separate data-flow and retention decision first.

### D-10 — Two independent history choices, both off by default

**Status:** Superseded by D-17

**Considered:** no history, one shared history toggle, automatic iCloud sync,
backend accounts, and separate local/cloud choices.

**Decision:** Protected SwiftData history can save explicitly eligible local or
online turns on the iPhone. A separate opt-in may sync only Online Quality text
to the user’s private CloudKit database. Eligibility is captured per turn; Local
Only turns are never backfilled. Audio is never saved. Account-generation
capabilities prevent queued writes from crossing iCloud accounts.

**Why:** Local retention and network sync have different privacy consequences.
Separating them avoids turning a convenience setting into retroactive upload
consent.

**Tradeoff:** Merge, pagination, deletion, account-change, quota, and
multi-device race handling are substantially more complex.

**Outcome:** The adversarial review demonstrated a stale-device resurrection
path after physical record deletion. Because cross-device history is not part
of the core translation value, D-17 removes the feature instead of attempting a
late custom-zone migration. The Apple account owner must separately verify and
record the external-data/purge status before release.

### D-11 — Confirmation and critical-entity checks, not silent correction

**Status:** Accepted

**Considered:** always speak immediately, ask for confirmation on every turn,
have an LLM rewrite suspicious output, or flag targeted risky content.

**Decision:** Source and translated text remain visible. Low confidence,
warnings, and mismatches in numbers, money, time, dates, addresses, negation,
allergy, medication, and emergency terms enter Careful Mode. The user may edit
the source and retranslate. The app flags discrepancies but does not invent a
correction.

**Why:** Fluent output can still be dangerously wrong, while an automatic
“fix” can introduce another unsupported meaning. Visible review gives both
speakers a repair path.

**Tradeoff:** Some turns require extra interaction, and rule-based extraction
cannot establish semantic correctness.

**Revisit when:** bilingual safety studies justify different thresholds or a
new checker independently meets the safety and latency gates.

### D-12 — Firestore stores security metadata only

**Status:** Accepted

**Considered:** in-memory state, Redis, relational storage, client-only quotas,
and Firestore transactions with TTL.

**Decision:** Firestore stores App Attest registrations/counters, challenges,
session hashes, StoreKit entitlement observations, device bindings,
revocations, quotas, and notification IDs. Replay, quota, session, binding, and
revocation mutations use atomic or monotonic writes. It stores no conversation
content.

**Why:** Cloud Run instances are ephemeral and horizontally scaled, so security
state and cost controls must be shared. Firestore is already available in the
selected cloud and supports transactional compare/update behavior.

**Tradeoff:** Each protected request has state-store latency/cost and depends on
correct TTL, IAM, and transaction behavior.

**Revisit when:** measured cost or contention warrants another store without
weakening replay, quota, or atomicity guarantees.

### D-13 — Terraform-managed protected Google Cloud boundary

**Status:** Accepted

**Considered:** a direct public Cloud Run URL, manually configured cloud
resources, multiple clouds, and a load-balanced Cloud Run service managed as
code.

**Decision:** Terraform creates Cloud Run behind an external HTTPS load
balancer and Cloud Armor, with the direct Cloud Run URL excluded by ingress.
The runtime uses a dedicated least-privilege service account, numeric secret
versions, regional Google endpoints, bounded scaling, TLS policy, budgets,
alerts, and content-aware log exclusions.

**Why:** The edge must reject malformed/abusive traffic before expensive work,
and the deployed contract must be reviewable from an immutable plan.

**Tradeoff:** The architecture has more resources and operational ceremony than
a default Cloud Run deployment.

**Revisit when:** regional/legal requirements, provider architecture, traffic,
or incident evidence requires a different boundary.

### D-14 — Production/TestFlight isolation and fail-closed builds

**Status:** Accepted

**Considered:** one backend/project for every build, environment flags supplied
by the client, and distinct signed configurations with separate cloud state.

**Decision:** Production and TestFlight use distinct bundle IDs, StoreKit
products, API domains, GCP projects/services, plans, and GCS state prefixes.
Both use production App Attest; TestFlight uses StoreKit Sandbox. Committed
Release/TestFlight settings are placeholders. An authenticated build environment
must supply ephemeral values and emit the resolved configuration as evidence;
ignored local xcconfig files are compile-only and are never trusted inputs.

**Why:** Client-selectable environment values and shared state create spoofing,
test-data, entitlement, and release-evidence ambiguity.

**Tradeoff:** More Apple/GCP configuration and separate evidence are required.

**Revisit when:** only if Apple or Google platform constraints force a change,
with equivalent isolation demonstrated in the threat model and release gate.

### D-15 — Evidence-driven release rather than aggregate benchmark claims

**Status:** Accepted

**Considered:** unit tests only, one aggregate translation score, informal QA,
and an exhaustive direction×route×device×environment evidence matrix.

**Decision:** Release requires independently replayed corpus/prediction metrics,
real bounded WAV inputs, unique run identities, physical device tiers,
production/TestFlight isolation, signed-build evidence, infrastructure and
container provenance, and four authenticated quality, security, privacy, and
operations approvals. Bilingual and product/legal reviews feed those evidence
and checklist responsibilities but are not extra cryptographic signer roles.
Starter fixtures can test plumbing but always report that they are not a release
decision.

**Why:** Averages can hide a failing direction, route, device, accent, or safety
stratum. Machine validation catches structural forgery and drift; qualified
humans remain necessary for meaning, legal, privacy, and physical-device facts.

**Tradeoff:** Release is deliberately expensive and some human evidence is an
authenticated process attestation, not a fact Python can prove.

**Revisit when:** the matrix changes with product scope. V2 accepts no waiver;
any threshold reduction is a criteria/decision change and requires a new signed
candidate. A future waiver protocol would need an authenticated, owned, scoped,
and expiring predicate rather than a manifest note.

### D-16 — iPhone/iOS 26 launch target

**Status:** Accepted

**Considered:** older iOS speech APIs, iPad/Mac support, a cross-platform client,
and a modern iPhone-only baseline.

**Decision:** The project targets iPhone on iOS 26 and uses the current Speech
and Translation APIs. iPad, Mac Catalyst, Android, and older iOS compatibility
are outside the initial build.

**Why:** The chosen offline speech and higher-fidelity translation capabilities
are platform features, and narrowing platform/layout combinations makes
physical performance and safety testing tractable.

**Tradeoff:** The addressable installed base is smaller and high-fidelity
translation still varies by Apple Intelligence capability.

**Revisit when:** device-qualification field data is complete or another
platform has an owned local pipeline that meets the same privacy, quality,
cancellation, and release-evidence contract.

### D-17 — V1 history is on-device only

**Status:** Accepted

**Considered:** rebuilding CloudKit around a custom record zone and atomic
deletion epoch, retaining the unsafe default-zone implementation, shipping a
cleanup transition, removing history entirely, and keeping only protected
on-device history.

**Decision:** Remove CloudKit code, settings, UI, identifiers, and entitlements
from every build. SwiftData stores bounded, validated, text-only history only
after per-turn consent. Reads are paged; audio is never saved. Before release,
the Apple account owner must record whether any CloudKit container ever held
external data and preserve evidence that known non-production containers were
purged before capability removal. The repository contains no transition binary;
that is acceptable only after the owner records a no-user-data conclusion.

**Why:** Cross-device history is not required for the conversation USP, while a
privacy-correct multi-device delete protocol would materially increase launch
risk and physical-test scope.

**Tradeoff:** Users cannot share history between devices. Adding sync later is
a new trust-boundary decision and cannot reuse the removed default-zone design.

**Revisit when:** user research establishes substantial demand and a custom-zone
protocol proves atomic write/delete ordering, durable tombstones, account
isolation, migration, and multi-device behavior on physical devices.

### D-18 — iPhone 15 Pro is the minimum device

**Status:** Superseded by D-20

**Considered:** every iPhone capable of iOS 26, iPhone 14 and newer, and an
Apple-Intelligence-capable iPhone 15 Pro baseline.

**Decision:** The former V1 baseline supported iPhone 15 Pro and newer. The
release-evidence contract named iPhone 15 Pro, iPhone 16 Pro, and iPhone 17 Pro
as minimum, intermediate, and current physical tiers. D-20 removes that runtime
floor while retaining those devices as the current release-qualification set.

**Why:** The rationale was that a modern hardware floor would make local-model
availability, memory, latency, thermal, and long-session validation tractable
without silently promising an unmeasured fallback experience on older devices.

**Tradeoff:** The addressable installed base would be smaller.

**Revisit when:** physical evidence shows an older tier meets the same offline,
quality, latency, memory, energy, thermal, and lifecycle contract.

### D-19 — GitHub OIDC/Sigstore is the release trust anchor

**Status:** Accepted

**Considered:** unsigned JSON evidence, an organization-held offline signing
key, upstream keyless Sigstore, and GitHub Artifact Attestations backed by
GitHub Actions OIDC.

**Decision:** Protected, commit-pinned GitHub attestation wrappers issue stored
Sigstore bundles for pre-existing build, corpus, device, infrastructure,
deployment, and approval predicates. Authenticated producer environments still
have to build/sign the app, build/scan/publish the image, run physical devices,
and deploy/query infrastructure; the wrappers do not perform that work. The
finalizer pins repository/workflow/environment identity and requires four
distinct digest-bound approvals. The trust policy also pins the immutable
numeric GitHub repository and owner IDs, and the finalizer orders evidence,
candidate, approval, and finalization using cryptographically verified signing
times rather than workflow-controlled predicate timestamps. Structural v1
fixtures can never emit a production approval.

**Why:** The public repository can use GitHub Artifact Attestations without a
long-lived release key, and workflow identity makes evidence provenance
independently verifiable.

**Tradeoff:** Production release depends on protected GitHub environments,
OIDC, an authenticated physical-device runner, and preserved verification
bundles.

**Revisit when:** repository visibility/hosting changes, GitHub trust semantics
change, or an offline/air-gapped release process becomes mandatory.

### D-20 — Device eligibility follows OS and runtime capabilities

**Status:** Accepted

**Considered:** retaining the iPhone 15 Pro floor, extending a generation-based
allowlist to older devices, and using the iOS deployment target plus direct
Apple-framework capability and readiness checks.

**Decision:** Any iPhone that can install the iOS 26 build may launch
LocalLingo. The app does not use marketing names or model identifiers as a
runtime allowlist. Before continuous conversation begins or a locally resolved
turn records audio, it checks on-device Listen capability for both selected
languages and Translation capability and installed readiness in both
directions. The applicable Start control remains unavailable when a required
component is unsupported or not ready, and Local Only never substitutes an
online request. Explicit Online Quality turns use their own route-specific
gates. High Fidelity is a requested Translation strategy rather than a device
requirement; iOS may use its traditional low-latency path when Apple
Intelligence is unavailable.

The current release contract requires iPhone 15 Pro, iPhone 16 Pro, and iPhone
17 Pro as three physical qualification tiers. A completed and accepted matrix
would establish quality and performance on those devices; it is not an
installation allowlist or proof that every iOS 26 iPhone meets the same budgets.

**Why:** A marketing-model threshold is only a proxy for the Apple framework
capabilities the app actually needs. Direct pre-capture checks describe the
selected pair accurately and allow system fallback behavior without silently
changing Local Only's privacy boundary.

**Tradeoff:** An install-eligible phone may expose fewer ready language pairs or
miss the latency, memory, energy, thermal, or long-session budgets required of
the current qualification tiers. Launch eligibility therefore does not imply
High Fidelity availability or production qualification for every device/pair.

**Revisit when:** a broader device claim is backed by capability-negative,
offline, quality, latency, memory, energy, thermal, and lifecycle evidence on
the additional physical-device strata, or field evidence justifies a narrower
documented support boundary.

### D-21 — Keep Hindi behind an offline beta release boundary

**Status:** Accepted

**Considered:** leaving Hindi research-only, exposing it in every build after a
capability inventory, using a network-backed Hindi recognizer, and exposing a
narrow fully local beta before production qualification.

**Decision:** Debug and the invitation-only offline `PrivateBeta` expose only
the English-Hindi pair, labelled `Hindi (Beta)`. The speech path uses Apple's
local `DictationTranscriber` and must never fall back to network recognition.
Standard TestFlight and Release configurations omit Hindi until its offline
runtime, bilingual coexistence, translation, synthesis, quality, safety, and
physical-device gates all pass.

**Evidence:** On one iPhone 13 Pro, the inventory found exact `hi-IN`
Dictation support, download-eligible Translation directions, and a Hindi voice.
An explicitly authorized operation installed the exact Hindi live/final
Dictation modules and obtained a compatible Hindi-only format. A later
read-only check found both bilingual aggregates only download-eligible because
the exact English modules were not installed under that research app identity.
No pinned offline fixture inference, complete bilingual runtime, Translation
execution, Hindi synthesis review, live continuous quality run, or production
qualification has completed.

**Why:** The beta surface allows the missing device evidence to be gathered
without turning capability metadata and a model download into a production
support claim.

**Tradeoff:** Private-beta testers can encounter unsupported, incomplete, or
low-quality Hindi behavior. The catalog differs intentionally by build
configuration and must remain clearly labelled. Every English-Hindi continuous
turn is marked review-required. The explicit Speak preference plays ordinary
turns automatically, while important details require an explicit reviewed Play
action and detected detail mismatches remain text-only.

**Revisit when:** the exact bilingual module set installs and runs offline, the
fixture and live pipelines complete without egress, Translation and synthesis
are exercised in both directions, and the evaluation contract's quality,
safety, performance, stability, and reviewer gates pass on the required device
tiers.

### D-22 — Speak Duet offline commerce and optional accounts

**Decision (2026-11-04):** In this secondary repository, Speak Duet's Debug and
Commerce experiences offer 14 elapsed days from first use on each device,
followed by one monthly subscription unlocking all new translation. The
intended U.S. price is $4.99/month and an additional two-week App Store trial
is offered only to eligible users who explicitly authorize the subscription.
This supersedes D-07's permanently free local tier for these configurations.
Existing results, replay, export, and deletion remain available after expiry.

Default-language onboarding is required; Apple/Google signup is optional.
Firebase Authentication manages identity without syncing conversation content
or settings. StoreKit is the subscription authority independently of Firebase
sign-in. The commercial path does not enable the cloud translation backend.

**Tradeoff:** The first-use period is stored locally in the device-only
Keychain, with best-effort persistence and clock-rollback detection. It does
not prevent repeat access on new/erased devices or guarantee uninstall
persistence. Strong cross-device trial enforcement is deferred. Paid offline
access ends at the last verified expiration or billing-grace deadline.

**Distribution:** The proposed permanent identity is
`com.ahanaroy.speakduet`; registration remains pending. Real sign-in and
purchases require the external setup described in
[Speak Duet setup](speak-duet-setup.md). The new Commerce archive configuration
has separate account disclosures and preflight; legacy online release gates
and the original account-free PrivateBeta remain distinct.

## Open decisions before production release

These choices cannot be responsibly finalized from source code alone:

- final App Store product identifiers, subscription prices, territories,
  introductory offers, and support policy;
- production Apple/GCP accounts, domains, regions, secrets, certificates,
  notification URLs, budgets, and on-call ownership;
- whether Spanish launch claims cover only Spain or named regional varieties;
- final provider DPA/terms, retention, training/use, residency, and legal
  disclosure conclusions;
- the real hidden bilingual/audio corpus, evaluator roster,
  release-qualification devices, compatibility evidence, performance budgets,
  and launch thresholds after baseline measurement;
- whether a custom local LLM is a future product differentiator after a
  licensed, runnable implementation beats the Apple baseline on real devices;
- whether English-Hindi can be promoted from `Hindi (Beta)` after the D-21
  offline runtime, bilingual coexistence, translation, synthesis, quality,
  safety, and physical-device gates are satisfied.

## How to update this record

For a material product, privacy, model, provider, entitlement, storage, or
release change:

1. Add or amend a numbered decision before implementation is approved.
2. Record the alternatives, user impact, privacy/security effect, operational
   cost, evidence, owner, and revisit trigger.
3. Update the linked architecture, privacy inventory, threat model, evaluation
   criteria, and launch checklist in the same change.
4. Mark superseded decisions rather than deleting their rationale.
5. Re-run the affected adversarial reviews and release evidence matrix.

## Related sources of truth

- [Architecture](architecture.md)
- [Privacy](privacy.md)
- [Threat model](threat-model.md)
- [Evaluation and acceptance](evaluation-and-acceptance.md)
- [Release trust and evidence flow](release-trust.md)
- [Launch checklist](launch-checklist.md)
- [Experimental local LLM](experimental-local-llm.md)
