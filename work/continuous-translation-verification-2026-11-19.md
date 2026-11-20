# Speak Duet continuous translation on iPhone

November 19, 2026 · iPhone 13 Pro · iOS 27.2.1 (24B156) · Debug build

With Auto Speak off, the three full runs each saved and correctly routed all 174 turns. Meaning improved from 118/174 to **165/174, 162/174 and 163/174**. English–Spanish preserved all six messages every time. English–Hindi preserved four of six every time. The target of retaining all baseline successes remains open, principally because the Italian departure still loses its negated time. An additional all-language Auto Speak run exposed a wrong-language playback. The final build addresses that case and passed 18/18 turns in focused retesting. I recommend keeping it in internal testing until the remaining recognition errors have been checked with human speakers.

## Implementation

Talk now gives each pause its own bilingual recognition context. The next speaker can start while the prior turn finishes. Rapid captions use separate Apple reporting streams for the eight non-Hindi languages. Only the authoritative final streams supply the saved transcript. English–Hindi uses progressive dictation and retains its language-evidence rules. When both languages produce plausible complete sentences with similar scores, the final build requests a speaker choice before translating or playing audio. A strong text-language contradiction gets a bounded second recognition attempt, followed when necessary by an inline language choice and editable transcript. Confirming it updates the same turn, including its history and playback direction. [Turn recognition](../ios/Sources/Services/Local/TurnSpeechSession.swift) · [Speaker policy](../ios/Sources/Domain/ContinuousSpeechRecognition.swift) · [Coordinator](../ios/Sources/Services/ContinuousConversationCoordinator.swift)

The number checker associates localized amounts with their currency and each departure time with its affirmed or excluded role. It handles number words, counters, decimal grouping, clock forms and meridiem. A confirmed mismatch blocks automatic speech and replay. A fragment retaining only a currency symbol still triggers Hindi’s important-detail review. The UI offers both speaker languages when the direction is unresolved. [Number recognition](../ios/Sources/Domain/LocalizedNumericClaims.swift) · [Playback policy](../ios/Sources/Domain/ContinuousConversation.swift) · [Relay panel](../ios/Sources/UI/TalkParticipantPanel.swift)

## Physical-device results

The device ran every supported pair, alternating speakers on three scenarios. Each direction used the same station, ticket-price and departure-time recordings as the original baseline. Counts describe these specific recordings. [Original device report](all-language-iphone-report-2026-11-19.md) · [Per-turn evidence and model transcripts](continuous-translation-verification-2026-11-19.json)

| Metric | Baseline | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- | --- |
| Saved once on pause | 174 | 174 | 174 | 174 |
| Correct speaker and direction | 168 | 174 | 174 | 174 |
| Transcript retained meaning | 114 | 160 | 158 | 160 |
| Translation retained meaning | 118 | 165 | 162 | 163 |
| Clean-text translation retained meaning | 174 | 174 | 174 | 174 |
| Known-language recognition retained meaning (of 27) | 23 | 23 | 23 | 23 |
| Baseline successes retained (of 118) | 118 | 117 | 115 | 117 |
| Recoveries among 46 known-language opportunities | — | 44 | 42 | 41 |
| Turns held for speaker choice | — | 0 | 0 | 0 |
| Replays with intended locale and saved text (of 87) | 73 | 86 | 86 | 86 |
| Standalone target voices (of 9) | 9 | 9 | 9 | 9 |
| Detector endpoint to visible turn, median / p95 | — | 167 / 233 ms | 168 / 247 ms | 168 / 257 ms |
| Last audible fixture buffer to visible turn, median / p95 | — | 1487.5 / 1632 ms | 1497 / 1637 ms | 1504 / 1651 ms |
| Turns with a live draft (of 174) | — | 115 | 118 | 124 |
| First live draft when available, median / p95 | — | 680 / 1716 ms | 679 / 1710 ms | 684.5 / 1714 ms |

### Final meaning by spoken language

| Spoken language | Baseline | Run 1 | Run 2 | Run 3 |
| --- | --- | --- | --- | --- |
| English | 14/24 | 24/24 | 24/24 | 24/24 |
| Spanish | 19/21 | 21/21 | 21/21 | 21/21 |
| French | 15/21 | 21/21 | 21/21 | 21/21 |
| German | 13/21 | 21/21 | 21/21 | 21/21 |
| Italian | 18/21 | 17/21 | 16/21 | 17/21 |
| Portuguese | 8/21 | 21/21 | 21/21 | 21/21 |
| Japanese | 14/21 | 19/21 | 17/21 | 16/21 |
| Korean | 16/21 | 20/21 | 20/21 | 21/21 |
| Hindi | 1/3 | 1/3 | 1/3 | 1/3 |

## Where the remaining errors occur

English–Spanish preserved the intended message on all six turns in each pass. English–Hindi preserved four of six every time. All three English inputs translated correctly into Hindi. Of the three Hindi inputs, the station question survived, while the ticket fare and the departure time lost essential details during recognition. Feeding the correct Hindi text directly to the same translator preserved all three. Improving speaker selection alone cannot recover an amount or time that disappeared from the source transcript.

The revised build recovered 48, 47 and 46 of the 56 baseline misses. Restricting that comparison to the 46 recordings Apple could recognize when given the source language, the recoveries were 44, 42 and 41. All three runs exceeded the plan’s 141/174 translation target and its 23/46 recovery target. All six previously misassigned turns reached the intended participant on every run. None of the 168 previously correct assignments required a speaker prompt under the selection policy used for these three runs. The stricter policy added after the Auto Speak run has a measured prompt cost below. Injected conflicts in the simulator exercised language choice, editing, history replacement and suppression of playback.

The plan also required retaining all 118 baseline successes. The build retained 117, 115 and 117. Italian → Portuguese consistently rendered the train as leaving at nine and “doesn’t have ten,” losing the explicit exclusion of ten o’clock. The second pass also lost that distinction from Italian → German and reduced the Korean → Japanese ticket price to “表2.” The Italian departure and Korean fare failed the fixed-source recognition control too. In the truncated Korean example each recognizer received 3.33 seconds of audio, and the Korean recognizer returned only “표 두.” A correct choice of speaker can still produce an incomplete message. The Japanese ticket recording sometimes changed the ticket noun even when its numbers survived.

## Turn boundaries, captions and playback

On the twelve-turn English–Spanish and English–French comparison, the shared recognizer with revised word boundaries got 9/12 meanings and 10/12 speakers correct. Isolating the final recognition to each turn and adding fast captions got 12/12 for both, with live text on 10/12 turns. Both revised paths retained the Spanish word “puente” on a separate bridge replay. That one example does not distinguish the two approaches. In the first full test of isolated finals alone, just 14/174 turns displayed a live draft. The separate caption streams raised that to 115–124/174 across the three full runs. They never supply the saved transcript.

In two separate three-turn tests, Spanish and Hindi were each the primary language. The partner’s reply started before the first translation was saved. Each conversation saved all three turns in order, including turns ended by Pause and Stop. Both device lifecycle regression tests passed. They exercised real Apple playback following simulated scene interruption and verified that resuming preserved the conversation. The tests did not use the physical lock button.

All 232 numeric controls passed across the 58 directions. The checker accepted each equivalent price and departure and flagged each changed price and reversed departure. All nine previously blocked correct replays played on every full pass. Across each set of 87 replay requests, 86 completed in the intended target locale and spoke exactly the saved text. The remaining case was a Japanese count written with 枚 that Korean translated using 매. The delivery build recognizes both counters. On its focused six-turn iPhone rerun all three requested replays completed in the right language, including that fare. The Japanese recognizer transcribed “subtitles” in place of “tickets” on this repetition, so the meaning score was 5/6. This repairs the comparison of quantities. It cannot correct an unrelated noun that speech recognition misheard.

The three acoustic repeats used the same signed Debug binary. The next signed build added the Korean counter, flags currency symbols whose amount disappeared, and lets authoritative recognition continue if an optional caption stream cannot start. The all-language automatic-playback and focused Japanese–Korean checks used that build. The final build also recognizes the Korean construction “10시에는 출발하지 않습니다” (does not depart at ten). It had blocked a good German → Korean translation when the source and target both preserved the two times. Tests pair this exact output with an intentionally reversed departure. The evidence includes all three app-library hashes.

### Auto Speak on the installed language packs

On the focused English–Spanish and English–Hindi check, all twelve turns saved once. All six English–Spanish translations and the two English–Hindi station questions played in the intended locale with the saved text. The app held the four English–Hindi turns involving prices and times for review. All six manual replay requests completed after the scene interruption.

A separate full run with Auto Speak enabled saved all 174 turns. It preserved full meaning on 162/174 and the correct speaker on 173/174. The app spoke 166 turns, with 165 in the intended voice, and completed all 87 requested replays, with 86 in the intended voice. Every completed synthesis used the saved text. The same wrong assignment explains both voice errors. Eight automatic playbacks were held for important details or a mismatch. A cold standalone English → Hindi text-control call reported unsupported source language and skipped the two remaining text controls for that direction. All 171 other clean-text controls succeeded. The three live English → Hindi turns succeeded later in that session. The three prior full runs each passed all 174 clean-text controls.

The incorrect assignment was a German speaker asking “Wo ist der Bahnhof?” French recognition returned “Vous Esteban Hof” with slightly higher confidence. Each candidate’s text fit its own language very well. Before the fix the app spoke “Sie Esteban Hof” in German. The final build requires a speaker choice if both languages produce substantial finals with strong language evidence and neither leads by the existing minimum score margin. Both candidates remain available to confirm and edit. Replaying the recorded scores through this rule would have held the incorrect German assignment and one correctly routed Spanish → Portuguese ticket fare on the Auto Speak run. It would have prompted on one, zero and one previously correct turns in the three Auto Speak-off runs, each for that same fare. These are retrospective counts on captured decisions. The final signed build received additional targeted live testing below.

On the final installed build, all 18 spoken turns across German–Korean, French–German and Spanish–Portuguese preserved meaning, saved once and played the saved text in the intended language. All nine manual replays were correct. No speaker choice was needed on these fresh runs of the recordings. Two separate iPhone regression tests fed the actual ambiguous French and German candidate texts and scores back to the decision code. They verified that the app withholds translation and playback, accepts German as the speaker, and corrects the original turn in place. Two further iPhone tests verified the exact Korean negated departure, its deliberately reversed counterpart, and the 232 multilingual numeric controls.

## Offline Hindi model on the iPhone

Both recognizers received the same Hindi recording with the source explicitly set to Hindi. Their transcripts went through the same installed Apple translator. The six new utterances include a destination, a medicine price, a negated bus time, a short acknowledgement and two Hindi–English mixtures. They use the same synthetic voice at different rates. The scores below are my review of message meaning.

| Synthetic recordings | Apple recognition → Apple translation | Whisper large-v3-turbo Q5 → Apple translation |
| --- | ---: | ---: |
| Original thirteen | 6/13 | 10/13 |
| Six new prompts | 3/6 | 5/6 |
| Total | 9/19 | 15/19 |

Whisper recovered the station near the bridge, the six o’clock arrival, the medicine costing fifty rupees and a mixed-language meeting at three. Both systems missed the seven-versus-eight bus time and the original two-ticket price. Whisper also changed Delhi into Dili on a turn Apple got right. The older Apple baseline scored 8/13 on the original recordings. The 6/13 figure above is the fixed-Hindi control recorded beside Whisper during this run.

The 574 MB model took **12.02 s** to load. With the model resident, decode plus translation took **3.01 s median** and **4.29 s p95** across nineteen clips. Apple streamed recognition while the recording played and took **94 ms median** from input completion through translation. Whisper started decoding when the complete recording became available. The Debug process peaked at **741 MB decimal** (707 MiB), including Apple frameworks. The sampled iOS thermal state reached **serious**. Both English replies immediately following a model turn transcribed and translated correctly with the model still resident (254 ms and 129 ms after input).

On the repeat, all nineteen English outputs from each path matched that path’s first-run outputs exactly. Cached model load took **0.66 s**, while decode plus translation took **8.30 s median** and **10.30 s p95**. The phone reported fair to serious thermal conditions after the preceding device tests. Peak process memory was **744 MB decimal**. The host CPU energy counters totaled **0.614 J** during the nineteen Whisper decodes and **0.418 J** during the Apple streaming controls, or 30.5 and 19.9 mJ median per utterance. These counters cover the app process’s CPU work. They omit GPU energy, Apple’s out-of-process speech service, and the rest of the phone, so they cannot establish comparative battery drain. The two immediate English replies again succeeded. The benchmark removed its 574 MB model and nineteen recordings, and a device-container listing confirmed the staging directory was empty. [Apple kernel CPU accounting](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/task.c#L6387-L6403)

Keep Apple enabled for the Hindi Beta and Whisper in the development benchmark. The gain on these clips warrants testing a smaller or streaming model, with special attention to prices, proper names and mixed-language replies. A public model download still needs recordings from consenting speakers and blinded bilingual review in normal room noise.

## Method and coverage

The device runner feeds 27 synthetic 16 kHz WAVs at microphone speed through the app’s pause detector, bilingual speech recognizers, translator, coordinator, and real iOS synthesizer. The corpus uses one voice per language. The scorer checks the participant and target direction before counting meaning. Numeric amounts, currency, destination and negation must survive. Punctuation and intelligible paraphrases are accepted. For example, “I’m 30 euros for 2 tickets” conveys the fare despite its awkward opening. An amount and count attached to “subtitles” or “home” fails the same check. The same recording recurs across partners and runs. Repetition measures stability on that recording. [Fixtures](../evaluation/fixtures/continuous-speech/rows.json) · [Runner](../evaluation/scripts/run_continuous_matrix.py) · [Scorer](../evaluation/scripts/score_continuous_matrix.py)

Endpoint latency starts at the detector event. The second latency measure includes the silence the detector waits through and uses the last fixture buffer louder than roughly −44 dBFS as its starting point. Both end when the coordinator publishes the saved turn for the UI. Replay verification records the requested language, saved text and actual synthesis completion. The matrix uses synthetic input, and the interruption checks use the app’s background and foreground callbacks. Physical lock and unlock, spontaneous human speech, loudspeaker acoustics and blinded bilingual judgments remain outside this run.

The simulator selected 347 tests, with 338 passed and nine skipped when the separate StoreKit integration test was excluded. That test continued to report an active subscription after simulated expiration in an isolated rerun. The pass count includes the two tests of the competing French and German candidates and the Korean negated-verb regression. The baseline device trace had a SwiftUI background-publication warning without a source stack. Xcode reported no runtime warnings in the three full acoustic test results. The baseline warning was not reproduced with a backtrace.

To repeat a matrix run, build the LocalLingo Debug scheme for testing on iOS and supply its generated test specification, the iPhone UDID and a new result path to the checked-in runner. The scorer accepts a device log, the earlier baseline JSON and the verification JSON saved alongside this report. [Evaluation instructions](../evaluation/README.md) · [Hindi benchmark instructions](../evaluation/hindi-model-trial/README.md)
