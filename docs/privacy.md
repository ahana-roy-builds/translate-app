# Privacy design

For the new Speak Duet Commerce configuration, optional Apple/Google account
identity is processed by the chosen provider and Firebase Authentication.
Only FirebaseAuth is linked; settings and conversation history are not synced.
Account deletion is available in Settings and is independent of Apple billing.
The app-owned Commerce privacy manifest declares name, email address, and user
ID for app functionality without tracking. The bundled Google Sign-In and
Firebase Auth manifests also declare provider diagnostic, identifier, usage,
and other data. Their full disclosure inventory is in the
[Speak Duet TestFlight tracker](speak-duet-testflight.md#privacy-disclosure-inventory).
Audit actual SDK traffic/manifests and publish matching privacy/store disclosures
before distribution. See
[Speak Duet setup](speak-duet-setup.md). Its initial free period and StoreKit
subscription gate all new translation; the older free-local/paid-online model
described below applies to legacy configurations.

This is an engineering baseline, not a substitute for jurisdiction-specific legal review. The shipped privacy notice, in-product mode disclosures, App Store answers, code behavior, Google/Apple terms, SDK configuration, regional deployment, and retention evidence must agree.

## User-facing processing contract

- **Local Only:** raw turn audio, source transcript, translation, and synthesized speech are processed inside the application sandbox. Conversation content has a zero-egress guarantee. Model-manifest/download requests, App Store entitlement checks, or consented content-free diagnostics may still use the network, but must not carry turn content.
- **Online Quality:** the active turn audio is sent through the protected Cloud Run backend to US regional Google Cloud Speech-to-Text; the resulting source text is sent to regional Cloud Translation. Translated text returns to the iPhone for local speech. The app displays a persistent online indicator and explains this boundary before first use.
- **Auto:** eligible Pro users can enable a policy that chooses Online Quality when available. The resolved path is shown before each turn. Auto must not upload a turn after the UI represented it as Local Only.
- **History:** text-only on-device saving is independent and off by default. A turn may enter only protected on-device storage when consent was captured for that turn. The app does not synchronize history, and audio is never history.

Online processing consent is separate from microphone permission, analytics,
model-training use, and on-device history. Users can lock Local Only and disable
or clear history independently. A support-upload feature is not implemented;
adding one requires a separate preview, consent, retention, access, and deletion
design.

Any implementation that differs from this contract must update the product UI, this document, privacy/store disclosures, data-processing inventory, and release tests before shipping.

## Data inventory

| Data | Purpose | Path/location | Application-controlled retention | User control |
| --- | --- | --- | --- | --- |
| Live microphone audio in Local Only | Local ASR | Volatile device memory | End of turn/cancel | Stop/cancel; microphone permission; Local Only lock |
| Live microphone audio in Online Quality/Auto-online | Cloud recognition | Device → Cloud Run → Google Speech-to-Text | Client/backend buffer only for request; provider handling per reviewed terms/configuration | Mode choice/Auto setting; stop before upload; Local Only lock |
| Source transcript in Local Only | Review and local translation | App memory; protected on-device history only when enabled at capture | Conversation/session end or local deletion | Edit, clear, optional copy/share/local history |
| Source transcript in Online Quality/Auto-online | Review and cloud translation | Google service/backend response → app; optional protected local history | Backend request lifetime; provider handling per reviewed terms/configuration; app session or until local history deletion | Clear, optional copy/share/local history; Local Only lock for future turns |
| Translation in Local Only | Display and local TTS | App memory; protected on-device history only when enabled at capture | Conversation/session end or local deletion | Clear, optional copy/share/local history |
| Translation in Online Quality/Auto-online | Display and local TTS | Cloud Translation → backend/app; optionally protected local text history | Backend request lifetime; provider handling per reviewed terms/configuration; local history until deletion | Clear, optional copy/share/history; Local Only lock for future turns |
| Synthesized audio | Playback | Volatile device memory | End of playback/turn; never history | Stop/replay during active session |
| On-device text history | User-requested device history | Protected application store | Until item/all deletion or app removal | Separate off-by-default setting; delete item/all |
| Apple-managed language assets | Offline speech/translation/voice readiness | Apple system framework asset service → OS/app-managed availability | Per Apple/OS asset lifecycle | Prepare assets before travel; OS controls underlying asset lifecycle |
| App Attest assertion and replay fields | Protect public API | Device → Cloud Run; Apple validation path as designed | Short anti-replay/security window | Required for Online Quality; use Local Only instead |
| StoreKit transaction/entitlement evidence | Pro access and backend enforcement | App Store/device; limited evidence to backend if used | Short session plus legally/accounting-required entitlement record | Manage/restore purchase; Local Only remains available per product policy |
| IP, request time, transport metadata | Deliver and defend online service | CDN/Cloud Run/Google/Apple infrastructure | Short documented security/operations period | Avoid content upload with Local Only; network metadata may still arise from downloads/entitlement |
| Coarse stage timing and enumerated error | Reliability and abuse measurement | Device/backend; upload under disclosed analytics/security basis | Short documented period | Analytics setting where applicable; essential security events documented separately |
| Crash diagnostic | Stability | OS/vendor crash pipeline if enabled | Per documented vendor configuration | OS/app analytics control where available |

Do not collect advertising identifiers, precise location, contacts, keyboard contents, a stable cross-app identity, speaker/voice embeddings, or raw model prompts for the initial product.

## Permission, mode, and participant notice

Request microphone access only when the user starts a feature that needs it. The usage description must explain speech conversion/translation and that the selected Online Quality or Auto-online path sends the turn to cloud providers. The UI must remain useful enough to explain how to enable access after denial.

Both participants should be able to see when listening is active and whether the next turn is Local Only or Online. Provide a full-screen recording cue and avoid background/covert capture. The traveler remains responsible for local recording/consent rules, but the product must make informed participation practical.

Before first Online Quality use or enabling Auto, present a concise data-flow explanation with a link to details. A persistent per-turn badge is more reliable than a one-time dialog. Changing mode after recording begins cancels the turn; it does not reroute already captured speech behind the user's back.

## Local storage and sharing

- Use appropriate iOS data-protection classes for persisted settings and local
  history. Exclude protected LocalLingo history and app-owned recreatable caches
  from backups; Apple controls the storage lifecycle of system language assets.
- Do not persist raw audio in logs, caches, crash breadcrumbs, analytics, notifications, or normal conversation history.
- Snapshot on-device consent when capture starts. Enabling it later never backfills earlier turns.
- Bound and validate every local snapshot before decoding or saving; page reads,
  target updates/deletes by ID, and reject capacity growth instead of silently
  evicting history.
- Redact authorization, App Attest assertions, StoreKit evidence, query strings, text/audio bodies, and free-form errors at the logging boundary.
- Use the system share sheet only after a direct user action and make clear that the receiving application controls its copy.
- “Clear conversation” synchronously removes visible/session state. “Clear local history” removes every protected LocalLingo history record on the device and reports failures honestly.

## Google Cloud and other providers

Maintain a current provider/SDK register recording exact data fields, purpose, API/model, hosts, region, role (processor/subprocessor or independent controller as legally determined), training/use commitments, human access, retention/deletion, contract/DPA, transfer mechanism, privacy manifest, and tracking behavior.

At minimum, review Cloud Run/load balancing/Cloud Armor, Speech-to-Text, Cloud
Translation, Apple App Attest, StoreKit/App Store Server services, crash
reporting, and any analytics vendor actually enabled. Review a model host/CDN or
support vendor only if that future feature is introduced. Provider defaults and
terms change; save dated evidence for the selected editions, logging settings,
and data regions rather than assuming “no retention” or “not used for training.”

Cloud Run handlers must keep turn content only in bounded memory for the request,
never log it, and not write it to a database/object store. Google API calls use
project-scoped credentials on the server. Operator access is role-based,
audited, time-limited, and separated by environment. Never use online turns or
history for training without a new, specific consent and governance process.

## Subscription and account assumptions

The initial product can use App Store purchases without a bespoke user account.
StoreKit/App Store supplies purchase state, and the backend may see a
pseudonymous, scoped entitlement/session subject. Do not link this identity
more broadly than needed for entitlement, abuse prevention, support, or legally
required records.

Active and Apple billing-grace states qualify for Pro. Expired, revoked,
billing-retry, unknown-product, and Family Shared transactions do not. Recompute
on transaction updates, foreground, and storefront changes. Expired entitlement
must not delete history or remove free local capability. Backend sessions last at
most 15 minutes, bind to an attested installation, and are revocable; purchase
evidence and App Store credentials are never analytics.

## App Store disclosure mapping

Before every submission, derive App Privacy answers from observed release-build
flows. Local Only conversation content remains on-device, while Online Quality
sends audio and text through developer-controlled and Google services and is
bound to a pseudonymous App Attest installation/session. The committed privacy
manifest therefore declares Audio Data, Other User Content, Device ID, and
Purchase History as linked for app functionality and not used for tracking.
That is a conservative engineering baseline, not a substitute for reviewing
the exact release traffic and current App Store definitions. Local text
history, diagnostics, IP/security logs, and third-party SDK behavior still
require case-by-case disclosure analysis. Any future support upload needs its
own analysis. Record the rationale, evidence, and reviewer for every answer.

Also maintain:

- a public privacy policy and in-app link with a clear Local Only/Online Quality/Auto/History explanation;
- a provider, purpose, region, retention/deletion table and privacy/support contact;
- a signed-off list of required-reason APIs and privacy manifests from embedded SDKs;
- regional legal assessment for recording consent, children, accessibility, voice/biometric classification, consumer protection, automated decision-making, and international transfers;
- data-subject request, local-history deletion, provider deletion, incident-notification, and regulator inquiry procedures.

## Privacy verification

Capture release-build network traffic and inspect device/backend/provider logs for at least:

- Local Only with network denied and allowed;
- Online Quality and each Auto routing outcome;
- mode change/cancel/retry and online-to-local fallback;
- history off/on/write/delete/clear and capacity/corruption behavior;
- Apple language-asset preparation, entitlement/restore, App Attest rejection,
  analytics off/on, and crash behavior. Add support-upload cases only if that
  future feature is implemented.

Fail the release if any turn content leaves the device in Local Only; if Auto uploads after showing Local Only; if history leaves the device, is written without opt-in, or contains audio/hidden fields; or if sensitive content appears in console, unified logs, backend/provider-accessible application logs, crash reports, or analytics. Verify backend request-body logging is disabled and provider retention/configuration evidence is current.
