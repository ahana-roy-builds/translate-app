import Foundation

enum AppRuntimeEnvironment: String, Codable, Equatable, Sendable {
    case development
    case privateBeta = "private-beta"
    case staging
    case testflight
    case production
}

struct AppBuildIdentity: Equatable, Sendable {
    static let maximumReleaseBuildIDBytes = 128

    let releaseBuildID: String
    let environment: AppRuntimeEnvironment

    init?(releaseBuildID: String, environment: String) {
        guard let runtimeEnvironment = AppRuntimeEnvironment(rawValue: environment),
              Self.isValidReleaseBuildID(releaseBuildID),
              runtimeEnvironment == .development || releaseBuildID.utf8.count >= 16,
              !Self.containsPlaceholder(releaseBuildID) else { return nil }
        self.releaseBuildID = releaseBuildID
        self.environment = runtimeEnvironment
    }

    init?(bundle: Bundle) {
        guard let releaseBuildID = bundle.object(forInfoDictionaryKey: "RELEASE_BUILD_ID") as? String,
              let environment = bundle.object(forInfoDictionaryKey: "APP_RUNTIME_ENVIRONMENT") as? String else { return nil }
        self.init(releaseBuildID: releaseBuildID, environment: environment)
    }

    private static func isValidReleaseBuildID(_ value: String) -> Bool {
        !value.isEmpty
            && value.utf8.count <= maximumReleaseBuildIDBytes
            && value.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
    }

    private static func containsPlaceholder(_ value: String) -> Bool {
        let lowered = value.lowercased()
        return ["replace", "placeholder", "todo", "tbd", "example"].contains { lowered.contains($0) }
    }
}

struct BackendBuildIdentity: Decodable, Equatable, Sendable {
    let releaseBuildID: String
    let ociDigest: String
    let environment: String
    let revision: String
    let assurance: String
}

enum BuildIdentityRequestHeaders {
    static let releaseBuildID = "X-LocalLingo-Release-Build-ID"
    static let backendOCIDigest = "X-LocalLingo-Backend-OCI-Digest"
    static let runtimeEnvironment = "X-LocalLingo-Runtime-Environment"
    static let cloudRunRevision = "X-LocalLingo-Cloud-Run-Revision"

    /// Availability is the unauthenticated routing preflight. It carries the
    /// app-owned fields only; protected requests are bound to all four values
    /// returned by the accepted availability response.
    static func applyPreflight(_ app: AppBuildIdentity, to request: inout URLRequest) {
        request.setValue(app.releaseBuildID, forHTTPHeaderField: releaseBuildID)
        request.setValue(app.environment.rawValue, forHTTPHeaderField: runtimeEnvironment)
    }

    static func applyBound(
        app: AppBuildIdentity,
        backend: BackendBuildIdentity,
        to request: inout URLRequest
    ) throws {
        guard BackendBuildIdentityPolicy.matches(backend, expected: app) else {
            throw PipelineError.server("Online Quality is unavailable because no current matching service release identity is available.")
        }
        request.setValue(backend.releaseBuildID, forHTTPHeaderField: releaseBuildID)
        request.setValue(backend.ociDigest, forHTTPHeaderField: backendOCIDigest)
        request.setValue(backend.environment, forHTTPHeaderField: runtimeEnvironment)
        request.setValue(backend.revision, forHTTPHeaderField: cloudRunRevision)
    }
}

enum BackendBuildIdentityPolicy {
    static func isStructurallyValid(_ identity: BackendBuildIdentity) -> Bool {
        identity.releaseBuildID.utf8.count <= AppBuildIdentity.maximumReleaseBuildIDBytes
            && identity.releaseBuildID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil
            && identity.ociDigest.range(of: #"^sha256:[0-9a-f]{64}$"#, options: .regularExpression) != nil
            && AppRuntimeEnvironment(rawValue: identity.environment) != nil
            && identity.revision.range(of: #"^[a-z][a-z0-9-]{0,62}$"#, options: .regularExpression) != nil
            && identity.assurance == "self-reported-diagnostic"
    }

    static func matches(_ backend: BackendBuildIdentity, expected app: AppBuildIdentity) -> Bool {
        isStructurallyValid(backend)
            && backend.releaseBuildID == app.releaseBuildID
            && backend.environment == app.environment.rawValue
    }
}
