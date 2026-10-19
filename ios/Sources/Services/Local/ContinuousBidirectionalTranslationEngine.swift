import Foundation

@MainActor
final class ContinuousBidirectionalTranslationEngine: ContinuousBidirectionalTranslating {
    private var travelerToLocal: AppleTranslationEngine?
    private var localToTraveler: AppleTranslationEngine?
    private var preparedPair: LanguagePair?

    func prepare(
        pair: LanguagePair,
        strategy: OnDeviceTranslationStrategy
    ) async throws {
        cancel()
        let travelerToLocal = AppleTranslationEngine(strategy: strategy)
        let localToTraveler = AppleTranslationEngine(strategy: strategy)

        do {
            try await travelerToLocal.prepare(
                source: pair.traveler.language,
                target: pair.local.language
            )
            try await localToTraveler.prepare(
                source: pair.local.language,
                target: pair.traveler.language
            )
        } catch {
            travelerToLocal.cancel()
            localToTraveler.cancel()
            throw error
        }

        self.travelerToLocal = travelerToLocal
        self.localToTraveler = localToTraveler
        preparedPair = pair
    }

    func translate(_ text: String, speaker: SpeakerSide, pair: LanguagePair) async throws -> String {
        guard preparedPair == pair else {
            throw PipelineError.assetsUnavailable("Continuous translation is not prepared for this language pair.")
        }
        let source = pair.source(for: speaker)
        let target = pair.target(for: speaker)
        let engine = speaker == .traveler ? travelerToLocal : localToTraveler
        guard let engine else {
            throw PipelineError.assetsUnavailable("Continuous translation is not prepared.")
        }
        return try await engine.translate(text, source: source.language, target: target.language)
    }

    func cancel() {
        preparedPair = nil
        travelerToLocal?.cancel()
        localToTraveler?.cancel()
        travelerToLocal = nil
        localToTraveler = nil
    }
}
