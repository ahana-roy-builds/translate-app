import Foundation

struct SpeechAssetInventorySnapshot: Equatable, Sendable {
    var maximumReservedLocales: Int
    var reservedLocales: [Locale]

    static let empty = SpeechAssetInventorySnapshot(
        maximumReservedLocales: 0,
        reservedLocales: []
    )

    var reservedCount: Int { reservedLocales.count }

    func reservedLocale(matching language: AppLanguage) -> Locale? {
        guard let expected = language.locale.language.languageCode?.identifier else {
            return nil
        }
        return reservedLocales.first {
            $0.language.languageCode?.identifier.caseInsensitiveCompare(expected) == .orderedSame
        }
    }

    func contains(_ language: AppLanguage) -> Bool {
        reservedLocale(matching: language) != nil
    }
}

enum LanguagePackOperationTarget: Equatable, Sendable {
    case pair(LanguagePair)
    case language(AppLanguage)

    func contains(_ language: AppLanguage) -> Bool {
        switch self {
        case let .pair(pair):
            pair.traveler == language || pair.local == language
        case let .language(activeLanguage):
            activeLanguage == language
        }
    }
}

struct LanguageAssetState: Identifiable, Equatable, Sendable {
    let language: AppLanguage
    var listenReadiness: ComponentReadiness
    var listenReserved: Bool
    var speakReadiness: ComponentReadiness
    var lastUsedAt: Date?
    var errorMessage: String?

    var id: AppLanguage { language }

    init(
        language: AppLanguage,
        listenReadiness: ComponentReadiness = .unknown,
        listenReserved: Bool = false,
        speakReadiness: ComponentReadiness = .unknown,
        lastUsedAt: Date? = nil,
        errorMessage: String? = nil
    ) {
        self.language = language
        self.listenReadiness = listenReadiness
        self.listenReserved = listenReserved
        self.speakReadiness = speakReadiness
        self.lastUsedAt = lastUsedAt
        self.errorMessage = errorMessage
    }

    var isListenReady: Bool {
        listenReserved && listenReadiness == .ready
    }
}
