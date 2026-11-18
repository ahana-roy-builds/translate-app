# Speak Duet Talk and onboarding fix plan

Start with the reported loss of hands-free turns. Use the same device run to identify the flashing UI. Then simplify setup using the verified Talk readiness rules. The runtime symptoms are user reports. The evidence below comes from the current working tree. The local diff against HEAD identifies leads but does not establish which code shipped in the last working build.

## 1. Restore translation after a natural pause

**Evidence.** The default Talk tab opens `ContinuousConversationView`. Its overflow menu also opens a manual conversation screen whose recording button explicitly translates on Stop. In continuous mode, each captured buffer goes to both recognition and voice activity detection. A live `.speechEnded` queues an utterance. The worker finalizes recognition for that audio range, translates it, and commits a turn. Pause and End have a separate path that flushes the detector. The worker silently drops `noSpeech`, so a missing displayed turn can also mean a boundary arrived but produced no accepted transcript. The detector defaults to 0.90 seconds of silence. [Manual control](../ios/Sources/UI/ConversationView.swift) · [Live and flush paths](../ios/Sources/Services/ContinuousConversationCoordinator.swift) · [Range finalization](../ios/Sources/Services/Local/AppleContinuousSpeechRecognizer.swift) · [Detector](../ios/Sources/Domain/VoiceActivityDetection.swift)

1. Reproduce on an iPhone with the affected build and language pair if available. Record build, iOS, pair, entry screen, button label, and Auto Speak setting. Start from Talk with a verified pair. Speak a short sentence with a brief hesitation, pause for two seconds, then alternate speakers for three turns. Repeat with Auto Speak toggled. Run manual mode as a control. If a previous working build is available, repeat on the same device and pair.
2. In a debug build, time capture start, speech start/end and reason, queue insertion, requested and delivered audio endpoints, analyzer finalization return, candidate count, translation completion, turn commit, and capture resume. Correlate events by session and turn number. Include access-check outcome and duration because the working-tree diff adds authorization at speech start and capture restart. Record only timings, states, counts, and outcomes. Compare a natural pause with a user-requested flush in a separate run.
3. Fix the first observed divergence. If users reached manual mode unexpectedly, correct the entry or fallback explanation. If the detector never emits an end, inspect captured silent buffers and detector input continuity before changing the threshold. If an end is queued, inspect audio-range alignment, finalization delay, discarded candidates, and worker errors. If a turn commits but the next speaker is missed, inspect capture pause/resume around playback. Preserve expiry handling for new turns and completion of an already-authorized turn.
4. Extend the existing detector and coordinator tests at the failing boundary. Exercise live buffer processing with a started and ended utterance, an authorized session, and subsequent turns before any Pause or End call. Include a shorter hesitation and a trailing utterance flushed once by End. Use a device run for the real microphone, speech analyzer, and playback path. [Detector tests](../ios/Tests/VoiceActivityBoundaryDetectorTests.swift) · [Continuous-mode tests](../ios/Tests/ContinuousModePolicyTests.swift)

**Pass condition.** One mic tap produces three correctly ordered translated turns across both directions. A brief hesitation stays within a turn. Playback resumes listening automatically when enabled, and ending the session does not duplicate a committed turn.

## 2. Remove transient download prompts

**Evidence.** Talk already gates its download panel on an inactive session. Its optional voice notice uses a different condition. Talk appearance, app activation, and system voice changes can each request a pair check. For a supported pair, the manager publishes all components as `.checking` before probing them. This makes a previously ready pair temporarily fail the Talk readiness test. It can also temporarily turn off the coordinator’s spoken-output preference. This explains a route to flicker around transitions. The exact surface seen mid-session still needs identification. [Talk presentation](../ios/Sources/UI/ContinuousConversationView.swift) · [Pair check](../ios/Sources/Services/LanguagePackManager.swift) · [Voice notification](../ios/Sources/App/RootView.swift) · [Foreground refresh](../ios/Sources/App/LocalLingoApp.swift)

1. During the first device run, capture the visible label and correlate it with screen, coordinator state, session activity, check trigger, pair/generation, and displayed notice. Inspect unexpected transitions to idle, ended, or failed if the full setup panel appears between turns.
2. Keep the last completed result for the same pair while a background recheck is in flight. Track checking separately from the result. Coalesce overlapping checks for that pair and retain generation protection for pair switches, cancellations, and explicit installations. For a new pair with no result, show a neutral checking state until a confirmed result determines the available action.
3. Drive setup actions and spoken-output availability from confirmed results. Preserve explicit installation progress, actionable failures, and the existing manual fallback for incompatible continuous assets. If a required asset actually disappears during use, surface a recovery action for the affected pair at a stable session boundary.
4. Test ready → recheck → ready, a genuinely removed asset, missing optional voices, overlapping refreshes, and an old check completing after a pair switch. Assert intermediate published states and visible actions while listening, processing, playing back, and resuming. [Manager tests](../ios/Tests/LanguagePackManagerTests.swift)

**Pass condition.** A same-pair recheck produces zero download prompts, layout jumps, or spoken-output interruptions during the three-turn test. A confirmed missing resource still presents the correct setup action.

## 3. Combine preparation and entry into Talk

**Evidence.** The last onboarding screen has independent download and completion buttons. Completion can currently succeed before resources are ready. The manager may return from `install(pair)` while the root SwiftUI translation task still has to prepare one or both directions. Its tests also allow manual setup to succeed on a device that cannot run the two recognizers together. [Current buttons](../ios/Sources/UI/OnboardingFlowView.swift) · [Installation lifecycle and existing tests](../ios/Tests/LanguagePackManagerTests.swift) · [Root translation task](../ios/Sources/App/RootView.swift)

- Show the pair and one primary action. Use **Download and start** for missing downloadable resources and **Start conversation** for a verified continuous-ready pair. While preparing, show progress and allow cancellation.
- Bind completion to the terminal outcome for the requested pair and operation generation. Require continuous listening and both translation directions for hands-free Talk. Optional voices can be missing. If only manual use is available, explicitly explain that each speaker taps to finish a turn and offer the existing manual route.
- On success, activate device access at onboarding completion, persist the selected pair through the existing store, and open the selected conversation screen with the microphone idle. Failure or cancellation leaves the selection intact and permits retry. Guard against repeated taps, late callbacks, and a view disappearing. A resumed setup should recheck installed resources. Preserve completed onboarding for existing users. [Onboarding persistence](../ios/Sources/Services/OnboardingStore.swift) · [Access activation](../ios/Sources/Services/TranslationAccessManager.swift)
- Verify preinstalled, fresh two-direction download, cancellation, interrupted setup/relaunch, retry, access-storage failure, and manual-only outcomes. Assert that the first direction finishing cannot advance onboarding, and that failure or cancellation cannot start the free period.

## 4. Clarify welcome and language selection

Replace the repeated mic symbol on the welcome screen with two speech bubbles and a small waveform. Use dark text on the mint primary button. Remove the introductory payment paragraphs and keep subscription details on the subscription screen. Keep the existing on-device privacy message. Use native language names and retain the existing supported-pair filtering.

| Screen | Proposed wording |
| --- | --- |
| Welcome | **Speak two languages. Have one conversation.** |
| How it works | Tap the mic once and take turns speaking. Speak Duet translates when you pause. |
| First speaker | **What language do you speak?** |
| Second speaker | **What language does the other person speak?** Show the first selection in the helper text and the resulting pair after selection. |

Use the hands-free wording once the device acceptance test passes. Update the existing onboarding UI journey, which currently advances without downloading, and its exact-heading assertions. Use controlled readiness fixtures for deterministic UI tests. Verify light/dark appearance, the largest supported Dynamic Type layout, and VoiceOver reading order on the revised screens. [Onboarding UI tests](../ios/UITests/OnboardingJourneyTests.swift)

## Verification and delivery order

Land the diagnosed Talk regression with its regression test first, then readiness presentation, then onboarding behavior and copy. Run the repository’s `make ios-test` simulator suite and repeat the physical-device three-turn test from fresh onboarding and with an already configured pair. Record build, device, language pair, Auto Speak setting, and measured pause-to-turn times with the result. Simulator tests alone cannot establish that live Apple recognition completes on a natural pause.

## Implementation and device evidence

The updated Debug build closes the recognizer’s input when a speech boundary pauses capture for Auto Speak, then prepares fresh input for the next turn. With the microphone kept open, recognition also gives a late first final result more time to arrive. Same-pair readiness checks now share a probe and retain the last confirmed result. The final onboarding action advances only after the manager confirms installation.

On November 17, the iPhone 13 Pro running iOS 27.2.1 translated three recorded turns using the installed English and Spanish speech and translation models. The first turn kept capture open. The second and third exercised the automatic playback pause and restart with a test playback service. Measured from the start of each recording until listening resumed, the turns took 4.93, 4.02, and 4.16 seconds. Ending the session kept exactly three turns. A separate test ran the bundled voice detector on three spoken phrases with silence between them. The input for both tests was synthetic PCM. The original room, microphone route, and acoustic conditions were not reproduced.
