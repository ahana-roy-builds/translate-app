import AuthenticationServices
import Combine
import CryptoKit
import FirebaseAuth
import FirebaseCore
import GoogleSignIn
import Security
import UIKit

struct AccountProfile: Equatable {
    let id: String
    let name: String?
    let email: String?
    let usesApple: Bool
}

@MainActor
final class AuthenticationManager: ObservableObject {
    @Published private(set) var user: AccountProfile?
    @Published private(set) var isBusy = false
    @Published var errorMessage: String?
    let isConfigured: Bool
    private var listener: AuthStateDidChangeListenerHandle?
    private var appleNonce: String?

    init(isEnabled: Bool, bundle: Bundle = .main) {
        // Never initialize a provider using placeholder or another app's config.
        // FirebaseAuth is the only Firebase product linked by this application.
        if isEnabled,
           let path = bundle.path(forResource: "GoogleService-Info", ofType: "plist"),
           let options = FirebaseOptions(contentsOfFile: path),
           options.bundleID == bundle.bundleIdentifier,
           let clientID = options.clientID, !clientID.isEmpty,
           let infoData = try? Data(contentsOf: URL(fileURLWithPath: path)),
           let info = (try? PropertyListSerialization.propertyList(from: infoData, format: nil)) as? [String: Any],
           let reversedID = info["REVERSED_CLIENT_ID"] as? String,
           let types = bundle.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]],
           types.contains(where: { ($0["CFBundleURLSchemes"] as? [String])?.contains(reversedID) == true }) {
            if FirebaseApp.app() == nil { FirebaseApp.configure(options: options) }
            GIDSignIn.sharedInstance.configuration = GIDConfiguration(clientID: clientID)
            isConfigured = true
        } else {
            isConfigured = false
        }
        if isConfigured {
            listener = Auth.auth().addStateDidChangeListener { [weak self] _, _ in
                Task { @MainActor [weak self] in
                    self?.user = Auth.auth().currentUser.map {
                        AccountProfile(id: $0.uid, name: $0.displayName, email: $0.email,
                                       usesApple: $0.providerData.contains { $0.providerID == "apple.com" })
                    }
                }
            }
        }
    }

    func prepareAppleRequest(_ request: ASAuthorizationAppleIDRequest) {
        errorMessage = nil
        do {
            var bytes = [UInt8](repeating: 0, count: 32)
            guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else {
                throw AuthenticationError.unavailable
            }
            let nonce = bytes.map { String(format: "%02x", $0) }.joined()
            appleNonce = nonce
            request.requestedScopes = [.fullName, .email]
            request.nonce = SHA256.hash(data: Data(nonce.utf8)).map { String(format: "%02x", $0) }.joined()
        } catch { errorMessage = "Apple sign-in could not start. Please try again." }
    }

    func completeAppleSignIn(_ result: Result<ASAuthorization, Error>, deletingAccount: Bool = false) async {
        guard isConfigured, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false; appleNonce = nil }
        do {
            let authorization = try result.get()
            guard let apple = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let tokenData = apple.identityToken,
                  let token = String(data: tokenData, encoding: .utf8),
                  let nonce = appleNonce else { throw AuthenticationError.unavailable }
            let credential = OAuthProvider.appleCredential(withIDToken: token, rawNonce: nonce, fullName: apple.fullName)
            if deletingAccount {
                guard let user = Auth.auth().currentUser,
                      let codeData = apple.authorizationCode,
                      let code = String(data: codeData, encoding: .utf8) else {
                    throw AuthenticationError.unavailable
                }
                try await user.reauthenticate(with: credential)
                try await Auth.auth().revokeToken(withAuthorizationCode: code)
                try await user.delete()
                self.user = nil
            } else {
                _ = try await Auth.auth().signIn(with: credential)
            }
        } catch {
            if (error as? ASAuthorizationError)?.code != .canceled {
                errorMessage = deletingAccount
                    ? "Your account could not be deleted. Check your connection and confirm with the same Apple account."
                    : "Apple sign-in did not finish. Check your connection and try again."
            }
        }
    }

    func signInWithGoogle(deletingAccount: Bool = false) async {
        guard isConfigured, !isBusy else { return }
        isBusy = true
        errorMessage = nil
        defer { isBusy = false }
        do {
            guard let presenter = presentingController() else { throw AuthenticationError.unavailable }
            let result = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenter)
            guard let token = result.user.idToken?.tokenString else { throw AuthenticationError.unavailable }
            let credential = GoogleAuthProvider.credential(withIDToken: token, accessToken: result.user.accessToken.tokenString)
            if deletingAccount {
                guard let user = Auth.auth().currentUser else { throw AuthenticationError.unavailable }
                try await user.reauthenticate(with: credential)
                try await user.delete()
                self.user = nil
                GIDSignIn.sharedInstance.signOut()
            } else {
                _ = try await Auth.auth().signIn(with: credential)
            }
        } catch {
            let nsError = error as NSError
            if nsError.domain != kGIDSignInErrorDomain || nsError.code != GIDSignInError.canceled.rawValue {
                errorMessage = deletingAccount
                    ? "Your account could not be deleted. Check your connection and confirm with the same Google account."
                    : "Google sign-in did not finish. Try the provider you previously used, or continue without an account."
            }
        }
    }

    func signOut() {
        guard isConfigured, !isBusy else { return }
        do {
            try Auth.auth().signOut()
            GIDSignIn.sharedInstance.signOut()
            user = nil
        } catch { errorMessage = "Sign-out did not finish. Please try again." }
    }

    func handleURL(_ url: URL) -> Bool {
        isConfigured && GIDSignIn.sharedInstance.handle(url)
    }

    private func presentingController() -> UIViewController? {
        let window = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .filter { $0.activationState == .foregroundActive }
            .flatMap(\.windows).first(where: \.isKeyWindow)
        var controller = window?.rootViewController
        while let presented = controller?.presentedViewController { controller = presented }
        return controller
    }
}

private enum AuthenticationError: Error { case unavailable }
