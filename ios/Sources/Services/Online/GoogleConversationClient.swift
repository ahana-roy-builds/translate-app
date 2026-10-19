import CryptoKit
import DeviceCheck
import Foundation

enum ChallengeFreshness {
    // A pool prepared before recording must survive a 30s capture, the
    // backend's 18s request window, and a small scheduling/network margin.
    static let maximumCapture: TimeInterval = 30
    static let schedulingMargin: TimeInterval = 7
    static let assertionCreation: TimeInterval = 22
    static let requestWindow: TimeInterval = 18
    static let pooled = maximumCapture + requestWindow + schedulingMargin
    // Shared deployment contract: backend TTL validation must never permit a
    // value below this floor. Production uses 120 seconds.
    static let minimumBackendTTL: TimeInterval = 60
}

struct OnlineTurnResponse: Decodable, Sendable {
    let sourceText: String
    let translatedText: String
    let recognitionConfidence: Double?
    let engine: String
    let warnings: [String]
    let timingsMs: [String: Int]
}

@MainActor
final class GoogleConversationClient: OnlineTranslationClient {
    private let baseURL: URL
    private let origin: OnlineServiceOrigin
    private let session: URLSession
    private let sessionDelegate: RejectingRedirectSessionDelegate
    private let attest: AppAttestProvider
    private let encoder: JSONEncoder
    private let expectedBuildIdentity: AppBuildIdentity?
    private(set) var lastBackendBuildIdentity: BackendBuildIdentity?
    private var onlineSession: OnlineSession?
    private var activeRequest: Task<(Data, URLResponse), Error>?
    private var activeRequestID: UUID?
    private var availabilityCache: (value: Bool, checkedAt: Date)?
    private let operationGate = OnlineClientOperationGate()

    init(baseURL: URL, expectedBuildIdentity: AppBuildIdentity? = AppBuildIdentity(bundle: .main)) {
        guard let origin = OnlineServiceOrigin(baseURL: baseURL) else {
            preconditionFailure("API_BASE_URL must be an HTTPS origin without credentials, query, or fragment (DEBUG also permits loopback HTTP).")
        }
        let delegate = RejectingRedirectSessionDelegate()
        let configuration = URLSessionConfiguration.ephemeral
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.timeoutIntervalForRequest = 22
        configuration.timeoutIntervalForResource = 30
        configuration.waitsForConnectivity = false

        self.baseURL = baseURL
        self.origin = origin
        self.expectedBuildIdentity = expectedBuildIdentity
        sessionDelegate = delegate
        session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        attest = AppAttestProvider(baseURL: baseURL, origin: origin, session: session)
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
    }

    deinit { session.invalidateAndCancel() }

    func prepareSecurity(signedTransaction: String) async throws {
        try await serialized {
            guard try await self.isAvailable() else { throw PipelineError.onlineUnavailable }
            _ = try await self.withSecurityRecovery(signedTransaction: signedTransaction) {
                try await self.ensureSession(signedTransaction: signedTransaction)
                return true
            }
        }
    }

    private func isAvailable() async throws -> Bool {
        guard let expectedBuildIdentity else {
            throw PipelineError.server("Online Quality is disabled because this app build has no valid release identity.")
        }
        if let availabilityCache, Date().timeIntervalSince(availabilityCache.checkedAt) < 15 { return availabilityCache.value }
        var request = URLRequest(url: endpoint("/v2/availability"))
        request.httpMethod = "GET"
        request.timeoutInterval = 5
        BuildIdentityRequestHeaders.applyPreflight(expectedBuildIdentity, to: &request)
        let response = try decode(AvailabilityResponse.self, from: await send(request, expectedStatus: 200))
        guard BackendBuildIdentityPolicy.isStructurallyValid(response.buildIdentity) else {
            throw PipelineError.malformedResponse
        }
        lastBackendBuildIdentity = response.buildIdentity
        guard BackendBuildIdentityPolicy.matches(response.buildIdentity, expected: expectedBuildIdentity) else {
            availabilityCache = (false, Date())
            throw PipelineError.server("Online Quality is unavailable because the app and service release identities do not match.")
        }
        availabilityCache = (response.available, Date())
        return response.available
    }

    func translateTurn(audio: AudioTurn, source: AppLanguage, target: AppLanguage, signedTransaction: String) async throws -> OnlineTurnResponse {
        try await serialized {
            guard audio.wavData.count <= 960_044, audio.duration <= 30 else {
                throw PipelineError.server("Please keep each turn under 30 seconds.")
            }
            return try await self.withSecurityRecovery(signedTransaction: signedTransaction) {
                try await self.ensureSession(signedTransaction: signedTransaction)
                let body = audio.wavData
                var request = try await self.attestedRequest(path: "/v2/translate-turn", body: body, contentType: "audio/wav", sourceLocale: source.code, targetLocale: target.code)
                request.setValue(String(body.count), forHTTPHeaderField: "Content-Length")
                let response = try self.decode(OnlineTurnResponse.self, from: await self.send(request, expectedStatus: 200))
                return try self.validated(response, expectsRecognition: true)
            }
        }
    }

    func translateText(_ text: String, source: AppLanguage, target: AppLanguage, signedTransaction: String) async throws -> OnlineTurnResponse {
        try await serialized {
            let boundedText = try TurnTextPolicy.validated(text)
            return try await self.withSecurityRecovery(signedTransaction: signedTransaction) {
                try await self.ensureSession(signedTransaction: signedTransaction)
                let body = try self.encoder.encode(TextTranslationRequest(sourceLocale: source.code, targetLocale: target.code, text: boundedText))
                guard body.count <= 8_192 else { throw PipelineError.server("Typed text is too long.") }
                let request = try await self.attestedRequest(path: "/v2/translate-text", body: body, contentType: "application/json", sourceLocale: source.code, targetLocale: target.code)
                let decoded = try self.decode(OnlineTurnResponse.self, from: await self.send(request, expectedStatus: 200))
                let response = try self.validated(decoded, expectsRecognition: false)
                _ = try TypedTranslationSourcePolicy.authoritativeSource(requested: boundedText, echoed: response.sourceText)
                return response
            }
        }
    }

    func removeCurrentDevice(signedTransaction: String) async throws {
        try await serialized {
            try await self.withSecurityRecovery(signedTransaction: signedTransaction) {
                try await self.ensureSession(signedTransaction: signedTransaction)
                let request = try await self.attestedRequest(method: "DELETE", path: "/v2/devices/current", body: Data(), contentType: nil, sourceLocale: nil, targetLocale: nil)
                _ = try await self.send(request, expectedStatus: 204, maximumBytes: 1_024)
                self.onlineSession = nil
            }
        }
    }

    /// Explicit, user-confirmed recovery for an installation that cannot create
    /// a normal session because all subscription device slots are occupied.
    func replaceOldestDevice(signedTransaction: String) async throws {
        try await serialized {
            try await self.withSecurityRecovery(signedTransaction: signedTransaction) {
                try await self.replaceOldestBinding(signedTransaction: signedTransaction)
            }
            // Establishing the normal bearer session is a separate bounded
            // recovery scope. A retry here must never repeat the destructive
            // replacement request.
            self.onlineSession = nil
            try await self.withSecurityRecovery(signedTransaction: signedTransaction) {
                try await self.ensureSession(signedTransaction: signedTransaction)
            }
        }
    }

    func cancel() {
        // Cancellation must be able to interrupt the request currently holding
        // the serialized lane. It does not create assertions or mutate sessions.
        activeRequest?.cancel()
        activeRequest = nil
        activeRequestID = nil
    }

    private func serialized<Value>(_ operation: () async throws -> Value) async throws -> Value {
        await operationGate.acquire()
        do {
            // A task canceled while queued must not begin an App Attest or
            // network operation when its turn in the lane arrives.
            try Task.checkCancellation()
            let value = try await operation()
            await operationGate.release()
            return value
        } catch {
            await operationGate.release()
            throw error
        }
    }

    private func ensureSession(signedTransaction: String) async throws {
        let buildIdentity = try boundBuildIdentity()
        let evidenceHash = Data(SHA256.hash(data: Data(signedTransaction.utf8)))
        if var onlineSession,
           onlineSession.evidenceHash == evidenceHash,
           onlineSession.buildIdentity == buildIdentity,
           onlineSession.expiresAt.timeIntervalSinceNow > 30 {
            onlineSession.challenges.removeAll { Self.remainingLifetime(of: $0) <= ChallengeFreshness.pooled }
            self.onlineSession = onlineSession
            if !onlineSession.challenges.isEmpty { return }
        }

        let challenge = try await attest.challenge(purpose: .session)
        try OnlineOperationCheckpoint.requireActive()
        guard Self.remainingLifetime(of: challenge) > ChallengeFreshness.assertionCreation else {
            throw Self.expiredChallengeError()
        }
        let body = try encoder.encode(SessionRequest(signedTransaction: signedTransaction))
        let proof = try await attest.assertion(
            method: "POST",
            path: "/v2/session",
            challenge: challenge,
            sessionToken: nil,
            sourceLocale: nil,
            targetLocale: nil,
            buildIdentity: buildIdentity,
            body: body
        )
        try OnlineOperationCheckpoint.requireActive()
        guard Self.remainingLifetime(of: challenge) > ChallengeFreshness.requestWindow else {
            throw Self.expiredChallengeError()
        }
        var request = URLRequest(url: endpoint("/v2/session"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 22
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try applyBuildIdentity(buildIdentity, to: &request)
        apply(proof, to: &request)
        let response = try decode(SessionResponse.self, from: await send(request, expectedStatus: 200))
        let freshChallenges = response.challenges.filter {
            Self.validChallenge($0) && Self.remainingLifetime(of: $0) > ChallengeFreshness.pooled
        }
        guard let expiry = Self.parseDate(response.expiresAt), expiry.timeIntervalSinceNow > 0, expiry.timeIntervalSinceNow <= 3_600,
              response.token.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              (1...16).contains(response.challenges.count),
              response.challenges.allSatisfy(Self.validChallenge) else { throw PipelineError.malformedResponse }
        guard !freshChallenges.isEmpty else { throw Self.expiredChallengeError() }
        onlineSession = OnlineSession(
            token: response.token,
            expiresAt: expiry,
            challenges: freshChallenges,
            evidenceHash: evidenceHash,
            buildIdentity: buildIdentity
        )
    }

    private func replaceOldestBinding(signedTransaction: String) async throws {
        let path = "/v2/devices/replace-oldest"
        let buildIdentity = try boundBuildIdentity()
        let challenge = try await attest.challenge(purpose: .session)
        try OnlineOperationCheckpoint.requireActive()
        guard Self.remainingLifetime(of: challenge) > ChallengeFreshness.assertionCreation else {
            throw Self.expiredChallengeError()
        }
        let body = try encoder.encode(SessionRequest(signedTransaction: signedTransaction))
        let proof = try await attest.assertion(
            method: "POST",
            path: path,
            challenge: challenge,
            sessionToken: nil,
            sourceLocale: nil,
            targetLocale: nil,
            buildIdentity: buildIdentity,
            body: body
        )
        try OnlineOperationCheckpoint.requireActive()
        guard Self.remainingLifetime(of: challenge) > ChallengeFreshness.requestWindow else {
            throw Self.expiredChallengeError()
        }
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 22
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        try applyBuildIdentity(buildIdentity, to: &request)
        apply(proof, to: &request)
        let response = try decode(ReplaceOldestDeviceResponse.self, from: await send(request, expectedStatus: 200, maximumBytes: 4_096))
        guard response.replaced else { throw PipelineError.malformedResponse }
    }

    private func attestedRequest(method: String = "POST", path: String, body: Data, contentType: String?, sourceLocale: String?, targetLocale: String?) async throws -> URLRequest {
        onlineSession?.challenges.removeAll { Self.remainingLifetime(of: $0) <= ChallengeFreshness.assertionCreation }
        guard onlineSession?.challenges.isEmpty == false else {
            onlineSession = nil
            throw Self.expiredChallengeError()
        }
        if onlineSession?.challenges.count ?? 0 <= 1 { try await replenishChallenges() }
        try OnlineOperationCheckpoint.requireActive()
        guard var onlineSession, let challenge = onlineSession.challenges.first else { throw PipelineError.onlineUnavailable }
        guard Self.remainingLifetime(of: challenge) > ChallengeFreshness.assertionCreation else {
            self.onlineSession = nil
            throw Self.expiredChallengeError()
        }
        onlineSession.challenges.removeFirst()
        self.onlineSession = onlineSession
        let proof = try await attest.assertion(
            method: method,
            path: path,
            challenge: challenge,
            sessionToken: onlineSession.token,
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            buildIdentity: onlineSession.buildIdentity,
            body: body
        )
        try OnlineOperationCheckpoint.requireActive()
        // Recheck after the asynchronous Secure Enclave operation. The proof is
        // not sent unless the challenge can still cover the backend's 18s window.
        guard Self.remainingLifetime(of: challenge) > ChallengeFreshness.requestWindow else {
            self.onlineSession = nil
            throw Self.expiredChallengeError()
        }
        var request = URLRequest(url: endpoint(path))
        request.httpMethod = method
        request.httpBody = body
        request.timeoutInterval = 22
        if let contentType { request.setValue(contentType, forHTTPHeaderField: "Content-Type") }
        if let sourceLocale { request.setValue(sourceLocale, forHTTPHeaderField: "X-Source-Locale") }
        if let targetLocale { request.setValue(targetLocale, forHTTPHeaderField: "X-Target-Locale") }
        request.setValue("Bearer \(onlineSession.token)", forHTTPHeaderField: "Authorization")
        try applyBuildIdentity(onlineSession.buildIdentity, to: &request)
        apply(proof, to: &request)
        return request
    }

    private func replenishChallenges() async throws {
        guard var onlineSession else { throw PipelineError.onlineUnavailable }
        guard onlineSession.expiresAt.timeIntervalSinceNow > 30 else {
            self.onlineSession = nil
            throw PipelineError.onlineUnavailable
        }
        onlineSession.challenges.removeAll { Self.remainingLifetime(of: $0) <= ChallengeFreshness.assertionCreation }
        guard let challenge = onlineSession.challenges.first else {
            self.onlineSession = nil
            throw PipelineError.onlineUnavailable
        }
        onlineSession.challenges.removeFirst()
        self.onlineSession = onlineSession
        let body = Data()
        let proof = try await attest.assertion(
            method: "POST",
            path: "/v2/session/challenges",
            challenge: challenge,
            sessionToken: onlineSession.token,
            sourceLocale: nil,
            targetLocale: nil,
            buildIdentity: onlineSession.buildIdentity,
            body: body
        )
        try OnlineOperationCheckpoint.requireActive()
        guard Self.remainingLifetime(of: challenge) > ChallengeFreshness.requestWindow else {
            self.onlineSession = nil
            throw Self.expiredChallengeError()
        }
        var request = URLRequest(url: endpoint("/v2/session/challenges"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 22
        request.setValue("Bearer \(onlineSession.token)", forHTTPHeaderField: "Authorization")
        try applyBuildIdentity(onlineSession.buildIdentity, to: &request)
        apply(proof, to: &request)
        let response = try decode(ChallengePoolResponse.self, from: await send(request, expectedStatus: 200))
        let freshChallenges = response.challenges.filter {
            Self.validChallenge($0) && Self.remainingLifetime(of: $0) > ChallengeFreshness.pooled
        }
        guard (1...16).contains(response.challenges.count),
              response.challenges.allSatisfy(Self.validChallenge) else { throw PipelineError.malformedResponse }
        guard !freshChallenges.isEmpty else { throw Self.expiredChallengeError() }
        self.onlineSession?.challenges = freshChallenges
    }

    private func send(_ request: URLRequest, expectedStatus: Int, maximumBytes: Int = 65_536) async throws -> Data {
        try OnlineOperationCheckpoint.requireActive()
        guard origin.matches(request.url) else { throw PipelineError.malformedResponse }
        let requestID = UUID()
        let task = Task {
            try OnlineOperationCheckpoint.requireActive()
            return try await Self.boundedData(session: session, request: request, maximumBytes: maximumBytes)
        }
        activeRequest = task
        activeRequestID = requestID
        defer {
            if activeRequestID == requestID { activeRequest = nil; activeRequestID = nil }
        }
        let (data, response) = try await withTaskCancellationHandler {
            try await task.value
        } onCancel: {
            task.cancel()
        }
        try OnlineOperationCheckpoint.requireActive()
        guard let http = response as? HTTPURLResponse, origin.matches(http.url) else {
            throw PipelineError.malformedResponse
        }
        guard http.statusCode == expectedStatus else {
            let payload = try? JSONDecoder().decode(ServerError.self, from: data)
            let code = payload?.error.code ?? "HTTP_\(http.statusCode)"
            let recovery = AppAttestRecoveryPolicy.action(serverCode: code)
            // Preserve a still-live binding long enough to attempt its explicit
            // release before controlled key rotation. Other auth failures must
            // not leave a session eligible for reuse.
            if (http.statusCode == 401 || http.statusCode == 409), recovery != .rotateKey { onlineSession = nil }
            if code == "BUILD_IDENTITY_MISMATCH" || code == "INVALID_BUILD_IDENTITY_HEADER" {
                availabilityCache = nil
                lastBackendBuildIdentity = nil
            }
            throw ServerResponseError(status: http.statusCode, code: code, message: payload?.error.message ?? "Online translation failed (\(http.statusCode)).")
        }
        return data
    }

    private func apply(_ proof: AppAttestProof, to request: inout URLRequest) {
        request.setValue(proof.keyID, forHTTPHeaderField: "X-App-Attest-Key-ID")
        request.setValue(proof.assertion.base64EncodedString(), forHTTPHeaderField: "X-App-Attest-Assertion")
        request.setValue(proof.challengeToken, forHTTPHeaderField: "X-App-Attest-Challenge-Token")
    }

    private func boundBuildIdentity() throws -> BackendBuildIdentity {
        guard let expectedBuildIdentity,
              let lastBackendBuildIdentity,
              BackendBuildIdentityPolicy.matches(lastBackendBuildIdentity, expected: expectedBuildIdentity) else {
            throw PipelineError.server("Online Quality requires a fresh matching availability preflight.")
        }
        return lastBackendBuildIdentity
    }

    private func applyBuildIdentity(_ backend: BackendBuildIdentity, to request: inout URLRequest) throws {
        guard let expectedBuildIdentity else {
            throw PipelineError.server("Online Quality is disabled because this app build has no valid release identity.")
        }
        try BuildIdentityRequestHeaders.applyBound(app: expectedBuildIdentity, backend: backend, to: &request)
    }

    private func endpoint(_ path: String) -> URL {
        baseURL.appending(path: String(path.drop(while: { $0 == "/" })))
    }

    private func decode<Value: Decodable>(_ type: Value.Type, from data: Data) throws -> Value {
        do { return try JSONDecoder().decode(type, from: data) }
        catch { throw PipelineError.malformedResponse }
    }

    private func withSecurityRecovery<Value>(signedTransaction: String, operation: @escaping @MainActor () async throws -> Value) async throws -> Value {
        var attemptedRecovery = false
        while true {
            do {
                try await attest.prepare()
                try OnlineOperationCheckpoint.requireActive()
                return try await operation()
            } catch {
                guard !attemptedRecovery, Self.isRecoverableSecurityError(error) else { throw error }
                attemptedRecovery = true
                let nsError = error as NSError
                let action = AppAttestRecoveryPolicy.action(
                    serverCode: (error as? ServerResponseError)?.code,
                    deviceKeyInvalid: nsError.domain == DCError.errorDomain && nsError.code == DCError.Code.invalidKey.rawValue
                )
                if action == .rotateKey {
                    await releaseCurrentBindingBestEffort()
                    try OnlineOperationCheckpoint.requireActive()
                }
                onlineSession = nil
                attest.recover(from: error)
            }
        }
    }

    private static func isRecoverableSecurityError(_ error: any Error) -> Bool {
        let nsError = error as NSError
        return AppAttestRecoveryPolicy.action(
            serverCode: (error as? ServerResponseError)?.code,
            deviceKeyInvalid: nsError.domain == DCError.errorDomain && nsError.code == DCError.Code.invalidKey.rawValue
        ) != .none
    }

    private func validated(_ response: OnlineTurnResponse, expectsRecognition: Bool) throws -> OnlineTurnResponse {
        let sourceBytes = response.sourceText.utf8.count, translatedBytes = response.translatedText.utf8.count
        guard !response.sourceText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.translatedText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !response.sourceText.contains("\0"), !response.translatedText.contains("\0"),
              sourceBytes <= 16_384, translatedBytes <= 16_384,
              response.warnings.count <= 16,
              response.warnings.allSatisfy({ !$0.isEmpty && $0.utf8.count <= 64 }),
              !response.engine.isEmpty, response.engine.utf8.count <= 64,
              !response.timingsMs.isEmpty, response.timingsMs.count <= 8,
              response.timingsMs.values.allSatisfy({ $0 >= 0 && $0 <= 60_000 }) else { throw PipelineError.malformedResponse }
        if let confidence = response.recognitionConfidence, !(0...1).contains(confidence) { throw PipelineError.malformedResponse }
        if !expectsRecognition, response.sourceText.utf8.count > 8_192 { throw PipelineError.malformedResponse }
        return response
    }

    private static func boundedData(session: URLSession, request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
        try await boundedURLSessionData(session: session, request: request, maximumBytes: maximumBytes)
    }

    private static func parseDate(_ value: String) -> Date? {
        parseISO8601Date(value)
    }

    private static func remainingLifetime(of challenge: AppAttestChallenge) -> TimeInterval {
        parseDate(challenge.expiresAt)?.timeIntervalSinceNow ?? 0
    }

    private static func expiredChallengeError() -> ServerResponseError {
        ServerResponseError(status: 410, code: "CHALLENGE_EXPIRED", message: "No fresh request challenge is available.")
    }

    private static func validChallenge(_ value: AppAttestChallenge) -> Bool {
        guard decodeBase64URL(value.challenge)?.count == 32,
              value.challengeToken.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil,
              let expiry = parseDate(value.expiresAt) else { return false }
        return expiry.timeIntervalSinceNow > 0 && expiry.timeIntervalSinceNow <= 600
    }

    private func releaseCurrentBindingBestEffort() async {
        guard var current = onlineSession, current.expiresAt.timeIntervalSinceNow > ChallengeFreshness.requestWindow else { return }
        current.challenges.removeAll { Self.remainingLifetime(of: $0) <= ChallengeFreshness.assertionCreation }
        guard let challenge = current.challenges.first else { return }
        current.challenges.removeFirst(); onlineSession = current
        do {
            let proof = try await attest.assertion(
                method: "DELETE",
                path: "/v2/devices/current",
                challenge: challenge,
                sessionToken: current.token,
                sourceLocale: nil,
                targetLocale: nil,
                buildIdentity: current.buildIdentity,
                body: Data()
            )
            try OnlineOperationCheckpoint.requireActive()
            guard Self.remainingLifetime(of: challenge) > ChallengeFreshness.requestWindow else { return }
            var request = URLRequest(url: endpoint("/v2/devices/current")); request.httpMethod = "DELETE"; request.httpBody = Data(); request.timeoutInterval = 22
            request.setValue("Bearer \(current.token)", forHTTPHeaderField: "Authorization")
            try applyBuildIdentity(current.buildIdentity, to: &request)
            apply(proof, to: &request)
            _ = try await send(request, expectedStatus: 204, maximumBytes: 1_024)
        } catch {
            // The old credential may already be unusable. Backend-side stale-key
            // replacement is still required to guarantee immediate slot reclamation.
        }
    }
}

enum AppAttestDigest {
    static func make(
        method: String,
        path: String,
        challenge: String,
        keyID: String,
        sessionToken: String?,
        sourceLocale: String?,
        targetLocale: String?,
        releaseBuildID: String,
        backendOCIDigest: String,
        runtimeEnvironment: String,
        cloudRunRevision: String,
        body: Data
    ) -> Data {
        let tokenHash = sessionToken.map { base64URL(Data(SHA256.hash(data: Data($0.utf8)))) } ?? ""
        let prefix = "locallingo-request-v3\n\(method.uppercased())\n\(path)\n\(challenge)\n\(keyID)\n\(tokenHash)\n\(sourceLocale ?? "")\n\(targetLocale ?? "")\n\(releaseBuildID)\n\(backendOCIDigest)\n\(runtimeEnvironment)\n\(cloudRunRevision)\n"
        var canonical = Data(prefix.utf8)
        canonical.append(Data(SHA256.hash(data: body)))
        return Data(SHA256.hash(data: canonical))
    }
}

enum AppAttestRecoveryAction: Equatable { case none, retrySession, reregister, rotateKey }

enum AppAttestRecoveryPolicy {
    static func action(serverCode: String?, deviceKeyInvalid: Bool = false) -> AppAttestRecoveryAction {
        if deviceKeyInvalid { return .rotateKey }
        switch serverCode {
        case "INVALID_SESSION", "CHALLENGE_EXPIRED", "CHALLENGE_REPLAYED", "REPLAYED", "INVALID_CHALLENGE", "INVALID_ASSERTION_COUNTER": return .retrySession
        case "APP_ATTEST_KEY_NOT_REGISTERED", "KEY_NOT_REGISTERED": return .reregister
        case "INVALID_APP_ATTEST", "INVALID_APP_ATTEST_KEY_ID", "INVALID_APP_ATTEST_ASSERTION", "INVALID_APP_ATTEST_COUNTER": return .rotateKey
        default: return .none
        }
    }

    static func registrationWasAlreadyCompleted(serverCode: String?) -> Bool { serverCode == "KEY_ALREADY_REGISTERED" }
}

private actor OnlineClientOperationGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func acquire() async { if !locked { locked = true; return }; await withCheckedContinuation { waiters.append($0) } }
    func release() { if waiters.isEmpty { locked = false } else { waiters.removeFirst().resume() } }
}

enum AppAttestChallengeHash {
    static func make(encodedChallenge: String) -> Data? {
        guard let rawChallenge = decodeBase64URL(encodedChallenge), rawChallenge.count == 32 else { return nil }
        return Data(SHA256.hash(data: rawChallenge))
    }
}

enum OnlineOperationCheckpoint {
    static func requireActive() throws {
        try Task.checkCancellation()
    }
}

private struct OnlineSession {
    let token: String
    let expiresAt: Date
    var challenges: [AppAttestChallenge]
    let evidenceHash: Data
    let buildIdentity: BackendBuildIdentity
}

private struct TextTranslationRequest: Encodable { let sourceLocale: String; let targetLocale: String; let text: String }
// StoreKit Sandbox and Production JWS values are forwarded unchanged. The
// backend derives and enforces their signed environment; the client must not
// send a spoofable environment selector.
private struct SessionRequest: Encodable { let signedTransaction: String }
private struct SessionResponse: Decodable { let token: String; let expiresAt: String; let challenges: [AppAttestChallenge] }
private struct ChallengePoolResponse: Decodable { let challenges: [AppAttestChallenge] }
private struct ReplaceOldestDeviceResponse: Decodable { let replaced: Bool }
struct AvailabilityResponse: Decodable, Equatable {
    let available: Bool
    let buildIdentity: BackendBuildIdentity
}

private struct ServerError: Decodable {
    struct Payload: Decodable { let code: String; let message: String; let requestId: String? }
    let error: Payload
}

private struct ServerResponseError: LocalizedError {
    let status: Int
    let code: String
    let message: String
    var errorDescription: String? { message }
}

private struct AppAttestProof {
    let keyID: String
    let assertion: Data
    let challengeToken: String
}

private enum ChallengePurpose: String, Encodable { case register, session }

private struct AppAttestChallenge: Codable {
    let challenge: String
    let challengeToken: String
    let expiresAt: String
}

@MainActor
private final class AppAttestProvider {
    private let service = DCAppAttestService.shared
    private let baseURL: URL
    private let origin: OnlineServiceOrigin
    private let session: URLSession
    private let encoder: JSONEncoder
    private var keyID: String?
    private let defaultsKey = "LocalLingo.AppAttestKeyID.v2"
    private let registeredDefaultsKey = "LocalLingo.RegisteredAppAttestKeyID.v2"
    private let localDevelopmentBypass: Bool

    init(baseURL: URL, origin: OnlineServiceOrigin, session: URLSession) {
        self.baseURL = baseURL
        self.origin = origin
        self.session = session
        encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        #if DEBUG
        localDevelopmentBypass = ["localhost", "127.0.0.1", "::1"].contains(baseURL.host?.lowercased() ?? "")
        #else
        localDevelopmentBypass = false
        #endif
        keyID = UserDefaults.standard.string(forKey: defaultsKey)
    }

    func prepare() async throws {
        guard localDevelopmentBypass || service.isSupported else { throw PipelineError.server("App Attest is unavailable on this device.") }
        let key = try await deviceKey()
        try OnlineOperationCheckpoint.requireActive()
        if UserDefaults.standard.string(forKey: registeredDefaultsKey) != key {
            try await register(keyID: key)
            try OnlineOperationCheckpoint.requireActive()
            UserDefaults.standard.set(key, forKey: registeredDefaultsKey)
        }
    }

    func invalidateRegistration() {
        UserDefaults.standard.removeObject(forKey: registeredDefaultsKey)
    }

    func recover(from error: any Error) {
        let serverCode = (error as? ServerResponseError)?.code
        let nsError = error as NSError
        switch AppAttestRecoveryPolicy.action(serverCode: serverCode, deviceKeyInvalid: nsError.domain == DCError.errorDomain && nsError.code == DCError.Code.invalidKey.rawValue) {
        case .none, .retrySession: break
        case .reregister: invalidateRegistration()
        case .rotateKey: rotateKey()
        }
    }

    func challenge(purpose: ChallengePurpose) async throws -> AppAttestChallenge {
        let key = try await deviceKey()
        try OnlineOperationCheckpoint.requireActive()
        let body = try encoder.encode(ChallengeRequest(purpose: purpose, keyID: key))
        var request = URLRequest(url: endpoint("/v2/app-attest/challenge"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await boundedURLSessionData(session: session, request: request, maximumBytes: 16_384)
        try OnlineOperationCheckpoint.requireActive()
        guard let http = response as? HTTPURLResponse, origin.matches(http.url) else { throw PipelineError.malformedResponse }
        guard http.statusCode == 200 else { throw serverError(data: data, fallback: "Could not request an App Attest challenge.") }
        let challenge = try JSONDecoder().decode(AppAttestChallenge.self, from: data)
        guard decodeBase64URL(challenge.challenge)?.count == 32,
              challenge.challengeToken.range(of: #"^[A-Za-z0-9_-]{43}$"#, options: .regularExpression) != nil else { throw PipelineError.malformedResponse }
        guard let expiry = parseISO8601Date(challenge.expiresAt),
              expiry.timeIntervalSinceNow <= 600 else { throw PipelineError.malformedResponse }
        guard expiry.timeIntervalSinceNow > ChallengeFreshness.assertionCreation else {
            throw ServerResponseError(status: 410, code: "CHALLENGE_EXPIRED", message: "The App Attest challenge was not fresh enough to use.")
        }
        return challenge
    }

    func assertion(
        method: String,
        path: String,
        challenge: AppAttestChallenge,
        sessionToken: String?,
        sourceLocale: String?,
        targetLocale: String?,
        buildIdentity: BackendBuildIdentity,
        body: Data
    ) async throws -> AppAttestProof {
        let key = try await deviceKey()
        try OnlineOperationCheckpoint.requireActive()
        let digest = AppAttestDigest.make(
            method: method,
            path: path,
            challenge: challenge.challenge,
            keyID: key,
            sessionToken: sessionToken,
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            releaseBuildID: buildIdentity.releaseBuildID,
            backendOCIDigest: buildIdentity.ociDigest,
            runtimeEnvironment: buildIdentity.environment,
            cloudRunRevision: buildIdentity.revision,
            body: body
        )
        let assertion: Data
        if localDevelopmentBypass { assertion = Data("debug-local-assertion".utf8) }
        else {
            assertion = try await service.generateAssertion(key, clientDataHash: digest)
            try OnlineOperationCheckpoint.requireActive()
        }
        return AppAttestProof(keyID: key, assertion: assertion, challengeToken: challenge.challengeToken)
    }

    private func deviceKey() async throws -> String {
        if let keyID { return keyID }
        let key: String
        if localDevelopmentBypass { key = Data(repeating: 0x42, count: 32).base64EncodedString() }
        else {
            key = try await service.generateKey()
            try OnlineOperationCheckpoint.requireActive()
        }
        keyID = key
        UserDefaults.standard.set(key, forKey: defaultsKey)
        return key
    }

    private func register(keyID: String) async throws {
        let challenge: AppAttestChallenge
        do { challenge = try await self.challenge(purpose: .register) }
        catch let error as ServerResponseError where AppAttestRecoveryPolicy.registrationWasAlreadyCompleted(serverCode: error.code) { return }
        try OnlineOperationCheckpoint.requireActive()
        guard let clientDataHash = AppAttestChallengeHash.make(encodedChallenge: challenge.challenge) else { throw PipelineError.malformedResponse }
        let attestation: Data
        if localDevelopmentBypass { attestation = Data("debug-local-attestation".utf8) }
        else {
            attestation = try await service.attestKey(keyID, clientDataHash: clientDataHash)
            try OnlineOperationCheckpoint.requireActive()
        }
        guard (parseISO8601Date(challenge.expiresAt)?.timeIntervalSinceNow ?? 0) > ChallengeFreshness.requestWindow else {
            throw ServerResponseError(status: 410, code: "CHALLENGE_EXPIRED", message: "The App Attest registration challenge expired before use.")
        }
        let body = try encoder.encode(AppAttestRegistration(keyID: keyID, attestationObject: attestation.base64EncodedString(), challengeToken: challenge.challengeToken))
        var request = URLRequest(url: endpoint("/v2/app-attest/register"))
        request.httpMethod = "POST"
        request.httpBody = body
        request.timeoutInterval = 20
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await boundedURLSessionData(session: session, request: request, maximumBytes: 16_384)
        try OnlineOperationCheckpoint.requireActive()
        guard let http = response as? HTTPURLResponse, origin.matches(http.url) else { throw PipelineError.malformedResponse }
        guard http.statusCode == 201 else { throw serverError(data: data, fallback: "Could not finish App Attest registration.") }
        guard (try? JSONDecoder().decode(AppAttestRegistrationResponse.self, from: data).registered) == true else { throw PipelineError.malformedResponse }
    }

    private func endpoint(_ path: String) -> URL { baseURL.appending(path: String(path.drop(while: { $0 == "/" }))) }

    private func serverError(data: Data, fallback: String) -> any Error {
        let response = try? JSONDecoder().decode(ServerError.self, from: data)
        return ServerResponseError(status: 0, code: response?.error.code ?? "UNKNOWN", message: response?.error.message ?? fallback)
    }


    private func rotateKey() {
        keyID = nil
        UserDefaults.standard.removeObject(forKey: defaultsKey)
        UserDefaults.standard.removeObject(forKey: registeredDefaultsKey)
    }
}

private struct ChallengeRequest: Encodable { let purpose: ChallengePurpose; let keyID: String }
private struct AppAttestRegistration: Encodable { let keyID: String; let attestationObject: String; let challengeToken: String }
private struct AppAttestRegistrationResponse: Decodable { let registered: Bool }

/// The only origin a production networking response may come from. Parsing is
/// intentionally strict so a malformed build setting cannot silently weaken
/// transport security. DEBUG permits only literal loopback HTTP for local work.
struct OnlineServiceOrigin: Equatable {
    let scheme: String
    let host: String
    let port: Int

    init?(baseURL: URL) {
        guard let components = URLComponents(url: baseURL, resolvingAgainstBaseURL: false),
              let rawScheme = components.scheme,
              let rawHost = components.host,
              components.user == nil,
              components.password == nil,
              components.query == nil,
              components.fragment == nil,
              components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/" else { return nil }

        let scheme = rawScheme.lowercased()
        let host = Self.normalizedHost(rawHost)
        guard !host.isEmpty else { return nil }
        #if DEBUG
        let transportAllowed = scheme == "https" || (scheme == "http" && Self.isLiteralLoopback(host))
        #else
        let transportAllowed = scheme == "https"
        #endif
        guard transportAllowed else { return nil }
        let port = components.port ?? Self.defaultPort(for: scheme)
        guard (1...65_535).contains(port) else { return nil }
        self.scheme = scheme
        self.host = host
        self.port = port
    }

    func matches(_ url: URL?) -> Bool {
        guard let url,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              components.user == nil,
              components.password == nil,
              let candidateScheme = components.scheme?.lowercased(),
              let rawCandidateHost = components.host else { return false }
        let candidateHost = Self.normalizedHost(rawCandidateHost)
        let candidatePort = components.port ?? Self.defaultPort(for: candidateScheme)
        return candidateScheme == scheme && candidateHost == host && candidatePort == port
    }

    private static func defaultPort(for scheme: String) -> Int {
        scheme == "https" ? 443 : 80
    }

    private static func normalizedHost(_ host: String) -> String {
        let lowered = host.lowercased()
        guard lowered.hasPrefix("["), lowered.hasSuffix("]") else { return lowered }
        return String(lowered.dropFirst().dropLast())
    }

    private static func isLiteralLoopback(_ host: String) -> Bool {
        host == "localhost" || host == "127.0.0.1" || host == "::1"
    }
}

final class RejectingRedirectSessionDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

private func decodeBase64URL(_ value: String) -> Data? {
    var base64 = value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
    let remainder = base64.count % 4
    if remainder != 0 { base64 += String(repeating: "=", count: 4 - remainder) }
    return Data(base64Encoded: base64)
}

private func base64URL(_ data: Data) -> String {
    data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

private func parseISO8601Date(_ value: String) -> Date? {
    let fractional = ISO8601DateFormatter()
    fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    if let date = fractional.date(from: value) { return date }
    return ISO8601DateFormatter().date(from: value)
}

private func boundedURLSessionData(session: URLSession, request: URLRequest, maximumBytes: Int) async throws -> (Data, URLResponse) {
    try OnlineOperationCheckpoint.requireActive()
    let (bytes, response) = try await session.bytes(for: request)
    try OnlineOperationCheckpoint.requireActive()
    var data = Data(); data.reserveCapacity(min(maximumBytes, 16_384))
    for try await byte in bytes {
        guard data.count < maximumBytes else { throw PipelineError.server("The online service response was too large.") }
        data.append(byte)
    }
    try OnlineOperationCheckpoint.requireActive()
    return (data, response)
}
