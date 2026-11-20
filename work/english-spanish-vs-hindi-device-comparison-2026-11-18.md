# English–Spanish and English–Hindi in continuous Talk

November 18, 2026 · iPhone 13 Pro · iOS 27.2.1 · Speak Duet source `8e4a8a2`

Each pair had the same five two-turn exchanges, recorded with synthetic voices. The English audio files were identical for both pairs. Pass A started each clip immediately. Pass B added 512 ms of silence before each clip. Audio ran at microphone speed through the app’s pause detector, both recognizers, speaker selection and on-device translator. Each exchange used one continuous session, with Auto Speak off. The tests alternated which language was primary and which side spoke first. They used the debug test host on the phone. Room acoustics, human pronunciation, automatic playback and the TestFlight binary were outside the test.

## Matched results

| Across passes A and B | English–Spanish | English–Hindi |
| --- | --- | --- |
| Turns with a saved result | 20/20 | 18/20 |
| Correct speaker and translation direction | 18/20 (9 + 9) | 8/20 (4 + 4) |
| English turns assigned to the English speaker | 8/10 | 0/10 |
| Partner-language turns assigned to the partner | 10/10 | 8/10 |
| Full spoken meaning in the intended language, strict review | 4/20 (2 + 2) | 3/20 (2 + 1) |
| Translation of the ten reference sentences with audio bypassed | 10/10 | 10/10 on each prior pass |

A turn counted as complete if the listener got the action or question and its relevant details in the intended language. Paraphrases were accepted. The strict score treats a corrupted place name, an ambiguous time, a lost location or a question turned into a statement as incomplete. A saved turn containing only punctuation counted toward the saved-turn and routing measures. Repetitions used the same recordings, so these counts describe this set of exchanges and do not estimate accuracy in everyday use.

## What English–Spanish actually produced

| Spoken reference | Pass A translation | Pass B translation | Meaning review |
| --- | --- | --- | --- |
| Where is the railway station? | ¿Dónde está el ferrocarril? (es-ES) | ¿Dónde está la estación de tren? (es-ES) | Lost “station” on A. Complete on B. |
| La estación está cerca del puente. | The station is near the (en-US) | The station is near the (en-US) | Lost “bridge” on both passes. |
| ¿Cuánto cuestan estos dos billetes? | How much do these two cost? (en-US) | How much do these two tickets cost? (en-US) | Lost “tickets” on A. Complete on B. |
| Two tickets cost three hundred rupees. | Tickets? Your tickets cost 300 rubies (en-US) | Your tickets cost 3 300 (en-US) | English assigned to the Spanish speaker on both passes. Currency or amount was lost. |
| The train leaves at six fifteen, not six fifty. | El tren sale a las 6:15, no a las 650. (es-ES) | El tren sale a las 6:15, no a las 650. (es-ES) | Both preserved 6:15 and negation but rendered the contrasting time as “las 650.” |
| De acuerdo, llegaré a la estación a las seis. | Okay, I'll get to the station at six (en-US) | Okay, I'll get to the station at (en-US) | Complete on A. Lost the arrival time on B. |
| Quiero ir a Jaipur, no a Delhi. | I want to go to Diaipur, not to Delhi (en-US) | I want to go to Diibur, not to (en-US) | Jaipur became Diaipur or Diibur. B also dropped Delhi. |
| The next bus to Jaipur leaves from gate five. | El siguiente a Japer sale de la puerta 5. (es-ES) | .. El próximo autobús a Japer sale de la puerta 5. (es-ES) | Jaipur became Japer on both passes. A also lost “bus.” |
| ¿Puedo pagar con tarjeta aquí? | I can pay by card (en-US) | I can pay by card (en-US) | Lost “here” and changed the question to a statement on both passes. |
| Yes. | Sí. (es-ES) | . (es-ES) | Complete on A. Only punctuation on B. |

On both Spanish passes replay completed for all four station and ticket turns. Six of the eight replays used the intended target voice. On both passes the English ticket-price reply was routed to English playback. The synthesizer received the saved text and target locale. The test measured synthesis completion and locale, without grading how the voice sounded.

## Single-language transcription and clean-text translation

| Spoken reference | Transcribed with the spoken language selected | Translation of the original reference |
| --- | --- | --- |
| Where is the railway station? | Where is the railway station? | ¿Dónde está la estación de tren? |
| La estación está cerca del puente. | La estación está cerca del puente. | The station is near the bridge. |
| ¿Cuánto cuestan estos dos billetes? | Cuánto cuestan estos dos billetes? | How much do these two tickets cost? |
| Two tickets cost three hundred rupees. | 2 tickets cost 300 rupees. | Dos entradas cuestan trescientas rupias. |
| The train leaves at six fifteen, not six fifty. | The train leaves at 615, not 650. | El tren sale a las seis y cuarto, no a las seis y cincuenta. |
| De acuerdo, llegaré a la estación a las seis. | De acuerdo, llegaré a la estación a las seis. | Okay, I'll get to the station at six. |
| Quiero ir a Jaipur, no a Delhi. | Quiero ir a Diibur, no a Delhi. | I want to go to Jaipur, not Delhi. |
| The next bus to Jaipur leaves from gate five. | The next bus to Japer leaves from gate 5. | El siguiente autobús a Jaipur sale de la puerta cinco. |
| ¿Puedo pagar con tarjeta aquí? | Puedo pagar con tarjeta aquí? | Can I pay by card here? |
| Yes. | Yes. | Sí. |

Selecting Spanish in advance recovered “bridge,” “tickets,” “at six” and the full card-payment question on these recordings. Single-language recognition still wrote the wrong name for Jaipur in both languages. In the Hindi control, dictation also changed six o’clock to five and lost the meaning of the ticket-price question. [Hindi transcripts, translations and replay results](english-hindi-device-scenarios-2026-11-18.md)

## Why English is repeatedly labeled Hindi

The app runs a recognizer for each language. English and Spanish both use Apple’s SpeechTranscriber. Hindi uses DictationTranscriber. For English–Hindi, the app ranks Hindi first whenever its transcript has at least two Unicode scalars in the Devanagari block. An English sentence written phonetically in that script meets the condition. The selected language determines the participant, translation direction and replay locale. [Recognizer selection](../ios/Sources/Services/Local/AppleSpeechModulePlan.swift) · [Language selection](../ios/Sources/Domain/ContinuousSpeechRecognition.swift) · [Turn routing](../ios/Sources/Services/ContinuousConversationCoordinator.swift)

An additional Hindi pass captured both candidates and rescored those exact candidates with the pair-specific preference disabled. These are recognizer ranking scores, not probabilities of speaking a language. This pass is separate from the matched totals above.

| Spoken reference | English candidate and score | Hindi candidate and score | App chose | Score alone |
| --- | --- | --- | --- | --- |
| Where is the railway station? | Where is the railway station? (0.984) | व्हाट इस थे रेलवे स्टेशन (0.450) | HI | EN |
| स्टेशन पुल के पास है। | . Station Pulke Paas (0.759) | No candidate | EN | EN |
| इन दो टिकटों की कीमत कितनी है? | Indu, Tik Toki, Kimat, Kitni, (0.451) | लेकिन दो दिक्कतों किस्मत कितनी है (0.450) | HI | EN |
| Two tickets cost three hundred rupees. | No candidate | रोटी ₹300 (0.450) | HI | HI |
| The train leaves at six fifteen, not six fifty. | The train leaves at 615, not 650. (0.961) | थे ट्रेन लाइव्स ऐट सिक्स 650 (0.450) | HI | EN |
| ठीक है, मैं छह बजे स्टेशन पहुँच जाऊँगी। | . , mech Che Baji Station, Pahunt (0.493) | ठीक है 5 बजे स्टेशन पहुँच जाएँगी (0.450) | HI | EN |
| मुझे जयपुर जाना है, दिल्ली नहीं। | Mujhe, Jaipur, Jana, Hai, Delhi, (0.669) | मुझे जयपुर जाना है दिल्ली नहीं (0.450) | HI | EN |
| The next bus to Jaipur leaves from gate five. | ,......... from gate 5. (0.548) | थे तो जब लाइव्स फ्रॉम जी फाइव (0.450) | HI | EN |
| क्या यहाँ कार्ड चलेगा? | Yeah, yeah, card (0.357) | क्या यहाँ कार्य चलेगा (0.450) | HI | HI |
| Yes. | . (0.790) | प्रयास (0.450) | HI | EN |

The app selected the right language on 4/10 diagnostic turns. Score alone selected it on 5/10. It recovered 4 English labels but flipped 3 genuine Hindi turns to English. One recovered English label had only a period for its transcript. On the English ticket-price reply there was no English candidate to choose. A change to the ranking rule needs testing in both directions, plus a way to handle unusable text or missing candidates.

The English station recording isolates the failure particularly well. The English recognizer returned “Where is the railway station?” at 0.984. The Hindi recognizer wrote “व्हाट इस थे रेलवे स्टेशन” at 0.450. The app chose Hindi and translated that into English. Spanish correctly assigned the identical recording to the English speaker in both matched passes.

## Where words go at a pause

A separate four-utterance run per pair recorded Apple's final text and word timestamps immediately before Speak Duet clipped each candidate to the turn. This localized two Spanish-pair omissions to the app's clipping step.

| Pair and utterance | What Apple had already returned | App’s turn window | What survived |
| --- | --- | --- | --- |
| English–Spanish, English station question | “station?” from 1.020 to 1.980 s | 0.000–1.892 s | “Where is the railway” |
| English–Spanish, Spanish ticket question | “billetes?” from 1.260 to 2.640 s | 0.000–2.148 s | “¿Cuánto cuestan estos dos” |
| English–Hindi, Hindi bridge reply | “स्टेशन पुल कि पास है” with its last word ending at 6.662 s | 7.068–8.804 s | Empty Hindi candidate. The English recognizer supplied “. Station Pulke Paas” in this window. |

Speak Duet keeps a timed word when its end falls inside the turn. Most of “station” overlapped the turn, yet its end was 88 ms late and the word disappeared. On Hindi’s bridge reply the *entire* Hindi result was timestamped before the start of the turn. The trace establishes the mismatch but does not establish why the Hindi module produced those timestamps. The Spanish bridge word survived in this extra run even though it was missing in both matched passes. On the first matched pass the missing “billetes” also appeared at the start of the English reply. [Word clipping](../ios/Sources/Domain/ContinuousSpeechRecognition.swift) · [Finalization](../ios/Sources/Services/Local/AppleContinuousSpeechRecognizer.swift)

## Fixes to validate

1. Replace the unconditional Hindi-script preference with a decision tested on English and Hindi recordings, including phonetic spellings and short replies. Use a speaker confirmation when neither candidate is usable. Include cases where the English recognizer returns only punctuation or provides no candidate.

2. Verify pause finalization against word timestamps. Require the bridge and ticket sentences to retain the last word and the following turn to start with its own speaker’s words.

3. Retest Hindi dictation with the language selected in advance, using human speakers, numbers, negation and destination names. Track transcription, speaker assignment and meaning separately so that an improvement in routing does not mask a wrong number.
