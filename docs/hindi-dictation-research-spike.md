# Hindi DictationTranscriber research spike

This spike evaluates whether Apple's `DictationTranscriber` can provide the
offline Hindi listening path for LocalLingo. The resulting implementation is
exposed only as `Hindi (Beta)` in Debug and the offline Private Beta
configuration. Standard TestFlight and Release language catalogs remain
unchanged until the release gates below pass.

## Current evidence

The read-only probe and controlled installation on the connected iPhone 13 Pro
established:

- `SpeechTranscriber` has no Hindi locale or asset for this device;
- `DictationTranscriber` resolves `hi-IN`, with asset state
  `supported-not-installed` before the controlled installation;
- the explicitly authorized installation moved the exact Hindi live/final
  module pair to `installed`, exposed exact `hi-IN` in `installedLocales`, and
  returned a compatible 16 kHz mono format (`AVAudioCommonFormat(rawValue:
  3)`);
- Apple Translation reports Hindi as supported but not installed in both
  directions with every language in the current LocalLingo catalog; no
  Translation session has been run; and
- at least one Hindi speech-synthesis voice is present, but it has not been
  exercised or reviewed.

This changes the first candidate to test. Apple's documentation says
`DictationTranscriber` uses the on-device system-dictation model and does not
expose locales that `SFSpeechRecognizer` supports only through the network.
The controlled installation therefore clears the asset-availability and
Hindi-only analyzer-format gates. A later read-only check confirmed that the
hybrid and all-Dictation bilingual configurations are supported, but English's
exact modules were not installed in that app identity, so common-format and
runtime coexistence remain unproven. Offline inference, Hindi accuracy,
Hinglish behavior, latency, and thermals also remain unknown.

Primary Apple references:

- [DictationTranscriber](https://developer.apple.com/documentation/speech/dictationtranscriber)
- [DictationTranscriber presets](https://developer.apple.com/documentation/speech/dictationtranscriber/preset)
- [AssetInventory](https://developer.apple.com/documentation/speech/assetinventory)
- [SpeechAnalyzer WWDC25 session](https://developer.apple.com/videos/play/wwdc2025/277/)

## Existing architecture

`AppleContinuousSpeechRecognizer` constructs four modules in one
`SpeechAnalyzer`: live and final-only modules for both selected languages. The
shared module plan keeps `SpeechTranscriber` for the base catalog and selects
`DictationTranscriber` for Hindi without using network-backed
`SFSpeechRecognizer`. It converts each microphone buffer once, sends the same
time-coded audio through all four modules, and uses the VAD range to finalize
an utterance.

The closest Dictation configuration for continuous audio is:

- live: `progressiveLongDictation`, plus `audioTimeRange` and
  `transcriptionConfidence` attributes;
- authoritative final: `longDictation`, plus the same attributes; and
- both modules consuming the same analyzer input stream.

`shortDictation` is documented for approximately one minute and has no
volatile results. It is not the continuous-session configuration.

Two bilingual configurations must be measured after assets are installed:

1. Hybrid: English `SpeechTranscriber` live/final plus Hindi
   `DictationTranscriber` live/final. This preserves the newer English model,
   but may require two backing model families at once.
2. All-Dictation: English and Hindi `DictationTranscriber` live/final. Similar
   module configurations may share backing engines, but English quality may be
   lower and an additional dictation asset may be necessary.

Neither `AssetInventory.status` nor a non-null locale proves that four modules
can run together. Only call `SpeechAnalyzer.bestAvailableAudioFormat` for the
aggregate configuration after the required assets are installed, then run a
sustained file and live-audio test.

## Guarded XCTest harness

`HindiDictationResearchSpikeTests` has four deliberately separate operations:

1. The configuration inventory is read-only and runs without an environment
   variable. It checks all six Dictation presets, the exact live/final pair,
   both bilingual aggregate variants, all advertised Hindi locales, explicit
   `hi-IN`, `hi-Latn`, and `hi-IN-translit` equivalents, and the system's
   reservation limit/current reservations. It never requests an asset or asks
   for a compatible audio format. Raw and BCP-47 identifiers are recorded,
   along with exact-membership booleans; `supportedLocale(equivalentTo:)` is
   allowed to return a merely language-equivalent locale.
2. The install test is skipped unless its exact opt-in environment value is
   present. It can request only Apple's Hindi dictation asset and never opens
   the microphone.
3. The inference test is skipped unless a different exact opt-in value is
   present. It cannot request an asset. It reads one checksum-pinned WAV from
   the test bundle, requires an unsatisfied `NWPath` before inference, and
   checks the path again afterward.
4. The post-install bilingual compatibility report is read-only. It checks the
   hybrid and all-Dictation aggregates and queries a common format only after
   the complete module set reports installed.

Normal application and test runs do not install a model or transcribe audio.
Do not leave an opt-in environment variable enabled on the scheme after the
single intended research run.

## Phase 1: pre-install inventory

Run only this test on the physical iPhone while it is online:

```text
HindiDictationResearchSpikeTests/
testInventoryHindiDictationConfigurationsWithoutInstalling
```

Save `HindiDictationConfiguration.json`. Do not run the installation test yet.
The report must show the exact Hindi live/final pair as supported and clarify
whether `hi-Latn` or `hi-IN-translit` resolves to a genuinely distinct locale
or merely aliases `hi-IN`. Require exact membership in `supportedLocales` for
script/transliteration capability; treat a near-equivalent result as no
evidence of Hinglish support.

## Phase 2: explicit Apple asset install (completed)

After reviewing the Phase 1 report and receiving explicit approval, set this
environment value for only the installation test:

```text
LOCALLINGO_HINDI_DICTATION_RESEARCH_ACTION=INSTALL_APPLE_HINDI_DICTATION_ASSET
```

Run only:

```text
HindiDictationResearchSpikeTests/
testInstallAppleHindiDictationAssetWithExplicitOptIn
```

Keep the phone online and powered. Remove the environment value immediately
afterward. The test requests the exact live/final module pair and verifies the
final state is `installed`, confirms exact `hi-IN` membership in
`DictationTranscriber.installedLocales`, and requires a compatible audio
format for the pair. It attaches a redacted installation report containing
only those states and the format's sample rate, channel count, and common
format. It does not reserve or release any other locale.

On 2026-08-15, this test passed on the research device in 15.004 seconds. The
asset moved from `supported-not-installed` to `installed`; exact `hi-IN` was
present in `installedLocales`; and the exact live/final pair accepted a 16 kHz,
one-channel format. The sanitized report and SHA-256 are retained in the
[Hindi research evidence directory](research-evidence/hindi/README.md).

## Post-install bilingual aggregate status

A later read-only check found the exact Hindi live/final modules installed. The
hybrid configuration still lacked the exact English Speech modules, and the
all-Dictation alternative still lacked the exact English Dictation modules.
Both four-module aggregates therefore remained supported and
download-eligible rather than installed. The check did not request those
assets or query a common analyzer format. It does not establish bilingual
module coexistence or runtime behavior. The sanitized attachment from this
check was not retained, so treat the result as an unretained engineering
observation and repeat it before using it as evidence.

## Phase 3: deterministic offline inference

Use a fixed, appropriately licensed Hindi utterance rather than microphone
input or live TTS. The FLEURS fixture is CC BY 4.0, but its public materials do
not establish a project-specific speaker release; it therefore remains a
local, uncommitted plumbing fixture and is excluded from quality evidence.
TTS-to-ASR is useful only as a plumbing smoke test and must not be counted as
human-speech accuracy evidence.

1. Run `scripts/fetch-hindi-dictation-fixture.sh`. It retrieves FLEURS Hindi
   validation row 156, verifies its published metadata and byte-pinned SHA-256,
   and places the ignored `hindi-dictation-fixture.wav` in the local test
   resources. Source, license, transcript, and retention details are recorded
   in the [Hindi research evidence directory](research-evidence/hindi/README.md).
   Then run `cd ios && xcodegen generate` so a project generated before the
   download includes the ignored fixture in the test bundle.
2. Confirm the fixture SHA-256 is
   `9e34c3ddde1a12e9b4925ac1f8621018a4ab21096c870c18b55fab06f132e552`.
3. On the iPhone, enable Airplane Mode, then separately disable Wi-Fi. Confirm
   cellular data and Personal Hotspot are unavailable.
4. Set the single action value for only the inference test. The approved SHA-256
   and transcript are pinned in the test source and cannot be overridden:

   ```text
   LOCALLINGO_HINDI_DICTATION_RESEARCH_ACTION=TRANSCRIBE_PINNED_FIXTURE_OFFLINE
   ```

5. Run only
   `testTranscribePinnedHindiFixtureWhileOffline`, save
   `HindiDictationInference.json`, then remove the action value.

The test uses `AVAudioFile`, the existing `SpeechAnalyzerInputConverter`, and
the final-only long Dictation module. It requests no microphone or speech
permission. A before-and-after unsatisfied `NWPath`, installed asset state, the
pinned fixture digest, and Apple's on-device-only API contract form the offline
evidence. `NWPath` alone does not prove the Airplane Mode UI state, so retain a
screenshot or screen recording of the device controls with the test result. A
90-second monotonic watchdog fails the inference and cancels its analyzer,
input stream, and result consumers rather than allowing an unattended run to
hang indefinitely.

Exact-text equality makes this first run a plumbing check. The benchmark stage
must replace it with normalized word and character error rates across multiple
native speakers, accents, noise levels, travel entities, and code-switching.

## Continuous-mode decision gates

Do not add Hindi to the standard TestFlight or Release catalogs until all of
these pass on the iPhone 13 Pro:

- both aggregate module configurations return a compatible audio format;
- at least a 20-minute replay completes without a crash, runaway memory, or
  severe thermal throttling;
- Hindi and English final results share a usable time base and finalize through
  each VAD utterance boundary;
- one configuration reliably produces two candidates from the same audio;
- Devanagari Hindi is not systematically selected as English;
- English words embedded in Hindi and common Hinglish are measured separately;
- playback suppression prevents synthesized Hindi from becoming a new turn;
- the full recognize, translate, and speak path succeeds with no available
  network route; and
- human-reviewed WER/CER, entity preservation, translation safety, latency,
  battery, and thermal thresholds meet the acceptance criteria.

If the hybrid configuration is stable and at least as accurate, prefer it. If
it cannot load both model families concurrently, compare all-Dictation against
an on-device third-party ASR candidate before choosing an architecture.
