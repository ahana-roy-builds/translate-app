# Hindi capability probe

Run the read-only XCTest probe before choosing a Hindi speech-recognition
implementation. It inventories the exact physical iPhone and iOS build without
requesting permissions, opening the microphone, downloading or reserving an
asset, preparing Translation, or speaking audio.

The report covers:

- `SpeechTranscriber` and `DictationTranscriber` Hindi support and installed
  asset state;
- legacy `SFSpeechRecognizer` Hindi support, current service availability, and
  whether it advertises on-device recognition;
- Low Latency and High Fidelity Translation availability in both directions
  between `hi-IN` and every current LocalLingo language; and
- Hindi voices currently exposed by `AVSpeechSynthesisVoice`.

## Run on the iPhone

1. Connect and unlock the iPhone, trust the Mac, and leave Developer Mode
   enabled.
2. Generate and open the project:

   ```sh
   cd ios
   xcodegen generate
   open LocalLingo.xcodeproj
   ```

3. Select the `LocalLingo` scheme and the connected iPhone as the run
   destination. Confirm that the Debug app and test target resolve signing.
4. Open Xcode's Test navigator with **Command-6**. Expand
   `LocalLingoTests > HindiCapabilityProbeTests`.
5. Run only
   `testReportHindiCapabilitiesWithoutChangingDeviceState` using the diamond
   beside the test name. The probe intentionally skips on Simulator.
6. Open the latest test in the Report navigator with **Command-9**. Save or
   copy the `HindiCapabilityProbe.json` attachment. The same JSON is printed
   between `LOCALLINGO HINDI CAPABILITY PROBE` markers in the test log.

Run the first inventory with the phone online and without changing installed
language packs. The JSON contains no device name, Apple account, device ID,
voice name or identifier, conversation content, or captured audio. Share the
complete JSON for analysis.

## Interpret carefully

`supported-not-installed` is capability evidence, not a request to install a
model. `SFSpeechRecognizer.isAvailable` is only a point-in-time service signal;
the probe does not submit audio to determine real behavior. A false
`supportsOnDeviceRecognition` value means that this legacy recognizer would
require Apple's service if used.

On iOS 26.4 or newer, the Translation rows query separate
`LanguageAvailability` instances with Low Latency and High Fidelity as the
preferred strategy. Apple can fall back from High Fidelity, and the API does
not expose which translation engine it ultimately resolves. On an earlier iOS
26 release, the report records the legacy default status and marks both
strategy-specific fields as not queryable.
