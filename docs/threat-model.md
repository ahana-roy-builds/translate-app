# Threat model

## Scope and assets

The scope is the iOS client; Local Only, Online Quality, and Auto routing; Apple-managed on-device language assets; the non-runnable custom-model experiment boundary; protected Cloud Run API and Google speech/translation calls; local synthesis; StoreKit/Pro entitlement; protected on-device history; build/release pipeline; evaluation artifacts; and operator access. Assets include private speech/audio/text, translation integrity, mode integrity, microphone control, history isolation, purchase state, backend credentials, release credentials, service availability/cost, and user trust.

The model assumes a normally secured iPhone and modern TLS. A jailbroken device, a malicious OS, physical coercion, and a fully compromised developer account cannot be completely mitigated by the application; controls should limit their blast radius and make compromise detectable.

## Trust boundaries

1. Human speech crosses into the microphone and application audio session.
2. Untrusted spoken/text content crosses into ASR and the translation prompt/template.
3. The mode decision crosses from user/entitlement/network state into either the zero-egress local path or content-uploading online path.
4. Signed release code invokes Apple frameworks that manage production language assets. App-managed model data exists only as a disabled research boundary.
5. Online turn content crosses through Cloud Armor/load balancing to Cloud Run, then to regional Google Speech-to-Text and Translation; synthesized audio stays local.
6. StoreKit evidence crosses into entitlement/session validation; conversation history has no app-controlled network path.
7. The client separately crosses the network boundary for system language assets, telemetry, or support.
8. CI/CD and operators cross into Apple, artifact storage, Google Cloud, and signing systems.

## Threats and controls

| Threat | Consequence | Required controls | Residual risk / validation |
| --- | --- | --- | --- |
| Covert or overlong recording | Privacy harm and legal exposure | Foreground-only capture, obvious visual state, bounded turns, immediate stop, audio-session teardown on interruption/background | OS indicator may be missed; test lifecycle transitions and hardware routes |
| Another app/nearby person injects audio | False or harmful translation | Explicit tap-to-start foreground capture, immediate stop, source transcript review, edit-before-speak, confidence/language mismatch warning | No robust speaker authentication; user confirmation remains important |
| Spoken text attempts to control the translation system | Fabricated output or unintended action | Production passes bounded text directly to Apple/Google translation APIs and never treats it as an application command, URL, or tool selection; adversarial corpus and visible review remain required | Translation systems can still mishandle instruction-like speech; a future custom LLM requires a separate fixed prompt/data boundary and tool-free runtime review |
| ASR/translation hallucinates or loses negation, numbers, allergy, destination, or units | Financial, safety, or travel harm | Critical-token checks, confirmation UX, bilingual evaluation, low-confidence refusal/retry, visible disclaimer for high-stakes use | Semantic checks are imperfect; do not market as a professional interpreter |
| Mode-confusion or routing race uploads a Local Only turn | Violation of the zero-egress promise | Resolve an immutable mode before capture, persistent pre-turn badge, network-deny local tests, cancel on mode change, server request carries/validates mode and turn ID | UI bugs can mislead; privacy regression is an automatic release stop/incident |
| Auto selects online without meaningful disclosure | Unexpected collection and provider processing | Auto is opt-in for eligible Pro users, explain first use, show resolved path every turn, one-tap Local Only lock, no dark patterns | Users may overlook badges; user research and privacy review required |
| Compromised, unavailable, or defective Apple-managed language asset/runtime | Code/data exploitation, failed capture, or manipulated translations | Signed OS/framework trust boundary, supported OS floor, selected-pair capability/readiness checks before capture, physical-device regression tests, visible source review, OS/app rollback policy | The app cannot independently hash or pin Apple assets; capability varies by device and OS, and runtime regressions remain a release risk |
| Future custom-model manifest downgrade or corruption | Known-bad behavior restored | Feature remains compile-time disabled; introducing it requires signed manifests, digests, monotonic policy, staging, rollback, parser fuzzing, and a new review | These controls are requirements, not current functionality |
| Model or voice license violation | Takedown, forced rollback, reputational harm | Versioned SBOM/model BOM, source and license evidence, voice-specific review, attribution packaging, release legal sign-off | Upstream metadata can be wrong; preserve snapshots and counsel decision |
| Network interception or fake backend | Online speech/text disclosure or manipulated output | TLS, platform trust evaluation, strict endpoint allowlist, bounded schemas, artifact signatures independent of transport | Compromised CA/device can observe/modify online traffic; user can lock Local Only |
| App talks to the wrong backend release/environment | Unevaluated binary or infrastructure handles a reviewed app turn | Embed candidate ID/environment in the app; require exact content-free `/v2/availability` identity before session creation; bind app archive, OCI digest, revision, domain, plan, and deployment receipt in signed release evidence | A fully compromised deployment identity can still lie at runtime; monitoring and independent deployment attestations remain necessary |
| Public API abuse, Pro-entitlement bypass, scraping, or denial of service | Cost, fraud, and outage | Reject before expensive work unless short-lived session/entitlement and App Attest/replay checks pass; per-subject/device/IP quotas, body/duration limits, max instances, budgets, anomaly alerts | Attestation and client signals can be bypassed; hard cost caps and server entitlement are essential |
| Embedded credential extraction | Backend compromise | No service-account keys or durable shared secrets in the app, short-lived scoped tokens, server-side secret manager, rotation | Public client identifiers are not secrets and need abuse controls |
| Cloud provider retention, training, region, or human-access behavior differs from assumptions | Undisclosed secondary use or transfer | Dated review of selected Google API editions/settings/terms/DPA, region choice, vendor register, minimal request content, no application content logs, Local Only alternative | Provider and legal behavior can change; re-review and notify before material changes |
| Sensitive content in logs/crashes/analytics | Durable privacy breach | Structured allowlist events, body logging disabled, redaction at source, no free-form model errors, release client/backend/provider-log inspection, finite retention | OS/vendor diagnostic behavior changes; re-audit each release |
| Conversation remains in snapshots, clipboard, backup, or shared device | Local disclosure | Ephemeral default, sensitive-view snapshot handling, clear action, protected storage, exclude packs/cache from backup, deliberate clipboard/share | Screenshots and external recipients remain user-controlled |
| Corrupt or oversized local-history record exhausts memory or spoofs UI | Crash, denial of service, or misleading history | Protected local store, raw metadata/byte bounds before decode, strict schema validation, paged reads, bounded aggregate capacity, no automatic replay/translation | A compromised device can alter app data; deletion and visible error remain available |
| StoreKit receipt/session replay, stale live status, or forged Pro flag | Unauthorized online cost | Verify StoreKit transactions, causally merge live intervals with signed notifications, atomically bind sessions/devices, use 15-minute scoped tokens and one-use challenges, consume counters transactionally, disable Family Sharing | Attestation and client signals can still be bypassed; shared subscription and IP/daily quotas cap cost |
| Voice cloning or impersonation | Social harm | Ship licensed fixed voices, no speaker cloning/enrollment in initial release, label generated playback in UI, rate/bounds on export | A generic synthetic voice can still deceive outside context |
| Dependency/build pipeline compromise | Malicious app or model release | Protected branches, reviewed lockfile changes, pinned hashes, isolated CI, short-lived federated credentials, signed builds/artifacts, reproducible evidence | Developer account compromise remains high impact; exercise revocation |
| Forged, replayed, or mix-and-match release evidence | Unevaluated app/backend/device result is approved | Version-1 is preflight-only; version-2 verifies pinned GitHub OIDC workflow identities, Sigstore bundles, typed predicates, candidate/time/digest bindings, complete matrix uniqueness, and distinct role approvals | GitHub/maintainer/environment compromise remains high impact; preserve bundles and trusted-root material for independent re-verification |
| Unauthorized operator/support access | User-data or secret exposure | Least privilege, MFA, separate projects/roles, just-in-time elevation, audit alerts, no production data in development | Insider risk persists; minimize collected data |
| Resource exhaustion from long audio or crafted inputs | Crash, thermal/battery drain | Duration/file/dimension limits, cancellation, memory budget, thermal state adaptation, parser fuzzing, concurrency bounds | Resource-constrained devices may still fail; maintain device-stratified capability and performance tests |

## Security invariants

- A Local Only turn sends no audio, transcript, translation, synthesized speech, or derived content over any network interface.
- Any iPhone that can install the iOS 26 build may launch, but continuous and
  locally resolved recording remain disabled until the selected pair's required
  local capabilities and assets are ready; Local Only never uses the network to
  replace a missing capability.
- Online Quality and Auto-online turns are visibly identified before capture and send content only to the allowlisted Cloud Run/Google service path described in the privacy notice.
- History is local-only, default-off, consented per turn, text-only, bounded, and protected; Release/TestFlight carry no iCloud/CloudKit history capability.
- The client contains no credential that grants general backend or artifact-write access.
- Untrusted transcript text cannot select a tool, URL, file, prompt template, model path, or application command.
- Release/TestFlight use only Apple-managed production language assets; no app-managed custom model can be activated.
- No old asynchronous result can appear or play in a newer turn.
- Failure is visible: the app never substitutes a guessed translation for a failed stage.

Automate these invariants where possible with network-deny Local Only tests,
online endpoint allowlist tests, Auto/mode race tests, corrupt/oversized
local-history fixtures, entitlement/replay/ordering tests, instruction-like
speech cases, turn-cancellation races, and secret scanning. Add model-specific
prompt-injection tests if a custom LLM is ever enabled.

## Incident readiness

Maintain owners and runbooks for privacy exposure, compromised signing material,
harmful translation regression, backend abuse/cost spike, dependency
vulnerability, and App Store removal. V1 rollback uses the last known-good
app/backend release and a justified minimum safe app version; Apple controls its
language-asset lifecycle. Custom manifest disable and last-known-good pack
pinning are requirements only for a future app-managed model. Secrets can be
rotated and user notices published without uploading conversation content.

Review this model when changing provider/API/region, mode or subscription policy, adding any synchronization or account identity, changing content retention, support access, location, personalized voices, speaker cloning, training-data collection, third-party analytics, or model runtime. Each can change a trust boundary rather than merely adding a feature.
