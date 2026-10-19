# Private beta App Store Connect package

Prepared for the offline-only `PrivateBeta` configuration on 2026-08-11 and
amended for the Hindi beta on 2026-08-15. This document contains no private
contact values. Replace bracketed private fields only in App Store Connect,
never in the repository or a public support page.

## App record

| Field | Value |
| --- | --- |
| Platforms | iOS |
| App Store Connect record name | LocalLingoTranslate |
| Installed display name | LocalLingo |
| Primary language | English (U.S.) |
| Bundle ID | `com.sivaramankh.locallingo` |
| SKU | `locallingo-ios-001` |
| Primary category | Travel |
| Secondary category | Utilities |
| Made for Kids | No |
| User access | Full access unless the account needs role-based restriction |

`LocalLingoTranslate` is the current App Store Connect record name. The binary
and in-app product intentionally use the shorter display name `LocalLingo`.
Keep that relationship explicit in the beta description and review notes so
reviewers and invited testers do not mistake them for different apps. Resolve
the public listing name before a later App Store release; this beta record name
does not change the product branding or the privacy policy.

Use the standard Apple EULA. Leave the marketing URL blank for this beta. The
privacy-policy URL must be a public HTTPS page, but it must not display the
developer's personal email address. A later public App Store version will also
need a support URL; use a contact form or a purpose-created support alias rather
than exposing a personal address.

The app includes the Silero VAD Core ML model under the MIT license. If App
Store Connect asks whether the app contains, shows, or accesses third-party
content, answer that it does and that the developer has the necessary rights.
The bundled notice is in `ios/Resources/ThirdPartyNotices.txt`. Confirm rights
for the app icon and any future screenshots before a public App Store release.

## TestFlight test information

Language: English (U.S.)

### Beta app description

LocalLingoTranslate is the TestFlight record for the installed app named
LocalLingo. LocalLingo is an offline conversation translator for travelers.
Choose any two languages from English (U.S.), Spanish (Spain), French (France), German
(Germany), Italian (Italy), Portuguese (Brazil), Japanese, and Korean. After
the iPhone downloads the required Apple language resources, tap the center
microphone to keep listening between utterances. LocalLingo detects which of
the two selected languages was spoken, displays the transcript and translation,
and can speak the translation.

This invitation-only `PrivateBeta` also exposes `Hindi (Beta)` for
English-Hindi conversations only. It is an experimental device-testing path,
not a production support claim. Current evidence covers physical-device
capability inventory and installation of the exact Hindi Dictation modules;
offline fixture inference, the complete bilingual module set, Translation,
Hindi speech synthesis, live continuous behavior, and quality review remain
pending. Every English-Hindi continuous result is review-required. With Speak
on, ordinary translations play automatically; turns containing important
details wait for the tester to check the text and choose Play translation. A
detected important-detail mismatch remains text-only and cannot be played.
Standard TestFlight and Release configurations omit Hindi.

This beta also includes manual per-language microphone turns, typed input,
replay and slower speech, and optional text-only history stored on the iPhone.
During translation, conversation audio, language detection, transcripts, and
translations are processed on the device and are not sent to a LocalLingo
service. No account or purchase is required.

Requires iOS 26. Model availability and translation quality vary by language
and iPhone. Use one speaker at a time. Do not rely on LocalLingo for emergencies,
medical decisions, legal matters, or as a replacement for a qualified
interpreter.

### Feedback email

Enter `[PRIVATE_FEEDBACK_EMAIL]` only in App Store Connect. Apple states that
this address is available to testers for feedback and is the reply-to address
on invitation emails. It is not a public App Store listing field, but invited
testers can see or use it. Create a dedicated support alias first if the
personal account address should also be hidden from invited testers.

### What to test

Start with English and Spanish on an iPhone running iOS 26:

1. Allow microphone and speech-recognition access when requested.
2. Select the two languages at the top. In the Offline setup panel, tap
   Download and verify selected pair. Stay online until Listen for both
   languages and Translate report ready.
3. Tap the center microphone and alternate short utterances, leaving a pause
   between speakers. Confirm that every utterance appears once, the detected
   language is correct, and the source and translation remain in spoken order.
4. Test Pause, Resume, End conversation, spoken translations, and Swap detected
   language on an uncertain turn. Speaking playback should not be transcribed
   as a new turn.
5. Open the top-right menu and test Manual Conversation in both directions.
   Also test typed input, replay, and slower playback.
6. In Settings, try Low Latency and High Fidelity in separate new sessions.
   High Fidelity may fall back depending on the iPhone.
7. Enable text history, complete a conversation, then verify history sharing
   and Delete all history. Raw audio must never appear in history.
8. After the selected pair is ready, enable Airplane Mode and repeat continuous
   and manual turns. Translation should continue without a LocalLingo service.
9. After completing the English-Spanish baseline, optionally select
   English-Hindi. Record both individual Listen states, the combined
   four-module state, both Translation directions, Hindi playback, continuous
   turns, and the Airplane Mode result separately. A download-eligible state is
   not the same as installed or release-qualified, and no step may use a
   network speech fallback.

Please report the iPhone model, iOS version, selected language pair, whether
Speak was enabled, and steps for any crash, stalled download, wrong language,
duplicate or missing turn, unexpected network dependency, or poor translation.

## TestFlight App Review information

Enter these contact values only into the private App Store Connect review
fields:

| Field | Value |
| --- | --- |
| First name | `[PRIVATE_REVIEW_FIRST_NAME]` |
| Last name | `[PRIVATE_REVIEW_LAST_NAME]` |
| Phone | `[PRIVATE_REVIEW_PHONE]` |
| Email | `[PRIVATE_REVIEW_EMAIL]` |
| Sign-in required | No |

### Review notes

The App Store Connect record is named LocalLingoTranslate; the installed app
and in-app product are named LocalLingo. Both names refer to this beta with
bundle ID `com.sivaramankh.locallingo`.

This build is an intentionally offline-only private beta. Online Quality,
subscriptions and in-app purchases, App Attest, face-to-face layout, and the
experimental local LLM are disabled. No account or demo credentials are
required.

Testing requires a physical iPhone running iOS 26. On first launch, grant
microphone and speech-recognition permission. English (U.S.) and Spanish
(Spain) are the recommended review pair. Select them at the top of Talk, then
tap Download and verify selected pair in the Offline setup panel. Keep the
device online while iOS downloads Apple-managed Listen and Translation
resources. Preparation time and availability are controlled by iOS. If a Speak
voice is unavailable, spoken translations can be turned off with the speaker
button; text translation remains testable.

When the pair reports ready, tap the center microphone. The microphone remains
open across utterances. Speak one language at a time and pause briefly after a
phrase. The app chooses between only the two selected languages, finalizes the
utterance locally, translates it on-device, and displays the source and
translation. The center control pauses and resumes; the stop control ends the
session. Manual Conversation is available from the top-right menu and uses one
microphone per selected language; tap the active microphone again to finish a
manual turn.

After language preparation, continuous and manual translation can be verified
in Airplane Mode. Conversation audio is never persisted. Optional history is
off by default, stores text only on the iPhone, is excluded from backup, and can
be deleted in Settings or explicitly shared to an app selected by the user. The
build has no developer-operated conversation service, analytics SDK,
advertising SDK, or tracking. Network access during setup is limited to
Apple-managed language resources; user-opened legal or support links may also
open an HTTPS page.

This `PrivateBeta` alone exposes `Hindi (Beta)`, limited to English-Hindi. Its
local Listen path uses Apple's `DictationTranscriber` and has no network speech
fallback. Physical-device inventory and exact Hindi module installation have
been recorded, but offline fixture inference, installation and execution of the
complete bilingual module set, Translation in both directions, Hindi speech
synthesis, live continuous behavior, and quality review are still pending.
English-Hindi continuous results always require review. With Speak on, ordinary
translations play automatically; turns containing important details wait for
the tester to choose Play translation after checking the text. Turns with a
detected important-detail mismatch remain text-only and cannot be played.
Standard TestFlight and Release builds omit Hindi.

Translations can be wrong. The app is not an emergency, medical, legal, or
professional-interpreter service. The bundled Silero VAD model is used only to
find speech boundaries and is distributed under the MIT license.

## App privacy answers

These answers apply only to the uploaded offline `PrivateBeta` build and must be
revisited before enabling Online Quality, subscriptions, analytics, a support
upload, or any other off-device processing.

| Question | Answer |
| --- | --- |
| Does the developer or a third-party partner collect data from this app? | No, we do not collect data from this app |
| Tracking | No |
| Privacy Policy URL | `https://sivaramankh.github.io/locallingo-privacy/` |
| Privacy Choices URL | Leave blank |

Rationale:

- Live audio, transcripts, translations, synthesized audio, language detection,
  and optional history remain on the iPhone unless the user explicitly exports
  text through the system share sheet to a recipient app they select.
- Raw audio is never saved. Text history is off by default and is not uploaded
  or backed up by the app.
- The build has no account, backend URL, purchase flow, advertising, analytics,
  tracking, or developer-operated crash-reporting SDK.
- Apple manages Speech, Translation, voice-asset downloads, TestFlight, and any
  Apple diagnostic collection. Apple says data processed only on-device is not
  collected for the App Privacy answers and that developers are not responsible
  for disclosing data Apple itself collects.
- The `PrivateBeta` privacy manifest declares no tracking domains and no
  collected data types.

Do not reuse these answers for the future online TestFlight or Release
configurations. Those configurations have different data flows.

## Export compliance

The candidate `Info.plist` sets `ITSAppUsesNonExemptEncryption` to `false`.
The source contains no proprietary or non-standard encryption. It references
Apple-provided CryptoKit for hashing and signature verification in disabled
future paths and uses operating-system data protection. Therefore:

- If App Store Connect asks whether the build uses non-exempt encryption,
  answer No.
- If the questionnaire first asks whether the app contains or uses encryption,
  do not claim that the binary contains no cryptographic functionality. Follow
  the branch for standard or Apple operating-system cryptography and identify
  it as exempt.
- The expected result is no export-compliance document upload. Confirm this
  against the exact archived binary and current questionnaire before submission;
  the developer remains responsible for the legal determination.

## Age rating and content assumptions

Use the current App Store Connect age-rating questionnaire with these proposed
answers for this offline build:

| Section | Proposed answer |
| --- | --- |
| Parental controls | No |
| Age assurance | No |
| Unrestricted web access | No |
| User-generated content | No |
| Social media | No |
| Messaging and chat | No |
| Advertising | No |
| Profanity or crude humor | None |
| Horror or fear themes | None |
| Alcohol, tobacco, or drug references | None |
| Medical or treatment information | None |
| Health or wellness topics | None |
| Mature or suggestive themes | None |
| Sexual content or nudity | None |
| Graphic sexual content and nudity | None |
| Cartoon or fantasy violence | None |
| Realistic violence | None |
| Prolonged graphic or sadistic violence | None |
| Guns or other weapons | None |
| Gambling | No |
| Simulated gambling | None |
| Contests | None |
| Loot boxes | No |
| Age category/override | Not Applicable; do not override |

Expected iOS 26 global rating: 4+. Do not select Made for Kids.

These answers assume LocalLingo only translates a participant's private,
face-to-face speech or typed text. It does not provide a content catalog,
publish user content, connect remote users, provide medical guidance, or allow
unrestricted browsing. Opening a fixed privacy/support link in the system
browser and sharing one's own local history through the system share sheet do
not create those capabilities. Reassess the questionnaire if any of these
assumptions changes. The app is not a regulated medical device and should use
Travel, not Medical or Health & Fitness, as its category.

## External beta distribution

- Create an internal group named `LocalLingo Internal` first; Apple currently
  requires an internal group before an external group can be created.
- Group name: `LocalLingo Private Beta`
- Invitation method: individual email invitations only
- Public link: disabled
- Automatically notify testers: leave off for the first reviewed build, inspect
  the processed build, then notify testers manually after approval
- Build availability: TestFlight builds expire after 90 days

### Fields to complete after upload

After the build finishes processing, enter these values before adding it to the
external group:

| Location | Field | Value |
| --- | --- | --- |
| TestFlight > Test Information | Language | English (U.S.) |
| TestFlight > Test Information | Invitation Experience > App Information | Off for this unreleased beta |
| TestFlight > Test Information | Beta App Description | Use the text under **Beta app description** above |
| TestFlight > Test Information | Feedback Email | `[PRIVATE_FEEDBACK_EMAIL]` |
| TestFlight > Test Information | Marketing URL | Leave blank |
| TestFlight > Test Information | Privacy Policy URL | `https://sivaramankh.github.io/locallingo-privacy/` |
| TestFlight > Test Information | App Review first and last name | `[PRIVATE_REVIEW_FIRST_NAME]` and `[PRIVATE_REVIEW_LAST_NAME]` |
| TestFlight > Test Information | App Review phone | `[PRIVATE_REVIEW_PHONE]` |
| TestFlight > Test Information | App Review email | `[PRIVATE_REVIEW_EMAIL]` |
| TestFlight > Test Information | Sign-in required | No |
| TestFlight > Test Information | Review Notes | Use the text under **Review notes** above |
| External group > Add Build | What to Test | Use the text under **What to test** above |
| External group > Add Build | Automatically notify testers | Off for the first reviewed build |

If build processing asks about export compliance, confirm that the build does
not use non-exempt encryption. Do not submit the build as TestFlight Internal
Only, because that upload type cannot be added to an external group. Submit the
first external build for TestFlight App Review, inspect the processed build
after approval, and only then invite the selected testers by email.

## Values still required

The following values cannot be inferred or safely published:

- private App Review contact first name, last name, and phone number;
- confirmation that the private account email may be visible to invited testers
  as the TestFlight feedback/reply-to address, or a dedicated alias;
- legal copyright owner for a later public App Store version;
- public support URL using a contact form or non-personal support identity for a
  later public App Store release.

## Apple references

- TestFlight test information:
  <https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information>
- External tester review and invitation flow:
  <https://developer.apple.com/help/app-store-connect/test-a-beta-version/invite-external-testers>
- App Privacy answers:
  <https://developer.apple.com/app-store/app-privacy-details/>
- Managing App Privacy:
  <https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy>
- Export compliance:
  <https://developer.apple.com/documentation/security/complying-with-encryption-export-regulations>
- Age-rating categories:
  <https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions>
