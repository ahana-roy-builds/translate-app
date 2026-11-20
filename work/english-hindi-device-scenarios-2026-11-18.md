# English–Hindi device test results

November 18, 2026 · iPhone 13 Pro · iOS 27.2.1 · Speak Duet source commit `8e4a8a2`

I ran five two-turn exchanges twice on the phone. Each used the app’s pause detector, continuous recognizer, language decision and low-latency translation engine. The input consisted of ten synthetic recordings made with macOS voices Samantha (US English), Rishi (Indian English) and Lekha (Hindi). The test fed 16 kHz mono audio at microphone speed and let a pause close each turn. The tickets and destination exchanges used Hindi as the primary language. Hindi spoke first in the payment exchange even though English was primary.

The repeat used the same recordings with about half a second of leading silence. The manual transcription control selected the spoken language in advance. In the repeat, that control also fed audio at microphone speed and added trailing silence. The direct translation control supplied the original reference text. I compared meaning, numbers, negation and destination names. The physical microphone, human speakers, audible pronunciation, and the installed TestFlight binary were outside this run. The test host used the same app source as external build 3.

## Results

- Continuous Talk committed 9/10 turns in the first run and 9/10 in the repeat. It assigned the expected speaker on 4/10 and 4/10 attempted turns respectively.
- All 18 committed turns were labeled Hindi, including every English utterance. The bridge reply produced no committed turn in either run, within five seconds of trailing audio plus an eight-second wait.
- Judging both the target language and the intended meaning, 2/10 spoken turns succeeded on the first pass (Jaipur/Delhi and card payment), and 1/10 on the repeat (Jaipur/Delhi). The card-payment question became “Will the work be done here?” on the repeat.
- With the intended source text supplied, all ten translations conveyed the reference meaning on both runs. Different wording was accepted when the content was preserved.
- Isolated synthesis of the station question and reply completed using Hindi and English respectively. The replay records below show the actual locale requested for the app’s committed translations.

## What continuous Talk delivered

| Exchange | Spoken reference | First direction | First translation | Repeat direction | Repeat translation |
| --- | --- | --- | --- | --- | --- |
| station | Where is the railway station? | HI → EN | This was the railway station | HI → EN | What was this railway station |
| station | स्टेशन पुल के पास है। | — | No committed turn | — | No committed turn |
| tickets | इन दो टिकटों की कीमत कितनी है? | HI → EN | How much luck does it look like | HI → EN | But how much is luck with two problems |
| tickets | Two tickets cost three hundred rupees. | HI → EN | To ₹300 | HI → EN | Bread ₹300 |
| time | The train leaves at six fifteen, not six fifty. | HI → EN | On this | HI → EN | The train lives at six 650 |
| time | ठीक है, मैं छह बजे स्टेशन पहुँच जाऊँगी। | HI → EN | Okay will reach at 5 o'clock | HI → EN | Okay will reach the station at 5 o'clock |
| destination | मुझे जयपुर जाना है, दिल्ली नहीं। | HI → EN | I want to go to Jaipur not Delhi | HI → EN | I want to go to Jaipur not Delhi |
| destination | The next bus to Jaipur leaves from gate five. | HI → EN | The next bus from get five | HI → EN | Were so when lives from g five |
| payment | क्या यहाँ कार्ड चलेगा? | HI → EN | Will the card work here? | HI → EN | Will the work be done here? |
| payment | Yes. | HI → EN | Yes | HI → EN | Attempt |

## Correct-language transcription and direct translation controls

| Spoken reference | First manual transcript | Repeat manual transcript | Translation of the reference |
| --- | --- | --- | --- |
| Where is the railway station? | Where is the railway station? | Where is the railway station? | रेलवे स्टेशन कहां है? |
| स्टेशन पुल के पास है। | पुल कि पास है | स्टेशन पुल कि पास है | The station is near the bridge. |
| इन दो टिकटों की कीमत कितनी है? | दिखता किस्मत कितनी है | लेकिन दो दिक्कतों किस्मत कितनी है | How much is the price of these two tickets? |
| Two tickets cost three hundred rupees. | tickets cost 300 rupees. | 2 tickets cost 300 rupees. | दो टिकटों की क़ीमत तीन सौ रुपये है। |
| The train leaves at six fifteen, not six fifty. | The train leaves at 6.15, not 650. | The train leaves at 615, not 650. | ट्रेन छह पंद्रह बजे निकलती है, छह पचास नहीं। |
| ठीक है, मैं छह बजे स्टेशन पहुँच जाऊँगी। | ठीक है बजे पहुँच जाएँगी | ठीक है में 5 बजे पहुँच जाएँगी | Okay, I will reach the station at six o'clock. |
| मुझे जयपुर जाना है, दिल्ली नहीं। | मुझे जयपुर जाना है दिल्ली नहीं | मुझे जयपुर जाना है दिल्ली नहीं | I want to go to Jaipur, not Delhi. |
| The next bus to Jaipur leaves from gate five. | The next bus to Japer leaves from gate five. | The next bus to Japer leaves from gate 5. | जयपुर के लिए अगली बस गेट पांच से निकलती है। |
| क्या यहाँ कार्ड चलेगा? | क्या यहाँ कार्ड चलेगा | क्या यहाँ कार्य चलेगा | Will the card work here? |
| Yes. | Yes. | Yes. | हाँ। |

With the language fixed in advance, the English railway question transcribed exactly on both runs. On the repeat, Hindi dictation still changed six o’clock to five and lost the ticket-price question. Fixing automatic speaker assignment alone would leave these transcription errors.

## Continuous recognizer candidates on the repeat

| Spoken reference | Selected transcript | Alternate transcript |
| --- | --- | --- |
| Where is the railway station? | व्हाट इस थे रेलवे स्टेशन | Where is the railway station? |
| स्टेशन पुल के पास है। | — | — |
| इन दो टिकटों की कीमत कितनी है? | लेकिन दो दिक्कतों किस्मत कितनी है | Indup, Tik Toki, Kimat, Kitni, |
| Two tickets cost three hundred rupees. | रोटी ₹300 | No alternate |
| The train leaves at six fifteen, not six fifty. | थे ट्रेन लाइव्स ऐट सिक्स 650 | The train leaves at 615, not 650. |
| ठीक है, मैं छह बजे स्टेशन पहुँच जाऊँगी। | ठीक है 5 बजे स्टेशन पहुँच जाएँगी | . kk, make Che Baji station pahunt |
| मुझे जयपुर जाना है, दिल्ली नहीं। | मुझे जयपुर जाना है दिल्ली नहीं | Mujhe, Jaipur, Jana, Hai, Delhi, |
| The next bus to Jaipur leaves from gate five. | थे तो जब लाइव्स फ्रॉम जी फाइव | ,......... from gate 5. |
| क्या यहाँ कार्ड चलेगा? | क्या यहाँ कार्य चलेगा | Yeah, yeah, card |
| Yes. | प्रयास | . |

The current English–Hindi decision rule gives a Hindi candidate priority as soon as its output contains two Unicode scalars in the Devanagari block. The Hindi recognizer can write English sounds in that script. The selected language then determines the participant, translation direction, and playback language. [Decision rule](../ios/Sources/Domain/ContinuousSpeechRecognition.swift) · [Turn routing](../ios/Sources/Services/ContinuousConversationCoordinator.swift)

## Replay on the repeat

For the station and ticket exchanges, the test invoked the app’s replay action for each committed turn. A successful row means the system synthesis call completed with the committed translation text.

| Spoken reference | Intended playback | Observed playback |
| --- | --- | --- |
| Where is the railway station? | hi-IN | en-US |
| स्टेशन पुल के पास है। | en-US | No committed turn |
| इन दो टिकटों की कीमत कितनी है? | en-US | en-US |
| Two tickets cost three hundred rupees. | hi-IN | en-US |
