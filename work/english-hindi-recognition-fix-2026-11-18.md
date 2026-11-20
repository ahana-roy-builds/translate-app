# English–Hindi recognition after the speaker-routing fix

November 18, 2026 · iPhone 13 Pro · iOS 27.2.1 · local Debug build

The phone ran the same five recorded exchanges twice, including the original English recordings, and five additional exchanges once. Synthetic speech went through the app’s real pause detector, on-device recognizers and translation engine at microphone speed. The repeat added 512 ms of silence before each clip. A separate physical-device regression queued an English turn while the preceding Hindi turn was still being finalized. These tests did not use a room microphone or assess a voice by listening.

The original build assigned the correct speaker and direction on 8/20 attempts, saved 18/20, and preserved the full meaning in the intended language on 3/20. All ten original English turns were assigned to Hindi. [Original side-by-side comparison](english-spanish-vs-hindi-device-comparison-2026-11-18.md)

| Run | Saved | Right speaker and direction | Full meaning in target language | Intended voice on completed replays |
| --- | --- | --- | --- | --- |
| Original A | 10/10 | 10/10 | 6/10 | 3/3 (4 requested) |
| Original B | 10/10 | 10/10 | 4/10 | 3/3 (4 requested) |
| Additional exchanges | 10/10 | 10/10 | 9/10 | 3/3 (4 requested) |

The meaning score requires the listener to get the action or question and its relevant details, including times, names, and locations. Paraphrases count. The same rubric was used for the earlier comparison. “Right speaker” also checks the participant panel and target locale. Voice checks verify the locale and text sent to the synthesizer.

## Original recordings, first pass

| Spoken | Heard | Delivered | Full meaning |
| --- | --- | --- | --- |
| Where is the railway station? | Where is the railway station? | रेलवे स्टेशन कहां है? | Yes |
| स्टेशन पुल के पास है। | स्टेशन पुल कि पास है | The station is near the bridge | Yes |
| इन दो टिकटों की कीमत कितनी है? | दिखता किस्मत कितनी है | How much luck does it look like | No |
| Two tickets cost three hundred rupees. | 2 tickets cost 300 rupees. | 2 टिकटों की क़ीमत 300 रुपये है। | Yes |
| The train leaves at six fifteen, not six fifty. | The train leaves at 615, not 650. | ट्रेन 615 पर निकलती है, 650 पर नहीं। | No |
| ठीक है, मैं छह बजे स्टेशन पहुँच जाऊँगी। | ठीक है में 5 बजे स्टेशन पहुँच जाएँगी | Okay I will reach the station at 5 o'clock | No |
| मुझे जयपुर जाना है, दिल्ली नहीं। | मुझे जयपुर जाना है दिल्ली नहीं | I want to go to Jaipur not Delhi | Yes |
| The next bus to Jaipur leaves from gate five. | The next bus to Japer leaves from gate five. | जैपर के लिए अगली बस गेट पांच से निकलती है। | No |
| क्या यहाँ कार्ड चलेगा? | क्या यहाँ कार्ड चलेगा | Will the card work here? | Yes |
| Yes. | Yes. | हाँ। | Yes |

## Original recordings, repeat

| Spoken | Heard | Delivered | Full meaning |
| --- | --- | --- | --- |
| Where is the railway station? | Where is the railway station? | रेलवे स्टेशन कहां है? | Yes |
| स्टेशन पुल के पास है। | पुल कि पास है | The bridge is near | No |
| इन दो टिकटों की कीमत कितनी है? | धूप खातों की हिम्मत कितनी है | How much courage do you have? | No |
| Two tickets cost three hundred rupees. | 2 tickets cost 300 rupees. | 2 टिकटों की क़ीमत 300 रुपये है। | Yes |
| The train leaves at six fifteen, not six fifty. | The train leaves at 615, not 650. | ट्रेन 615 पर निकलती है, 650 पर नहीं। | No |
| ठीक है, मैं छह बजे स्टेशन पहुँच जाऊँगी। | ठीक है में 5 बजे पहुँच जाएँगी | Okay I will reach at 5 o'clock | No |
| मुझे जयपुर जाना है, दिल्ली नहीं। | मुझे जयपुर जाना है दिल्ली नहीं | I want to go to Jaipur not Delhi | Yes |
| The next bus to Jaipur leaves from gate five. | The next bus to Japer leaves from gate five. | जैपर के लिए अगली बस गेट पांच से निकलती है। | No |
| क्या यहाँ कार्ड चलेगा? | क्या यहाँ कि चलेगा | Will it go here? | No |
| Yes. | Yes. | हाँ। | Yes |

## Additional recordings

| Spoken | Heard | Delivered | Full meaning |
| --- | --- | --- | --- |
| कृपया दरवाज़ा बंद कर दीजिए। | प्रिय दरवाजा बंद कर दीजिए | Dear close the door | Yes |
| I will close the door. | I will close the door. | मैं दरवाजा बंद कर दूंगा। | Yes |
| Can I have a glass of water? | Can I have a glass of water? | क्या मुझे एक गिलास पानी मिल सकता है? | Yes |
| पानी मेज़ पर है। | पानी में इस पर है | It is in the water on it | No |
| दुकान सुबह नौ बजे खुलती है। | दुकान 9 AM बजे खुलती है | The shop opens at 9 AM | Yes |
| I will come back tomorrow. | I will come back tomorrow. | मैं कल वापस आऊंगा। | Yes |
| We are going to Mumbai on Sunday. | We are going to Mumbai on Sunday. | हम रविवार को मुंबई जा रहे हैं। | Yes |
| मैं भी आपके साथ चलूँगी। | में भी आपके साथ जाऊँगी | I will also go with you | Yes |
| धन्यवाद। | धन्यवाद | Giving thanks | Yes |
| You are welcome. | You are welcome. | आपका स्वागत है। | Yes |

The additional set’s meaning score includes “Dear close the door” and “Giving thanks.” Both communicate the basic intent with awkward English wording. “Water is on the table” lost the location entirely. All nine completed replays used the intended target voice. Three of the twelve requests were unavailable on turns flagged for an entity mismatch.

The English–Spanish control routed 18/20 turns correctly on this build, matching its earlier total. The final device suite completed 32 tests without failures, including the back-to-back Hindi and English fixture. XCTest completion is separate from the meaning scores above.

## What changed

Each English–Hindi turn starts a fresh bilingual recognition stream on the iPhone. The next speaker can begin while the preceding result finishes. The app checks the English recognizer’s acoustic confidence and independently identifies the language of its text before preferring Hindi based on its script. The language packs screen checks the same modules used for this path. Hindi finals use the complete turn-local transcript. A short span of captured pre-roll retains quiet onsets, bounded by the end of the previous turn.

Testing Apple’s short-dictation setting produced the same errors on the Hindi ticket-price and arrival-time recordings. The fix keeps the installed progressive long-dictation model. The underlying recognizer can still mishear Hindi words, numbers, and names. Human bilingual speech, including code-switching and background noise, needs separate validation before making a general accuracy claim.
