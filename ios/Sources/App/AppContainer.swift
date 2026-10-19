import Combine
import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let capabilities: AppCapabilities
    let settings: SettingsStore
    let buildIdentity: AppBuildIdentity?
    let subscription: SubscriptionManager
    let network: NetworkStatus
    let history: HistoryStore
    let onlineClient: any OnlineTranslationClient
    let languagePacks: LanguagePackManager
    let conversation: ConversationOrchestrator
    let continuousConversation: ContinuousConversationCoordinator

    init() {
        let capabilities = AppCapabilities()
        buildIdentity = AppBuildIdentity(bundle: .main)
        let settings = SettingsStore(capabilities: capabilities)
        let subscription = SubscriptionManager(isEnabled: capabilities.onlineFeaturesEnabled)
        let network = NetworkStatus()
        let history = HistoryStore()
        let speech = AppleSpeechRecognitionEngine()
        let translation = AppleTranslationEngine()
        let synthesis = AppleSpeechSynthesisEngine()
        let local = LocalConversationPipeline(recognition: speech, translation: translation)
        let playback = PlaybackService(synthesis: synthesis)
        let client = OnlineTranslationClientFactory.make(
            capabilities: capabilities,
            bundle: .main,
            expectedBuildIdentity: buildIdentity
        )
        let online = OnlineConversationPipeline(client: client) { subscription.entitlementJWS }

        self.capabilities = capabilities
        self.settings = settings; self.subscription = subscription; self.network = network; self.history = history; onlineClient = client
        languagePacks = LanguagePackManager(
            speech: speech,
            translation: translation,
            synthesis: synthesis
        )
        conversation = ConversationOrchestrator(
            audio: AudioCaptureService(),
            local: local,
            online: online,
            playback: playback,
            settings: settings,
            network: network,
            subscription: subscription,
            history: history,
            onlineFeaturesEnabled: capabilities.onlineFeaturesEnabled
        )
        continuousConversation = ContinuousConversationCoordinator(
            capture: MicrophoneCaptureSession(),
            voiceActivity: SileroVoiceActivityDetector(),
            recognition: AppleContinuousSpeechRecognizer(),
            translation: ContinuousBidirectionalTranslationEngine(),
            playback: PlaybackService(synthesis: AppleSpeechSynthesisEngine()),
            settings: settings,
            history: history
        )
    }
}

@MainActor
enum OnlineTranslationClientFactory {
    static func make(
        capabilities: AppCapabilities,
        bundle: Bundle,
        expectedBuildIdentity: AppBuildIdentity?
    ) -> any OnlineTranslationClient {
        guard capabilities.onlineFeaturesEnabled else {
            return UnavailableOnlineTranslationClient()
        }
        guard let baseURLString = bundle.object(forInfoDictionaryKey: "API_BASE_URL") as? String,
              let baseURL = URL(string: baseURLString) else {
            preconditionFailure("API_BASE_URL is not a valid URL.")
        }
        return GoogleConversationClient(
            baseURL: baseURL,
            expectedBuildIdentity: expectedBuildIdentity
        )
    }
}
