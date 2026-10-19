import AVFoundation
import Darwin
import Foundation
import Speech
@preconcurrency import Translation
import UIKit
import XCTest
@testable import LocalLingo

/// A read-only inventory probe. It must never request permissions, capture
/// audio, install/reserve assets, prepare translation, or synthesize speech.
@MainActor
final class HindiCapabilityProbeTests: XCTestCase {
    func testReportHindiCapabilitiesWithoutChangingDeviceState() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Run the Hindi capability probe on a physical iPhone.")
#else
        let report = await makeReport()
        let data = try JSONEncoder.probeEncoder.encode(report)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))

        print("\n=== LOCALLINGO HINDI CAPABILITY PROBE BEGIN ===")
        print(json)
        print("=== LOCALLINGO HINDI CAPABILITY PROBE END ===\n")

        let attachment = XCTAttachment(string: json)
        attachment.name = "HindiCapabilityProbe.json"
        attachment.lifetime = .keepAlways
        add(attachment)
#endif
    }

    private func makeReport() async -> HindiCapabilityReport {
        HindiCapabilityReport(
            schemaVersion: 1,
            probeBehavior: ProbeBehavior(
                readOnly: true,
                requestedPermissions: false,
                capturedAudio: false,
                requestedAssetDownloads: false,
                preparedTranslation: false,
                synthesizedSpeech: false
            ),
            device: DeviceReport(
                hardwareIdentifier: Self.hardwareIdentifier(),
                deviceClass: UIDevice.current.model,
                systemName: UIDevice.current.systemName,
                systemVersion: UIDevice.current.systemVersion,
                operatingSystemVersion: ProcessInfo.processInfo.operatingSystemVersionString
            ),
            requestedLocale: Self.hindiLocale.identifier,
            currentAppLanguageCatalog: AppLanguage.conversationLanguages.map(\.code),
            speechTranscriber: await speechTranscriberReport(),
            dictationTranscriber: await dictationTranscriberReport(),
            legacySpeechRecognizer: legacySpeechRecognizerReport(),
            translationDirections: await translationReports(),
            speechSynthesis: speechSynthesisReport(),
            interpretationNotes: [
                "Asset status values are inventory snapshots; this probe never asks iOS to install or reserve an asset.",
                "DictationTranscriber exposes no separate isAvailable flag; a null frameworkAvailable value is not an unavailable result.",
                "SFSpeechRecognizer.isAvailable is a point-in-time service signal. No recognition request is made.",
                "Translation strategy is preferred, not guaranteed. High Fidelity may fall back, and Apple exposes no resolved-engine result through this availability API.",
                "Speech synthesis lists voices currently exposed to the app; this probe does not speak or download a voice."
            ]
        )
    }

    private func speechTranscriberReport() async -> SpeechModuleReport {
        let installed = await SpeechTranscriber.installedLocales
        let supported = await SpeechTranscriber.supportedLocale(equivalentTo: Self.hindiLocale)
        let assetStatus: String
        if let supported {
            let module = SpeechTranscriber(locale: supported, preset: .transcription)
            assetStatus = Self.assetStatus(
                await AssetInventory.status(forModules: [module])
            )
        } else {
            assetStatus = "not-queried-unsupported-locale"
        }

        return SpeechModuleReport(
            frameworkAvailable: SpeechTranscriber.isAvailable,
            supportedLocale: supported?.identifier,
            installedHindiLocales: Self.hindiLocaleIdentifiers(in: installed),
            assetStatus: assetStatus
        )
    }

    private func dictationTranscriberReport() async -> SpeechModuleReport {
        let installed = await DictationTranscriber.installedLocales
        let supported = await DictationTranscriber.supportedLocale(equivalentTo: Self.hindiLocale)
        let assetStatus: String
        if let supported {
            let module = DictationTranscriber(locale: supported, preset: .shortDictation)
            assetStatus = Self.assetStatus(
                await AssetInventory.status(forModules: [module])
            )
        } else {
            assetStatus = "not-queried-unsupported-locale"
        }

        return SpeechModuleReport(
            frameworkAvailable: nil,
            supportedLocale: supported?.identifier,
            installedHindiLocales: Self.hindiLocaleIdentifiers(in: installed),
            assetStatus: assetStatus
        )
    }

    private func legacySpeechRecognizerReport() -> LegacySpeechRecognizerReport {
        let supportedHindiLocales = Self.hindiLocaleIdentifiers(
            in: Array(SFSpeechRecognizer.supportedLocales())
        )
        let explicitlySupportsHindi = !supportedHindiLocales.isEmpty
        let recognizer = SFSpeechRecognizer(locale: Self.hindiLocale)
        let resolvedLocale = recognizer?.locale
        let resolvedToHindi = resolvedLocale.map(Self.isHindi) ?? false
        let canEvaluateHindiRecognizer = explicitlySupportsHindi && resolvedToHindi
        let supportsOnDevice = canEvaluateHindiRecognizer
            ? recognizer?.supportsOnDeviceRecognition
            : nil

        return LegacySpeechRecognizerReport(
            authorizationStatus: Self.authorizationStatus(
                SFSpeechRecognizer.authorizationStatus()
            ),
            supportedHindiLocales: supportedHindiLocales,
            explicitlySupportsHindi: explicitlySupportsHindi,
            recognizerCreated: recognizer != nil,
            recognizerLocale: resolvedLocale?.identifier,
            recognizerResolvedToHindi: resolvedToHindi,
            serviceAvailableAtProbeTime: canEvaluateHindiRecognizer
                ? recognizer?.isAvailable
                : nil,
            supportsOnDeviceRecognition: supportsOnDevice,
            networkRequiredIfUsed: supportsOnDevice.map { !$0 }
        )
    }

    private func translationReports() async -> [TranslationDirectionReport] {
        let hindi = Self.hindiLocale.language
        var directions: [(source: Locale.Language, target: Locale.Language)] = []
        for appLanguage in AppLanguage.conversationLanguages
            where appLanguage != .hindiIndia {
            directions.append((source: hindi, target: appLanguage.language))
            directions.append((source: appLanguage.language, target: hindi))
        }

        if #available(iOS 26.4, *) {
            let lowLatency = LanguageAvailability(preferredStrategy: .lowLatency)
            let highFidelity = LanguageAvailability(preferredStrategy: .highFidelity)
            var results: [TranslationDirectionReport] = []
            for direction in directions {
                let lowStatus = await lowLatency.status(
                    from: direction.source,
                    to: direction.target
                )
                let highStatus = await highFidelity.status(
                    from: direction.source,
                    to: direction.target
                )
                results.append(TranslationDirectionReport(
                    source: Self.languageIdentifier(direction.source),
                    target: Self.languageIdentifier(direction.target),
                    lowLatencyStatus: Self.translationStatus(lowStatus),
                    highFidelityStatus: Self.translationStatus(highStatus),
                    legacyDefaultStatus: "not-applicable-on-ios-26.4-or-newer"
                ))
            }
            return results
        }

        let legacy = LanguageAvailability()
        var results: [TranslationDirectionReport] = []
        for direction in directions {
            let status = await legacy.status(from: direction.source, to: direction.target)
            results.append(TranslationDirectionReport(
                source: Self.languageIdentifier(direction.source),
                target: Self.languageIdentifier(direction.target),
                lowLatencyStatus: "not-queryable-before-ios-26.4",
                highFidelityStatus: "not-queryable-before-ios-26.4",
                legacyDefaultStatus: Self.translationStatus(status)
            ))
        }
        return results
    }

    private func speechSynthesisReport() -> SpeechSynthesisReport {
        let voices = AVSpeechSynthesisVoice.speechVoices()
            .filter { Self.isHindi(Locale(identifier: $0.language)) }
            .map {
                SpeechVoiceReport(
                    language: $0.language,
                    quality: Self.voiceQuality($0.quality)
                )
            }
            .sorted {
                ($0.language, $0.quality) < ($1.language, $1.quality)
            }

        return SpeechSynthesisReport(
            hasHindiLanguageVoice: !voices.isEmpty,
            hasExactHindiIndiaVoice: voices.contains {
                let language = Locale(identifier: $0.language).language
                return language.languageCode?.identifier.lowercased() == "hi"
                    && language.region?.identifier.uppercased() == "IN"
            },
            voiceCount: voices.count,
            voices: voices
        )
    }

    private static let hindiLocale = Locale(identifier: "hi-IN")

    private static func isHindi(_ locale: Locale) -> Bool {
        locale.language.languageCode?.identifier.lowercased() == "hi"
    }

    private static func hindiLocaleIdentifiers(in locales: [Locale]) -> [String] {
        locales
            .filter(isHindi)
            .map(\.identifier)
            .sorted()
    }

    private static func languageIdentifier(_ language: Locale.Language) -> String {
        let languageCode = language.languageCode?.identifier ?? "und"
        if let region = language.region?.identifier {
            return "\(languageCode)-\(region)"
        }
        return languageCode
    }

    private static func assetStatus(_ status: AssetInventory.Status) -> String {
        switch status {
        case .unsupported: "unsupported"
        case .supported: "supported-not-installed"
        case .downloading: "downloading"
        case .installed: "installed"
        @unknown default: "unknown"
        }
    }

    private static func translationStatus(_ status: LanguageAvailability.Status) -> String {
        switch status {
        case .installed: "installed"
        case .supported: "supported-not-installed"
        case .unsupported: "unsupported"
        @unknown default: "unknown"
        }
    }

    private static func authorizationStatus(
        _ status: SFSpeechRecognizerAuthorizationStatus
    ) -> String {
        switch status {
        case .notDetermined: "not-determined"
        case .denied: "denied"
        case .restricted: "restricted"
        case .authorized: "authorized"
        @unknown default: "unknown"
        }
    }

    private static func voiceQuality(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .default: "default"
        case .enhanced: "enhanced"
        case .premium: "premium"
        @unknown default: "unknown-\(quality.rawValue)"
        }
    }

    private static func hardwareIdentifier() -> String {
        var size = 0
        guard sysctlbyname("hw.machine", nil, &size, nil, 0) == 0, size > 1 else {
            return "unavailable"
        }
        var value = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.machine", &value, &size, nil, 0) == 0 else {
            return "unavailable"
        }
        let bytes = value.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
        return String(decoding: bytes, as: UTF8.self)
    }
}

private struct HindiCapabilityReport: Encodable {
    let schemaVersion: Int
    let probeBehavior: ProbeBehavior
    let device: DeviceReport
    let requestedLocale: String
    let currentAppLanguageCatalog: [String]
    let speechTranscriber: SpeechModuleReport
    let dictationTranscriber: SpeechModuleReport
    let legacySpeechRecognizer: LegacySpeechRecognizerReport
    let translationDirections: [TranslationDirectionReport]
    let speechSynthesis: SpeechSynthesisReport
    let interpretationNotes: [String]
}

private struct ProbeBehavior: Encodable {
    let readOnly: Bool
    let requestedPermissions: Bool
    let capturedAudio: Bool
    let requestedAssetDownloads: Bool
    let preparedTranslation: Bool
    let synthesizedSpeech: Bool
}

private struct DeviceReport: Encodable {
    let hardwareIdentifier: String
    let deviceClass: String
    let systemName: String
    let systemVersion: String
    let operatingSystemVersion: String
}

private struct SpeechModuleReport: Encodable {
    let frameworkAvailable: Bool?
    let supportedLocale: String?
    let installedHindiLocales: [String]
    let assetStatus: String
}

private struct LegacySpeechRecognizerReport: Encodable {
    let authorizationStatus: String
    let supportedHindiLocales: [String]
    let explicitlySupportsHindi: Bool
    let recognizerCreated: Bool
    let recognizerLocale: String?
    let recognizerResolvedToHindi: Bool
    let serviceAvailableAtProbeTime: Bool?
    let supportsOnDeviceRecognition: Bool?
    let networkRequiredIfUsed: Bool?
}

private struct TranslationDirectionReport: Encodable {
    let source: String
    let target: String
    let lowLatencyStatus: String
    let highFidelityStatus: String
    let legacyDefaultStatus: String
}

private struct SpeechSynthesisReport: Encodable {
    let hasHindiLanguageVoice: Bool
    let hasExactHindiIndiaVoice: Bool
    let voiceCount: Int
    let voices: [SpeechVoiceReport]
}

private struct SpeechVoiceReport: Encodable {
    let language: String
    let quality: String
}

private extension JSONEncoder {
    static var probeEncoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }
}
