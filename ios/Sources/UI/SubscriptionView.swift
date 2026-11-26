import StoreKit
import SwiftUI

struct SpeakDuetSubscriptionView: View {
    @ObservedObject var subscription: SubscriptionManager
    @ObservedObject var access: TranslationAccessManager
    @Environment(\.dismiss) private var dismiss
    @State private var showManageSubscriptions = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 20) {
                    SpeakDuetLogo(height: 96)
                    Text("Keep the conversation going").font(.largeTitle.bold()).multilineTextAlignment(.center)
                    Text("One subscription unlocks all Speak Duet translation: continuous conversations, manual turns, and typed input. Conversation processing stays on your iPhone.")
                        .multilineTextAlignment(.center).foregroundStyle(.secondary)
                    Text(access.state.message).font(.callout).multilineTextAlignment(.center)

                    if case .freeAccess = access.state {
                        Text("Enjoy your remaining free access. When it ends, you can choose an additional subscription trial if eligible.")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else if subscription.isEnabled, !SubscriptionManager.productIDs.isEmpty {
                        SubscriptionStoreView(productIDs: SubscriptionManager.productIDs)
                            .storeButton(.visible, for: .restorePurchases)
                            .subscriptionStorePolicyDestination(url: legalURL("TERMS_URL") ?? URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/")!, for: .termsOfService)
                            .subscriptionStorePolicyDestination(for: .privacyPolicy) {
                                ScrollView {
                                    VStack(alignment: .leading, spacing: 16) {
                                        Text("Speak Duet privacy").font(.title.bold())
                                        Text("Conversation audio and text are processed on this iPhone. Audio is never saved. Optional text history stays on this iPhone until you explicitly share or delete it.")
                                        Text("Optional Apple or Google sign-in shares account information with the selected provider and Firebase Authentication. Signing in does not upload conversation history. Apple manages purchases and subscription billing.")
                                        if let url = legalURL("PRIVACY_POLICY_URL") { Link("Read the full privacy policy", destination: url) }
                                    }.padding()
                                }
                            }
                        Text("The App Store shows your eligible offer, subscription duration, and localized price before you confirm. The subscription renews automatically unless canceled.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    if let error = subscription.errorMessage { Text(error).font(.footnote).foregroundStyle(.secondary) }
                    HStack {
                        Button("Restore purchases") { Task { await subscription.restore() } }
                        Button("Manage subscription") { showManageSubscriptions = true }
                    }.buttonStyle(.bordered).disabled(subscription.loadingState != .idle)
                    Button("Refresh access") {
                        Task { await subscription.refresh(); access.refresh() }
                    }
                    Text("An account is optional. Existing history remains available even when translation access ends.")
                        .font(.footnote).foregroundStyle(.secondary)
                }.padding()
            }
            .navigationTitle("Speak Duet")
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .tint(TranslatorTheme.accent)
        .task { await subscription.refresh(); access.refresh() }
        .onChange(of: subscription.entitlement) { _, value in
            if value.hasPro { dismiss() }
        }
    }

    private func legalURL(_ key: String) -> URL? {
        guard let value = Bundle.main.object(forInfoDictionaryKey: key) as? String,
              let url = URL(string: value), url.scheme == "https",
              let host = url.host, !host.contains("invalid"), !host.contains("REPLACE") else { return nil }
        return url
    }
}
