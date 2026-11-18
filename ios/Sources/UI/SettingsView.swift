import StoreKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var settings: SettingsStore
    @ObservedObject var subscription: SubscriptionManager
    @ObservedObject var access: TranslationAccessManager
    @ObservedObject var authentication: AuthenticationManager
    @ObservedObject var history: HistoryStore
    @ObservedObject var languagePacks: LanguagePackManager
    let onlineClient: any OnlineTranslationClient
    let capabilities: AppCapabilities
    @State private var showPaywall = false
    @State private var confirmDeleteAll = false
    @State private var showOnlineConsent = false
    @State private var pendingRoute: RoutingPreference?
    @State private var showManageSubscriptions = false
    @State private var confirmRemoveDevice = false
    @State private var confirmReplaceOldestDevice = false
    @State private var isRemovingDevice = false
    @State private var isReplacingDevice = false
    @State private var deviceMessage: String?

    var body: some View {
        Form {
            Section("Conversation") {
                Picker("Default language", selection: $settings.value.defaultLanguage) {
                    ForEach(AppLanguage.conversationLanguages) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("Your default language is saved separately from the current conversation pair.")
                    .font(.caption).foregroundStyle(.secondary)
                if !capabilities.onlineFeaturesEnabled {
                    Label(
                        "Conversation audio and text stay on this device. Local history is never uploaded.",
                        systemImage: "lock.shield.fill"
                    )
                    .font(.caption)
                    .foregroundStyle(TranslatorTheme.accent)
                } else {
                    Picker("Default route", selection: routingBinding) {
                        ForEach(RoutingPreference.allCases) { preference in
                            Text(preference.title)
                                .tag(preference)
                                .disabled(
                                    preference != .localOnly
                                        && !OnlineLanguagePolicy.supports(
                                            settings.value.pair
                                        )
                                )
                        }
                    }
                    if settings.value.routing == .localOnly {
                        Label(
                            "Conversation audio and text stay on this device. Local history is never uploaded.",
                            systemImage: "lock.shield.fill"
                        )
                        .font(.caption)
                        .foregroundStyle(TranslatorTheme.accent)
                    } else {
                        Label("Online turns send audio and text to Google Cloud for recognition and translation. Speech playback remains on-device.", systemImage: "network").font(.caption).foregroundStyle(.orange)
                        if !settings.value.hasCurrentOnlineProcessingConsent {
                            Button("Review updated Online Quality disclosure") {
                                pendingRoute = settings.value.routing
                                showOnlineConsent = true
                            }
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Continuous translation")
                    Picker(
                        "Continuous translation quality",
                        selection: continuousTranslationStrategyBinding
                    ) {
                        ForEach(OnDeviceTranslationStrategy.allCases) { strategy in
                            Text(strategy.title).tag(strategy)
                        }
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .accessibilityIdentifier("settings.continuousTranslationStrategy")
                    Text(continuousTranslationStrategyDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Speak automatically", isOn: boolBinding(\.autoSpeak))
                Toggle("Slower speech", isOn: boolBinding(\.slowerSpeech))
            }

            Section("Offline Languages") {
                NavigationLink {
                    LanguagePacksView(
                        manager: languagePacks,
                        settings: settings
                    )
                } label: {
                    Label {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Language Packs")
                            Text(selectedPackStatus)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    } icon: {
                        Image(systemName: "arrow.down.circle")
                            .foregroundStyle(TranslatorTheme.accent)
                    }
                }
                .accessibilityIdentifier("settings.languagePacks")
                Text("Download and verify the selected pair. Listen reservations for inactive languages can also be released here.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Private History") {
                Toggle("Save history on this iPhone", isOn: boolBinding(\.saveHistoryOnDevice))
                    .onChange(of: settings.value.saveHistoryOnDevice) { _, _ in reloadHistory() }
                Text("Text history uses iOS Data Protection, stays on this iPhone, and is excluded from device backups. Raw audio is never saved.").font(.caption).foregroundStyle(.secondary)
                Button("Delete all history", role: .destructive) { confirmDeleteAll = true }
                if let error = history.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            }

            if capabilities.subscriptionsEnabled {
                Section("Speak Duet subscription") {
                    Text(access.state.message).font(.footnote)
                    if subscription.hasPro {
                        Label("Subscription active", systemImage: "checkmark.seal.fill")
                            .foregroundStyle(TranslatorTheme.accent)
                    } else {
                        Button("View subscription") { showPaywall = true }
                    }
                    Button("Restore purchases") { Task { await subscription.restore() } }
                        .disabled(subscription.loadingState != .idle)
                    Button("Manage subscription") { showManageSubscriptions = true }
                    if subscription.hasPro && capabilities.onlineFeaturesEnabled {
                        Button("Remove this iPhone from Pro devices", role: .destructive) { confirmRemoveDevice = true }
                            .disabled(isRemovingDevice || isReplacingDevice)
                        Text("This frees a subscription device slot. Using Online Quality again will add this iPhone back.")
                            .font(.caption).foregroundStyle(.secondary)
                        Button("Replace least-recently-used Pro device", role: .destructive) { confirmReplaceOldestDevice = true }
                            .disabled(isRemovingDevice || isReplacingDevice)
                        Text("Use this only when this iPhone is blocked by the Pro device limit and you can no longer remove an older installation directly.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if let deviceMessage { Text(deviceMessage).font(.caption).foregroundStyle(.secondary) }
                    if let error = subscription.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
                }
            }

            Section("Privacy & Support") {
                if capabilities.accountsEnabled {
                    NavigationLink("Account") {
                        AccountView(authentication: authentication, history: history, settings: settings)
                    }
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text("Audio").font(.subheadline)
                    Text(capabilities.onlineFeaturesEnabled ? "Never saved; Online audio is transiently processed by Google" : "Never saved; processed on this iPhone")
                        .font(.caption).foregroundStyle(.secondary)
                }
                LabeledContent("Analytics content", value: "Never logged")
                Text(capabilities.onlineFeaturesEnabled
                     ? "Local Only is a hard network boundary for conversation content. Language downloads and App Store features may use Apple services. Saved text history never leaves this iPhone."
                     : "Conversation content stays on this iPhone. Language downloads may use Apple services. Saved text history never leaves this iPhone.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Translations can be wrong. Speak Duet is not an emergency, medical, or professional-interpreter service. For urgent situations, contact local emergency services or a qualified interpreter.")
                    .font(.caption).foregroundStyle(.secondary)
                legalLinks
            }
        }
        .navigationTitle("Settings")
        .tint(TranslatorTheme.accent)
        .task { await languagePacks.refreshAll() }
        .sheet(isPresented: $showPaywall) { SpeakDuetSubscriptionView(subscription: subscription, access: access) }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .alert("Delete all history?", isPresented: $confirmDeleteAll) {
            Button("Delete all", role: .destructive) { Task { await history.deleteAll() } }
            Button("Cancel", role: .cancel) {}
        } message: { Text("This permanently removes all Speak Duet text history from this iPhone.") }
        .alert("Use Online Quality?", isPresented: $showOnlineConsent) {
            Button("Continue") {
                settings.value.acceptCurrentOnlineProcessingDisclosure()
                settings.value.routing = OnlineLanguagePolicy.normalizedRouting(
                    pendingRoute ?? .automatic,
                    for: settings.value.pair
                )
                pendingRoute = nil
            }
            Button("Cancel", role: .cancel) { pendingRoute = nil }
        } message: {
            Text("Online turns send recorded audio and text to Google Cloud for transient recognition and translation. Playback remains on this iPhone.")
        }
        .alert("Remove this iPhone?", isPresented: $confirmRemoveDevice) {
            Button("Remove device", role: .destructive) { Task { await removeCurrentDevice() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("The backend will remove this installation from the subscription’s active-device list and invalidate its Online session.")
        }
        .alert("Replace the least-recently-used device?", isPresented: $confirmReplaceOldestDevice) {
            Button("Replace device", role: .destructive) { Task { await replaceOldestDevice() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes the subscription’s least-recently-used installation, adds this iPhone, and may immediately stop Online Quality on that older device.")
        }
    }

    private var routingBinding: Binding<RoutingPreference> {
        Binding(get: { settings.value.routing }, set: { newValue in
            let normalized = OnlineLanguagePolicy.normalizedRouting(
                newValue,
                for: settings.value.pair
            )
            if normalized != newValue {
                pendingRoute = nil
                settings.value.routing = normalized
            } else if newValue == .onlineQuality && !subscription.hasPro {
                showPaywall = true
                settings.value.routing = .localOnly
            } else if newValue != .localOnly
                && !settings.value.hasCurrentOnlineProcessingConsent {
                pendingRoute = newValue
                showOnlineConsent = true
            } else {
                settings.value.routing = newValue
            }
        })
    }

    private func boolBinding(_ keyPath: WritableKeyPath<AppSettings, Bool>) -> Binding<Bool> {
        Binding(get: { settings.value[keyPath: keyPath] }, set: { settings.value[keyPath: keyPath] = $0 })
    }

    private var continuousTranslationStrategyBinding: Binding<OnDeviceTranslationStrategy> {
        Binding(
            get: { settings.value.continuousTranslationStrategy },
            set: { settings.value.continuousTranslationStrategy = $0 }
        )
    }

    private var continuousTranslationStrategyDescription: String {
        switch settings.value.continuousTranslationStrategy {
        case .lowLatency:
            "Prioritizes faster responses. The selection applies when the next conversation starts."
        case .highFidelity:
            "Prefers Apple's higher-quality model when supported; iOS may fall back to Low Latency. The selection applies when the next conversation starts."
        }
    }

    private var selectedPackStatus: String {
        let pair = settings.value.pair
        let readiness = languagePacks.readiness
        let core = [
            readiness.listenTraveler,
            readiness.listenLocal,
            readiness.listenPair,
            readiness.translateForward,
            readiness.translateReverse,
        ]
        let status: String
        if languagePacks.isWorking
            && languagePacks.activeOperation == .pair(pair) {
            status = "Preparing"
        } else if readiness.pair != pair {
            status = "Checking availability"
        } else if readiness.isReady(
            requiringVoices: settings.value.autoSpeak
        ) {
            status = "Ready on this iPhone"
        } else if settings.value.autoSpeak,
                  readiness.isReady(requiringVoices: false) {
            status = "Text ready; Speak voices needed"
        } else if readiness.listenPair == .unavailable,
                  readiness.isManualReady(
                    requiringVoices: settings.value.autoSpeak
                  ) {
            status = "Manual ready; continuous unavailable"
        } else if readiness.listenPair == .unavailable,
                  settings.value.autoSpeak,
                  readiness.isManualReady(requiringVoices: false) {
            status = "Manual needs Speak voices or Auto Speak off"
        } else if core.contains(.unavailable) {
            status = "Unavailable"
        } else if core.contains(.unknown) || core.contains(.checking) {
            status = "Checking availability"
        } else {
            status = "Download required"
        }
        return "\(pair.traveler.displayName) ↔ \(pair.local.displayName) - \(status)"
    }

    private func reloadHistory() {
        Task { await history.load(enabled: settings.value.saveHistoryOnDevice) }
    }

    @ViewBuilder private var legalLinks: some View {
        if let url = bundleURL("PRIVACY_POLICY_URL") { Link("Privacy Policy", destination: url) }
        if let url = bundleURL("TERMS_URL") { Link("Terms / EULA", destination: url) }
        if let url = bundleURL("SUPPORT_URL") { Link("Support", destination: url) }
    }

    private func bundleURL(_ key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value), url.scheme == "https" else { return nil }
        return url
    }

    private func removeCurrentDevice() async {
        guard let signedTransaction = subscription.entitlementJWS else {
            deviceMessage = "Refresh or restore the subscription before removing this device."
            return
        }
        isRemovingDevice = true
        defer { isRemovingDevice = false }
        do {
            try await onlineClient.removeCurrentDevice(signedTransaction: signedTransaction)
            deviceMessage = "This iPhone was removed from the active-device list."
        } catch {
            deviceMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func replaceOldestDevice() async {
        guard let signedTransaction = subscription.entitlementJWS else {
            deviceMessage = "Refresh or restore the subscription before replacing a device."
            return
        }
        isReplacingDevice = true
        defer { isReplacingDevice = false }
        do {
            try await onlineClient.replaceOldestDevice(signedTransaction: signedTransaction)
            deviceMessage = "The least-recently-used installation was replaced, and this iPhone is ready for Online Quality."
        } catch {
            deviceMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }
}
