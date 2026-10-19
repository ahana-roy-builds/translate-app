import AVFoundation
import SwiftUI
import Translation

struct RootView: View {
    @ObservedObject var container: AppContainer
    @ObservedObject private var languagePacks: LanguagePackManager

    init(container: AppContainer) {
        _container = ObservedObject(wrappedValue: container)
        _languagePacks = ObservedObject(wrappedValue: container.languagePacks)
    }

    var body: some View {
        supportedApp
    }

    private var supportedApp: some View {
        TabView {
            NavigationStack {
                ContinuousConversationView(
                    coordinator: container.continuousConversation,
                    settings: container.settings,
                    subscription: container.subscription,
                    network: container.network,
                    languagePacks: container.languagePacks,
                    conversation: container.conversation,
                    capabilities: container.capabilities
                )
            }
            .tabItem { Label("Talk", systemImage: "mic.fill") }

            NavigationStack { HistoryView(store: container.history, settings: container.settings) }
                .tabItem { Label("History", systemImage: "clock") }

            NavigationStack {
                SettingsView(
                    settings: container.settings,
                    subscription: container.subscription,
                    history: container.history,
                    languagePacks: container.languagePacks,
                    onlineClient: container.onlineClient,
                    capabilities: container.capabilities
                )
            }
                .tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .tint(TranslatorTheme.accent)
        .translationTask(languagePacks.translationDownloadConfiguration) { session in
            await languagePacks.prepareTranslation(using: session)
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: AVSpeechSynthesizer.availableVoicesDidChangeNotification
            )
        ) { _ in
            Task {
                await container.languagePacks.check(container.settings.value.pair)
                await container.languagePacks.refreshAll()
            }
        }
    }

}
