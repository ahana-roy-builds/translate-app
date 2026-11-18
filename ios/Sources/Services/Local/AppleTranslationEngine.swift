import Foundation
@preconcurrency import Translation

@available(iOS 26.4, *)
extension OnDeviceTranslationStrategy {
    var appleStrategy: TranslationSession.Strategy {
        switch self {
        case .lowLatency: .lowLatency
        case .highFidelity: .highFidelity
        }
    }
}

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
        session = installedSession(source: source, target: target)
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
        let inventory: LanguageAvailability
        if #available(iOS 26.4, *) {
            inventory = LanguageAvailability(preferredStrategy: strategy.appleStrategy)
        } else {
            inventory = LanguageAvailability()
        }
        let status = await inventory.status(from: source, to: target)
        if status == .installed { return .ready }

        // Cold inventory can report either "supported" or "unsupported" for a
        // working direction. This session cannot request a download.
        let installed = installedSession(source: source, target: target)
        if await installed.isReady { return .ready }
        guard let code = source.languageCode?.identifier,
              let sample = Locale(identifier: code).localizedString(forLanguageCode: code) else { return .unknown }
        do {
            let response = try await installed.translate(sample)
            return response.targetText.isEmpty ? .unknown : .ready
        } catch TranslationError.notInstalled {
            return .downloadRequired
        } catch TranslationError.unsupportedLanguagePairing,
                TranslationError.unsupportedSourceLanguage, TranslationError.unsupportedTargetLanguage {
            return .unavailable
        } catch {
            return .unknown
        }
    }

    private func installedSession(source: Locale.Language, target: Locale.Language) -> TranslationSession {
        if #available(iOS 26.4, *) {
            return TranslationSession(installedSource: source, target: target, preferredStrategy: strategy.appleStrategy)
        }
        return TranslationSession(installedSource: source, target: target)
    }

    func cancel() { session?.cancel(); session = nil }
}
