import Combine
import Foundation

@MainActor
final class SettingsStore: ObservableObject {
    @Published var value: AppSettings {
        didSet {
            let canonical = normalized(value)
            if canonical != value { value = canonical }
            save()
        }
    }
    private let defaults: UserDefaults
    private let capabilities: AppCapabilities
    private let availableLanguages: [AppLanguage]
    private let key = "LocalLingo.AppSettings.v1"

    init(
        defaults: UserDefaults = .standard,
        capabilities: AppCapabilities = .allDisabled,
        availableLanguages: [AppLanguage] = AppLanguage.conversationLanguages
    ) {
        self.defaults = defaults
        self.capabilities = capabilities
        self.availableLanguages = availableLanguages
        let saved = defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) }
        value = Self.normalized(
            saved ?? AppSettings(),
            capabilities: capabilities,
            availableLanguages: availableLanguages
        )
        // Re-encode immediately so removed sync keys and the legacy consent
        // Boolean cannot survive indefinitely in the canonical settings blob.
        save()
    }

    private func normalized(_ settings: AppSettings) -> AppSettings {
        Self.normalized(
            settings,
            capabilities: capabilities,
            availableLanguages: availableLanguages
        )
    }

    private static func normalized(
        _ settings: AppSettings,
        capabilities: AppCapabilities,
        availableLanguages: [AppLanguage]
    ) -> AppSettings {
        var result = settings
        if !LocalConversationLanguagePolicy.supports(
            result.pair,
            availableLanguages: availableLanguages
        ) {
            result.pair = LanguagePair()
        }
        result.routing = OnlineLanguagePolicy.normalizedRouting(
            result.routing,
            for: result.pair
        )
        if !capabilities.onlineFeaturesEnabled { result.routing = .localOnly }
        if !capabilities.faceToFaceEnabled { result.layout = .heldPhone }
        return result
    }

    private func save() { if let data = try? JSONEncoder().encode(value) { defaults.set(data, forKey: key) } }
}
