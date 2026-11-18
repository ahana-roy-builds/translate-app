import Combine
import Foundation

@MainActor
final class OnboardingStore: ObservableObject {
    static let currentVersion = 1
    private let defaults: UserDefaults
    private let key = "SpeakDuet.Onboarding.v1"

    struct Progress: Codable, Equatable {
        var completedVersion = 0
        var step = 0
        var defaultLanguage: AppLanguage?
        var partnerLanguage: AppLanguage?
    }

    @Published var progress: Progress { didSet { persist() } }
    var isComplete: Bool { progress.completedVersion >= Self.currentVersion }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        progress = defaults.data(forKey: key)
            .flatMap { try? JSONDecoder().decode(Progress.self, from: $0) } ?? Progress()
        progress.step = min(max(progress.step, 0), 3)
    }

    func complete(settings: SettingsStore) -> Bool {
        guard let language = progress.defaultLanguage,
              let partner = progress.partnerLanguage,
              AppLanguage.conversationLanguages.contains(language),
              LocalConversationLanguagePolicy.supports(LanguagePair(traveler: language, local: partner)) else {
            return false
        }
        settings.value.defaultLanguage = language
        settings.value.pair = LanguagePair(traveler: language, local: partner)
        progress.completedVersion = Self.currentVersion
        return true
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(progress) { defaults.set(data, forKey: key) }
    }
}
