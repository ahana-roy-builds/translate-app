import CoreMedia
import Foundation
import Speech

enum AppleSpeechModuleRole: Equatable, Sendable {
    case manual
    case continuousLive
    case continuousFinal
}

enum AppleSpeechModuleImplementation: Equatable, Sendable {
    case speechTranscriber
    case progressiveLongDictation
    case longDictation
}

struct NormalizedAppleSpeechResult: Sendable {
    let range: CMTimeRange
    let resultsFinalizationTime: CMTime
    let text: AttributedString
    let isFinal: Bool

    init(_ result: SpeechTranscriber.Result) {
        range = result.range
        resultsFinalizationTime = result.resultsFinalizationTime
        text = result.text
        isFinal = result.isFinal
    }

    init(_ result: DictationTranscriber.Result) {
        range = result.range
        resultsFinalizationTime = result.resultsFinalizationTime
        text = result.text
        isFinal = result.isFinal
    }
}

enum AppleSpeechTranscriptionModule: Sendable {
    case speech(SpeechTranscriber)
    case dictation(DictationTranscriber)

    var analyzerModule: any SpeechModule {
        switch self {
        case let .speech(transcriber): transcriber
        case let .dictation(transcriber): transcriber
        }
    }

    func normalizedResults() -> AsyncThrowingStream<NormalizedAppleSpeechResult, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    switch self {
                    case let .speech(transcriber):
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            continuation.yield(NormalizedAppleSpeechResult(result))
                        }
                    case let .dictation(transcriber):
                        for try await result in transcriber.results {
                            try Task.checkCancellation()
                            continuation.yield(NormalizedAppleSpeechResult(result))
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }
}

/// Resolves one requested locale to an exact, local-only SpeechAnalyzer module
/// family. Hindi is intentionally never routed through SpeechTranscriber or the
/// legacy SFSpeechRecognizer API.
struct AppleSpeechModulePlan: Sendable {
    let requestedLocale: Locale
    let supportedLocale: Locale

    static func resolve(for requestedLocale: Locale) async throws -> Self {
        let supportedLocale: Locale?
        if usesDictation(for: requestedLocale) {
            supportedLocale = await DictationTranscriber.supportedLocale(
                equivalentTo: requestedLocale
            )
        } else {
            guard SpeechTranscriber.isAvailable else {
                throw PipelineError.assetsUnavailable(
                    "On-device listening is not supported on this iPhone."
                )
            }
            supportedLocale = await SpeechTranscriber.supportedLocale(
                equivalentTo: requestedLocale
            )
        }
        try Task.checkCancellation()
        guard let requestedLanguageCode = languageCode(for: requestedLocale),
              let supportedLocale,
              languageCode(for: supportedLocale) == requestedLanguageCode else {
            throw PipelineError.unsupportedLocale(requestedLocale.identifier)
        }
        return Self(
            requestedLocale: requestedLocale,
            supportedLocale: supportedLocale
        )
    }

    func makeModule(for role: AppleSpeechModuleRole) -> AppleSpeechTranscriptionModule {
        switch Self.implementation(for: requestedLocale, role: role) {
        case .speechTranscriber:
            let preset = SpeechTranscriber.Preset.transcription
            let reportingOptions: Set<SpeechTranscriber.ReportingOption>
            switch role {
            case .manual:
                reportingOptions = preset.reportingOptions.union([.volatileResults])
            case .continuousLive:
                reportingOptions = preset.reportingOptions.union([
                    .volatileResults,
                    .fastResults
                ])
            case .continuousFinal:
                reportingOptions = preset.reportingOptions.subtracting([
                    .volatileResults,
                    .fastResults
                ])
            }
            return .speech(SpeechTranscriber(
                locale: supportedLocale,
                transcriptionOptions: preset.transcriptionOptions,
                reportingOptions: reportingOptions,
                attributeOptions: preset.attributeOptions.union([
                    .audioTimeRange,
                    .transcriptionConfidence
                ])
            ))

        case .progressiveLongDictation:
            return .dictation(Self.makeDictationTranscriber(
                locale: supportedLocale,
                preset: .progressiveLongDictation
            ))

        case .longDictation:
            return .dictation(Self.makeDictationTranscriber(
                locale: supportedLocale,
                preset: .longDictation
            ))
        }
    }

    /// Pack readiness covers every distinct configuration used at runtime.
    /// SpeechTranscriber shares one model across its reporting configurations;
    /// Hindi is checked and installed with both progressive and final modules.
    func makeAssetModules() -> [AppleSpeechTranscriptionModule] {
        Self.assetRoles(for: requestedLocale).map(makeModule(for:))
    }

    static func implementation(
        for locale: Locale,
        role: AppleSpeechModuleRole
    ) -> AppleSpeechModuleImplementation {
        guard usesDictation(for: locale) else { return .speechTranscriber }
        return role == .continuousFinal ? .longDictation : .progressiveLongDictation
    }

    static func assetRoles(for locale: Locale) -> [AppleSpeechModuleRole] {
        usesDictation(for: locale) ? [.continuousLive, .continuousFinal] : [.manual]
    }

    static func usesDictation(for locale: Locale) -> Bool {
        languageCode(for: locale) == "hi"
    }

    private static func makeDictationTranscriber(
        locale: Locale,
        preset: DictationTranscriber.Preset
    ) -> DictationTranscriber {
        DictationTranscriber(
            locale: locale,
            contentHints: preset.contentHints,
            transcriptionOptions: preset.transcriptionOptions,
            reportingOptions: preset.reportingOptions,
            attributeOptions: preset.attributeOptions.union([
                .audioTimeRange,
                .transcriptionConfidence
            ])
        )
    }

    private static func languageCode(for locale: Locale) -> String? {
        locale.language.languageCode?.identifier.lowercased()
    }
}
