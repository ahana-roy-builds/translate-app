import AVFoundation
import Foundation

@MainActor
protocol SpeechRecognitionEngine: AnyObject {
    func prepare(locale: Locale) async throws
    func start(locale: Locale, onPartial: @escaping @MainActor (Transcript) -> Void) async throws
    func append(_ buffer: AVAudioPCMBuffer) throws
    func finish() async throws -> Transcript
    func cancel()
}

@MainActor
protocol SpeechAssetManaging: AnyObject {
    func assetReadiness(locale: Locale) async -> ComponentReadiness
    func continuousAssetReadiness(pair: LanguagePair) async -> ComponentReadiness
    func inventorySnapshot() async -> SpeechAssetInventorySnapshot
    func reserveAssets(locale: Locale) async throws
    func releaseAssets(reservedLocale: Locale) async -> Bool
    func installAssets(
        locale: Locale,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws
    func installContinuousAssets(
        pair: LanguagePair,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws
}

@MainActor
protocol TranslationEngine: AnyObject {
    func availability(source: Locale.Language, target: Locale.Language) async -> ComponentReadiness
    func prepare(source: Locale.Language, target: Locale.Language) async throws
    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String
    func cancel()
}

@MainActor
protocol ContinuousBidirectionalTranslating: AnyObject {
    func prepare(
        pair: LanguagePair,
        strategy: OnDeviceTranslationStrategy
    ) async throws
    func translate(
        _ text: String,
        speaker: SpeakerSide,
        pair: LanguagePair
    ) async throws -> String
    func cancel()
}

@MainActor
protocol SpeechSynthesisEngine: AnyObject {
    func isVoiceAvailable(locale: Locale) -> Bool
    func availableVoices(for languages: [AppLanguage]) async -> Set<AppLanguage>
    func speak(_ text: String, locale: Locale, rate: Float) async throws
    func play(data: Data, format: String?) async throws
    func cancel()
}

extension SpeechSynthesisEngine {
    func availableVoices(for languages: [AppLanguage]) async -> Set<AppLanguage> {
        Set(languages.filter { isVoiceAvailable(locale: $0.locale) })
    }
}

@MainActor
protocol ConversationPipeline: AnyObject {
    var route: EngineRoute { get }
    func prepare(pair: LanguagePair) async throws
    func beginRecognition(locale: Locale, onPartial: @escaping @MainActor (Transcript) -> Void) async throws
    func append(_ buffer: AVAudioPCMBuffer) throws
    func process(audio: AudioTurn, source: AppLanguage, target: AppLanguage) async throws -> PipelineResult
    func translateText(_ text: String, source: AppLanguage, target: AppLanguage) async throws -> PipelineResult
    func cancel()
}

enum PipelineError: LocalizedError {
    case permissionDenied, unsupportedLocale(String), assetsUnavailable(String), noSpeech, offlineRequired, onlineUnavailable, malformedResponse, server(String)
    var errorDescription: String? {
        switch self {
        case .permissionDenied: "Microphone permission was denied."
        case let .unsupportedLocale(value): "The selected language is not supported: \(value)."
        case let .assetsUnavailable(value): "Required offline assets are unavailable: \(value)."
        case .noSpeech: "No speech was detected. Please try again."
        case .offlineRequired: "Local Only prevents this request from using the network."
        case .onlineUnavailable: "Online Quality is currently unavailable."
        case .malformedResponse: "The translation service returned an invalid response."
        case let .server(message): message
        }
    }
}
