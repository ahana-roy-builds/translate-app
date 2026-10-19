import Foundation
@preconcurrency import Translation

@MainActor
final class AppleTranslationEngine: TranslationEngine {
    private var session: TranslationSession?
    private var source: Locale.Language?
    private var target: Locale.Language?
    private let strategy: OnDeviceTranslationStrategy

    init(strategy: OnDeviceTranslationStrategy = .highFidelity) {
        self.strategy = strategy
    }

    func prepare(source: Locale.Language, target: Locale.Language) async throws {
        if #available(iOS 26.4, *) {
            switch strategy {
            case .highFidelity:
                self.session = TranslationSession(
                    installedSource: source,
                    target: target,
                    preferredStrategy: .highFidelity
                )
            case .lowLatency:
                self.session = TranslationSession(
                    installedSource: source,
                    target: target,
                    preferredStrategy: .lowLatency
                )
            }
        } else {
            self.session = TranslationSession(installedSource: source, target: target)
        }
        self.source = source
        self.target = target
    }

    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        let boundedInput = try TurnTextPolicy.validatedFinal(text, field: "source")
        if session == nil || self.source != source || self.target != target { try await prepare(source: source, target: target) }
        guard let session else { throw PipelineError.assetsUnavailable("Translation languages are not installed") }
        let response = try await session.translate(boundedInput)
        return try TurnTextPolicy.validatedFinal(response.targetText, field: "translation")
    }

    func availability(source: Locale.Language, target: Locale.Language) async -> ComponentReadiness {
        let status = await LanguageAvailability().status(from: source, to: target)
        return switch status {
        case .installed: .ready
        case .supported: .downloadRequired
        case .unsupported: .unavailable
        @unknown default: .unknown
        }
    }

    func cancel() { session?.cancel(); session = nil }
}
