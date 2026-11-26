import AVFoundation
import SwiftUI
import Translation

enum TalkDestination: Hashable { case manual, languagePacks, settings }

struct AppNavigation {
    enum Tab { case talk, split, history }

    var selection: Tab = .split
    var talkPath: [TalkDestination] = []
    var splitPath: [TalkDestination] = []

    var showsConversation: Bool {
        switch selection {
        case .talk: talkPath.isEmpty
        case .split: splitPath.isEmpty
        case .history: false
        }
    }
}

struct RootView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject private var settings: SettingsStore
    @ObservedObject private var languagePacks: LanguagePackManager
    @ObservedObject private var onboarding: OnboardingStore
    @ObservedObject private var access: TranslationAccessManager
    @ObservedObject private var continuous: ContinuousConversationCoordinator
    @Environment(\.scenePhase) private var scenePhase
    @State private var navigation = AppNavigation()
    @State private var confirmedSetupNeeded = false
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
                                   languagePacks: languagePacks, access: access) { navigation.splitPath = [.manual] }
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
        .onChange(of: onboarding.isComplete && navigation.showsConversation && scenePhase == .active, initial: true) { _, active in
            continuous.handleSceneActivity(isActive: active)
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
        TabView(selection: $navigation.selection) {
            Tab(ConversationLayout.heldPhone.title, systemImage: "mic.fill", value: AppNavigation.Tab.talk) {
                talkStack(layout: .heldPhone, path: $navigation.talkPath)
            }
            Tab(ConversationLayout.faceToFace.title, systemImage: "rectangle.split.1x2", value: AppNavigation.Tab.split) {
                talkStack(layout: .faceToFace, path: $navigation.splitPath)
            }
            Tab("History", systemImage: "clock", value: AppNavigation.Tab.history) {
                NavigationStack {
                    HistoryView(store: container.history, settings: settings)
                        .toolbar {
                            ToolbarItem(placement: .topBarTrailing) {
                                Menu {
                                    NavigationLink(value: TalkDestination.settings) {
                                        Label("Settings", systemImage: "gearshape")
                                    }
                                } label: {
                                    Image(systemName: "ellipsis.circle")
                                }
                                .accessibilityLabel("More options")
                            }
                        }
                        .navigationDestination(for: TalkDestination.self, destination: destination)
                }
            }
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

    private func talkStack(layout: ConversationLayout, path: Binding<[TalkDestination]>) -> some View {
        NavigationStack(path: path) {
            ContinuousConversationView(
                coordinator: continuous, settings: settings, subscription: container.subscription,
                network: container.network, languagePacks: languagePacks, capabilities: container.capabilities,
                layout: layout, confirmedSetupNeeded: $confirmedSetupNeeded
            )
            .navigationDestination(for: TalkDestination.self, destination: destination)
        }
    }

    @ViewBuilder
    private func destination(_ route: TalkDestination) -> some View {
        switch route {
        case .manual:
            ConversationView(orchestrator: container.conversation, settings: settings, capabilities: container.capabilities)
        case .languagePacks:
            LanguagePacksView(manager: languagePacks, settings: settings)
        case .settings:
            SettingsView(
                settings: settings, subscription: container.subscription, access: access,
                authentication: container.authentication, history: container.history, languagePacks: languagePacks,
                onlineClient: container.onlineClient, capabilities: container.capabilities
            )
        }
    }

}
