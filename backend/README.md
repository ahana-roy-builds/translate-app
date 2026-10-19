# LocalLingo online translation service

Node 22/TypeScript service for the optional v2 Online Quality route. Audio, transcripts, translations, App Attest assertions, JWS bodies, and plaintext session tokens are never persisted or logged. Google Speech-to-Text and Translation use configured US regional endpoints; speech synthesis remains on the iPhone.

## v2 protocol

All responses have `Cache-Control: no-store`, `X-Content-Type-Options: nosniff`, and `X-Request-ID`. Errors have the stable shape `{"error":{"code":"…","message":"…","requestId":"…"}}` and never echo submitted content.

- `GET /livez`, `GET /readyz`, and `GET /v2/availability` provide process, dependency, and content-free kill-switch status respectively. Availability also returns a self-reported release build ID, OCI digest, environment, and Cloud Run revision as a runtime routing diagnostic.
- `POST /v2/app-attest/challenge` accepts exact JSON `{"purpose":"register|session","keyID":"…"}`.
- `POST /v2/app-attest/register` accepts exact JSON `{"keyID":"…","attestationObject":"<base64>","challengeToken":"…"}`.
- `POST /v2/session` accepts exact JSON `{"signedTransaction":"<StoreKit JWS>"}` plus App Attest headers. It returns a 15-minute opaque token and eight one-use assertion challenges.
- `POST /v2/session/challenges` accepts an empty attested, bearer-authenticated request and returns eight new challenges.
- `POST /v2/devices/replace-oldest` accepts exact JSON `{"signedTransaction":"<StoreKit JWS>"}` with a session-establishment assertion and no bearer token. After current Apple status verification it atomically evicts the least-recently-active binding, revokes that key's sessions, and binds the current key; the client then establishes a normal session.
- `POST /v2/translate-turn` accepts only a canonical mono, 16 kHz, signed 16-bit PCM `audio/wav` body of at most 30 seconds. `Content-Length`, `X-Source-Locale`, and `X-Target-Locale` are required. Duration is derived from the PCM bytes. The response contains text, recognition confidence, warnings, engine, and timings—never synthesized audio.
- `POST /v2/translate-text` accepts exact JSON `{"sourceLocale":"…","targetLocale":"…","text":"…"}` with matching locale headers.
- `DELETE /v2/devices/current` removes the current subscription binding and invalidates existing sessions.
- `POST /v2/storekit/notifications` verifies App Store Server Notification JWS input and atomically deduplicates and applies causal entitlement evidence.

Attested routes use `X-App-Attest-Key-ID`, `X-App-Attest-Assertion`, and `X-App-Attest-Challenge-Token`; session routes additionally use `Authorization: Bearer <token>`. Every session, challenge-pool, device, and translation request must also send the exact identity returned by its accepted availability preflight as `X-LocalLingo-Release-Build-ID` (1–128 canonical ASCII bytes), `X-LocalLingo-Backend-OCI-Digest` (exact lowercase `sha256:` digest), `X-LocalLingo-Runtime-Environment`, and `X-LocalLingo-Cloud-Run-Revision` (1–63 canonical ASCII bytes). The backend compares all four to its startup configuration before doing attestation or StoreKit work. Health, availability, App Attest bootstrap, and Apple notification routes intentionally do not require app-supplied build headers. The public `purpose=session` response is scoped only to session establishment or device replacement. Challenges returned inside a session are separately scoped to bearer-authenticated requests and cannot be interchanged.

The 32-byte App Attest client-data hash is:

```text
SHA256(
  UTF8("locallingo-request-v3\n" + METHOD + "\n" + PATH + "\n" +
       challenge + "\n" + keyID + "\n" +
       base64url(SHA256(UTF8(sessionToken))) + "\n" +
       sourceLocale + "\n" + targetLocale + "\n" +
       releaseBuildID + "\n" + backendOCIDigest + "\n" +
       runtimeEnvironment + "\n" + cloudRunRevision + "\n") ||
  SHA256(exactRequestBodyBytes)
)
```

The session hash and locale fields are empty when inapplicable; all four build-identity fields are always present on an attested route. Including them in the assertion prevents an intermediary from silently rewriting a stale app selection to the currently deployed identity. This is a time-of-check/time-of-use routing guard, not server attestation: the trusted release decision still comes only from independently signed control-plane evidence. Pass the final raw 32 bytes directly to `DCAppAttestService.generateAssertion`; do not hash them again.

## Security state

The deployed entry point performs App Attest certificate-chain, nonce, RP ID,
AAGUID, COSE-key, key-ID, assertion-counter, and supported
validation-category/bundle-version checks in process. StoreKit JWS and
certificate/OCSP validation uses Apple's pinned
`@apple/app-store-server-library`; every session also obtains current status
from the App Store Server API before issuing a token. Product, purchased
ownership, type, expiry, grace, billing-retry, upgrade, refund/revocation, and
notification ordering are then enforced locally. Live status is stored as a request interval and notifications as Apple-signed event points; overlapping evidence fails closed (`expired` then `grace-period` then `active`), while an active recovery is accepted only when its live request began after the terminal event. Firestore transactions
enforce one-use purpose-scoped challenges, atomic entitlement/binding/session/challenge-pool creation, monotonic
counters, three-device bindings and least-recently-active replacement, short-lived hashed sessions,
pre-StoreKit session-attempt admission, and installation/subscription quotas. Separate bounded session and notification lanes reserve user-session capacity; successful notification verification is coalesced and cached by payload hash, while UUID/payload conflicts fail closed. The reviewed Apple 3.1.0 dependency is hash-locked and patched to an absolute six-second, 64 KiB OCSP response budget with at most one redirect, without disabling online revocation checks. Deployed modes fail during startup when
identity, pinned roots, or the App Store Connect In-App Purchase API P-256 key
configuration is absent or malformed.

Modes are intentionally distinct: `staging` uses development App Attest plus
StoreKit Sandbox, `testflight` uses production App Attest category 2 plus
StoreKit Sandbox, and `production` uses production App Attest category 4 plus
StoreKit Production. Do not point a TestFlight build at either of the other
environments.

The separate development entry point injects in-memory fakes and binds only to `127.0.0.1`; it cannot be selected by the deployed server.

## Build and run

```sh
npm ci --ignore-scripts
npm run patch:storekit
npm test
npm run typecheck
RUNTIME_MODE=development npm run dev
```

Release container builds must provide an immutable Node image present in a
reviewed policy file. From the repository root, use `make backend-image` with
the `NODE_IMAGE`, `NODE_IMAGE_POLICY_FILE`, `BACKEND_IMAGE`,
`BACKEND_OCI_OUTPUT`, `BUILD_METADATA`, and `SBOM_OUTPUT` values documented in
the root README. The build is fixed to `linux/amd64` and emits an OCI archive,
BuildKit attestations/metadata, and a CycloneDX dependency SBOM. The Dockerfile
deliberately has no mutable default. A direct build is suitable only for local
diagnostics and is not release evidence:

```sh
docker build --build-arg NODE_IMAGE='node:22-bookworm-slim@sha256:<approved-digest>' .
```

The `/v2/availability` build identity is explicitly marked
`self-reported-diagnostic`. It can detect accidental app/backend mismatches,
but the server receives those values from its own environment and cannot use
them to attest which image is executing. Only the signed release verifier's
independent control-plane deployment receipt and immutable OCI-digest binding
are trusted release evidence.

Deploy behind the configured HTTPS load balancer and Cloud Armor. The Cloud Run
default URL must not be publicly reachable. Configure Firestore TTL for
challenge, session, challenge-pool quota, session-attempt quota, translation quota, and
notification-deduplication documents. `APPLE_IAP_SIGNING_KEY_P8` is a Secret
Manager value; never commit or expose it to the iOS app.

`GOOGLE_STT_LOCATION=us` and `GOOGLE_TRANSLATION_LOCATION=us-central1` are exact startup requirements. Deployments must also inject `RELEASE_BUILD_ID` and the immutable `BACKEND_OCI_DIGEST`; Cloud Run supplies `K_REVISION`. StoreKit admission defaults to two concurrent/six outstanding session checks and one concurrent/two outstanding notifications.

See the canonical [decision log](../docs/decision-log.md) and
[release-trust contract](../docs/release-trust.md) before changing the protocol,
deployment identity, or evidence boundary.
