# Hindi physical-device research evidence

These reports are sanitized XCTest attachments captured on 2026-08-15 from an
iPhone 13 Pro (`iPhone14,2`) running iOS 26.6 (23G71), using Xcode 26.6 and the
iOS 26.5 SDK. They are feasibility evidence only, not release qualification.

The capability and configuration tests passed and were read-only. They
requested no permission, microphone capture, asset reservation or download,
compatible audio format, Translation preparation, or speech synthesis.

The explicitly authorized installation test also passed, in 15.004 seconds. It
requested Apple's asset for only the exact Hindi live/final Dictation modules,
confirmed exact `hi-IN` installation, and found a compatible 16 kHz mono audio
format. It requested no permission, captured no audio, prepared no Translation
session, and synthesized no speech.

| Report | XCTest method | SHA-256 |
| --- | --- | --- |
| [`2026-08-15-iphone14-2-ios26-6-capability.json`](2026-08-15-iphone14-2-ios26-6-capability.json) | `HindiCapabilityProbeTests/testReportHindiCapabilitiesWithoutChangingDeviceState` | `bae7badc9dd5f2247e73390a562b7491478f16c55bf2c0dac0a160bf9ed59493` |
| [`2026-08-15-iphone14-2-ios26-6-dictation-configurations.json`](2026-08-15-iphone14-2-ios26-6-dictation-configurations.json) | `HindiDictationResearchSpikeTests/testInventoryHindiDictationConfigurationsWithoutInstalling` | `cd39564e029697aedbd3a7ba5d81dadf883d6919bad8e508c60a6847bac29c13` |
| [`2026-08-15-iphone14-2-ios26-6-dictation-installation.json`](2026-08-15-iphone14-2-ios26-6-dictation-installation.json) | `HindiDictationResearchSpikeTests/testInstallAppleHindiDictationAssetWithExplicitOptIn` | `7085a749ba3af4a16b8dbca320289c05fa41bfc27ea4215d2c2425a79decdab4` |

The raw `.xcresult` bundles and attachment manifests are deliberately excluded.
They contain the device name and UDID. The retained JSON contains no device
name, UDID, Apple account, signing identity, email address, phone number, or
conversation content.

The later post-install bilingual aggregate check is not listed because its
sanitized attachment was not retained. The observed supported-but-not-installed
statuses are documented only as an unretained engineering note and must be
repeated before they are used as evidence.

The offline inference fixture is also excluded from Git. Run
`scripts/fetch-hindi-dictation-fixture.sh` to fetch the exact byte-pinned FLEURS
Hindi clip into the local XCTest resources. Its source, license, transcript,
retention decision, and SHA-256 are recorded in
[`hindi-dictation-fixture-provenance.json`](hindi-dictation-fixture-provenance.json).
The public FLEURS materials reviewed here do not document a project-specific
speaker release. The fixture therefore remains local and uncommitted, is used
only for a plumbing smoke test, and is excluded from quality scoring and
release evidence.
