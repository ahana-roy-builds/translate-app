# Platform and account prerequisites

Requirements and store policies change. Reconfirm them against the current Apple and Google documentation before release and record the review date and owner.

## Apple development

- Active Apple Developer Program membership owned by the organization, with at least two administrators and phishing-resistant MFA where supported.
- A stable reverse-DNS bundle identifier, App Store Connect app record, SKU, team ownership, signing/capability plan, and isolated Debug/Staging/Release configuration. Xcode 26.4 or newer is required.
- Automated signing or a documented certificate/profile workflow that keeps App Store distribution credentials out of developer laptops and repository files.
- A microphone usage description (`NSMicrophoneUsageDescription`) that accurately explains the local speech-translation purpose. Request access only in context.
- Protected, bounded on-device history only. The v1 App IDs, profiles,
  entitlements, and resolved build settings must not include an iCloud/CloudKit
  history capability or container identifier.
- App Attest capability and server-side key/environment setup for the public Online Quality API. Define a DeviceCheck fallback or denial policy for unsupported/failed attestation without weakening Local Only.
- StoreKit 2 product identifiers and entitlement mapping for Pro, plus isolated
  staging, TestFlight, and production verification. TestFlight uses the
  production App Attest entitlement but StoreKit Sandbox/App Store Server API;
  it has a separate project, state prefix, bundle/App ID, API domain, secrets,
  and alerting. No App Store credential belongs in the
  client.
- Deployment-target and device-support decisions backed by real memory, latency, thermal, storage, audio-route, and offline tests.
- A public GitHub repository with protected tag/build, physical-device,
  infrastructure/deployment, quality, security, privacy, operations, and
  finalizer environments. Release workflows use short-lived GitHub OIDC and
  retained Sigstore bundles; no long-lived release-attestation private key is
  stored in the repository or runner.
- Privacy manifests for the app and every included SDK, plus an audited declaration for required-reason APIs.
- Accessibility pass covering VoiceOver, Dynamic Type, contrast, non-color state cues, Reduce Motion, captions/visible source and target text, and motor-friendly controls.

The production local path uses Apple Speech frameworks. Confirm current device,
locale, usage-description, authorization, and entitlement requirements against
the iOS 26.4 SDK and test the signed Release build on physical devices; do not
infer permission behavior from Simulator or from a bundled-model design.

## App Store Connect submission

- Accepted paid/free app agreements and current tax/banking details if monetized.
- App name, subtitle, category, age rating, support URL, marketing URL if used, public privacy-policy URL, copyright, localized description, keywords, and accurate screenshots/previews.
- App Privacy answers derived from release-build network and SDK observation, not from intended architecture alone.
- Export-compliance answers for the actual cryptography in the binary and backend; retain the determination and any required documentation.
- Content-rights evidence for every model, tokenizer, voice, font, icon, sound, benchmark, and attribution notice distributed with or downloaded by the app.
- Review notes and a short demo explaining language-pack download, offline conversation, microphone permission, model size, and any account/entitlement flow. Provide a functioning review account if one is required.
- TestFlight internal then external testing, beta review where required, crash feedback triage, and an explicit phased-release/rollback decision.
- In-app purchase/subscription setup, restore flow, server notifications, terms, and price localization if premium packs or features are sold. Do not implement alternate digital purchase paths without current policy review.
- A subscription group and Pro product configuration covering trial/introductory offers, billing grace period, Family Sharing disabled for v1, refund/revocation, offer codes if used, upgrade/downgrade, localization, review screenshot, and tested restore/manage-subscription paths. Configure App Store Server Notifications because the backend maintains entitlement state.

Do not claim perfect accuracy, guaranteed emergency availability, or equivalence to a certified medical/legal interpreter. Store metadata and onboarding should state supported pairs, offline pack size, device requirements, and material limitations.

## Google Cloud

- Organization-owned Google Cloud projects with billing, budget alerts,
  security contacts, and separate development, staging, TestFlight, and
  production boundaries. TestFlight and production must have distinct projects,
  state bucket/prefix pairs, registries, Cloud Run services, runtime identities,
  secrets, API domains, plans, and deployment receipts.
- Terraform 1.15.7 with the committed Google provider 7.34.0 locks,
  credentials using workforce/workload identity where possible, distinct GCS
  state prefixes for each environment/bootstrap/service stack, and permission to
  enable Cloud Run, Artifact Registry, Firestore, Compute/Cloud Armor,
  Monitoring/Logging, IAM, Resource Manager, Secret Manager, Service Usage,
  Speech-to-Text, and Cloud Translation APIs.
- A protected planner-output or approval channel for recording the plan digest
  emitted before artifact publication. `infra-apply` requires that independent
  digest plus the same reviewed backend and variables; a digest recovered from
  the plan or adjacent provenance in the artifact root is not independent.
- Immutable container image built from a locked dependency graph, scanned, and pushed to Artifact Registry. Production should use a digest rather than a mutable tag.
- Secret values created outside Terraform, per-resource access for the Cloud Run runtime identity, rotation and recovery owners, and no downloaded service-account key.
- `allUsers` invocation at Cloud Run paired with internal-and-load-balancer ingress. The public HTTPS load balancer and Cloud Armor are the only internet path; direct `run.app` requests must fail. Application validation still requires a short-lived device-bound session and one-use App Attest challenge before work, plus installation/subscription/daily/IP quotas.
- Runtime IAM limited to Cloud Speech Client, Cloud Translation API User, Firestore user, Service Usage Consumer, and named secret access. Confirm exact calls with IAM-denied tests; never grant Owner, Editor, service-agent, storage, or project-wide secret access.
- Explicit US regional Google Speech-to-Text and Cloud Translation edition/model selection backed by dated review of supported languages, quotas, price/budget, limits, terms/DPA, data use/training, retention, logging, human access, and residency. Google TTS is not enabled; synthesis is on-device.
- Logging/monitoring policy that expressly excludes content, defines retention, and alerts on errors, latency, abuse, unexpected egress, secret access, IAM change, and budget thresholds.
- Domain/DNS, load balancer, Cloud Armor, region/data-residency, backup, and disaster-recovery decisions for the user-facing Online Quality service, plus a clear Local Only/Auto degradation policy.

Apply [the Terraform module](../infra/README.md) only after the project and identity decisions are made.

## Future custom-model distribution

The current production path uses Apple-managed assets and has no custom model
host. If a future build introduces one, choose an artifact host/CDN that supports
byte ranges, immutable paths, cache control, geographic availability, cost
controls, access logs without content, and emergency revocation. Distribution
credentials must allow download only; publishing is a separate CI identity.
Sign manifests with a key isolated from the hosting account.

Those future custom artifacts require separate download, installed, staging, and
rollback storage budgets plus interruption, low-disk, tamper, and rollback tests.

## Operational ownership

Name human owners and backups for mobile release, model quality, licensing, privacy, security incident response, backend reliability/cost, customer support, and accessibility. Store access and secret access should be role-based and reviewed at least quarterly. No launch gate is satisfied by an unowned document.
