import AVFoundation
import Foundation

@MainActor
final class PlaybackService {
    private let synthesis: any SpeechSynthesisEngine

    init(synthesis: any SpeechSynthesisEngine) {
        self.synthesis = synthesis
    }

    func prepare(pair: LanguagePair) throws {
        guard synthesis.isVoiceAvailable(locale: pair.traveler.locale),
              synthesis.isVoiceAvailable(locale: pair.local.locale) else {
            throw PipelineError.assetsUnavailable("Speak voices are missing. Install both system voices in Settings → Accessibility → Read & Speak → Voices, or turn off Speak automatically for text-only mode.")
        }
    }

    func prepare(locale: Locale) throws {
        guard synthesis.isVoiceAvailable(locale: locale) else {
            throw PipelineError.assetsUnavailable(
                "The Speak voice for \(locale.identifier) is missing. Install it in Settings → Accessibility → Read & Speak → Voices."
            )
        }
    }

    func speak(_ text: String, locale: Locale, slower: Bool) async throws {
        try await synthesis.speak(
            text,
            locale: locale,
            rate: slower ? AVSpeechUtteranceDefaultSpeechRate * 0.72 : AVSpeechUtteranceDefaultSpeechRate
        )
    }

    func cancel() { synthesis.cancel() }
}
