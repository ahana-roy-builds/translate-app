# Launch checklist

Record an owner, evidence link, date, build/model digest, and approver for every checked item. “Not applicable” requires a reason. Re-open affected sections after any app, model, runtime, voice, SDK, backend, policy, or data-flow change.

## Product and model

- [ ] Install-eligible iPhones and OS versions, release-qualification devices, language directions, per-pair capability/readiness limitations, offline behavior, pack sizes, and free-space requirements are explicitly distinguished.
- [ ] Local Only, Online Quality, and Pro Auto rules are documented; the next-turn mode is visible; locking Local Only and every Auto fallback/race path are tested.
- [ ] StoreKit Pro entitlement, restore, Apple grace, refund/revocation, disabled Family Sharing, offline, three-device binding, notifications, and 15-minute backend session behavior match the paywall and App Store configuration.
- [ ] On-device text history is off by default, consented per turn, bounded, paged, protected, excluded from backup, and delete-one/all work without audio; every build is proven to have no iCloud/CloudKit history capability.
- [ ] The Apple account owner records whether any removed CloudKit container ever
      held user data and preserves purge/no-data evidence; absence of CloudKit
      code in this repository is not evidence of administrative deletion.
- [ ] Conversation state machine handles interruption, cancellation, direction switch, replay, backgrounding, route changes, thermal/memory pressure, and late-result races.
- [ ] Low confidence, silence/noise, wrong selected language, empty output, repetition, and unsupported language fail visibly and recoverably.
- [ ] Source and target text remain visible; edit-before-speak, stop playback, clear, and Apple asset-readiness/preparation flows work with accessibility technologies.
- [ ] Numbers, dates, time, currency, units, destinations, names, negation, allergy, medication, and emergency phrases have targeted UX and tests.
- [ ] No claim implies guaranteed accuracy or professional medical/legal/emergency interpretation.

## Rights and governance

- [ ] Model/voice/runtime/tokenizer/dataset bill of materials records exact version, digest, source, license snapshot, notices, modifications, and redistribution/commercial-use decision.
- [ ] Counsel or accountable reviewer approved every non-standard, research-only, non-commercial, attribution, acceptable-use, voice, and dataset term.
- [ ] Required attribution and source-offer material is reachable in-app and in distribution artifacts as applicable.
- [ ] Training/evaluation audio and text have documented provenance, consent/rights, permitted purpose, retention, and deletion handling.
- [ ] Model card records intended use, exclusions, tested language varieties, known harms, evaluation, and rollback owner.

## Privacy and security

- [ ] Release-build traffic capture proves Local Only has zero conversation-content egress, Online Quality reaches only the documented Cloud Run/Google path, every Auto choice matches its pre-turn badge, and offline Local Only works with network denied.
- [ ] Microphone permission copy, recording/mode indicators, stop control,
      first-online disclosure, Auto opt-in, history opt-in, privacy notice, and
      clear actions match actual behavior. A support-upload preview is required
      only if that future feature is implemented.
- [ ] Dated provider review covers regional Google Speech-to-Text/Translation, Cloud Run/load balancing/Cloud Armor, App Attest, and StoreKit data fields, region, retention, logging, training/use, human access, terms/DPA, and store disclosures.
- [ ] Logs, metrics, crash reports, analytics, screenshots/snapshots, clipboard, backup, and support tooling contain no unintended audio/text/secrets.
- [ ] App Privacy answers, privacy manifests, required-reason API declarations, SDK/subprocessor register, retention, deletion, and regional legal reviews are signed off.
- [ ] Apple-managed asset availability and OS/runtime rollback assumptions are tested. If a future custom model is introduced, signed manifest, digest, bounds, atomic activation, downgrade, corruption, and rollback controls receive a separate review.
- [ ] No durable backend or publishing credential is embedded in the app; secret scan and binary/configuration review pass.
- [ ] Threat model, dependency/container scans, abuse tests, parser fuzz results,
      incident runbooks, contacts, and signing/credential revocation exercises
      are current. Model-specific prompt-injection and pack-revocation exercises
      are required if a custom LLM is introduced.

## Evaluation and devices

- [ ] Every direction and release-qualification device tier passes the machine-readable and human gates in [Evaluation and acceptance](evaluation-and-acceptance.md).
- [ ] On other install-eligible iOS 26 iPhones, unsupported or unready pair components keep continuous and locally resolved Start controls disabled, explain the unavailable/setup state, and never trigger a Local Only network fallback; explicit Online Quality remains route-gated independently.
- [ ] Local and Online Quality are evaluated separately and head-to-head; Auto routing has service-health, entitlement, latency, quality, privacy, and fallback acceptance evidence.
- [ ] Hidden-set scores are compared with production and reported by accent/dialect, noise, domain, utterance length, and device strata.
- [ ] Bilingual evaluators sign off all safety-critical cases and investigate every critical-check failure or severe meaning inversion.
- [ ] Cold/warm latency, time-to-first-audio, peak memory, disk staging/rollback, battery, thermal throttling, audio quality, Bluetooth/wired routes, and long-session stability meet budgets.
- [ ] Apple asset preparation handles interruption, low disk, connectivity change, backgrounding, and app/OS update. Future custom downloads require the broader CDN/tamper/rollback suite before activation.
- [ ] Accessibility, localization, right-to-left/pseudolocalization, Dynamic Type, VoiceOver, contrast, Reduce Motion, and large-control testing pass.

## Backend and operations

- [ ] Development, staging, TestFlight, and production are isolated as designed.
      In particular, TestFlight and production use distinct projects, state
      bucket/prefix pairs, registries, Cloud Run services, runtime identities,
      secrets, API domains, bundle/products, plans, and deployment receipts;
      production deletion protection and least-privilege IAM are enabled.
- [ ] Image is digest-pinned, scanned, provenance-attested where possible, and deploy/rollback rehearsed through reviewed CI with short-lived credentials.
- [ ] Each Terraform apply uses private snapshots of the clean configuration,
      lock, backend, variables, and saved plan, plus the plan SHA-256 captured
      from protected planner output before artifact publication; the digest is
      never reconstructed from the mutable artifact root.
- [ ] Signed deployment receipts query the Cloud Run control plane and bind the
      observed revision and resolved image digest to the candidate; the
      service's `/v2/availability` identity is used only as a runtime
      consistency check, never as its own attestation.
- [ ] Cloud Armor and pre-body limits reject abusive traffic; Cloud Run rejects missing/invalid/expired/replayed session and App Attest evidence before provider work; canonical WAV duration, quotas, time bounds, maximum instances, budgets, and abuse alerts pass load/cost tests.
- [ ] Direct Cloud Run URL bypass is denied. Runtime identity is limited to Speech Client, Translation User, Firestore User, Service Usage Consumer, and named secrets; IAM-denied tests prove no administrative/model/storage access.
- [ ] Online provider quotas, regional endpoints, timeouts, retry/cancellation, circuit breaking, duplicate suppression, output validation, and Local Only/Auto degradation pass integration and fault-injection tests.
- [ ] Dashboards and alerts cover availability, errors, latency, abuse, egress, secret access, IAM/configuration change, and spend without logging conversation content.
- [ ] Secret rotation, signing-material compromise, app/backend rollback, privacy
      incident, operator access, and user-communication runbooks are exercised.
      Manifest disable/model-pack rollback applies only to a future custom model.

## Store release

- [ ] Apple agreements, bundle ID, signing, microphone usage description, privacy policy/support URLs, age rating, export compliance, content rights, metadata, screenshots, and review notes are complete.
- [ ] Pro subscription group/products, localization, review assets, paywall/legal/support links, purchase, restore, grace, renewal failure, refund/revocation, disabled Family Sharing, entitlement, and App Store server flows pass sandbox/TestFlight testing.
- [ ] Signed entitlements, resolved build configuration, and binary inspection prove that iCloud/CloudKit history capability and container identifiers are absent.
- [ ] TestFlight beta meets crash-free and completion targets; all severity-1/2
      issues are closed. V2 accepts no waiver, so an open issue is a no-go.
- [ ] Customer support has language/pack diagnostics that do not require conversation content and an escalation path for harmful translations.
- [ ] Phased release, automatic halt signals, prior app/backend rollback, on-call
      coverage, and post-launch review times are confirmed. Pack rollback is
      conditional on a future custom-model implementation.

## Go / no-go record

The signed version-2 release decision is authoritative. This section is the
human-readable summary and cannot waive a missing matrix cell, failed
preflight, absent attestation, or mismatched candidate digest.

The unsigned version-1 preflight can never change this record to “go.”

- Release build and commit:
- App/model/manifest digests:
- Supported pairs, install eligibility, qualification devices, and capability exclusions:
- Waivers: none (required by v2)
- Quality approval (including bilingual/product evidence):
- Security approval:
- Privacy approval (including legal evidence):
- Operations approval:
- Release time and rollback owner:
