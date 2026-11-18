import AuthenticationServices
import SwiftUI
import StoreKit

struct AccountView: View {
    @ObservedObject var authentication: AuthenticationManager
    @ObservedObject var history: HistoryStore
    @ObservedObject var settings: SettingsStore
    @State private var confirmDelete = false
    @State private var eraseHistory = false
    @State private var showManageSubscriptions = false
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        Form {
            if let user = authentication.user {
                Section("Your account") {
                    if let name = user.name { Text(name) }
                    if let email = user.email { Text(email).textSelection(.enabled) }
                    Label(user.usesApple ? "Signed in with Apple" : "Signed in with Google", systemImage: "person.crop.circle.badge.checkmark")
                    Button("Sign out") { authentication.signOut() }
                    Button("Delete account", role: .destructive) { confirmDelete = true }
                }
                Section {
                    Text("Your subscription is managed by Apple separately from this account. Signing out does not cancel it.")
                    Text("Language settings and text history stay on this iPhone and are not synced to your account.")
                }.font(.footnote).foregroundStyle(.secondary)
            } else {
                Section {
                    Text("Your choice")
                        .font(.title2.bold())
                    Text("Create an account with Apple or Google, or keep using Speak Duet as a guest. An account is optional for translation and subscriptions.")
                    if authentication.isConfigured {
                        appleButton(deleting: false)
                        Button {
                            Task { await authentication.signInWithGoogle() }
                        } label: {
                            Text("Continue with Google").frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                        .accessibilityIdentifier("account.google")
                    } else {
                        Label("Account sign-in isn’t available in this build yet. You can continue without an account.", systemImage: "info.circle")
                            .foregroundStyle(.secondary)
                    }
                }
                Section("Your privacy") {
                    Text("Sign-in shares account information with the selected provider and Firebase. Conversation audio, translations, and local history stay on this iPhone.")
                        .font(.footnote)
                }
            }
            if authentication.isBusy { ProgressView("Please wait…") }
            if let error = authentication.errorMessage { Text(error).foregroundStyle(.red).font(.footnote) }
        }
        .disabled(authentication.isBusy)
        .navigationTitle("Account")
        .manageSubscriptionsSheet(isPresented: $showManageSubscriptions)
        .sheet(isPresented: $confirmDelete) {
            NavigationStack {
                Form {
                    Section {
                        Text("Delete your Speak Duet account?").font(.title2.bold())
                        Text("This permanently removes your account. Apple subscription billing continues unless you cancel it separately.")
                        Button("Manage Apple subscription") { showManageSubscriptions = true }
                        Toggle("Also delete text history on this iPhone", isOn: $eraseHistory)
                    }
                    Section {
                        if authentication.user?.usesApple == true {
                            Text("Confirm with the same Apple account to delete it.")
                            appleButton(deleting: true)
                        } else {
                            Button("Confirm with Google and delete account", role: .destructive) {
                                Task {
                                    await authentication.signInWithGoogle(deletingAccount: true)
                                    await finishDeletionIfNeeded()
                                }
                            }
                        }
                        if let error = authentication.errorMessage { Text(error).foregroundStyle(.red) }
                    }
                }
                .disabled(authentication.isBusy)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { confirmDelete = false } } }
            }
        }
    }

    private func appleButton(deleting: Bool) -> some View {
        SignInWithAppleButton(.continue) { request in
            authentication.prepareAppleRequest(request)
        } onCompletion: { result in
            Task {
                await authentication.completeAppleSignIn(result, deletingAccount: deleting)
                if deleting { await finishDeletionIfNeeded() }
            }
        }
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .frame(height: 48)
        .accessibilityIdentifier(deleting ? "account.delete.apple" : "account.apple")
    }

    private func finishDeletionIfNeeded() async {
        // The auth observer is asynchronous; check again after yielding to it.
        await Task.yield()
        guard authentication.user == nil, authentication.errorMessage == nil else { return }
        if eraseHistory {
            await history.deleteAll()
            if let error = history.errorMessage {
                authentication.errorMessage = "Your account was deleted, but local history could not be erased: \(error)"
                return
            }
        }
        confirmDelete = false
    }
}
