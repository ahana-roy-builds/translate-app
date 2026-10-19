import AVFoundation
import Foundation

@MainActor
final class LocalConversationPipeline: ConversationPipeline {
    let route: EngineRoute = .local
    private let recognition: any SpeechRecognitionEngine
    private let translation: any TranslationEngine

    init(recognition: any SpeechRecognitionEngine, translation: any TranslationEngine) {
        self.recognition = recognition; self.translation = translation
    }

    func prepare(pair: LanguagePair) async throws {
        try await recognition.prepare(locale: pair.traveler.locale)
        try await recognition.prepare(locale: pair.local.locale)
        let forward = await translation.availability(source: pair.traveler.language, target: pair.local.language)
        let reverse = await translation.availability(source: pair.local.language, target: pair.traveler.language)
        guard forward == .ready, reverse == .ready else {
            throw PipelineError.assetsUnavailable("Translation for both directions must be installed before recording")
        }
    }

    func beginRecognition(locale: Locale, onPartial: @escaping @MainActor (Transcript) -> Void) async throws {
        try await recognition.start(locale: locale, onPartial: onPartial)
    }

    func append(_ buffer: AVAudioPCMBuffer) throws { try recognition.append(buffer) }

    func process(audio: AudioTurn, source: AppLanguage, target: AppLanguage) async throws -> PipelineResult {
        let transcript = try await recognition.finish()
        let sourceText = try TurnTextPolicy.validatedFinal(transcript.text, field: "speech")
        let translated = try await translation.translate(sourceText, source: source.language, target: target.language)
        let translatedText = try TurnTextPolicy.validatedFinal(translated, field: "translation")
        return PipelineResult(sourceText: sourceText, translatedText: translatedText, recognitionConfidence: transcript.confidence, route: .local, warnings: transcript.isUncertain ? [.uncertainRecognition] : [])
    }

    func translateText(_ text: String, source: AppLanguage, target: AppLanguage) async throws -> PipelineResult {
        let sourceText = try TurnTextPolicy.validatedFinal(text, field: "source")
        let translated = try await translation.translate(sourceText, source: source.language, target: target.language)
        let translatedText = try TurnTextPolicy.validatedFinal(translated, field: "translation")
        return PipelineResult(sourceText: sourceText, translatedText: translatedText, route: .local, warnings: [])
    }

    func cancel() { recognition.cancel(); translation.cancel() }
}
