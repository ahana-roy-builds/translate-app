# Speak Duet TestFlight preparation

Last updated November 6, 2026. This checklist applies to the **Speak Duet**
scheme and **Commerce** archive configuration in this secondary repository.
The legacy LocalLingo PrivateBeta/TestFlight release records are separate.

## Current status

| Item | Status | Evidence / next action |
| --- | --- | --- |
| Ahana's paid developer account | Membership confirmed — user | Membership details show Team ID `TXG4R2U7P3`, Apple Developer Program, Individual enrollment. The subsequent Organizer archive succeeds under the same team. |
| Development signing identity | Signed Organizer archive created | Latest matching archive, created November 6 at 7:41 PM local time, records Ahana's Apple Development identity and team `TXG4R2U7P3`. User subsequently reports the App Store Connect distribution/upload finished. |
| Physical iPhone connection | Ready; user reports setup working | Connected iPhone is USB-paired with Developer Mode enabled and developer services available. Xcode lists it as a compatible Speak Duet destination. User reports working after project/device guidance; detailed Commerce authentication and purchase checks are not confirmed. |
| Bundle ID | Registered, user confirmed | `com.ahanaroy.speakduet` |
| App Store Connect record | Created, user confirmed | Speak Duet; account is Ahana's. |
| Monthly subscription and introductory offer | Created, user confirmed | `com.ahanaroy.speakduet.monthly`, US$4.99/month, two-week introductory free trial. Final live product fetch remains unverified. |
| Banking and tax | **Completed — user confirmed** | User reports both setup tasks complete. Apple's processing/approval status has not been independently checked. |
| Paid Apps Agreement | Status confirmation pending | Confirm it shows Active before accepting sandbox purchase results. Banking/tax completion alone does not confirm the agreement status. |
| Firebase app configuration | Installed and validated | User supplied project `speak-duet` plist. Bundle and callback match Commerce; Xcode includes it as an app resource. File remains ignored and untracked. |
| Firebase providers and live authentication | **In progress** | User reports Apple console checklist through step 3 complete: app capability, Services ID setup, and Sign in with Apple key creation. Actual Services ID/Key ID and Firebase provider save are not independently verified. Firebase Apple/Google provider confirmation and device testing remain. |
| Local Commerce signing settings | Prepared | Ignored override contains bundle ID, Team ID, and monthly product ID. |
| First TestFlight candidate configuration | Prepared; unsigned archive verified | Version `0.1.0 (1)`, release ID `speakduet-0.1.0-1-20261107T033540Z-fab28392` after correcting archive-script inputs. Configuration preflight and the full unsigned Commerce archive pass. Bundle name/identity/version, Firebase resource, and Commerce privacy manifest were verified in that local check. Signed Organizer archive and upload are tracked below. |
| Privacy/support pages | **Published and verified** | GitHub Pages reports `built` from `main` / root. Support, privacy, CSS, and icon all return HTTPS 200 and match repo commit `52e9910`. Live URLs are configured in the ignored Commerce override. Dedicated contact remains pending; beta pages use TestFlight feedback. |
| App Store Connect URLs and App Privacy | **Draft saved — user confirmed** | User confirms completing the live privacy/support URL and draft data-type entry steps. Publishing is not confirmed. Final release report/provider behavior still needs review before publication. |
| TestFlight copy and review notes | Drafted below | Enter contact details only into App Store Connect, after final device verification. |
| Final Commerce archive and upload | **Uploaded; reached beta review — user confirmed** | Organizer archive metadata confirms `com.ahanaroy.speakduet`, `0.1.0 (1)`, Ahana's development signing identity and team `TXG4R2U7P3`. User reports successful upload and subsequently Waiting for Review under TestFlight → Builds → iOS. Installation remains unverified. |
| External TestFlight review | **Waiting for Review — user confirmed** | Build is submitted to TestFlight App Review. Approval, automatic-notification setting, actual tester invitations, and external installation are not yet confirmed. |

Statuses based on user confirmation are not App Store Connect API verification.
Update this table as each external task finishes; the initial device free
period is separate from Apple's introductory subscription trial.

Local site verification passed: both pages' links, anchors, and image/CSS
assets resolve; public HTML contains no personal email address, old-account
URL, or deployment placeholder. Browser checks covered 390px phone and 1280px
desktop layouts, the subscription FAQ, page navigation, and dark appearance.
Phone pages had no horizontal overflow or broken images; the browser console
reported no errors. The public site is now published and its four page/asset
responses match the corrected repository files.

- Support: https://ahana-roy-builds.github.io/speak-duet-support/
- Privacy: https://ahana-roy-builds.github.io/speak-duet-support/privacy.html

## Remaining release work

- [x] Receive and validate `ios/Resources/GoogleService-Info.plist` for the
  permanent bundle; set its exact reversed client ID in the Commerce override.
- [ ] Verify Apple capability, Firebase Apple provider Service ID, Team ID,
  key ID/private key, and return URL. Private signing keys stay out of the repo.
- [x] Complete banking and required tax forms (user confirmed).
- [x] Resolve Xcode's stale Personal Team signing blocker: a subsequent
  Organizer archive succeeds under Ahana's confirmed team.
- [ ] Confirm Paid Apps Agreement is Active and banking/tax processing has
  completed for sandbox purchase testing. TestFlight transactions do not charge.
- [x] Publish the privacy/support site, verify public HTTPS responses and
  assets, and configure the actual URLs in Commerce.
- [ ] Confirm a dedicated support contact before public App Store release.
  TestFlight feedback remains the beta contact route.
- [ ] Inspect the final archive's privacy report and complete App Privacy
  answers including SDK declarations listed below.
- [x] Prepare version/build `0.1.0 (1)` and an immutable release build ID for
  the first upload candidate. Issue a fresh candidate ID for later changes.
- [ ] Test physical-device language preparation and offline translation,
  optional sign-in, sign-out, reauthentication, Apple revocation, and deletion.
- [ ] Verify live product fetch, trial eligibility, purchase, restore,
  accelerated renewals, cancellation, expiry, and refund/revocation.
- [ ] Capture the actual paywall screenshot for subscription review. The
  current UI offers a new purchase after device free access ends; plan a
  realistic device test/review path for that state without a release-only
  clock or entitlement bypass. Existing local policy tests do not prove live
  App Store transactions work.
- [x] Archive Speak Duet using Commerce and automatic signing under Ahana;
  matching signed Organizer archive metadata verified.
- [x] Upload using Organizer's App Store Connect distribution workflow
  (user confirmed completion).
- [x] Build passed processing far enough to reach TestFlight App Review
  (user reports Waiting for Review; individual compliance answers not inspected).
- [ ] Install through an internal TestFlight group and perform the smoke test.
- [x] Submit the external build to TestFlight App Review (user reports
  Waiting for Review).
- [ ] Receive beta review approval and notify/invite external testers.
  Email invitations are the current intended rollout; automatic notification
  has not been confirmed.

The standalone Commerce preflight and the check using actual Xcode-resolved
Commerce settings both pass for the prepared first candidate. This is configuration
validation, not a signed-archive or provider-login result. The repository
scanner permits only a schema-validated Firebase client file at the canonical
resource path when it is both Git-ignored and untracked. Tracked copies,
unexpected fields, wrong callback values, and other embedded credentials stay
blocked.

Xcode's resolved Commerce settings have also been checked against the supplied
plist: bundle ID, signing team, monthly product ID, Google callback, and Commerce
compilation condition match. All 61 script tests and the repository structural
checks pass with the ignored Firebase file installed.

## Next console setup: Firebase providers

Open [Authentication providers for project speak-duet](https://console.firebase.google.com/project/speak-duet/authentication/providers)
using the Google account that owns the project. Confirm Google is enabled.
Complete Apple provider configuration following
[Firebase's Apple instructions](https://firebase.google.com/docs/auth/ios/apple).

1. In [Apple Identifiers](https://developer.apple.com/account/resources/identifiers/list),
   Sign in with Apple is enabled for `com.ahanaroy.speakduet` (user confirmed).
2. Services ID setup is complete through this step (user reported). Suggested description:
   `Speak Duet Authentication`; suggested identifier:
   `com.ahanaroy.speakduet.auth`. The actual identifier has not been independently
   verified. Enable Sign in with Apple for it, choose the app's primary App ID,
   and configure:

   | Field | Value |
   | --- | --- |
   | Domain | `speak-duet.firebaseapp.com` |
   | Return URL | `https://speak-duet.firebaseapp.com/__/auth/handler` |

3. Sign in with Apple key creation is complete (user reported). In
   [Apple Keys](https://developer.apple.com/account/resources/authkeys/list), record its Key ID
   and securely retain the downloaded `.p8` file outside the repository.
4. In Firebase Authentication → Sign-in method → Apple, enable the provider
   and supply the actual Services ID, Team ID `TXG4R2U7P3`, Key ID, and private
   key in OAuth code flow configuration. Save these in Firebase, not app code.
5. Test Apple/Google sign-in, cancellation, sign-out, and account deletion on a
   physical device with the configured Commerce build. The plist alone does
   not verify these server-side settings.

## First TestFlight upload in Xcode

Resolved signing blocker: the user's first archive reported that Personal Teams
cannot use Sign in with Apple and that no development profile exists for the
bundle. Xcode's local team cache marks `TXG4R2U7P3` as free; the user separately
confirmed the exact same Team ID in paid Apple Developer Program membership
details. A subsequent signed Organizer archive succeeded under that same team.
Individual paid enrollment is valid; no Team ID or Firebase Team ID change was
needed. User subsequently completed App Store Connect distribution/upload;
Apple processing and TestFlight installation are the next steps.

An independent unsigned archive check found the deployment preflight was denied
access to the Firebase client plist and Commerce privacy manifest. Both are now
declared as build-script inputs, with Firebase required only in Commerce so
other builds still work without a local Firebase file. Script sandboxing stays
enabled. The project was regenerated and all 61 script tests plus repository
validation pass. The unsigned Commerce archive also succeeds, including the
sandboxed preflight. Its bundled app identity/version, matching Firebase
resource, and Commerce privacy manifest were checked. A subsequent signed
Organizer archive was created and uploaded per user confirmation; the unsigned
`/tmp` verification archive remains a local build check.

1. Open this repository's `ios/LocalLingo.xcodeproj` and select **Speak Duet**.
   In Product → Scheme → Edit Scheme → Archive, confirm **Commerce** is the
   build configuration. Select a physical iPhone or **Any iOS Device**.
2. Choose Product → Archive. When complete, select the newest archive in
   Window → Organizer → Archives. Its internal app/project name may still be
   LocalLingo; verify bundle `com.ahanaroy.speakduet`, version/build, and team
   Ahana Roy instead of relying on that name.
3. Choose Distribute App → **App Store Connect** (the label shown in this
   installed Xcode; other versions call it TestFlight & App Store), which
   supports the planned internal and external rollout. Use Ahana's account/team and
   automatic signing. Complete Xcode's review and Distribute/upload step.
   The custom equivalent is App Store Connect → Upload.
4. In App Store Connect → Speak Duet → TestFlight, wait for build processing
   and resolve any applicable export-compliance prompt. Uploading the build
   does not itself submit a public App Store release.
5. Create an internal testing group, add the processed build and eligible
   App Store Connect users, then install using TestFlight and verify the
   Commerce flows. Keep actual account/provider and transaction results in
   the remaining acceptance checklist above.
6. For external email invitations, enter beta test information, feedback
   email, and review contact. Add the build to an external group and submit
   it to TestFlight App Review; invite testers after approval.

See [Apple's distribution workflow](https://developer.apple.com/documentation/xcode/distributing-your-app-for-beta-testing-and-releases).

## Privacy disclosure inventory

The app's own Commerce manifest declares name, email, and user ID for account
functionality, linked to the user, without tracking. That is not the full SDK
inventory. Local inspection of the pinned dependencies and their bundles in
the unsigned device build found:

| Source | Declared data | Linked | Declared purposes |
| --- | --- | --- | --- |
| Google Sign-In 9.2.0 | Name, email address, phone number, coarse location | Yes | App functionality |
| Google Sign-In 9.2.0 | User ID, other data types | Yes | App functionality and analytics |
| Google Sign-In 9.2.0 | Device ID, other usage data | Yes | Analytics |
| Firebase Auth 12.19.3 | User ID | Yes | App functionality |
| Firebase Auth 12.19.3 | Other diagnostic data | No | Analytics |

All these inspected manifests declare no tracking. Their declarations do not
prove that every field is collected in every app flow. Use them as the
conservative starting point for App Store answers and verify the final
archive/provider settings. The app does not request phone, contacts, or GPS
permissions or extra Google scopes. Do not equate absence of the separate
Google Analytics product with absence of provider analytics/diagnostics.

Conversation audio/text/history remain on-device. StoreKit purchase evidence
is checked locally with Apple and is not sent to a developer backend in
Commerce. Evaluate support information and Apple/TestFlight diagnostics based
on the final support route and Apple's disclosure definitions; do not reuse
the legacy app's "no data collected" answers.

## App Store Connect copy

### Beta description

Speak Duet is an iPhone conversation translator with on-device speech
recognition, translation, and spoken playback. Choose a default language and a
conversation language, download the required Apple language resources, and
take turns speaking. Continuous conversation, manual microphone turns, typed
input, and optional text-only history are available.

Supported base languages are English (U.S.), Spanish (Spain), French (France),
German (Germany), Italian (Italy), Portuguese (Brazil), Japanese, and Korean.
Requires iOS 26 or later; resource availability depends on Apple and the device.

Completing setup starts 14 days of free translation on that device. A monthly
subscription is offered afterward, with an additional two-week introductory
trial for eligible subscribers. TestFlight purchases use Apple's sandbox and
do not charge testers. Optional Apple or Google sign-in does not synchronize
conversation history. Conversation processing stays on the iPhone.

### What to test

1. Complete onboarding, choose two different languages, and verify the default
   language persists after reopening the app.
2. Prepare English and Spanish resources. Test continuous, manual, and typed
   translations; check language detection, turn order, pause/resume, and playback.
3. With resources ready and access valid, repeat in Airplane Mode.
4. Change the default language in Settings and verify it remains independent
   from the active conversation pair.
5. Try guest use, each sign-in provider, cancellation, sign-out, and account
   deletion. Local history must not appear on another device after sign-in.
6. Enable local history, save a conversation, share selected text, and delete
   history. Never include private conversation content in a bug report.
7. On a device eligible to show the purchase UI, test the App Store offer,
   purchase, restore, cancellation, and subscription expiry. Keep existing text
   available when new translation access expires.

### Beta review notes

Speak Duet uses bundle ID `com.ahanaroy.speakduet` under Ahana Roy's account.
Select the Commerce build. No sign-in or demo credentials are required to use
the app; Apple and Google accounts are optional.

Use a physical iPhone running iOS 26 or later. Complete setup with English
(U.S.) and Spanish (Spain), allow microphone and speech-recognition access, and
keep the device online while preparing Apple language resources. Once the pair
reports ready and translation access is valid, test offline continuous,
manual, and typed translations. Availability varies by device and Apple assets.

The first 14 days are device-local free access without billing authorization.
The monthly subscription is `com.ahanaroy.speakduet.monthly` with a two-week
introductory offer for eligible Apple purchasing accounts. This build uses
StoreKit and Apple's sandbox for beta purchases. Signing out or deleting the
optional Speak Duet identity does not cancel Apple subscription billing.

Conversation audio, transcripts, translations, and optional text history stay
on the iPhone. Raw audio is not saved. Account identity and provider technical
data are handled by the selected sign-in provider and Firebase Authentication.
The build has no online translation backend, advertising, face-to-face mode,
Hindi experiment, or local LLM experiment.

### Private fields to enter directly in App Store Connect

- Beta feedback email: dedicated support alias; visible to invited testers and
  used as invitation reply-to. It is not the private review contact field.
- Beta review contact: actual first/last name, phone, and email. Keep these out
  of repository files and public pages.
- Sign-in required: No, because guest access is supported.
- Privacy policy and support URLs: use verified live Speak Duet pages once
  published. Do not enter a proposed hostname as if it were live.

## References

- [Apple sandbox availability requirements](https://developer.apple.com/documentation/technotes/tn3186-troubleshooting-in-app-purchases-availability-in-the-sandbox?changes=_7)
- [TestFlight test information](https://developer.apple.com/help/app-store-connect/test-a-beta-version/provide-test-information/)
- [Apple privacy definitions](https://developer.apple.com/app-store/app-privacy-details/)
- [Firebase privacy information](https://firebase.google.com/support/privacy)
- [Pinned Google Sign-In manifest](https://github.com/google/GoogleSignIn-iOS/blob/9.2.0/GoogleSignIn/Sources/Resources/PrivacyInfo.xcprivacy)
