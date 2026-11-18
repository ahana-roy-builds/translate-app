import SwiftUI

@main
struct LocalLingoApp: App {
    @StateObject private var container = AppContainer()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ZStack {
                RootView(container: container)
                    .onOpenURL { _ = container.authentication.handleURL($0) }
                if scenePhase != .active { PrivacyCover().transition(.opacity) }
                PrivacyShieldHost(isPresented: scenePhase != .active).frame(width: 0, height: 0)
            }
            .onChange(of: scenePhase) { _, phase in
                let isActive = phase == .active
                container.conversation.handleSceneActivity(isActive: isActive)
                container.continuousConversation.handleSceneActivity(isActive: isActive)
                if isActive {
                    container.access.refresh()
                    Task {
                        await container.languagePacks.check(container.settings.value.pair)
                        await container.languagePacks.refreshAll()
                    }
                }
                if isActive, container.capabilities.subscriptionsEnabled {
                    Task { await container.subscription.refresh() }
                }
            }
        }
    }
}

struct PrivacyCover: View {
    var body: some View {
        ZStack {
            Color(.systemBackground).ignoresSafeArea()
            VStack(spacing: 12) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 44))
                    .foregroundStyle(TranslatorTheme.accent)
                Text("Speak Duet").font(.title2.bold())
                Text("Conversation hidden for privacy").font(.caption).foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
