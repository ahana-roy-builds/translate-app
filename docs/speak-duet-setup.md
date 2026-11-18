# Speak Duet commerce and accounts

This secondary repository uses the Speak Duet product name. Internal Swift
module/project names and existing local-history/settings keys remain LocalLingo
so existing data and the test suite continue to work.

## Implemented behavior

- Required, resumable onboarding explicitly selects a default language and a
  different conversation language. Download and start prepares the pair and opens
  Talk after both translation directions are ready. Pairs that only support
  manual turns offer a labeled manual conversation instead.
- Completing onboarding activates 14 elapsed days of translation on that
  device, without registering an account or authorizing billing.
- One monthly subscription unlocks all new continuous, manual, typed, and
  corrected translations. Existing text, sharing, deletion, and replay remain
  available when access expires.
- The local StoreKit configuration models US$4.99/month with a two-week
  introductory free trial. Actual distribution pricing and offer eligibility
  come from App Store Connect and StoreKit, never hardcoded UI copy.
- Optional Apple and Google authentication uses Firebase Authentication.
  Guests have no Firebase account. Sign-out does not cancel Apple billing.
- Accounts store identity only. Default language, settings, and history are
  not synchronized to Firebase. No Analytics, Firestore, or Crashlytics product
  is linked. Provider SDKs include their own privacy manifests.
- Deletion reauthenticates, revokes Apple authorization when applicable,
  deletes the Firebase identity, and optionally erases local text history.

The initial free record is stored in a non-synchronizing, device-only Keychain
item. It is independent of onboarding/settings resets and account sign-out.
It provides best-effort device-local enforcement: erased devices, Keychain
loss, and deliberate clock manipulation are not reliably prevented. Reinstall
retention is not guaranteed. This is the explicitly selected first version,
not a server-backed once-per-person trial.

## Local development

```sh
cd ios
xcodegen generate
open LocalLingo.xcodeproj
```

Select the **Speak Duet** scheme and an iPhone simulator. Its Debug run action
loads `Config/LocalLingo.storekit`, allowing simulated purchases without a real
App Store product. Debug preserves the existing developer bundle/signing
override, and does not require registering the proposed permanent identity.

Without a matching Firebase configuration, Account explains that sign-in is
unavailable in this build and leaves guest access available. There is no fake
authenticated state. Live Apple sign-in also requires the Apple capability
and a paid developer team; the default free-Personal-Team Debug entitlement
does not enable it.

The unit tests inject clocks/storage and exercise a genuine StoreKitTest
purchase, failed price loading, and expiry. UI tests use isolated Debug-only
onboarding/free-access fixtures and attach normal/accessibility screenshots.
These fixture launch arguments and storage are absent from Commerce binaries.
If the simulator StoreKitTest service cannot persist its test controls, the
purchase integration test explicitly skips with that reason. Entitlement
policy and failed-price-loading behavior still run in deterministic tests;
actual purchase/restore verification remains a device/TestFlight requirement.

```sh
make ios-test
make test-fast
```

The checked-in generated-workspace `Package.resolved` pins transitive packages;
`project.yml` pins Firebase 12.19.3 and Google Sign-In 9.2.0. Only FirebaseAuth
and GoogleSignIn products are application dependencies.

## Distribution setup

See the [TestFlight tracker](speak-duet-testflight.md) for current completion
status and beta submission copy. Banking/tax setup is complete per user
confirmation; Paid Apps Agreement status and Firebase provider acceptance still
need confirmation and do not block independent release preparation.
The user-supplied Firebase app configuration is installed locally; the bundle
ID and Google callback have been validated and the Xcode project regenerated.

As of November 6, 2026, the user has confirmed registration of the permanent
bundle ID **com.ahanaroy.speakduet** under Ahana's account and creation of the
Speak Duet App Store Connect record. This Mac has a usable Apple Development
identity for Ahana Roy; its certificate identifies signing team **TXG4R2U7P3**.
The user confirmed that same Team ID in paid Apple Developer Program membership
details (Individual). An initial stale Personal Team classification blocked
provisioning, but the subsequent signed Organizer archive succeeded under the
same team. User reports App Store Connect distribution/upload completed;
Apple processing and TestFlight installation remain pending.
The ignored `Commerce.local.xcconfig` has been prepared with that team, bundle
ID, and monthly product ID. The user has also confirmed creation of
`com.ahanaroy.speakduet.monthly` with the US$4.99 monthly price and two-week
introductory free trial. App Store Connect settings have not been independently
inspected from this workspace.

Firebase provider setup can proceed in parallel with development, local
StoreKit testing, and release preparation. The matching Firebase file and
callback scheme and verified public privacy/support URLs are wired into
Commerce. The first candidate is prepared as `0.1.0 (1)` with an immutable release
build identifier; both standalone and Xcode-resolved Commerce preflight pass.
The signed Organizer archive was created and the upload completed per user
confirmation. TestFlight installation, sign-in, account deletion, and purchases
remain to be verified.

Complete the remaining setup under Ahana's accounts before distributing the
commercial build:

1. Confirm Sign in with Apple is enabled for the registered explicit App ID
   and that any required developer agreements are accepted. Xcode can manage
   distribution signing through Organizer; the installed development
   certificate alone is not distribution signing verification.
2. The installed Firebase file identifies project `speak-duet` and the exact
   distribution bundle ID. Confirm Google and Apple authentication are enabled
   in that project's console. Complete Apple's provider credentials/return URL
   following the official instructions below. Apple private keys stay in
   provider configuration, never in the app or repository.
3. The matching `GoogleService-Info.plist` is installed in
   `ios/Resources/GoogleService-Info.plist` (Git-ignored) on this Mac, with
   `GOOGLE_REVERSED_CLIENT_ID` set to its exact `REVERSED_CLIENT_ID`. The app
   checks the bundle ID and callback scheme before initializing authentication.
   On another checkout, supply the ignored file and regenerate the project.
   A configuration for the Debug bundle is a different Firebase iOS app from
   the distribution bundle. Do not commit the local Firebase file.
4. Subscription creation is complete per user confirmation: one group and
   monthly product `com.ahanaroy.speakduet.monthly`, US$4.99/month, and a
   two-week free introductory offer. Complete any remaining commercial
   agreements, banking/tax setup, and product review metadata. Keep Family
   Sharing disabled for this first version. The development
   `speakduet.monthly` ID is only for local StoreKit tests and must not be used
   as the distribution product ID.
5. The [Speak Duet privacy policy and support pages](../distribution/speak-duet/)
   are published on GitHub Pages and verified over HTTPS. Their actual URLs
   are configured in Commerce; enter the same URLs into App Store Connect.
   A dedicated support contact remains pending before public App Store release;
   beta pages use TestFlight feedback. Account identity
   goes to the chosen provider/Firebase; conversation content and history stay
   local. The old no-account/no-collected-data LocalLingo policy and TestFlight
   metadata are not suitable for this account-enabled build.
6. Complete `ios/Config/Commerce.local.xcconfig` with the provider callback
   scheme, public privacy/support URLs, final version/build numbers, and an
   immutable release build ID. The local file is prepared on this Mac; other
   checkouts can copy `Commerce.local.xcconfig.example` and supply their
   verified signing team. Use the standard Apple EULA or supply reviewed
   terms. Do not put credentials in this file.
7. Regenerate and archive the **Speak Duet** scheme, whose Archive action uses
   **Commerce**. Its preflight rejects missing/placeholder deployment values,
   mismatched/missing Firebase configuration, unsafe feature flags, and
   incorrect account privacy disclosures. Online translation, face-to-face,
   and the local LLM experiment remain disabled. Commerce uses the base eight
   languages; Hindi remains exclusive to Debug and the legacy PrivateBeta.

Commerce is uploaded to TestFlight and can graduate to the App Store using the
same bundle identity. TestFlight uses sandbox purchases and does not charge
testers. Authentication services must still be genuinely configured. The
existing legacy TestFlight/Release online-backend configurations retain their
own deployment requirements and are not the offline commerce archive path.

## Physical-device acceptance

Verify both sign-in providers, user cancellation, reauthentication, Apple token
revocation, account deletion, and subscription management. Confirm the app's
Apple account can differ from its App Store purchasing account. Test purchase,
restore on another device using the purchasing account, trial eligibility,
renewal, billing grace, refund/revocation, and cancellation.

After downloading models and verifying access, cold-launch in Airplane Mode
and translate continuously, manually, and through typed input. A product-price
loading error must not erase valid paid access. New translations stop at a
safe utterance boundary after access expires; completed text remains visible.
Once the last verified subscription deadline passes offline, reconnect to
verify renewal instead of silently granting an additional paid period.

## Official references

- [Firebase Apple authentication](https://firebase.google.com/docs/auth/ios/apple)
- [Firebase Google authentication](https://firebase.google.com/docs/auth/ios/google-signin)
- [Apple introductory offers](https://developer.apple.com/help/app-store-connect/manage-subscriptions/set-up-introductory-offers-for-auto-renewable-subscriptions/)
- [Account deletion](https://developer.apple.com/support/offering-account-deletion-in-your-app/)
- [StoreKit testing](https://developer.apple.com/documentation/storekit/testing-at-all-stages-of-development-with-xcode-and-the-sandbox)
