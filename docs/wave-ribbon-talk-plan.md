# Wave ribbon for face-to-face Talk

Deliver the two TestFlight P0s together with the Talk-screen typography, language labels, light/dark styling, and speaking feedback from REQ-05. The selected design places the partner above a narrow mint waveform and the phone owner below it. The app-wide Light/Dark/Automatic preference can ship separately.

## What each person sees

| Moment | Bottom, owner viewing English | Top, partner viewing Spanish, rotated 180° | Center ribbon |
| --- | --- | --- | --- |
| Ready | English language label and shared mic control | Español language label | Still |
| Owner speaks | Partial English text updates in place | Last completed Spanish translation stays readable | Pulses on detected speech |
| Owner pauses | Last English draft stays visible until final text arrives | Previous text remains while translation runs | Contracts into a smaller wave |
| Turn commits | Final English original | Spanish translation | Settles |
| Partner replies | Latest English content stays readable while awaiting translation | Live Spanish original appears with the preceding translation still available above it | Pulses again |
| Partner’s turn commits | English translation | Final Spanish original | Settles |

Use the selected pair’s two roles for placement. Either person can speak first. Swapping languages while idle changes the contents of each seat. The top half, including its labels, always faces the partner.

## Implementation sequence

### 1. Remove the banner and expose the first draft

- Remove the Talk-specific top inset that renders the access message and Subscription button. Retain the existing Settings subscription entry, access checks, and paywall for blocked actions. A UI test should assert the dated banner is absent and an expired account still reaches the paywall through an attempted translation. [Root view](../ios/Sources/App/RootView.swift)
- Fix the first-turn rendering branch in Held phone and build the face-to-face surface around session state. Today a valid live draft is hidden whenever the completed-turn array is empty. Test a draft arriving before turn zero commits. Render setup and genuine failures through the existing readiness flow. [Continuous Talk view](../ios/Sources/UI/ContinuousConversationView.swift)

### 2. Project one session into two participant panels

- Keep one coordinator, microphone, translation queue, and history record. For each completed turn, render the original on the speaker’s side and the translation on the listener’s side, keyed by the same turn ID. Use the stored sequence for ordering. Reuse correction, review warnings, and replay eligibility from Talk. A corrected turn keeps its ID and updates both panels. [Coordinator](../ios/Sources/Services/ContinuousConversationCoordinator.swift) · [Turn model](../ios/Sources/Domain/Models.swift)
- Make transient text identifiable by recognition stream and audio range. Currently a draft contains a language and text but no time range, the recognizer selects from accumulated text, and both recognizer cleanup and turn commit can clear the current draft. With Auto Speak off, turn B can already be arriving when A finishes. Carry the range from recognition results, snapshot the draft at the speech boundary, and retire only the completed range. Discard stale callbacks after a stream restart. Keep draft revisions out of persistent history. [Draft type and selector](../ios/Sources/Domain/ContinuousSpeechRecognition.swift) · [Recognizer](../ios/Sources/Services/Local/AppleContinuousSpeechRecognizer.swift)
- Use the existing draft language selector for provisional attribution and the finalized speaker decision for the committed turn. If an early guess changes, move just the draft. Keep both panels anchored. A turn that yields no text or fails translation clears its pending indicator and follows the coordinator’s existing error or recovery path.

### 3. Drive the ribbon from actual work

- Derive a small display state from the existing voice activity events, utterance queue, and playback state. Listening with an open mic is quiet. A confirmed speech start pulses the bars even before the recognizer produces a word. Speech end with an outstanding utterance tightens the wave. A successful commit settles it. Keep playback visibly distinct so the app’s own voice never appears as a new speaker. [Voice events](../ios/Sources/Domain/VoiceActivityDetection.swift) · [Session states](../ios/Sources/Domain/ContinuousConversation.swift)
- Give active speech priority when the mic is open and an earlier turn is still processing. Give pause, end, interruption, and failure priority over decorative motion. Use a single lightweight SwiftUI animation driven by phase changes. Reduce Motion uses static bar shapes and a short status label. The ribbon is symmetric so either reader can interpret it from across the table.

### 4. Build the screen and layout switch

- Give the two panels equal space around the ribbon. Keep language labels fixed, the newest content prominent, and recent context scrollable per participant. Follow the latest turn when a reader is at the end; preserve their position when they scroll back. Keep the last translation on screen while adding the next draft. Use concise role labels in each reader’s language, including a localized equivalent of “You said” or “Translation.”
- Keep a single compact owner-facing control area for start, pause/resume, end, playback preferences, and switching layouts. Hold the coordinator above both layouts so switching mid-turn simply redraws the current session. Keep the layout switch reachable while Talk’s overflow menu is hidden during capture. Language-pair changes retain their existing session restrictions.
- Add a persisted **continuous Talk** preference using the existing layout enum. Default a missing preference to Face to face and remember an explicit Held phone choice. The existing layout field also controls Manual Conversation and is forced to Held phone in several builds, including Commerce and Debug. Give continuous Talk its own key so its default works in the actual Speak Duet distribution configuration. Test decoding existing settings and reopening after a choice. [Settings normalization](../ios/Sources/Services/SettingsStore.swift) · [Settings model](../ios/Sources/Domain/Models.swift)
- Use the existing adaptive theme for each seat, with contrast from typography and labels as well as color. Check large Dynamic Type on a 13 Pro, readable text in both orientations, safe areas, 44-point controls, and logical VoiceOver focus. Announce completed turns once. Partial word revisions should preserve focus.

## Verification and release

1. **Unit tests.** Cover either speaker going first, partial revisions, provisional language changes, final attribution, correction by ID, and silence with no transcript. Force A to finish after B starts. Assert B’s draft survives, both panels have one entry per committed turn, and the ribbon reflects the active speaker. Cover playback, retry, cancellation, and stream restart.
2. **Simulator UI tests.** Use deterministic turns to capture the first draft, resolving, first translation, reverse-direction reply, and mid-turn layout switch. Check the rotated partner label and text, light/dark contrast, large text, Reduced Motion, and an unusually long turn. Exercise the access banner removal and genuine missing-pack notice.
3. **Physical TestFlight acceptance.** Put the iPhone 13 Pro between two people. Start once, exchange at least three English–Spanish turns with Auto Speak off, then repeat with it on. Include a brief hesitation, a fast reply, changing layouts mid-session, and changing the pair while idle. Verify the first words appear during speech, the prior translation stays readable, both readers can identify originals and translations, playback returns to listening, and the session ends with exactly the expected turns. Record time from speech onset to first visible draft and from a natural pause to visible translation for comparison with the current build.

Ship the two-person screen when this live microphone test passes on the intended TestFlight build. The earlier prerecorded device checks remain regression coverage for translation and pause handling.
