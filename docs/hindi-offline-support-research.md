# Hindi offline support research

**Status:** experimental beta implementation, not a production Hindi support
claim. Findings were reviewed on 2026-08-15. Debug and the offline
`PrivateBeta` configuration expose English-Hindi as `Hindi (Beta)`; standard
TestFlight and Release configurations omit it. Every continuous beta turn is
review-required. With Speak on, ordinary translations play automatically;
important details require the tester to check the text and choose Play
translation. A detected important-detail mismatch remains text-only.

## Scope and acceptance bar

The first candidate scope is continuous, fully offline English (`en-US`) and
Hindi (`hi-IN`) conversation on iPhone, with Devanagari Hindi, ordinary English,
and common Hindi-English code switching represented in evaluation. Hindi against
the other seven current app languages was inventoried for future compatibility,
but is outside both the beta implementation and the first production-release
scope.

The existing [evaluation contract](evaluation-and-acceptance.md) remains the
source of truth. A Hindi direction cannot ship unless, independently by direction
and device tier, it meets at least:

- ASR WER (or an approved Hindi metric) at or below 20%, critical-entity
  deletion at or below 5%, silence/noise hallucination at or below 0.5%, and
  wrong-language output at or below 1%;
- 100% preservation or explicit flagging of the emergency/allergy set, no known
  severity-1 meaning inversion, median bilingual adequacy at least 4/5, and no
  required stratum below 3.5/5;
- warm endpoint-to-visible-translation latency of at most 1.5 seconds p50 and
  3 seconds p95; and
- zero conversation-content egress in Local Only, with no crash, watchdog,
  stale playback, unbounded memory growth, or unacceptable thermal behavior.

Capability inventory does not satisfy any quality or runtime threshold.

## Apple platform findings

- Apple describes `SpeechTranscriber` as an entirely on-device, downloadable
  model intended for live and long-form audio. Apple explicitly identifies
  `DictationTranscriber` as the fallback for unsupported languages or devices in
  its [SpeechAnalyzer session](https://developer.apple.com/videos/play/wwdc2025/277/).
- [`DictationTranscriber`](https://developer.apple.com/documentation/speech/dictationtranscriber)
  uses the on-device models behind system dictation and on-device
  `SFSpeechRecognizer`; it excludes locales that only work through the network.
  Its presets distinguish short and long, volatile and final-result behavior.
- [`AssetInventory`](https://developer.apple.com/documentation/speech/assetinventory)
  owns speech-model installation. A supported status means an asset is eligible
  to download, not that it is installed or works accurately for this app.
- A false
  [`supportsOnDeviceRecognition`](https://developer.apple.com/documentation/speech/sfspeechrecognizer/supportsondevicerecognition)
  value means the legacy recognizer requires Apple's service and therefore
  cannot back Local Only.
- Translation's
  [`lowLatency`](https://developer.apple.com/documentation/translation/translationsession/strategy/lowlatency)
  strategy uses traditional models, while
  [`highFidelity`](https://developer.apple.com/documentation/translation/translationsession/strategy/highfidelity)
  prefers Apple Intelligence and may fall back to Low Latency. An availability
  status neither identifies the resolved engine nor proves translation quality.
- [`AVSpeechSynthesisVoice.speechVoices()`](https://developer.apple.com/documentation/avfaudio/avspeechsynthesisvoice/speechvoices%28%29)
  inventories voices exposed on the device. Presence alone does not prove
  offline synthesis, pronunciation quality, or intelligibility.

## Speech asset lifecycle constraints

- Speech assets are downloaded from Apple, retained in system storage, shared
  between apps, and updated and removed by iOS. They do not increase the app's
  binary or container size. The app supplies module configurations; it does not
  receive an asset file or control its storage location.
- [`reserve(locale:)`](https://developer.apple.com/documentation/speech/assetinventory/reserve%28locale%3A%29)
  claims one of the app's locale reservation slots; it does not itself download
  a model. An installation request reserves required locales automatically.
  [`maximumReservedLocales`](https://developer.apple.com/documentation/speech/assetinventory/maximumreservedlocales)
  can vary by device according to available storage, so capacity must be read
  at runtime rather than assumed.
- An [`AssetInstallationRequest`](https://developer.apple.com/documentation/speech/assetinstallationrequest)
  exposes Foundation `Progress` and `downloadAndInstall()`, but the iOS 26 SDK
  exposes no Speech API for the asset's byte size, required free space, file
  URL, pause/resume, or direct uninstall. The progress fraction can drive a
  progress indicator, but it is not a documented byte count.
- Calling generic Foundation `Progress.cancel()` is not a documented guarantee
  that Speech's system delivery or later retry stops. In particular,
  [`downloadAndInstall()`](https://developer.apple.com/documentation/speech/assetinstallationrequest/downloadandinstall%28%29)
  may return after a failed initial attempt while the system retries later.
  Cancellation must therefore be treated as best effort and followed by a fresh
  asset-status check.
- [`release(reservedLocale:)`](https://developer.apple.com/documentation/speech/assetinventory/release%28reservedlocale%3A%29)
  unsubscribes this app from locale-dependent assets and frees its reservation;
  it is not synchronous deletion. Apple states that the system removes assets
  later, and a shared asset may remain because another app or system feature
  uses it.
- As of this review, Apple's iPhone and Speech documentation describes controls
  for turning Dictation on or off and removing a
  [keyboard](https://support.apple.com/en-gb/guide/iphone/iph73b71eb/26/ios/26),
  but no Settings control for deleting an app-requested Speech
  `AssetInventory` model. Those controls, and Translate's downloaded-language
  controls, must not be presented as speech-model deletion.

Product copy should report observed status and download progress, avoid exact
model-size or freed-space promises, and label the destructive-looking action as
"Release Listen reservation." The app should recheck status and reservations
after interruption and on launch. Compatible analyzer audio formats must be
checked only after the exact required assets are installed, because the system
chooses formats from the available installed assets.

## Physical-device probe

The read-only [capability probe](hindi-capability-probe.md) passed on one
iPhone 13 Pro (`iPhone14,2`) running iOS 26.6 (23G71). It requested no
permissions, captured no audio, installed or reserved no assets, prepared no
translation session, and synthesized no speech. No device name, account,
unique identifier, or other personal value is retained here.

The sanitized JSON attachments and their hashes are retained in the
[Hindi research evidence directory](research-evidence/hindi/README.md). Raw
Xcode result bundles and manifests are excluded because they contain physical
device identifiers.

| Component | Observed result | What it establishes |
| --- | --- | --- |
| `SpeechTranscriber` | Framework available; locale lookup resolved `hi_IN`; no Hindi locale installed; the `.transcription` module asset status was unsupported. | Locale lookup alone is insufficient. This exact module is unusable on this device; it does not prove global Hindi absence from `SpeechTranscriber`. |
| `DictationTranscriber` | Locale lookup resolved `hi_IN`; the initial probe found the asset supported but not installed. A later explicitly authorized test installed the exact live/final pair and confirmed exact `hi-IN` in `installedLocales`. | The device exposes and can install Apple's Hindi Dictation asset. Offline inference and recognition quality remain untested. |
| `SFSpeechRecognizer` | Listed `hi-IN`, `hi-IN-translit`, and `hi-Latn`; recognizer resolved and was available at probe time; on-device recognition was false. | The legacy Hindi path requires network access and is disqualified for Local Only. No recognition request was made. |
| Translation | All 16 directions between Hindi and `en-US`, `es-ES`, `fr-FR`, `de-DE`, `it-IT`, `pt-BR`, `ja-JP`, and `ko-KR` were supported but not installed under both preferred-strategy queries. | At least the fallback path is download-eligible. This does not demonstrate High Fidelity execution, installed assets, offline inference, or quality. |
| Speech synthesis | One exact `hi-IN` voice was exposed at default quality. | A Hindi voice can be selected. No audio was generated or reviewed. |

### Extended module inventory

A second read-only XCTest passed 1/1 on the same device and OS. It made no
download or reservation request and did not query an analyzer audio format.

| Inventory query | Observed result |
| --- | --- |
| Reservation capacity | Maximum locale reservations was 5; this app had none reserved. |
| Hindi Dictation locales | `supportedLocales` contained exact `hi-IN`, but neither exact `hi-Latn` nor `hi-IN-translit`. Equivalent-locale lookup mapped both aliases to `hi-IN`; that does not establish distinct transliteration models or output scripts. |
| Hindi Dictation presets | All six presets - `phrase`, `shortDictation`, `progressiveShortDictation`, `longDictation`, `progressiveLongDictation`, and `timeIndexedLongDictation` - were supported but not installed. |
| Exact Hindi continuous configuration | The `progressiveLongDictation` live module, `longDictation` final module, and combined live-plus-final module set were each supported but not installed. |
| Hybrid English Speech plus Hindi Dictation | The individual English `SpeechTranscriber` live and final modules, and the aggregate four-module English Speech plus Hindi Dictation live/final set, were supported but not installed. |
| All-Dictation bilingual alternative | The individual English Dictation live and final modules, and the aggregate four-module English-plus-Hindi Dictation set, were supported but not installed. |
| Hindi `SpeechTranscriber` | `supportedLocales` contained no Hindi locale, and the exact Hindi live and final module statuses were unsupported. The earlier equivalent-locale lookup result therefore remains insufficient evidence of usable Hindi `SpeechTranscriber` support. |

These inventory results screen the exact requested configurations for asset
eligibility and establish that the reservation limit can cover the two
locales. The follow-up installation below establishes only the Hindi pair's
installation and compatible format; it does not show that bilingual assets can
be installed together, that a compatible co-resident format exists, or that
either bilingual configuration runs correctly.

### Controlled Hindi Dictation installation

After explicit approval, the guarded installation XCTest passed 1/1 on the
same device in 15.004 seconds. It requested only the exact Hindi
`progressiveLongDictation` live and `longDictation` final modules. Their asset
status moved from `supported-not-installed` to `installed`, exact `hi-IN`
appeared in `DictationTranscriber.installedLocales`, and
`SpeechAnalyzer.bestAvailableAudioFormat` returned a compatible 16 kHz mono
format (`AVAudioCommonFormat(rawValue: 3)`). The test requested no permission,
opened no microphone, submitted no audio, prepared no Translation session, and
synthesized no speech.

### Post-install bilingual aggregate check

A later read-only check evaluated both the hybrid English Speech plus Hindi
Dictation configuration and the all-Dictation English-plus-Hindi alternative.
The exact Hindi modules were installed, but the exact English modules required
by each aggregate were not installed under the research app identity. Both
aggregates therefore remained supported and download-eligible, not installed.
The check did not request another asset or query a common analyzer format.
Its sanitized attachment was not retained, so this is an unretained engineering
observation rather than durable evidence. It is not evidence that all four
modules can coexist or process one stream.

## ASR shortlist

1. **Apple `DictationTranscriber` - first spike.** It has the lowest integration
   and privacy risk. The extended inventory found all Hindi
   [presets](https://developer.apple.com/documentation/speech/dictationtranscriber/preset),
   the exact long-form live/final pair, and both bilingual module alternatives
   download-eligible. The likely continuous starting point remains
   `progressiveLongDictation`, paired with `longDictation` for final results.
   Installation and a compatible Hindi-only pair format are now confirmed;
   the bilingual aggregates remain only download-eligible because their exact
   English assets were not installed. Offline inference, bilingual coexistence,
   and quality remain untested.
2. **WhisperKit with the 626 MB multilingual Large v3 variant - first custom
   fallback.** The maintainer's
   [Swift package](https://github.com/argmaxinc/argmax-oss-swift) supports Core ML
   models and streaming. A pinned
   [maintainer benchmark](https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks/blob/b500a4205355aa64a21eb3a2899f3d71657cca36/dashboard_data/performance_data.json)
   reports a 3.99x speed factor on an iPhone 13 Pro for English performance
   inputs, but the separate
   [Common Voice 17 multilingual results](https://huggingface.co/spaces/argmaxinc/whisperkit-benchmarks/blob/178c838043e0d6753f37154437dc843afeeeecd2/dashboard_data/multilingual_results.csv)
   report Hindi WER of 27.3% with a language hint and 47.4% with language
   prediction for this model. Both exceed the 20% gate. These are external
   screening results on older OS/configurations, not LocalLingo measurements.
3. **`whisper.cpp` - lower-level Whisper runtime fallback.** Its
   [official repository](https://github.com/ggml-org/whisper.cpp) provides iOS,
   Swift/Objective-C examples, Metal, Core ML encoder support, and quantized
   models. It offers more runtime control but more integration and maintenance
   work; using the same Whisper weights does not remove the Hindi accuracy risk.
4. **AI4Bharat IndicConformer - accuracy challenger only.** AI4Bharat publishes
   a [600M multilingual model and Hindi-specific variants](https://huggingface.co/collections/ai4bharat/indicconformer).
   No first-party supported iOS/Core ML artifact or LocalLingo-compatible
   streaming integration has been identified. Model access terms, conversion,
   memory, latency, decoding, and app-distribution rights must be cleared before
   an iPhone spike.

## Evaluation sequence

1. **Completed read-only:** inventory every Dictation preset, the exact Hindi
   live/final configurations, the hybrid and all-Dictation bilingual module
   sets, their exact and aggregate asset statuses, and reservation capacity.
2. **Completed with explicit approval:** installed only the Hindi Dictation
   asset requested by the exact live/final pair, confirmed exact `hi-IN` in
   `installedLocales`, and obtained a compatible 16 kHz mono audio format.
3. **Observed read-only; attachment not retained:** rechecked the hybrid and
   all-Dictation bilingual aggregates after the Hindi installation. Both were
   supported but remained download-eligible because their exact English modules
   were not installed; no common format was queried and no coexistence claim was
   established. Repeat and retain a sanitized report before relying on it.
4. Transcribe a versioned, licensed Hindi test file through the final-only long
   module in Airplane Mode before opening the microphone. Treat this as a
   plumbing check for installed-asset inference and output script, not as live,
   quality, latency, or resource evidence.
5. Run an instrumented continuous-session spike with the live/final pair, one
   audio stream, and the existing VAD/turn-boundary policy. Measure confidence,
   finalization latency, memory, thermal state, and failure behavior. Cover
   Hindi, English, Hinglish, silence, overlapping speech, noise, accents,
   names, numbers, negation, medications, allergies, and emergencies.
6. Install and exercise English-Hindi Translation in both directions in
   Airplane Mode, then synthesize Hindi and have bilingual reviewers assess
   meaning, pronunciation, numbers, names, and intelligibility.
7. Score the full hidden and field-challenge corpora on each qualification
   device tier, including a sustained-session battery, memory, and thermal run
   and network-deny/allow egress verification.

## Decision gates

- **Proceed with Apple ASR:** exact modules coexist, assets install and remain
  available, file and live inference complete offline, and the full quality,
  latency, stability, and privacy gates pass.
- **Evaluate a custom ASR:** Apple inference works but misses a gate, or its
  required module combination is unsupported. Run the same corpus first with
  WhisperKit; only advance another runtime/model if it materially improves the
  failing metric within the device budget and passes license review.
- **Do not promote Hindi:** no candidate passes all gates. Keep Hindi absent
  from standard TestFlight and Release, and remove the beta surface if its
  safety or offline contract cannot be maintained. Never add a fallback that
  silently uses the network.

## Current conclusion

An Apple-only Hindi path has cleared the controlled `DictationTranscriber`
asset-installation and Hindi-only compatible-format gates. It is not yet
evidence that Hindi works offline end to end in LocalLingo: no pinned offline
fixture has been recognized, no translation has been executed, no Hindi voice
has been spoken and reviewed, and no live continuous bilingual session has
been quality-tested. The bilingual aggregates remain only download-eligible
because the exact English modules were not installed in the research app
identity. `Hindi (Beta)` is therefore limited to Debug and the offline
`PrivateBeta`; it must remain absent from standard TestFlight and Release until
those experiments and every release gate pass. Production Hindi release
remains blocked.
