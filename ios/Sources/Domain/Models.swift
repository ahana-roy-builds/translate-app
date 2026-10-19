import Foundation

enum AppLanguage: String, CaseIterable, Codable, Identifiable, Hashable, Sendable {
    case englishUS = "englishUS"
    case spanishSpain = "spanishSpain"
    case japaneseJapan = "japaneseJapan"
    case frenchFrance = "frenchFrance"
    case germanGermany = "germanGermany"
    case italianItaly = "italianItaly"
    case portugueseBrazil = "portugueseBrazil"
    case koreanSouthKorea = "koreanSouthKorea"
    case hindiIndia = "hindiIndia"

    var id: String { rawValue }

    static let conversationLanguages: [AppLanguage] = {
#if DEBUG || PRIVATE_BETA
        catalog(includingExperimentalHindi: true)
#else
        catalog(includingExperimentalHindi: false)
#endif
    }()

    static func catalog(includingExperimentalHindi: Bool) -> [AppLanguage] {
        var languages: [AppLanguage] = [
            .englishUS,
            .spanishSpain,
            .frenchFrance,
            .germanGermany,
            .italianItaly,
            .portugueseBrazil,
            .japaneseJapan,
            .koreanSouthKorea
        ]
        if includingExperimentalHindi { languages.append(.hindiIndia) }
        return languages
    }

    var locale: Locale {
        switch self {
        case .englishUS: Locale(identifier: "en-US")
        case .spanishSpain: Locale(identifier: "es-ES")
        case .japaneseJapan: Locale(identifier: "ja-JP")
        case .frenchFrance: Locale(identifier: "fr-FR")
        case .germanGermany: Locale(identifier: "de-DE")
        case .italianItaly: Locale(identifier: "it-IT")
        case .portugueseBrazil: Locale(identifier: "pt-BR")
        case .koreanSouthKorea: Locale(identifier: "ko-KR")
        case .hindiIndia: Locale(identifier: "hi-IN")
        }
    }
    var language: Locale.Language { locale.language }
    var code: String {
        switch self {
        case .englishUS: "en-US"
        case .spanishSpain: "es-ES"
        case .japaneseJapan: "ja-JP"
        case .frenchFrance: "fr-FR"
        case .germanGermany: "de-DE"
        case .italianItaly: "it-IT"
        case .portugueseBrazil: "pt-BR"
        case .koreanSouthKorea: "ko-KR"
        case .hindiIndia: "hi-IN"
        }
    }
    var displayName: String {
        switch self {
        case .englishUS: "English"
        case .spanishSpain: "Spanish"
        case .japaneseJapan: "Japanese"
        case .frenchFrance: "French"
        case .germanGermany: "German"
        case .italianItaly: "Italian"
        case .portugueseBrazil: "Portuguese (Brazil)"
        case .koreanSouthKorea: "Korean"
        case .hindiIndia: "Hindi (Beta)"
        }
    }
    var nativeName: String {
        switch self {
        case .englishUS: "English"
        case .spanishSpain: "Español"
        case .japaneseJapan: "日本語"
        case .frenchFrance: "Français"
        case .germanGermany: "Deutsch"
        case .italianItaly: "Italiano"
        case .portugueseBrazil: "Português (Brasil)"
        case .koreanSouthKorea: "한국어"
        case .hindiIndia: "हिन्दी"
        }
    }
}

struct LanguagePair: Codable, Equatable, Hashable, Sendable {
    var traveler: AppLanguage = .englishUS
    var local: AppLanguage = .spanishSpain

    var isValid: Bool { traveler != local }

    var swapped: Self {
        Self(traveler: local, local: traveler)
    }

    func replacing(_ side: SpeakerSide, with language: AppLanguage) -> Self? {
        let replacement = switch side {
        case .traveler:
            Self(traveler: language, local: local)
        case .local:
            Self(traveler: traveler, local: language)
        }
        return replacement.isValid ? replacement : nil
    }

    func source(for speaker: SpeakerSide) -> AppLanguage { speaker == .traveler ? traveler : local }
    func target(for speaker: SpeakerSide) -> AppLanguage { speaker == .traveler ? local : traveler }
}

enum SpeakerSide: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case traveler
    case local
    var other: Self { self == .traveler ? .local : .traveler }
}

enum ConversationLayout: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case heldPhone
    case faceToFace
    var id: String { rawValue }
    var title: String { self == .heldPhone ? "Held phone" : "Face to face" }
}

enum RoutingPreference: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case automatic
    case localOnly
    case onlineQuality
    var id: String { rawValue }
    var title: String {
        switch self {
        case .automatic: "Auto"
        case .localOnly: "Local Only"
        case .onlineQuality: "Online Quality"
        }
    }
}

enum OnDeviceTranslationStrategy: String, Codable, CaseIterable, Identifiable, Equatable, Sendable {
    case lowLatency
    case highFidelity

    var id: String { rawValue }

    var title: String {
        switch self {
        case .lowLatency: "Low Latency"
        case .highFidelity: "High Fidelity"
        }
    }
}

enum EngineRoute: String, Codable, Equatable, Hashable, Sendable { case local, online }

struct Transcript: Equatable, Sendable {
    var text: String
    var isFinal: Bool
    var confidence: Double?
    var lowConfidenceFraction: Double
    var languageMatchesExpectation: Bool?

    init(
        text: String,
        isFinal: Bool,
        confidence: Double? = nil,
        lowConfidenceFraction: Double = 0,
        languageMatchesExpectation: Bool? = nil
    ) {
        self.text = text
        self.isFinal = isFinal
        self.confidence = confidence
        self.lowConfidenceFraction = lowConfidenceFraction
        self.languageMatchesExpectation = languageMatchesExpectation
    }

    var isUncertain: Bool {
        guard let confidence else { return true }
        return confidence < 0.70 || lowConfidenceFraction >= 0.20 || languageMatchesExpectation == false
    }
}

struct AudioTurn: @unchecked Sendable {
    let wavData: Data
    let duration: TimeInterval
}

enum ConversationContentPolicy {
    static let maximumTypedSourceUTF8Bytes = 8_000
    static let maximumFinalTextUTF8Bytes = 16_384
    static let maximumTurns = 500
    static let maximumSafetyEntities = 64
    static let maximumRenderedSafetyEntities = 24
    static let maximumSpeechSegments = 512
}

enum TurnTextPolicy {
    /// Keeps typed and edited turns bounded before translation, entity scanning,
    /// speech synthesis, or persistence. Final recognizer and translation
    /// output has a separate, larger boundary and is never truncated.
    static let maximumUTF8Bytes = ConversationContentPolicy.maximumTypedSourceUTF8Bytes
    static let maximumFinalUTF8Bytes = ConversationContentPolicy.maximumFinalTextUTF8Bytes

    static func validated(_ value: String) throws -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw PipelineError.noSpeech }
        guard cleaned.utf8.count <= maximumUTF8Bytes else {
            throw PipelineError.server("Typed text is too long. Keep it under \(maximumUTF8Bytes) UTF-8 bytes.")
        }
        return cleaned
    }

    static func validatedFinal(_ value: String, field: String) throws -> String {
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else {
            throw field == "speech" ? PipelineError.noSpeech : PipelineError.malformedResponse
        }
        guard cleaned.utf8.count <= maximumFinalUTF8Bytes else {
            throw PipelineError.server("The \(field) result is too long. Please split the turn and try again.")
        }
        return cleaned
    }

    static func isFinalTextWithinLimit(_ value: String) -> Bool {
        value.utf8.count <= maximumFinalUTF8Bytes
    }

    static func clamped(_ value: String) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        var result = String()
        result.reserveCapacity(min(value.count, maximumUTF8Bytes))
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= maximumUTF8Bytes else { break }
            result.append(character)
            bytes += count
        }
        return result
    }


    /// Presentation-only clamp for volatile speech results. Committed final
    /// text is validated and rejected rather than truncated.
    static func clampedPartial(_ value: String) -> String {
        clamp(value, maximumUTF8Bytes: maximumFinalUTF8Bytes)
    }

    private static func clamp(_ value: String, maximumUTF8Bytes: Int) -> String {
        guard value.utf8.count > maximumUTF8Bytes else { return value }
        var result = String()
        result.reserveCapacity(min(value.count, maximumUTF8Bytes))
        var bytes = 0
        for character in value {
            let count = String(character).utf8.count
            guard bytes + count <= maximumUTF8Bytes else { break }
            result.append(character)
            bytes += count
        }
        return result
    }
}

enum TranslationWarning: String, Codable, Hashable, Sendable {
    case uncertainRecognition
    case entityMismatch
    case unsupportedLanguage
    case serviceDegraded
}

enum LanguageReviewStatus: String, Codable, Equatable, Sendable {
    case confident
    case needsReview
    case corrected
}

struct AlternateTranscript: Codable, Equatable, Sendable {
    let locale: String
    let text: String
    let recognitionConfidence: Double?
}

struct PipelineResult: Sendable {
    var sourceText: String
    var translatedText: String
    var recognitionConfidence: Double? = nil
    var route: EngineRoute
    var warnings: Set<TranslationWarning>
}

enum CriticalEntityKind: String, Codable, CaseIterable, Equatable, Hashable, Sendable {
    case number, currency, unit, time, date, address, phone, properName, negation, allergy, medication, emergency

    var label: String {
        switch self {
        case .properName: "Name"
        default: rawValue.capitalized
        }
    }
}

struct CriticalEntity: Identifiable, Codable, Equatable, Hashable, Sendable {
    let id: UUID
    let kind: CriticalEntityKind
    let value: String
    let normalizedValue: String

    init(id: UUID = UUID(), kind: CriticalEntityKind, value: String, normalizedValue: String? = nil) {
        self.id = id
        self.kind = kind
        self.value = value
        self.normalizedValue = normalizedValue ?? value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
    }
}

struct ConversationTurn: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let sequence: Int
    let speaker: SpeakerSide
    let sourceLocale: String
    let targetLocale: String
    var sourceText: String
    var translatedText: String
    var userEdited: Bool
    let createdAt: Date
    let entities: [CriticalEntity]
    let route: EngineRoute
    let recognitionConfidence: Double?
    var warnings: Set<TranslationWarning>
    var languageReviewStatus: LanguageReviewStatus
    var alternateTranscript: AlternateTranscript?

    init(
        id: UUID,
        sequence: Int,
        speaker: SpeakerSide,
        sourceLocale: String,
        targetLocale: String,
        sourceText: String,
        translatedText: String,
        userEdited: Bool,
        createdAt: Date,
        entities: [CriticalEntity],
        route: EngineRoute,
        recognitionConfidence: Double?,
        warnings: Set<TranslationWarning> = [],
        languageReviewStatus: LanguageReviewStatus = .confident,
        alternateTranscript: AlternateTranscript? = nil
    ) {
        self.id = id
        self.sequence = sequence
        self.speaker = speaker
        self.sourceLocale = sourceLocale
        self.targetLocale = targetLocale
        self.sourceText = sourceText
        self.translatedText = translatedText
        self.userEdited = userEdited
        self.createdAt = createdAt
        self.entities = entities
        self.route = route
        self.recognitionConfidence = recognitionConfidence
        self.warnings = warnings
        self.languageReviewStatus = languageReviewStatus
        self.alternateTranscript = alternateTranscript
    }

    private enum CodingKeys: String, CodingKey {
        case id, sequence, speaker, sourceLocale, targetLocale, sourceText, translatedText, userEdited, createdAt, entities, route, recognitionConfidence
        case warnings, languageReviewStatus, alternateTranscript
    }

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        sequence = try values.decode(Int.self, forKey: .sequence)
        speaker = try values.decode(SpeakerSide.self, forKey: .speaker)
        sourceLocale = try values.decode(String.self, forKey: .sourceLocale)
        targetLocale = try values.decode(String.self, forKey: .targetLocale)
        sourceText = try values.decode(String.self, forKey: .sourceText)
        translatedText = try values.decode(String.self, forKey: .translatedText)
        userEdited = try values.decode(Bool.self, forKey: .userEdited)
        createdAt = try values.decode(Date.self, forKey: .createdAt)
        entities = try values.decode([CriticalEntity].self, forKey: .entities)
        route = try values.decodeIfPresent(EngineRoute.self, forKey: .route) ?? .local
        recognitionConfidence = try values.decodeIfPresent(Double.self, forKey: .recognitionConfidence)
        warnings = try values.decodeIfPresent(Set<TranslationWarning>.self, forKey: .warnings) ?? []
        languageReviewStatus = try values.decodeIfPresent(
            LanguageReviewStatus.self,
            forKey: .languageReviewStatus
        ) ?? .confident
        alternateTranscript = try values.decodeIfPresent(
            AlternateTranscript.self,
            forKey: .alternateTranscript
        )
    }
}

struct TurnContext: Identifiable, Equatable, Sendable {
    let id: UUID
    let speaker: SpeakerSide
    let pair: LanguagePair
    let route: EngineRoute
    let startedAt: Date
    let saveOnDevice: Bool
}

struct ConversationRecord: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var createdAt: Date
    var updatedAt: Date
    var languageA: String
    var languageB: String
    var title: String
    var turns: [ConversationTurn]
}

enum ComponentReadiness: String, Codable, Equatable, Sendable {
    case unknown
    case checking
    case downloading
    case ready
    case downloadRequired
    case unavailable
}

struct TripReadiness: Equatable, Sendable {
    var pair: LanguagePair?
    var generation: Int = 0
    var listenTraveler: ComponentReadiness = .unknown
    var listenLocal: ComponentReadiness = .unknown
    var listenPair: ComponentReadiness = .unknown
    var translateForward: ComponentReadiness = .unknown
    var translateReverse: ComponentReadiness = .unknown
    var speakTraveler: ComponentReadiness = .unknown
    var speakLocal: ComponentReadiness = .unknown
    var isReady: Bool { [listenTraveler, listenLocal, listenPair, translateForward, translateReverse, speakTraveler, speakLocal].allSatisfy { $0 == .ready } }
    func isManualReady(requiringVoices: Bool) -> Bool {
        let core = [listenTraveler, listenLocal, translateForward, translateReverse]
            .allSatisfy { $0 == .ready }
        return core && (!requiringVoices || (speakTraveler == .ready && speakLocal == .ready))
    }
    func isReady(requiringVoices: Bool) -> Bool {
        let core = [listenTraveler, listenLocal, listenPair, translateForward, translateReverse].allSatisfy { $0 == .ready }
        return core && (!requiringVoices || (speakTraveler == .ready && speakLocal == .ready))
    }
}

struct AppSettings: Codable, Equatable, Sendable {
    var pair = LanguagePair()
    var routing: RoutingPreference = .localOnly
    var layout: ConversationLayout = .heldPhone
    var continuousTranslationStrategy: OnDeviceTranslationStrategy = .lowLatency
    var saveHistoryOnDevice = false
    var acceptedOnlineDisclosureVersion: Int? = nil
    var autoSpeak = true
    var slowerSpeech = false

    var hasCurrentOnlineProcessingConsent: Bool {
        acceptedOnlineDisclosureVersion == OnlineProcessingDisclosure.currentVersion
    }

    mutating func acceptCurrentOnlineProcessingDisclosure() {
        acceptedOnlineDisclosureVersion = OnlineProcessingDisclosure.currentVersion
    }

    private enum CodingKeys: String, CodingKey {
        case pair, routing, layout, saveHistoryOnDevice
        case continuousTranslationStrategy
        case onlineProcessingConsentGranted, acceptedOnlineDisclosureVersion, autoSpeak, slowerSpeech
    }

    init() {}

    init(from decoder: any Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        pair = try values.decodeIfPresent(LanguagePair.self, forKey: .pair) ?? LanguagePair()
        routing = try values.decodeIfPresent(RoutingPreference.self, forKey: .routing) ?? .localOnly
        layout = try values.decodeIfPresent(ConversationLayout.self, forKey: .layout) ?? .heldPhone
        continuousTranslationStrategy = try values.decodeIfPresent(
            OnDeviceTranslationStrategy.self,
            forKey: .continuousTranslationStrategy
        ) ?? .lowLatency
        saveHistoryOnDevice = try values.decodeIfPresent(Bool.self, forKey: .saveHistoryOnDevice) ?? false
        if let version = try values.decodeIfPresent(Int.self, forKey: .acceptedOnlineDisclosureVersion) {
            acceptedOnlineDisclosureVersion = version
        } else if try values.decodeIfPresent(Bool.self, forKey: .onlineProcessingConsentGranted) == true {
            // Disclosure version 1 has the same data flow as the legacy Boolean.
            acceptedOnlineDisclosureVersion = 1
        } else {
            acceptedOnlineDisclosureVersion = nil
        }
        autoSpeak = try values.decodeIfPresent(Bool.self, forKey: .autoSpeak) ?? true
        slowerSpeech = try values.decodeIfPresent(Bool.self, forKey: .slowerSpeech) ?? false
    }

    func encode(to encoder: any Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(pair, forKey: .pair)
        try values.encode(routing, forKey: .routing)
        try values.encode(layout, forKey: .layout)
        try values.encode(continuousTranslationStrategy, forKey: .continuousTranslationStrategy)
        try values.encode(saveHistoryOnDevice, forKey: .saveHistoryOnDevice)
        try values.encodeIfPresent(acceptedOnlineDisclosureVersion, forKey: .acceptedOnlineDisclosureVersion)
        try values.encode(autoSpeak, forKey: .autoSpeak)
        try values.encode(slowerSpeech, forKey: .slowerSpeech)
    }
}

enum OnlineProcessingDisclosure {
    static let currentVersion = 1
}
