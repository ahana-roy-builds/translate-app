# Speak Duet development and distribution

Use the **Speak Duet** scheme for the new onboarding/accounts/subscription
experience. Its Archive action selects the offline **Commerce** configuration.
Read [Speak Duet setup](../docs/speak-duet-setup.md) before preparing an archive;
the Apple/Firebase identities and public policy URLs are not registered or
configured automatically. The sections below document the underlying app and
legacy PrivateBeta/online release configurations.

# LocalLingo iOS

Native SwiftUI iPhone app for alternating travel conversations on iOS 26. It
uses SpeechAnalyzer, TranslationSession, and AVSpeechSynthesizer for local work.
Online Quality sends canonical speech to the companion backend for regional
Google recognition and translation, then synthesizes the returned text locally.

## Local-only developer-device MVP

The first runnable milestone is a signed Debug build installed directly from
Xcode on a physical iPhone running iOS 26. Use Xcode 26.4.1 and XcodeGen 2.45.4;
check the selected tools before generating the project:

```sh
xcodebuild -version
xcodegen --version
```

Create the ignored signing override from the committed example, then replace
the placeholders with a reverse-DNS bundle identifier unique to your Apple
Developer account and your 10-character team ID:

```sh
cd ios
cp Config/Debug.local.xcconfig.example Config/Debug.local.xcconfig
xcodegen generate
open LocalLingo.xcodeproj
```

```xcconfig
APP_BUNDLE_IDENTIFIER = com.yourcompany.locallingo.debug
DEVELOPMENT_TEAM = ABCDE12345
```

Do not commit `Config/Debug.local.xcconfig`. Regenerate the project after
changes to `project.yml`, but not after ordinary Swift or xcconfig changes.

From the repository root, run the Debug unit suite on the configured simulator
before installing on a phone:

```sh
make ios-test
```

`make ios-test` generates `LocalLingo.xcodeproj` and runs the `Speak Duet`
scheme using the Debug configuration. A simulator compile and test run does not
verify Listen recognition models, Translation assets, microphone behavior, or
Speak system voices.

### Repeatable Talk regression tests

The same simulator command runs locally and in pull-request CI. It covers turn handling, speaker routing, playback, the 20-second silence cutoff and resume, transcript rendering, Relay controls, language-pack navigation and downloads, and checks on numbers and other important details. Run it from the repository root with Xcode and XcodeGen installed.

```sh
make ios-talk-test
```

The default destination is the iPhone 17 simulator on the latest installed iOS. To select another installed iPhone, use `python3 evaluation/scripts/run_talk_tests.py simulator --simulator 'platform=iOS Simulator,id=SIMULATOR_UDID'`. CI supplies its pinned runtime.

For physical tests, use an unlocked development iPhone and the Debug signing configuration described above. Get its UDID with `xcrun xctrace list devices`. Replace `IPHONE_UDID` in the commands below. Each command generates the project, builds the tests, and writes a fresh run folder under `evaluation/results/talk/`.

| Suite | What it checks | Command |
| --- | --- | --- |
| Recorded device checks | English–Hindi controlled silence and queued speech, plus an English–Spanish recorded conversation and replay with the installed Apple models | `python3 evaluation/scripts/run_talk_tests.py device --device IPHONE_UDID` |
| All language pairs | Three phrases in both directions for each of 29 supported pairs, 174 turns total. Includes speaker assignment, transcript and translation meaning, target voice, and replay. | `python3 evaluation/scripts/run_talk_tests.py matrix --device IPHONE_UDID` |
| English–Spanish and English–Hindi comparison | The same scoring on 12 turns, with automatic playback enabled | `python3 evaluation/scripts/run_talk_tests.py matrix --device IPHONE_UDID --pairs en-US_es-ES,en-US_hi-IN --auto-speak` |
| Live microphone | Microphone recovery after playback, Relay controls, and a 20-second quiet interval. Put the phone beside the Mac speaker. The runner plays the Hindi and English clips when the phone is listening. | `python3 evaluation/scripts/run_talk_tests.py live --device IPHONE_UDID` |

Before a TestFlight upload, `make ios-talk-preflight DEVICE_UDID=IPHONE_UDID` runs the simulator, recorded device checks, then the full matrix with Auto Speak. It stops at the first unsuccessful suite. Run the live microphone suite separately when the phone and Mac are in the same quiet room.

Install the relevant translation packs and voices before a device run. The matrix also installs missing listening assets and releases its temporary reservations on normal completion. Keep the Mac speaker audible during the live suite.

Open `tests.xcresult` in Xcode for individual failures, skips, and UI attachments. Each run keeps the Xcode log and a `summary.json` verdict. Selected tests that skip, including for missing packs, make the run incomplete and return a nonzero exit code. CI retains the simulator run as a downloadable artifact for seven days.

The matrix also writes `matrix-score.json` using the checked-in reviewed transcripts and translations. It flags missing turns, incorrect routing or playback, regressions on previously correct transcripts or translations, and new wording that needs human review. Previously observed meaning errors remain visible in the counts. The underlying runner also supports the reversed-primary rapid-reply and shared-analyzer experiments. [Matrix options and scoring](../evaluation/README.md#continuous-speech-on-iphone)

### Install and prepare an iPhone

1. Connect and trust an iPhone running iOS 26, enable Developer Mode when iOS
   requests it, and select the phone as the `LocalLingo` scheme destination.
2. Confirm Signing & Capabilities resolves the team and unique Debug bundle
   identifier from `Debug.local.xcconfig`, then run the app from Xcode.
3. Allow microphone and speech-recognition access. Keep the phone online for
   this one-time preparation phase.
4. Select the two languages at the top of Talk, open **Manage Language Packs**,
   and tap **Download and verify selected pair**. Selecting a language checks
   readiness but does not download it.
5. Wait until Listen for both selected languages, Translate both directions,
   and the required Speak voices report Ready. Repeat the explicit download for
   every pair in the acceptance matrix below.
6. Install missing Speak voices in Settings > Accessibility
   > Read & Speak > Voices. Speak is optional only when automatic speech and
   continuous-mode Speak are off.

The local catalog is English (US), Spanish (Spain), French (France), German
(Germany), Italian (Italy), Portuguese (Brazil), Japanese (Japan), and Korean
(South Korea). Any two distinct catalog languages can be selected. LocalLingo
checks and prepares the exact pair; Apple still decides whether both
translation directions are available on the current iPhone.

Debug and the offline Private Beta configuration additionally expose
`Hindi (Beta)` for English-Hindi conversations only. Hindi uses Apple's local
`DictationTranscriber`; it never falls back to network speech recognition.
Every continuous English-Hindi result remains review-required. With Speak on,
ordinary translations play automatically. A turn containing important details
waits until the tester checks the text and chooses Play translation. A detected
important-detail mismatch remains text-only and cannot be played.
Standard TestFlight and Release configurations omit Hindi until its physical
device, quality, and safety gates are complete. Current physical-device
evidence covers capability inventory and installation of the exact Hindi
live/final Dictation modules. A bilingual aggregate was only
download-eligible because the research app identity did not yet have the exact
English modules installed. Offline fixture inference, Translation execution,
Hindi speech synthesis, live continuous behavior, and quality remain pending.

LocalLingo does not use the iPhone marketing model as an eligibility gate. Any
iPhone that can install the iOS 26 build may launch the app. Before continuous
conversation begins or a turn resolved to Local Only records audio, the app
checks on-device Listen support for both selected languages and Translation
support and installed readiness in both directions. The applicable Start
control remains unavailable when a required component is unsupported or not
ready. Local Only never replaces a missing local capability with an online
request. Explicit Online Quality turns instead use their entitlement, consent,
service, and network gates.

The Language Packs screen shows the iPhone's Listen reservation limit.
LocalLingo protects both selected languages. If the limit is full, it releases
the least recently used inactive language before reserving a new one. To
release a selected language manually, change that side of the pair first, then
use **Release Listen reservation**. Releasing a reservation does not delete the
shared model file; iOS decides when that file is removed.

Apple manages removal of the other asset types outside LocalLingo. Remove
Translation assets in Settings > Apps > Translate > Downloaded Languages, and
install or remove Speak voices in Settings > Accessibility > Read & Speak >
Voices. Preparation may use the network; prepared Local Only conversations
must work with network access disabled.

### Device and pair acceptance

The following developer matrix covers all 28 selectable local pairs. Complete
it on each physical device for which you intend to make expanded-catalog claims.
It is broader than the current production release contract, which requires 96
signed cells for English-Spanish and English-Japanese across iPhone 15 Pro,
iPhone 16 Pro, and iPhone 17 Pro qualification tiers and two environments. Those
tiers are not a runtime allowlist. On another iOS 26 iPhone, first record the
pair-readiness result; if a required local capability is unavailable, confirm
that continuous and Local Only Start controls remain disabled.

| Pair | Pair Ready | Manual A to B | Manual B to A | Continuous pair | Airplane Mode |
| --- | --- | --- | --- | --- | --- |
| `en-US` / `es-ES` | Required | Required | Required | Required | Required |
| `en-US` / `fr-FR` | Required | Required | Required | Required | Required |
| `en-US` / `de-DE` | Required | Required | Required | Required | Required |
| `en-US` / `it-IT` | Required | Required | Required | Required | Required |
| `en-US` / `pt-BR` | Required | Required | Required | Required | Required |
| `en-US` / `ja-JP` | Required | Required | Required | Required | Required |
| `en-US` / `ko-KR` | Required | Required | Required | Required | Required |
| `es-ES` / `fr-FR` | Required | Required | Required | Required | Required |
| `es-ES` / `de-DE` | Required | Required | Required | Required | Required |
| `es-ES` / `it-IT` | Required | Required | Required | Required | Required |
| `es-ES` / `pt-BR` | Required | Required | Required | Required | Required |
| `es-ES` / `ja-JP` | Required | Required | Required | Required | Required |
| `es-ES` / `ko-KR` | Required | Required | Required | Required | Required |
| `fr-FR` / `de-DE` | Required | Required | Required | Required | Required |
| `fr-FR` / `it-IT` | Required | Required | Required | Required | Required |
| `fr-FR` / `pt-BR` | Required | Required | Required | Required | Required |
| `fr-FR` / `ja-JP` | Required | Required | Required | Required | Required |
| `fr-FR` / `ko-KR` | Required | Required | Required | Required | Required |
| `de-DE` / `it-IT` | Required | Required | Required | Required | Required |
| `de-DE` / `pt-BR` | Required | Required | Required | Required | Required |
| `de-DE` / `ja-JP` | Required | Required | Required | Required | Required |
| `de-DE` / `ko-KR` | Required | Required | Required | Required | Required |
| `it-IT` / `pt-BR` | Required | Required | Required | Required | Required |
| `it-IT` / `ja-JP` | Required | Required | Required | Required | Required |
| `it-IT` / `ko-KR` | Required | Required | Required | Required | Required |
| `pt-BR` / `ja-JP` | Required | Required | Required | Required | Required |
| `pt-BR` / `ko-KR` | Required | Required | Required | Required | Required |
| `ja-JP` / `ko-KR` | Required | Required | Required | Required | Required |

These 28 rows are the base catalog. Debug and `PrivateBeta` add only the
experimental `en-US` / `hi-IN` pair. Record each Listen asset, the combined
four-module status, Translation in both directions, Hindi playback, and the
Airplane Mode result separately. A ready download state is not release
qualification for Hindi.

For every direction, complete a normal spoken phrase, a number or time phrase
that invokes review, typed input, translated playback, slower playback, and
replay. Confirm that each speaker control captures the language shown on it and
that Start Conversation remains unavailable whenever the selected pair is
not ready.

For each Airplane Mode cell, repeat a manual turn in both directions and a
continuous sequence. The route indicator must remain Local Only and every turn
must finish without the LocalLingo backend. Across the matrix, also verify
permission denial and recovery, app backgrounding during capture,
interruption/cancellation, and the 30-second manual capture limit.

### Continuous pair mode

Continuous conversation is the primary Talk screen and remains local-only.
The microphone starts only when the center control is tapped. While active, it
uses the bundled Silero VAD Core ML model to find utterance boundaries and runs
the two selected Listen models together. Each language has one live and one
final-only transcriber, for four modules total. The app
chooses between only that pair and translates the winning transcript on-device.
All 28 base-catalog pairs in the matrix are selectable. Debug and `PrivateBeta`
add the English-Hindi beta pair. Actual availability remains gated by Apple's
on-device Listen and Translation checks.

Continuous translation defaults to Low Latency. Settings > Conversation can
instead prefer High Fidelity for the next session. When Apple Intelligence is
available, iOS can use it for that strategy; otherwise it can fall back to the
traditional Low Latency model. Speak Duet checks and prepares the model for the selected strategy in both directions.
iOS chooses the model used at runtime.

The Speak translations preference is remembered. When enabled, capture pauses
during playback and resumes afterward. The main control can also pause
listening without discarding speech already in progress: the app finalizes and
drains that fragment before entering the paused state, then opens a fresh
recognition segment on Resume. Ending keeps the completed transcript visible;
starting again creates a new session and clears the prior transcript. The mode
assumes one person speaks at a time and does not resolve overlapping speakers,
mid-utterance code switching, television audio, or noisy group conversations.
A low-confidence choice is retained and marked for review; **Swap detected
language** retranslates the stored alternate transcript without retaining
audio.

For each Continuous pair cell, validate at least ten alternating utterances
with Speak off, then ten with Speak on. Include short phrases, numbers, a 10-14
second utterance, rapid handoffs, silence longer than one second, a Bluetooth
route change, and backgrounding. Confirm that:

- capture remains open between utterances when Speak is off;
- each completed turn appears once and in spoken order;
- Speak pauses the microphone and capture resumes after playback;
- user Pause finalizes a valid in-progress phrase and Resume accepts new audio
  without duplicating earlier turns;
- uncertain turns expose the language-swap correction;
- a backlog pauses capture at the limit and resumes after it drains;
- End conversation finalizes an active utterance and drains completed turns;
- the completed transcript remains visible until the next session starts;
- no network request occurs and no raw audio is added to history.

For at least one representative pair, repeat the sequence once with Low Latency
and once with High Fidelity, restarting the conversation after each Settings
change. Record first-translation latency and bilingual quality observations on
the same utterances.

Simulator tests cover deterministic selection, queue, persistence, and
lifecycle policies. They cannot qualify dual SpeechTranscriber throughput,
microphone timing, VAD accuracy, or Translation model behavior.

Debug is intentionally the local-only MVP configuration: online routing,
StoreKit/Pro controls, and face-to-face layout controls are hidden and disabled.
The underlying future implementations remain available to Staging, TestFlight,
and Release configurations; this milestone does not qualify or release them.

## Private TestFlight beta

`PrivateBeta` packages the working Local Only experience for invited TestFlight
testers without coupling that beta to the unfinished backend, StoreKit, or App
Attest release work. It uses release optimization, has no App Attest entitlement,
and locks Online Quality, subscriptions, face-to-face, and the experimental local
LLM off after local overrides are applied. Continuous conversation and language
pack preparation remain available on supported iOS 26 iPhones. This
configuration exposes English-Hindi as `Hindi (Beta)` specifically to gather
the missing physical-device evidence described above; standard TestFlight and
Release builds do not expose it.

Create the ignored identity override and replace the bundle identifier, team
ID, and public privacy-policy URL with the values registered for the app:

```sh
cd ios
cp Config/PrivateBeta.local.xcconfig.example Config/PrivateBeta.local.xcconfig
xcodegen generate
```

Give every uploaded candidate a new positive `CURRENT_PROJECT_VERSION` and a
new immutable `RELEASE_BUILD_ID`. The bundle identifier must remain unchanged
after the App Store Connect app record is created. Before archiving, run the
tests and the unsigned distribution compile:

```sh
make ios-test
make ios-private-beta-compile
```

In Xcode, select the shared **LocalLingo Private Beta** scheme and a generic iOS
device, then choose **Product > Archive**. Validate and upload the archive from
Organizer. After App Store Connect finishes processing it, add the build to a
private external TestFlight group and invite testers by email. This flow does
not require tester device IDs and must not use a public TestFlight link.

## Configurations

Generate the project with the pinned tools described above. The configurations
have different trust and deployment purposes:

- Debug uses a developer-owned identifier and signing team, exposes only the
  held-phone Local Only workflow, and does not require a backend, StoreKit, or
  the App Attest entitlement.
- PrivateBeta is the release-optimized, invitation-only Local Only build. Use
  the final production bundle identifier when the beta will graduate under the
  same App Store listing; use a separate identifier only for an intentionally
  separate beta app. It has no service or StoreKit configuration and no App
  Attest entitlement. Its shared scheme archives this configuration.
- Staging uses a dedicated bundle and backend project. It
  performs real verification with Apple's development App Attest environment
  and StoreKit Sandbox; it never enables localhost fakes.
- TestFlight uses another dedicated bundle, API domain, and
  backend project. TestFlight builds must carry Apple's **production** App
  Attest entitlement while that isolated backend verifies StoreKit Sandbox and
  App Store Server API status. Never point this configuration at production.
- Release uses production App Attest. Its committed values are deliberate
  blockers, not usable defaults.

Developers may create untracked `Config/PrivateBeta.local.xcconfig`,
`Config/Staging.local.xcconfig`,
`Config/TestFlight.local.xcconfig`, and `Config/Release.local.xcconfig` for
non-authoritative compile checks; they are optionally included last by the
committed configurations. Start from the corresponding `.example`. Trusted
release evidence does not use these hidden files. An authenticated external
signing/build environment must supply the same settings to Xcode and the
resolved-configuration emitter; the committed protected workflow validates and
attests the resulting evidence but does not build or sign the archive. Release
requires:

```xcconfig
APP_BUNDLE_IDENTIFIER = org.company.locallingo
DEVELOPMENT_TEAM = ABCDE12345
APP_ATTEST_ENVIRONMENT = production
APP_RUNTIME_ENVIRONMENT = production
RELEASE_BUILD_ID = candidate-2026.07.12-1
API_BASE_URL = https:/$()/api.company.tld
STOREKIT_MONTHLY_PRODUCT_ID = org.company.locallingo.pro.monthly
STOREKIT_ANNUAL_PRODUCT_ID = org.company.locallingo.pro.annual
PRIVACY_POLICY_URL = https:/$()/company.tld/privacy
TERMS_URL = https:/$()/company.tld/terms
SUPPORT_URL = https:/$()/company.tld/support
```

Do not commit these local files or treat them as release evidence. PrivateBeta
preflight validates its distribution identity and version, locks its offline
feature flags, rejects the experimental LLM, and checks the app icon, usage
descriptions, and privacy manifest. It does not require or validate a backend,
StoreKit product, terms/support URL, or App Attest environment; it does require
an HTTPS privacy-policy URL for App Store Connect and the in-app Settings link. Staging,
TestFlight, and Release additionally verify their resolved online-service
configuration, expected attestation environment, HTTPS legal/API URLs, and
bundle-owned distinct products. Every deployment configuration rejects iCloud
capabilities and checks the complete opaque 1024-pixel AppIcon assets. The external
producer must emit the resolved non-secret configuration as hashed evidence and
cross-check its API/Apple/product/build contract against the Terraform plan;
the attestation wrapper signs the protected predicate after generation.
`RELEASE_BUILD_ID` must exactly equal the Terraform `release_build_id` for the
candidate. Online Quality accepts only an availability response marked
`self-reported-diagnostic` whose release ID and runtime environment match the
app. Every later session, challenge-pool, device, and translation request sends
that response's exact four-part build identity and binds it into the App Attest
v3 request digest. This prevents routing changes between preflight and content
submission; it does not replace independently signed release evidence.
The project targets iPhone only on iOS 26 and applies no marketing-model
allowlist. Any iPhone that can install the build may launch it; selected-pair
Listen and Translation capability and installed readiness determine whether
continuous conversation and locally resolved turns can start. The release
contract requires an iPhone 15 Pro, iPhone 16 Pro, and iPhone 17 Pro physical
matrix. A completed and accepted matrix would provide evidence for those
qualification tiers, not impose an installation restriction or prove that every
iOS 26 iPhone meets the same quality and performance budgets. Simulator runs
never count as physical-device evidence.

## Privacy behavior

Local Only is resolved before capture and makes no conversation-content network
request. Raw audio stays in bounded memory for the active turn and is never
persisted. On-device history is a separate, default-off setting that stores
bounded text snapshots under complete Data Protection, excludes them
from backups, and never uploads or backfills them. History is paged in groups of
25, limited to 500 conversations, 8 MiB per snapshot, and 16 MiB in aggregate.
Disabling history stops new writes without deleting existing records; Delete
All removes every on-device snapshot.

The privacy manifest declares transient Online Quality audio/user content for
app functionality and UserDefaults required-reason access. Reconcile it and App
Store privacy answers against observed Release-build traffic before every
submission.

## Safety behavior

Careful Mode shows bounded, separately labeled critical details extracted from
the source and translation. Medication or emergency content on either side
always displays the medical-use warning. The deterministic medication guard
canonicalizes reviewed names across the base eight languages and the Hindi
beta guardrails; an
otherwise unknown product is treated as a medication identity
only behind an explicit, bounded “medicine called …” construction. Formulation
suffixes such as XR and XL remain part of that identity. For typed Online
Quality turns, the validated text submitted by the user remains authoritative
and a changed backend echo is rejected rather than displayed or saved.

## Apple services

Confirm the production App ID has App Attest, StoreKit, and required speech
capabilities. It must not have iCloud containers or CloudKit services. Verify the
Release archive has no iCloud entitlement and that local history uses the
protected, backup-excluded application-support store. Audio, location, prompts,
auth data, and conversation text must never be placed in history metadata or
backups.

Use StoreKit sandbox and TestFlight to exercise verified purchase, restore,
active/grace state, expiration, refund/revocation, device-binding limits,
notifications, and Manage Subscription. Family Sharing is disabled for v1.

Physical-device release evidence must cover audio interruptions, Bluetooth,
backgrounding, rapid taps, cancellation races, network transitions, Local Only
packet capture, local-history paging/capacity/deletion, accessibility, thermal
and storage pressure, and all supported language directions.

See the canonical [decision log](../docs/decision-log.md) and
[release-trust contract](../docs/release-trust.md) before changing a deployment
configuration or treating an artifact as release evidence.
