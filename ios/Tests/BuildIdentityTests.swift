import Foundation
import XCTest
@testable import LocalLingo

final class BuildIdentityTests: XCTestCase {
    func testAppIdentityAcceptsBoundedReviewedValues() throws {
        let identity = try XCTUnwrap(AppBuildIdentity(releaseBuildID: "candidate-2026.07.12-1", environment: "testflight"))
        XCTAssertEqual(identity.releaseBuildID, "candidate-2026.07.12-1")
        XCTAssertEqual(identity.environment, .testflight)
    }

    func testAppIdentityAcceptsPrivateBetaCandidate() throws {
        let identity = try XCTUnwrap(
            AppBuildIdentity(
                releaseBuildID: "private-beta-build-00000001",
                environment: "private-beta"
            )
        )

        XCTAssertEqual(identity.releaseBuildID, "private-beta-build-00000001")
        XCTAssertEqual(identity.environment, .privateBeta)
    }

    func testAppIdentityRejectsPlaceholderInvalidAndOversizedValues() {
        XCTAssertNil(AppBuildIdentity(releaseBuildID: "REPLACE_RELEASE_BUILD_ID", environment: "production"))
        XCTAssertNil(AppBuildIdentity(releaseBuildID: "todo-candidate", environment: "production"))
        XCTAssertNil(AppBuildIdentity(releaseBuildID: "bad value", environment: "production"))
        XCTAssertNil(AppBuildIdentity(releaseBuildID: "too-short", environment: "production"))
        XCTAssertNil(AppBuildIdentity(releaseBuildID: String(repeating: "a", count: 129), environment: "production"))
        XCTAssertNil(AppBuildIdentity(releaseBuildID: "candidate", environment: "test"))
        XCTAssertNotNil(AppBuildIdentity(releaseBuildID: "development", environment: "development"))
    }

    func testAvailabilityDecodesAndMatchesExactCandidateAndEnvironment() throws {
        let data = Data(#"{"available":true,"buildIdentity":{"releaseBuildID":"candidate-release-1","ociDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","environment":"production","revision":"locallingo-api-00001","assurance":"self-reported-diagnostic"}}"#.utf8)
        let response = try JSONDecoder().decode(AvailabilityResponse.self, from: data)
        let app = try XCTUnwrap(AppBuildIdentity(releaseBuildID: "candidate-release-1", environment: "production"))

        XCTAssertTrue(response.available)
        XCTAssertTrue(BackendBuildIdentityPolicy.isStructurallyValid(response.buildIdentity))
        XCTAssertTrue(BackendBuildIdentityPolicy.matches(response.buildIdentity, expected: app))
    }

    func testAvailabilityRequiresAllBuildIdentityFields() {
        let missingRevision = Data(#"{"available":true,"buildIdentity":{"releaseBuildID":"candidate-release-1","ociDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","environment":"production"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AvailabilityResponse.self, from: missingRevision))

        let missingAssurance = Data(#"{"available":true,"buildIdentity":{"releaseBuildID":"candidate-release-1","ociDigest":"sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","environment":"production","revision":"locallingo-api-00001"}}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(AvailabilityResponse.self, from: missingAssurance))
    }

    func testCandidateOrEnvironmentMismatchFailsClosed() throws {
        let app = try XCTUnwrap(AppBuildIdentity(releaseBuildID: "candidate-release-1", environment: "production"))
        let wrongCandidate = BackendBuildIdentity(
            releaseBuildID: "candidate-release-2",
            ociDigest: "sha256:" + String(repeating: "b", count: 64),
            environment: "production",
            revision: "locallingo-api-00001",
            assurance: "self-reported-diagnostic"
        )
        let wrongEnvironment = BackendBuildIdentity(
            releaseBuildID: "candidate-release-1",
            ociDigest: "sha256:" + String(repeating: "b", count: 64),
            environment: "testflight",
            revision: "locallingo-api-00001",
            assurance: "self-reported-diagnostic"
        )

        XCTAssertFalse(BackendBuildIdentityPolicy.matches(wrongCandidate, expected: app))
        XCTAssertFalse(BackendBuildIdentityPolicy.matches(wrongEnvironment, expected: app))
    }

    func testMalformedDigestAndRevisionFailStructuralValidation() {
        let malformed = BackendBuildIdentity(
            releaseBuildID: "candidate-release-1",
            ociDigest: "sha256:not-a-digest",
            environment: "production",
            revision: "UPPERCASE",
            assurance: "self-reported-diagnostic"
        )
        XCTAssertFalse(BackendBuildIdentityPolicy.isStructurallyValid(malformed))
    }

    func testAvailabilityAssuranceMustMarkIdentityAsSelfReportedDiagnostic() {
        let identity = BackendBuildIdentity(
            releaseBuildID: "candidate-release-1",
            ociDigest: "sha256:" + String(repeating: "a", count: 64),
            environment: "production",
            revision: "locallingo-api-00001",
            assurance: "trusted"
        )

        XCTAssertFalse(BackendBuildIdentityPolicy.isStructurallyValid(identity))
    }

    func testPreflightAndBoundRequestsCarryExactBoundedIdentityHeaders() throws {
        let app = try XCTUnwrap(AppBuildIdentity(releaseBuildID: "candidate-release-1", environment: "production"))
        let backend = BackendBuildIdentity(
            releaseBuildID: app.releaseBuildID,
            ociDigest: "sha256:" + String(repeating: "a", count: 64),
            environment: app.environment.rawValue,
            revision: "locallingo-api-00001",
            assurance: "self-reported-diagnostic"
        )
        var preflight = URLRequest(url: URL(string: "https://api.example.com/v2/availability")!)
        BuildIdentityRequestHeaders.applyPreflight(app, to: &preflight)
        XCTAssertEqual(preflight.value(forHTTPHeaderField: "X-LocalLingo-Release-Build-ID"), app.releaseBuildID)
        XCTAssertEqual(preflight.value(forHTTPHeaderField: "X-LocalLingo-Runtime-Environment"), "production")
        XCTAssertNil(preflight.value(forHTTPHeaderField: "X-LocalLingo-Backend-OCI-Digest"))

        var protected = URLRequest(url: URL(string: "https://api.example.com/v2/session")!)
        try BuildIdentityRequestHeaders.applyBound(app: app, backend: backend, to: &protected)
        XCTAssertEqual(protected.value(forHTTPHeaderField: "X-LocalLingo-Release-Build-ID"), app.releaseBuildID)
        XCTAssertEqual(protected.value(forHTTPHeaderField: "X-LocalLingo-Backend-OCI-Digest"), backend.ociDigest)
        XCTAssertEqual(protected.value(forHTTPHeaderField: "X-LocalLingo-Runtime-Environment"), backend.environment)
        XCTAssertEqual(protected.value(forHTTPHeaderField: "X-LocalLingo-Cloud-Run-Revision"), backend.revision)
        XCTAssertLessThanOrEqual(app.releaseBuildID.utf8.count, AppBuildIdentity.maximumReleaseBuildIDBytes)
        XCTAssertEqual(backend.ociDigest.utf8.count, 71)
        XCTAssertLessThanOrEqual(backend.revision.utf8.count, 63)
    }

    func testBoundHeadersRejectAnIdentityFromAnotherDeployment() throws {
        let app = try XCTUnwrap(AppBuildIdentity(releaseBuildID: "candidate-release-1", environment: "production"))
        let backend = BackendBuildIdentity(
            releaseBuildID: "candidate-release-2",
            ociDigest: "sha256:" + String(repeating: "a", count: 64),
            environment: "production",
            revision: "locallingo-api-00001",
            assurance: "self-reported-diagnostic"
        )
        var request = URLRequest(url: URL(string: "https://api.example.com/v2/session")!)

        XCTAssertThrowsError(try BuildIdentityRequestHeaders.applyBound(app: app, backend: backend, to: &request))
    }
}
