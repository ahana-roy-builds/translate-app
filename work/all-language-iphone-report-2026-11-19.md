# Speak Duet language test and fix plan

November 19, 2026 · iPhone 13 Pro · 9 languages · 29 supported pairs

All **174/174** spoken turns saved automatically after a pause. **168/174** went to the correct speaker and **118/174** delivered the full intended meaning. With clean reference text, **174/174** translations preserved the expected meaning. I would prioritize the speech path and the handling of numbers before changing the translator.

| Stage | Result | What it measures |
| --- | --- | --- |
| Clean-text translation | 174/174 retained meaning | Returned text on 174/174 calls |
| Known-language recognition | 23/27 retained meaning | One three-clip pass per locale |
| Continuous speaker selection | 168/174 correct | Saved participant and translation direction |
| Continuous transcription | 114/174 retained meaning | Right source and complete message |
| Final translation | 118/174 retained meaning | Right target and complete message |
| Reviewed replay | 76/87 completed | 76 matched the stored target and text, 73 reached the intended voice |
| Standalone playback | 9/9 completed | Requested each target locale directly |

Of the spoken failures, **56** already had a wrong speaker or incomplete transcript. **0** had a correct source and full transcript but lost meaning on translation. Of the 11 unavailable replays, 11 carried an entity-mismatch warning. My review counted 9 of the blocked final messages as correct. Wrong-speaker turns marked for review numbered 6/6.

Before installing translation assets, only English ↔ Spanish and English ↔ Hindi returned a station translation. Apple returned the specific missing-model error for the other 54 directions. Six translation downloads completed, and each of the six additional listening languages was exercised on the phone. The device reported five speech reservation slots. The tests rotated test reservations while preserving the initial English, Spanish and Hindi reservations.

[Machine-readable evidence for every turn, replay and control](all-language-iphone-evidence-2026-11-19.json)

## Findings that affect the fix

**Continuous recognition loses words that the same iPhone can recognize.** On the French departure sentence, fixed-language recognition heard “Le train part à 9h, pas à 10h.” In continuous French → English the transcript stopped at “pas à” and the English stopped at “not at.” In English → German, “Where is the train station?” became “Wo ist der Zug?” In Japanese → English, the fixed-language recognizer got the tickets right, but the continuous turn told the listener it cost 30 euros for two axes. In Portuguese → English, “the train leaves” became “come in and leave.” The repeated bridge test below also lost its last word. A different noun or subject also calls for comparing the underlying recognizers and candidate selection.

**All six speaker mistakes were on English audio.** The English ticket recording went to the Spanish, French, German or Italian participant depending on the partner. English departure-time audio went to the German or Japanese participant. All six carried a language-review flag. English ↔ Spanish retained meaning on 5/6 turns. English ↔ Hindi assigned the correct participant on 6/6 and retained meaning on 4/6. Both Hindi-source failures also failed the fixed-language control. The earlier, broader English–Spanish fixture set exposed additional errors. [Earlier comparison](english-spanish-vs-hindi-device-comparison-2026-11-18.md)

**A replay error can start with speaker selection or entity handling.** All 76 completed replays used the saved text and target locale. In three cases the wrong speaker had been saved and the listener got the wrong language. In another nine cases a correct final message was unavailable for replay. For example, the Spanish price “Dos billetes cuestan 30 €” was correctly rendered as “2枚のチケットは30ユーロです。” and replay was blocked. The coordinator explicitly rejects reviewed replay on an entity-mismatch warning. The automatic speech policy applies a different rule to Hindi and the other pairs. Auto Speak was off during this matrix. [Reviewed replay](../ios/Sources/Services/ContinuousConversationCoordinator.swift) · [Automatic speech](../ios/Sources/Domain/ContinuousConversation.swift)

**The warning cannot distinguish a correct price or departure from these specific changes.** In all 58 directions, changing thirty to forty produced exactly the same mismatch decision as the correct price. Reversing “nine, not ten” produced the same decision as the correct departure time in all 58. The extractor relies in part on digit patterns and small number-word dictionaries, then compares recognized values by kind without tracking which time is negated. This explains how it can reject an equivalent localized price and accept a reversed departure. A wrong number that already entered the source transcript presents a separate problem. Matching two texts cannot recover what the speaker actually said. [Extraction and comparison](../ios/Sources/Domain/EntityIntegrity.swift)

**Secondary diagnostic.** Xcode also recorded a SwiftUI warning about publishing changes from a background thread in the hosted device run. The log does not identify the publisher. Capture a backtrace in the app before tying this warning to a user-visible issue.

## Does extending the speech boundary fix it?

I replayed three English–Spanish recordings in fresh sessions on the phone, alternating two requests for the normal finalization range with two requests for an additional 320 ms. The production recognizer still clamps the requested range to delivered audio. The pause detector returned the same boundaries on the repeated bridge recording. The normal range delivered “bridge” once in two runs. The extended request lost it on both runs. When the saved Spanish text lost “puente,” the alternate recognizer still contained it. In all four fresh-session English ticket trials the app recognized the speaker and amount correctly, although the identical clip had been routed to Spanish in the preceding multi-turn test.

All four Spanish departure controls retained both times and the negation. A fixed delay alone did not resolve these recordings. Instrument which final timed words were available and which were retained, compare shared-session and isolated-turn decoding on the same sequence, and preserve the next speaker’s onset in any proposed change. The raw boundaries, both candidates and their scores are in the evidence file.

## Offline Hindi model comparison

I ran multilingual Whisper large-v3-turbo Q5 with whisper.cpp on the Mac against 13 Hindi clips, using the same WAVs as the Apple phone runs. I then sent both transcripts and the clean Hindi references through the same Apple Hindi-to-English translator on the iPhone. For the five original clips, the Apple column uses the first reference pass from the previous day. The model weighs 574 MB. Phone speed, memory and battery use for Whisper remain open. [Model file and checksum](https://huggingface.co/ggerganov/whisper.cpp/blob/main/ggml-large-v3-turbo-q5_0.bin) · [whisper.cpp](https://github.com/ggml-org/whisper.cpp)

Across these 13 matched recordings, Apple recognition led to **8/13** English translations that conveyed the full message. Whisper with Hindi specified led to **10/13**. It corrected the six o’clock arrival, the location of the water and the contrasted train times. It changed Delhi into “Dili” and both recognizers still missed the tickets in two price sentences. An awkward but recognizable thanks or request to close the door earned credit. The clean references produced the intended meaning on all 13.

| Expected meaning | Apple recognition → English | Whisper with Hindi specified → English |
| --- | --- | --- |
| Station near the bridge | The station is near the bridge | The station is near the bridge. |
| Price question for two tickets | How much luck does it look like | How much is the price of these double ticks? |
| I will reach the station at six | Okay I will reach the station at 5 o'clock | Okay, I will reach the station at 6 o'clock. |
| Go to Jaipur, not Delhi | I want to go to Jaipur not Delhi | I want to go to Jaipur, not Dili. |
| Can I use a card here? | Will the card work here? | Will the card work here? |
| Please close the door | Dear close the door | Please close the door. |
| Water is on the table | It is in the water on it | The water is on the table. |
| Shop opens at nine in the morning | The shop opens at 9 AM | The shop opens at 9 am. |
| I will go with you too | I will also go with you | I will also go with you. |
| Thank you | Giving thanks | Giving thanks |
| Where is the train station? | Where is the railway station | Where is the railway station? |
| Two tickets cost thirty euros | Look at the sun, luck is thirty euros | The price of the doupticks is 30 euros. |
| Train leaves at nine, not ten | Then let's go 8 not at ten o'clock | The train runs at 9 o'clock, not 10 o'clock. |

In a separate automatic-language test, the model identified 17/18 recordings correctly across English and Hindi. It classified the short Hindi “धन्यवाद” as Chinese and returned “Dhanyevad.” Specifying Hindi recovered “धन्यवाद.” The automatic test used five English and thirteen Hindi clips. The exact transcripts and automatic language results are in the evidence file.

## What to fix, in order

1. **Make each pause produce a complete turn.** The fixed 320 ms extension failed the bridge check. Record the end time from the pause detector, the final word ranges from both recognizers, and the text before and after clipping. Replay identical audio with different leading silence and with an immediate reply. Compare overlap-based word attribution with a fresh final recognition of the audio for that turn. Test both with back-to-back turns. Preserve quiet first words and the last word while preventing words from the next speaker entering the turn. Require each clean clip to save exactly once and include its last meaningful word on repeated passes. Start with the earlier Spanish “near the bridge” recording. [Turn clipping](../ios/Sources/Domain/ContinuousSpeechRecognition.swift) · [Recognizer finalization](../ios/Sources/Services/Local/AppleContinuousSpeechRecognizer.swift)
2. **Improve speaker selection independently of translation.** Retain both candidate transcripts and their acoustic scores, text-language evidence and final timing in fixture diagnostics. Reject candidates containing only punctuation for every pair. Calibrate on identical audio across pairs, especially closely related languages and short replies. Use an explicit participant choice when both candidates are plausible. Verify that correcting a turn updates its panel, translation direction and replay language together. [Language decision](../ios/Sources/Domain/ContinuousSpeechRecognition.swift) · [Coordinator](../ios/Sources/Services/ContinuousConversationCoordinator.swift)
3. **Make number and negation checks preserve the claim.** Normalize number words, local digits, times and currency amounts across all nine locales. Associate each time or amount with its action and affirmed or negated status. Use the 58 correct and 58 corrupted examples for each numeric scenario as paired regression controls. Agree on automatic speech and manual replay behavior for a suspected mismatch across all pairs. Test that a correct localized price remains playable when a reviewer confirms it. [Entity comparison](../ios/Sources/Domain/EntityIntegrity.swift) · [Automatic speech policy](../ios/Sources/Domain/ContinuousConversation.swift)
4. **Run an offline Hindi recognizer trial behind a development flag.** Keep the live Apple draft and existing English path. Decode the captured Hindi turn once at the speech boundary with the Hindi language specified and transcription mode selected. Compare both transcripts using the same translator. When they disagree on a time, amount, place or negation, offer the speaker a review. Evaluate human Hindi, English and Hinglish with several speakers, accents, room noise, rapid replies and short acknowledgments. Measure time from pause to final text, peak memory, warm/cold startup, battery and thermal behavior on the iPhone 13 Pro before proposing a separate optional model download.
5. **Repeat the device matrix before a wider beta.** Retain per-direction counts for correct participant, complete transcript, preserved intent and correct replay. Include different speakers and both primary-language settings, test Auto Speak and manual replay, and repeat after a physical lock/unlock. Have bilingual reviewers judge naturalness and meaning using blinded outputs. Report numeric or negation reversals and wrong-speaker confident turns separately so aggregate scores cannot hide them.

## What ran

The iPhone 13 Pro ran iOS 27.2.1 and the current Debug checkout based on `8e4a8a2`, including the existing uncommitted Hindi recognition work. The supported set comprises every pair among English, Spanish, French, German, Italian, Brazilian Portuguese, Japanese and Korean, plus English–Hindi Beta. Each pair had three turns in each direction. The speakers alternated in one continuous session, with Auto Speak off. Role checks verified the saved participant as well as both locales.

The three prompts asked for the train station, quoted thirty euros for two tickets, and said the train leaves at nine rather than ten. One native-system synthetic voice per locale produced 27 audio files. The same source recording was reused for every partner, fed as 16 kHz mono PCM at microphone speed into the app’s actual pause detector, dual recognition, language decision, translator and turn coordinator. A separate run recognized the same files with the source language explicitly chosen. The clean-text control sent the original sentences through Apple’s low-latency translator on the phone.

A meaning pass requires the correct direction and an intelligible rendering of the key details. “Where is the station?” and equivalent local shorthand count. “Where is the train?” loses the place. A dangling preposition earns credit when the question still identifies the station. A ticket or fare paraphrase counts when both quantities and the currency survive. The train-time sentence must retain the departure, nine, and the exclusion of ten. Punctuation, diacritics, script variants for numbers and minor grammar are tolerated when the listener can recover the meaning. Scores are my review of this fixed set. The same three recordings per language recur across partners.

For playback, the test simulated the app’s background and foreground callbacks, invoked the normal reviewed-replay action for each station turn and the primary speaker’s price turn, and recorded completed synthesis, text and requested locale. These checks establish which voice language the app requested and whether synthesis completed. Room microphones, physical lock/unlock, audible voice naturalness, spontaneous human speech and TestFlight performance require separate testing.

## Results by language spoken

| Spoken | Turns | Right speaker | Transcript kept meaning | Translation kept meaning | Clean text kept meaning | Fixed-language transcription |
| --- | --- | --- | --- | --- | --- | --- |
| English | 24 | 18 | 14 | 14 | 24/24 | 3/3 |
| Spanish | 21 | 21 | 19 | 19 | 21/21 | 3/3 |
| French | 21 | 21 | 15 | 15 | 21/21 | 3/3 |
| German | 21 | 21 | 13 | 13 | 21/21 | 3/3 |
| Italian | 21 | 21 | 14 | 18 | 21/21 | 2/3 |
| Portuguese | 21 | 21 | 8 | 8 | 21/21 | 3/3 |
| Japanese | 21 | 21 | 14 | 14 | 21/21 | 3/3 |
| Korean | 21 | 21 | 16 | 16 | 21/21 | 2/3 |
| Hindi | 3 | 3 | 1 | 1 | 3/3 | 1/3 |

## All 58 directions

Each count for text, speaker and meaning is out of three. Replay shows completions using the intended voice over requested replays. Both directions use the same primary-language setting for that pair.

| Direction | Clean text | Saved | Right speaker | Transcript meaning | Final meaning | Replay |
| --- | --- | --- | --- | --- | --- | --- |
| English → Spanish | 3 | 3 | 2 | 2 | 2 | 1/2 |
| Spanish → English | 3 | 3 | 3 | 3 | 3 | 1/1 |
| English → French | 3 | 3 | 2 | 1 | 1 | 1/2 |
| French → English | 3 | 3 | 3 | 2 | 2 | 1/1 |
| English → German | 3 | 3 | 1 | 0 | 0 | 1/2 |
| German → English | 3 | 3 | 3 | 2 | 2 | 1/1 |
| English → Italian | 3 | 3 | 2 | 2 | 2 | 1/2 |
| Italian → English | 3 | 3 | 3 | 2 | 2 | 1/1 |
| English → Portuguese | 3 | 3 | 3 | 3 | 3 | 2/2 |
| Portuguese → English | 3 | 3 | 3 | 2 | 2 | 1/1 |
| English → Japanese | 3 | 3 | 2 | 0 | 0 | 2/2 |
| Japanese → English | 3 | 3 | 3 | 2 | 2 | 1/1 |
| English → Korean | 3 | 3 | 3 | 3 | 3 | 2/2 |
| Korean → English | 3 | 3 | 3 | 2 | 2 | 1/1 |
| English → Hindi | 3 | 3 | 3 | 3 | 3 | 2/2 |
| Hindi → English | 3 | 3 | 3 | 1 | 1 | 1/1 |
| Spanish → French | 3 | 3 | 3 | 3 | 3 | 2/2 |
| French → Spanish | 3 | 3 | 3 | 2 | 2 | 1/1 |
| Spanish → German | 3 | 3 | 3 | 2 | 2 | 2/2 |
| German → Spanish | 3 | 3 | 3 | 1 | 1 | 1/1 |
| Spanish → Italian | 3 | 3 | 3 | 2 | 2 | 2/2 |
| Italian → Spanish | 3 | 3 | 3 | 2 | 2 | 1/1 |
| Spanish → Portuguese | 3 | 3 | 3 | 3 | 3 | 2/2 |
| Portuguese → Spanish | 3 | 3 | 3 | 1 | 1 | 1/1 |
| Spanish → Japanese | 3 | 3 | 3 | 3 | 3 | 1/2 |
| Japanese → Spanish | 3 | 3 | 3 | 2 | 2 | 1/1 |
| Spanish → Korean | 3 | 3 | 3 | 3 | 3 | 1/2 |
| Korean → Spanish | 3 | 3 | 3 | 2 | 2 | 1/1 |
| French → German | 3 | 3 | 3 | 2 | 2 | 2/2 |
| German → French | 3 | 3 | 3 | 2 | 2 | 1/1 |
| French → Italian | 3 | 3 | 3 | 2 | 2 | 2/2 |
| Italian → French | 3 | 3 | 3 | 2 | 2 | 1/1 |
| French → Portuguese | 3 | 3 | 3 | 2 | 2 | 2/2 |
| Portuguese → French | 3 | 3 | 3 | 1 | 1 | 1/1 |
| French → Japanese | 3 | 3 | 3 | 2 | 2 | 1/2 |
| Japanese → French | 3 | 3 | 3 | 2 | 2 | 1/1 |
| French → Korean | 3 | 3 | 3 | 3 | 3 | 1/2 |
| Korean → French | 3 | 3 | 3 | 2 | 2 | 1/1 |
| German → Italian | 3 | 3 | 3 | 2 | 2 | 2/2 |
| Italian → German | 3 | 3 | 3 | 2 | 3 | 1/1 |
| German → Portuguese | 3 | 3 | 3 | 2 | 2 | 1/2 |
| Portuguese → German | 3 | 3 | 3 | 1 | 1 | 1/1 |
| German → Japanese | 3 | 3 | 3 | 2 | 2 | 1/2 |
| Japanese → German | 3 | 3 | 3 | 2 | 2 | 1/1 |
| German → Korean | 3 | 3 | 3 | 2 | 2 | 1/2 |
| Korean → German | 3 | 3 | 3 | 3 | 3 | 1/1 |
| Italian → Portuguese | 3 | 3 | 3 | 2 | 3 | 2/2 |
| Portuguese → Italian | 3 | 3 | 3 | 1 | 1 | 1/1 |
| Italian → Japanese | 3 | 3 | 3 | 2 | 3 | 1/2 |
| Japanese → Italian | 3 | 3 | 3 | 2 | 2 | 1/1 |
| Italian → Korean | 3 | 3 | 3 | 2 | 3 | 1/2 |
| Korean → Italian | 3 | 3 | 3 | 2 | 2 | 1/1 |
| Portuguese → Japanese | 3 | 3 | 3 | 1 | 1 | 1/2 |
| Japanese → Portuguese | 3 | 3 | 3 | 2 | 2 | 1/1 |
| Portuguese → Korean | 3 | 3 | 3 | 1 | 1 | 2/2 |
| Korean → Portuguese | 3 | 3 | 3 | 2 | 2 | 1/1 |
| Japanese → Korean | 3 | 3 | 3 | 2 | 2 | 2/2 |
| Korean → Japanese | 3 | 3 | 3 | 3 | 3 | 1/1 |

## Number and negation controls

Each of 58 directions used the same native reference texts, then a deliberately changed price and a reversal of which departure time was negated. A mismatch alert is distinct from the broader confirmation flag for a turn containing a recognized entity. Some directions get the same alert for both the correct and the corrupted sentence.

| Fixture | Comparisons | Flagged mismatch | Requested confirmation |
| --- | --- | --- | --- |
| Correct station question | 58 | 0 | 0 |
| Correct price | 58 | 14 | 58 |
| Correct departure | 58 | 24 | 58 |
| Changed thirty to forty | 58 | 14 | 58 |
| Reversed nine and ten | 58 | 24 | 58 |

The mismatch check accepted the correct price and flagged its corrupted counterpart in **0/58** directions.

The mismatch check accepted the correct time and flagged its corrupted counterpart in **0/58** directions.
