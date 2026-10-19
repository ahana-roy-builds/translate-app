import Foundation
import XCTest
@testable import LocalLingo

final class AppAttestDigestTests: XCTestCase {
    private let fixtureDigest = "905db59ebea299d5d3c76c201c146d420c0735eba7af74ea8ab0d0c32350c4b6"

    private func digest(
        method: String = "POST",
        path: String = "/v2/translate-text",
        challenge: String = "fixture-challenge",
        keyID: String = "fixture-key-id",
        sessionToken: String? = "fixture-session-token",
        sourceLocale: String? = "en-US",
        targetLocale: String? = "es-ES",
        releaseBuildID: String = "candidate-release-1",
        backendOCIDigest: String = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
        runtimeEnvironment: String = "production",
        cloudRunRevision: String = "locallingo-api-00001",
        body: Data = Data(#"{"sourceLocale":"en-US","targetLocale":"es-ES","text":"Where is the station?"}"#.utf8)
    ) -> Data {
        AppAttestDigest.make(
            method: method,
            path: path,
            challenge: challenge,
            keyID: keyID,
            sessionToken: sessionToken,
            sourceLocale: sourceLocale,
            targetLocale: targetLocale,
            releaseBuildID: releaseBuildID,
            backendOCIDigest: backendOCIDigest,
            runtimeEnvironment: runtimeEnvironment,
            cloudRunRevision: cloudRunRevision,
            body: body
        )
    }

    func testCanonicalV3DigestMatchesBackendFixture() {
        XCTAssertEqual(digest().hex, fixtureDigest)
    }

    func testEveryCanonicalRequestFieldIncludingBuildIdentityIsBound() {
        let body = Data("same".utf8)
        let baseline = digest(path: "/v2/translate-turn", targetLocale: "ja-JP", body: body)

        XCTAssertNotEqual(baseline, digest(method: "PUT", path: "/v2/translate-turn", targetLocale: "ja-JP", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-text", targetLocale: "ja-JP", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", challenge: "other", targetLocale: "ja-JP", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", keyID: "other-key", targetLocale: "ja-JP", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", sessionToken: "other", targetLocale: "ja-JP", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", sourceLocale: "es-ES", targetLocale: "ja-JP", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", targetLocale: "es-ES", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", targetLocale: "ja-JP", releaseBuildID: "candidate-release-2", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", targetLocale: "ja-JP", backendOCIDigest: "sha256:" + String(repeating: "b", count: 64), body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", targetLocale: "ja-JP", runtimeEnvironment: "testflight", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", targetLocale: "ja-JP", cloudRunRevision: "locallingo-api-00002", body: body))
        XCTAssertNotEqual(baseline, digest(path: "/v2/translate-turn", targetLocale: "ja-JP", body: Data("changed".utf8)))
    }

    func testRegistrationChallengeIsDecodedThenHashedExactlyOnce() {
        let digest = AppAttestChallengeHash.make(encodedChallenge: "AAECAwQFBgcICQoLDA0ODxAREhMUFRYXGBkaGxwdHh8")
        XCTAssertEqual(digest?.hex, "630dcd2966c4336691125448bbb25b4ff412a49c732db2c8abc1b8581bd710dd")
    }

    func testDeviceReplacementProofIsSessionlessAndPathBound() {
        let body = Data(#"{"signedTransaction":"fixture-jws"}"#.utf8)
        let replacement = digest(path: "/v2/devices/replace-oldest", challenge: "challenge", keyID: "key", sessionToken: nil, sourceLocale: nil, targetLocale: nil, body: body)
        let bearerVariant = digest(path: "/v2/devices/replace-oldest", challenge: "challenge", keyID: "key", sessionToken: "unexpected-bearer", sourceLocale: nil, targetLocale: nil, body: body)
        let sessionPath = digest(path: "/v2/session", challenge: "challenge", keyID: "key", sessionToken: nil, sourceLocale: nil, targetLocale: nil, body: body)

        XCTAssertNotEqual(replacement, bearerVariant)
        XCTAssertNotEqual(replacement, sessionPath)
    }
}

private extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
}
