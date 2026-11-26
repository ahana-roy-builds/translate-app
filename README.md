# Speak Duet

Speak Duet (previously LocalLingo) adds language onboarding, a device-local
14-day free-access period, optional Apple/Google accounts, and one monthly
subscription for all translation. The intended U.S. price is $4.99/month with
an additional two-week introductory trial for eligible subscribers.

Use the **Speak Duet** Xcode scheme for local development and the **Commerce**
archive configuration for the new offline paid app. See
[Speak Duet setup](docs/speak-duet-setup.md) for implemented behavior, testing,
and the Apple/Firebase configuration still required before distribution.
Internal project/module names remain LocalLingo to preserve existing data.

LocalLingo is an offline-first iOS conversation translator for travelers. The
launch implementation supports bidirectional English–Spanish and
English–Japanese conversations with a half-duplex, one-speaker-at-a-time flow.

Debug builds and the invitation-only offline `PrivateBeta` configuration also
expose English–Hindi as `Hindi (Beta)`. This is an experimental device-testing
surface, not a production support claim. The standard `TestFlight` and
`Release` configurations omit Hindi until offline inference, bilingual model
coexistence, Translation, speech synthesis, live continuous use, quality, and
safety gates pass on physical iPhones. See the
[Hindi research status](docs/hindi-offline-support-research.md).

Every English–Hindi continuous turn is marked review-required while this beta
is being evaluated. With Speak on, ordinary translations play automatically.
Turns containing important details wait for the tester to check the text and
choose Play translation. A turn with an important-detail mismatch remains
text-only and cannot be played.

The app has two explicit processing paths:

- **Local:** Apple Speech, Translation, and AVFAudio frameworks process the
  conversation on the iPhone.
- **Online Quality:** an App-Attested Cloud Run service uses US regional Google
  Cloud Speech-to-Text and Translation. Translated text returns to the iPhone
  for on-device speech. Conversation content is processed transiently and is
  never written to application logs or backend storage.

The active path is always shown before recording. Local Only mode never falls
back to the network.

## Repository layout

| Path | Purpose |
| --- | --- |
| `ios/` | SwiftUI iOS 26 application and XcodeGen project definition |
| `backend/` | TypeScript Cloud Run translation-turn API |
| `infra/` | Google Cloud infrastructure and deployment configuration |
| `evaluation/` | Traveler-domain quality and latency evaluation harness |
| `docs/` | Architecture, privacy, operations, and release documentation |

The rationale behind the launch baseline—including alternatives considered,
deferred choices, tradeoffs, and open decisions—is maintained in the
[product and architecture decision record](docs/decision-log.md).

## Prerequisites

- macOS with Xcode 26.4 or newer and the iOS 26 SDK
- [XcodeGen](https://github.com/yonaskolb/XcodeGen)
- Node.js 22 and npm
- Python 3.10 or newer for the dependency-free evaluation and release gates
- A paid Apple Developer account for device, App Attest, StoreKit, and App
  Store testing
- A Google Cloud project with billing enabled for the online path
- Terraform 1.15.7 for managed cloud deployment

## Quick start

### Backend

```bash
cd backend
cp .env.example .env
npm install
npm test
npm run dev
```

The development server accepts test credentials only when its explicit local
development bypass is enabled. Production startup fails if verification or
Google Cloud configuration is missing.

Release container builds have no mutable base-image default:

```bash
NODE_IMAGE='node:22-bookworm-slim@sha256:APPROVED_64_HEX_DIGEST' \
NODE_IMAGE_POLICY_FILE=/secure/release/approved-node-images.txt \
BACKEND_IMAGE='us-central1-docker.pkg.dev/PROJECT/locallingo/api:BUILD' \
BACKEND_OCI_OUTPUT=/secure/release/backend-image.oci.tar \
BUILD_METADATA=/secure/release/backend-build-metadata.json \
SBOM_OUTPUT=/secure/release/backend-sbom.cdx.json \
make backend-image
```

The policy file must contain the exact reviewed base reference. The build is
fixed to `linux/amd64` and emits an OCI archive, BuildKit provenance/SBOM
attestations and metadata, plus a CycloneDX dependency SBOM. The metadata is
augmented with the clean Git commit and a digest of the exact backend build
inputs; the release gate requires this file and verifies that its BuildKit
provenance binds the approved base digest and deployed application digest. An
authenticated producer job must scan and publish the reviewed OCI artifact,
record the resolved base/application digests, and deploy by digest, never by tag.
This repository's release workflows attest protected, pre-existing evidence;
they do not include a registry publisher.

### iOS

```bash
cd ios
xcodegen generate
open LocalLingo.xcodeproj
```

Use Debug for local work. An untracked `ios/Config/Release.local.xcconfig` is
available for non-authoritative developer compile checks, as described in
[`ios/README.md`](ios/README.md). The authenticated external signing/build
environment must inject deployment values into Xcode and emit the resolved
configuration before the protected wrapper attests its evidence; the committed
wrapper does not build or sign an archive. An ignored xcconfig is never a
trusted release input. Placeholder deployment configuration is intentionally
rejected. Apple Speech and Translation asset behavior cannot be fully exercised
in Simulator.

### Infrastructure

Follow [`infra/README.md`](infra/README.md) and
[`docs/platform-prerequisites.md`](docs/platform-prerequisites.md) after the
backend tests pass.
Do not place Apple private keys, Google service-account keys, or API credentials
in this repository.

## Product behavior

- Two large, language-labelled microphone controls
- Held-phone and face-to-face conversation layouts
- Finalized-source translation only; partial speech results are never spoken
- Careful Mode for numbers, money, times, dates, addresses, allergy,
  medication, and emergency terms
- Typed, full-screen, replay, and slower-speech fallbacks
- Offline readiness checks for recognition, both translation directions, and
  installed voices
- Debug and offline Private Beta access to the English–Hindi `Hindi (Beta)`
  experiment; standard TestFlight and Release builds retain the base catalog
- No marketing-model allowlist: any iPhone that can install the iOS 26 build may
  launch, while selected-pair capability and asset readiness gate continuous
  conversation and routes resolved to Local Only
- Fourteen days of free local translation, followed by optional subscription access
- One monthly Speak Duet subscription; legacy online configurations retain their separate product setup
- Optional on-device, text-only history

## Privacy invariants

1. Local Only mode performs no conversation-content network requests.
2. Audio is never saved to history.
3. Online turn audio and text are held only for the request lifetime.
4. Logs and analytics contain operational metadata, never conversation content.
5. On-device history is off by default, protected with iOS Data Protection,
   excluded from backup, and never synchronized by the app.
6. Delete All removes every LocalLingo history snapshot stored on the iPhone.

See [`docs/privacy.md`](docs/privacy.md) and
[`docs/threat-model.md`](docs/threat-model.md) for the complete data-flow and
security review.

## Validation

```bash
make test-fast
```

Run `make ios-talk-test` on a Mac for the conversation and Relay simulator checks used in CI. The recorded iPhone, all-language matrix and live microphone commands are in the [Talk testing guide](ios/README.md#repeatable-talk-regression-tests).

`make test-integration` additionally requires pinned Terraform, XcodeGen, Xcode
26.4+, and the configured simulator. The pinned GitHub workflow runs fast and
Terraform validation on each pull request; it does not claim physical-device or
signed-archive coverage.

`make release-preflight` performs the exhaustive local version-1 structural
check against an explicit private artifact root, manifest, physical-device
registry, environment-resolved iOS configurations, distinct reviewed
production/TestFlight Terraform plans and inputs, BuildKit provenance, and a
digest-pinned base image. `make release-check` remains only a compatibility
alias for that non-approving preflight; both always report
`release_decision: false`.

Only `make release-finalize` can report an approved production decision. It
verifies the signed version-2 decision, GitHub OIDC/Sigstore bundles, pinned
workflow identities, strict corpus/build/plan/deployment/device predicates,
the complete 96-cell physical-device matrix, and four distinct digest-bound
approvals. The committed protected workflows are attestation wrappers around
artifacts produced by authenticated build/sign, corpus, physical-device, and
deploy/control-plane jobs; they do not perform those producer tasks. Deployment
settings must be supplied by the build environment and emitted as attestable
resolved configuration—ignored local xcconfig files are never trusted release
inputs. Unsigned TestFlight/Release compiles remain compiler checks only. See
[release trust](docs/release-trust.md), the [decision log](docs/decision-log.md),
and [evaluation/README.md](evaluation/README.md) for the evidence contract.
