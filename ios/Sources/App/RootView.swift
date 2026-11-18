import AVFoundation
import SwiftUI
import Translation

struct RootView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var languagePacks: LanguagePackManager
    @ObservedObject private var onboarding: OnboardingStore
    @ObservedObject private var access: TranslationAccessManager
    @ObservedObject private var continuous: ContinuousConversationCoordinator
    private enum TalkDestination: Hashable { case manual }
    @State private var talkPath: [TalkDestination] = []
    @State private var showSignup = false
    @AppStorage("SpeakDuet.HasOfferedAccount.v1") private var hasOfferedAccount = false

    init(container: AppContainer) {
        _container = ObservedObject(wrappedValue: container)
        _settings = ObservedObject(wrappedValue: container.settings)
        _languagePacks = ObservedObject(wrappedValue: container.languagePacks)
        _onboarding = ObservedObject(wrappedValue: container.onboarding)
        _access = ObservedObject(wrappedValue: container.access)
        _continuous = ObservedObject(wrappedValue: container.continuousConversation)
    }

    var body: some View {
        Group {
            if onboarding.isComplete {
                supportedApp
            } else {
                OnboardingFlowView(onboarding: onboarding, settings: container.settings,
                                   languagePacks: languagePacks, access: access) { talkPath = [.manual] }
            }
        }
        .translationTask(languagePacks.translationDownloadConfiguration) { session in
            await languagePacks.prepareTranslation(using: session)
        }
        .sheet(isPresented: $access.requestsPaywall) {
            SpeakDuetSubscriptionView(subscription: container.subscription, access: access)
        }
        .sheet(isPresented: $showSignup) {
            NavigationStack {
                AccountView(authentication: container.authentication, history: container.history, settings: container.settings)
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Continue as guest") { showSignup = false } } }
            }
        }
        .preferredColorScheme(settings.value.appearance.colorScheme)
        .onChange(of: settings.value.continuousTranslationStrategy) { _, _ in
            Task { await languagePacks.check(settings.value.pair) }
        }
        .onChange(of: continuous.state) { _, state in
            if state == .ended, !continuous.turns.isEmpty,
               !hasOfferedAccount, container.authentication.isConfigured,
               container.authentication.user == nil {
                hasOfferedAccount = true
                showSignup = true
            }
        }
    }

    private var supportedApp: some View {
        TabView {
            NavigationStack(path: $talkPath) {
                ContinuousConversationView(
                    coordinator: container.continuousConversation,
                    settings: container.settings,
                    subscription: container.subscription,
                    network: container.network,
                    languagePacks: container.languagePacks,
                    conversation: container.conversation,
                    capabilities: container.capabilities
                )
                .navigationDestination(for: TalkDestination.self) { _ in
                    ConversationView(orchestrator: container.conversation, settings: container.settings,
                                     capabilities: container.capabilities)
                }

            }
            .tabItem { Label("Talk", systemImage: "mic.fill") }

            NavigationStack { HistoryView(store: container.history, settings: container.settings) }
                .tabItem { Label("History", systemImage: "clock") }

            NavigationStack {
                SettingsView(
                    settings: container.settings,
                    subscription: container.subscription,
                    access: access,
                    authentication: container.authentication,
                    history: container.history,
                    languagePacks: container.languagePacks,
                    onlineClient: container.onlineClient,
                    capabilities: container.capabilities
                )
            }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(TranslatorTheme.accent)
        .onReceive(
            NotificationCenter.default.publisher(
                for: AVSpeechSynthesizer.availableVoicesDidChangeNotification
            )
        ) { _ in
            Task {
                container.languagePacks.invalidateCatalog()
                await container.languagePacks.check(container.settings.value.pair)
            }
        }
    }

}
