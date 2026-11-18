import Combine
import Foundation

@MainActor
final class AppContainer: ObservableObject {
    let capabilities: AppCapabilities
    let settings: SettingsStore
    let buildIdentity: AppBuildIdentity?
    let subscription: SubscriptionManager
    let access: TranslationAccessManager
    let onboarding: OnboardingStore
    let authentication: AuthenticationManager
    let network: NetworkStatus
    let history: HistoryStore
    let onlineClient: any OnlineTranslationClient
    let languagePacks: LanguagePackManager
    let conversation: ConversationOrchestrator
    let continuousConversation: ContinuousConversationCoordinator

    init() {
        let capabilities = AppCapabilities()
        buildIdentity = AppBuildIdentity(bundle: .main)
        let defaults: UserDefaults
        let freeAccessStorage: any FreeAccessStorage
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("SpeakDuet.UITests") {
            defaults = UserDefaults(suiteName: "SpeakDuet.UITests")!
            defaults.removePersistentDomain(forName: "SpeakDuet.UITests")
            freeAccessStorage = UITestFreeAccessStorage()
        } else {
            defaults = .standard
            freeAccessStorage = KeychainFreeAccessStorage()
        }
#else
        defaults = .standard
        freeAccessStorage = KeychainFreeAccessStorage()
#endif
        let settings = SettingsStore(defaults: defaults, capabilities: capabilities)
        let subscription = SubscriptionManager(isEnabled: capabilities.subscriptionsEnabled)
        let access = TranslationAccessManager(subscription: subscription, isRequired: capabilities.translationAccessRequired, storage: freeAccessStorage)
        self.access = access
        onboarding = OnboardingStore(defaults: defaults)
        authentication = AuthenticationManager(isEnabled: capabilities.accountsEnabled)
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
        var packSpeech: any SpeechAssetManaging = speech
        var packTranslation: any TranslationEngine = translation
#if DEBUG
        if ProcessInfo.processInfo.arguments.contains("SpeakDuet.UITests") {
            let assets = UITestLanguageAssets()
            packSpeech = assets
            packTranslation = assets
        }
#endif
        languagePacks = LanguagePackManager(
            speech: packSpeech,
            translation: packTranslation,
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
            access: access,
            onlineFeaturesEnabled: capabilities.onlineFeaturesEnabled
        )
        continuousConversation = ContinuousConversationCoordinator(
            capture: MicrophoneCaptureSession(),
            voiceActivity: SileroVoiceActivityDetector(),
            recognition: AppleContinuousSpeechRecognizer(),
            translation: ContinuousBidirectionalTranslationEngine(),
            playback: PlaybackService(synthesis: AppleSpeechSynthesisEngine()),
            settings: settings,
            history: history,
            access: access
        )
    }
}

#if DEBUG
@MainActor
private final class UITestLanguageAssets: SpeechAssetManaging, TranslationEngine {
    private var locales: [Locale] = ProcessInfo.processInfo.arguments.contains("SpeakDuet.UITests.needsDownload")
        ? [] : AppLanguage.conversationLanguages.map(\.locale)

    func inventorySnapshot() async -> SpeechAssetInventorySnapshot {
        .init(maximumReservedLocales: 32, reservedLocales: locales)
    }

    func assetReadiness(locale: Locale) async -> ComponentReadiness {
        locales.contains(locale) ? .ready : .downloadRequired
    }

    func continuousAssetReadiness(pair: LanguagePair) async -> ComponentReadiness {
        ProcessInfo.processInfo.arguments.contains("SpeakDuet.UITests.manualOnly") ? .unavailable : .ready
    }

    func reserveAssets(locale: Locale) async throws { locales.append(locale) }
    func releaseAssets(reservedLocale: Locale) async -> Bool {
        locales.removeAll { $0 == reservedLocale }
        return true
    }

    func installAssets(locale: Locale, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        if !locales.contains(locale) { locales.append(locale) }
        onProgress(1)
    }

    func installContinuousAssets(pair: LanguagePair, onProgress: @escaping @MainActor (Double) -> Void) async throws {
        onProgress(1)
    }

    func availability(source: Locale.Language, target: Locale.Language) async -> ComponentReadiness { .ready }
    func prepare(source: Locale.Language, target: Locale.Language) async throws {}
    func translate(_ text: String, source: Locale.Language, target: Locale.Language) async throws -> String {
        throw PipelineError.noSpeech
    }
    func cancel() {}
}

// Isolated UI-test state; this type and launch argument have no release path.
private final class UITestFreeAccessStorage: FreeAccessStorage {
    private var data: Data?
    func read() throws -> Data? { data }
    func write(_ data: Data) throws { self.data = data }
}
#endif

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
