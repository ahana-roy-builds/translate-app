import AVFoundation
import Foundation
import NaturalLanguage

@MainActor
protocol OnlineTranslationClient: AnyObject {
    func prepareSecurity(signedTransaction: String) async throws
    func translateTurn(audio: AudioTurn, source: AppLanguage, target: AppLanguage, signedTransaction: String) async throws -> OnlineTurnResponse
    func translateText(_ text: String, source: AppLanguage, target: AppLanguage, signedTransaction: String) async throws -> OnlineTurnResponse
    func removeCurrentDevice(signedTransaction: String) async throws
    func replaceOldestDevice(signedTransaction: String) async throws
    func cancel()
}

extension OnlineTranslationClient {
    func removeCurrentDevice(signedTransaction: String) async throws {
        throw PipelineError.onlineUnavailable
    }

    func replaceOldestDevice(signedTransaction: String) async throws {
        throw PipelineError.onlineUnavailable
    }
}

@MainActor
final class UnavailableOnlineTranslationClient: OnlineTranslationClient {
    func prepareSecurity(signedTransaction: String) async throws {
        throw PipelineError.onlineUnavailable
    }

    func translateTurn(
        audio: AudioTurn,
        source: AppLanguage,
        target: AppLanguage,
        signedTransaction: String
    ) async throws -> OnlineTurnResponse {
        throw PipelineError.onlineUnavailable
    }

    func translateText(
        _ text: String,
        source: AppLanguage,
        target: AppLanguage,
        signedTransaction: String
    ) async throws -> OnlineTurnResponse {
        throw PipelineError.onlineUnavailable
    }

    func cancel() {}
}

@MainActor
final class OnlineConversationPipeline: ConversationPipeline {
    let route: EngineRoute = .online
    private let client: any OnlineTranslationClient
    private let entitlementJWS: () -> String?

    init(client: any OnlineTranslationClient, entitlementJWS: @escaping () -> String?) {
        self.client = client; self.entitlementJWS = entitlementJWS
    }

    func prepare(pair: LanguagePair) async throws {
        guard let signedTransaction = entitlementJWS() else { throw PipelineError.onlineUnavailable }
        try await client.prepareSecurity(signedTransaction: signedTransaction)
    }

    func beginRecognition(locale: Locale, onPartial: @escaping @MainActor (Transcript) -> Void) async throws {
        // Online recognition happens only after the completed in-memory audio turn is submitted.
        onPartial(Transcript(text: "Listening…", isFinal: false))
    }

    func append(_ buffer: AVAudioPCMBuffer) throws {}

    func process(audio: AudioTurn, source: AppLanguage, target: AppLanguage) async throws -> PipelineResult {
        guard let jws = entitlementJWS() else { throw PipelineError.onlineUnavailable }
        let response = try await client.translateTurn(audio: audio, source: source, target: target, signedTransaction: jws)
        let sourceText = try TurnTextPolicy.validatedFinal(response.sourceText, field: "speech")
        let translatedText = try TurnTextPolicy.validatedFinal(response.translatedText, field: "translation")
        var warningSet = Self.warnings(response.warnings)
        if response.recognitionConfidence == nil || response.recognitionConfidence! < 0.70 { warningSet.insert(.uncertainRecognition) }
        if Self.isWrongLanguage(sourceText, expected: source) { warningSet.insert(.uncertainRecognition) }
        return PipelineResult(sourceText: sourceText, translatedText: translatedText, recognitionConfidence: response.recognitionConfidence, route: .online, warnings: warningSet)
    }

    func translateText(_ text: String, source: AppLanguage, target: AppLanguage) async throws -> PipelineResult {
        guard let jws = entitlementJWS() else { throw PipelineError.onlineUnavailable }
        let requestedSource = try TurnTextPolicy.validated(text)
        let response = try await client.translateText(requestedSource, source: source, target: target, signedTransaction: jws)
        let sourceText = try TypedTranslationSourcePolicy.authoritativeSource(
            requested: requestedSource,
            echoed: response.sourceText
        )
        let translatedText = try TurnTextPolicy.validatedFinal(response.translatedText, field: "translation")
        return PipelineResult(sourceText: sourceText, translatedText: translatedText, recognitionConfidence: response.recognitionConfidence, route: .online, warnings: Self.warnings(response.warnings))
    }

    func cancel() { client.cancel() }

    private static func warnings(_ values: [String]) -> Set<TranslationWarning> {
        var result = Set(values.compactMap(TranslationWarning.init(rawValue:)))
        if values.contains(where: { TranslationWarning(rawValue: $0) == nil }) { result.insert(.serviceDegraded) }
        return result
    }

    private static func isWrongLanguage(_ text: String, expected: AppLanguage) -> Bool {
        guard text.filter(\.isLetter).count >= 8,
              let detected = NLLanguageRecognizer.dominantLanguage(for: text),
              detected != .undetermined else { return false }
        return detected.rawValue != expected.locale.language.languageCode?.identifier
    }
}

enum TypedTranslationSourcePolicy {
    /// Typed input already has an authoritative source transcript. The backend
    /// echo is a consistency check, never a replacement for what the user saw.
    static func authoritativeSource(requested: String, echoed: String) throws -> String {
        let authoritative = try TurnTextPolicy.validated(requested)
        let validatedEcho = try TurnTextPolicy.validatedFinal(echoed, field: "source")
        guard validatedEcho == authoritative else { throw PipelineError.malformedResponse }
        return authoritative
    }
}
