import AVFoundation
import XCTest
@testable import LocalLingo

@MainActor
final class LocalPipelineReadinessTests: XCTestCase {
    func testPreparationRequiresBothTranslationDirections() async {
        let translation = ReadinessTranslationEngine([.ready, .downloadRequired])
        let pipeline = LocalConversationPipeline(
            recognition: ReadySpeechRecognitionEngine(),
            translation: translation
        )

        do {
            try await pipeline.prepare(pair: LanguagePair())
            XCTFail("Preparation should fail before recording when one translation direction is missing")
        } catch let error as PipelineError {
            guard case .assetsUnavailable = error else {
                XCTFail("Unexpected error: \(error)")
                return
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
        XCTAssertEqual(translation.availabilityChecks, 2)
    }

    func testPreparationSucceedsWhenBothDirectionsAreInstalled() async throws {
        let translation = ReadinessTranslationEngine([.ready, .ready])
        let speech = ReadySpeechRecognitionEngine()
        let pipeline = LocalConversationPipeline(recognition: speech, translation: translation)
        let pair = LanguagePair(
            traveler: .frenchFrance,
            local: .japaneseJapan
        )

        try await pipeline.prepare(pair: pair)

        XCTAssertEqual(speech.preparedLocales, ["fr-FR", "ja-JP"])
        XCTAssertEqual(translation.availabilityChecks, 2)
        XCTAssertEqual(translation.availabilityCalls, ["fr->ja", "ja->fr"])
    }
}

@MainActor
private final class ReadySpeechRecognitionEngine: SpeechRecognitionEngine {
    private(set) var preparedLocales: [String] = []

    func prepare(locale: Locale) async throws { preparedLocales.append(locale.identifier) }
    func start(locale: Locale, onPartial: @escaping @MainActor (Transcript) -> Void) async throws {}
    func append(_ buffer: AVAudioPCMBuffer) throws {}
    func finish() async throws -> Transcript { Transcript(text: "hello", isFinal: true, confidence: 1) }
    func cancel() {}
}

@MainActor
private final class ReadinessTranslationEngine: TranslationEngine {
    private var readiness: [ComponentReadiness]
    private(set) var availabilityChecks = 0
    private(set) var availabilityCalls: [String] = []

    init(_ readiness: [ComponentReadiness]) { self.readiness = readiness }

    func availability(source: Locale.Language, target: Locale.Language) async -> ComponentReadiness {
        availabilityCalls.append(
            "\(source.languageCode?.identifier ?? "?")->\(target.languageCode?.identifier ?? "?")"
        )
        defer { availabilityChecks += 1 }
        return readiness[min(availabilityChecks, readiness.count - 1)]
    }

    func prepare(source: Locale.Language, target: Locale.Language) async throws {}
    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String { text }
    func cancel() {}
}
