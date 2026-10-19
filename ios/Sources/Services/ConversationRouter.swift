import Combine
import Foundation
import Network

@MainActor
final class NetworkStatus: ObservableObject {
    @Published private(set) var isOnline = false
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "LocalLingo.NetworkStatus")

    init() {
        monitor.pathUpdateHandler = { [weak self] path in
            Task { @MainActor in self?.isOnline = path.status == .satisfied }
        }
        monitor.start(queue: queue)
    }
    deinit { monitor.cancel() }
}

struct RouteDecision: Equatable, Sendable {
    let route: EngineRoute
    let disclosure: String
}

enum OnlineLanguagePolicy {
    private static let supportedLanguages: Set<AppLanguage> = [
        .englishUS,
        .spanishSpain,
        .japaneseJapan
    ]
    private static let localOnlyLanguages: Set<AppLanguage> = [
        .hindiIndia
    ]

    static func supports(_ pair: LanguagePair) -> Bool {
        pair.traveler != pair.local
            && !localOnlyLanguages.contains(pair.traveler)
            && !localOnlyLanguages.contains(pair.local)
            && supportedLanguages.contains(pair.traveler)
            && supportedLanguages.contains(pair.local)
    }

    static func normalizedRouting(
        _ preference: RoutingPreference,
        for pair: LanguagePair
    ) -> RoutingPreference {
        guard preference == .localOnly || supports(pair) else {
            return .localOnly
        }
        return preference
    }
}

struct ConversationRouter: Sendable {
    let onlineFeaturesEnabled: Bool

    init(onlineFeaturesEnabled: Bool = false) {
        self.onlineFeaturesEnabled = onlineFeaturesEnabled
    }

    func decide(
        preference: RoutingPreference,
        pair: LanguagePair,
        hasPro: Bool,
        isOnline: Bool
    ) throws -> RouteDecision {
        guard onlineFeaturesEnabled else {
            return RouteDecision(
                route: .local,
                disclosure: "Conversation processing and optional Local history stay on this device."
            )
        }
        switch preference {
        case .localOnly:
            // Hard privacy boundary: this branch cannot produce an online route.
            return RouteDecision(route: .local, disclosure: "Conversation processing and optional Local history stay on this device.")
        case .onlineQuality:
            guard OnlineLanguagePolicy.supports(pair), hasPro, isOnline else {
                throw PipelineError.onlineUnavailable
            }
            return RouteDecision(route: .online, disclosure: "Audio and text for each turn are sent to Google Cloud for processing.")
        case .automatic:
            if OnlineLanguagePolicy.supports(pair), hasPro, isOnline {
                return RouteDecision(route: .online, disclosure: "Auto selected Online Quality. This turn is sent to Google Cloud.")
            }
            if !OnlineLanguagePolicy.supports(pair) {
                return RouteDecision(
                    route: .local,
                    disclosure: "Auto selected on-device processing because Online Quality does not support this language pair."
                )
            }
            return RouteDecision(route: .local, disclosure: "Auto selected on-device processing. Optional history stays on this iPhone.")
        }
    }
}
