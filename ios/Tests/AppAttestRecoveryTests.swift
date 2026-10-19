import XCTest
@testable import LocalLingo

final class AppAttestRecoveryTests: XCTestCase {
    func testBackendKeyLossReregistersWithoutRotation() {
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "APP_ATTEST_KEY_NOT_REGISTERED"), .reregister)
    }

    func testCounterOrCredentialFailureRotatesKey() {
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "INVALID_APP_ATTEST_COUNTER"), .rotateKey)
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: nil, deviceKeyInvalid: true), .rotateKey)
    }

    func testExpiredSessionRetriesWithoutTouchingRegistration() {
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "INVALID_SESSION"), .retrySession)
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "CHALLENGE_EXPIRED"), .retrySession)
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "CHALLENGE_REPLAYED"), .retrySession)
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "REPLAYED"), .retrySession)
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "INVALID_CHALLENGE"), .retrySession)
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "INVALID_ASSERTION_COUNTER"), .retrySession)
    }

    func testNonSecurityErrorsAreNeverRetried() {
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "QUOTA_EXCEEDED"), .none)
        XCTAssertEqual(AppAttestRecoveryPolicy.action(serverCode: "SUBSCRIPTION_REQUIRED"), .none)
    }

    func testLostRegistrationResponseIsReconciledOnNextAttempt() {
        XCTAssertTrue(AppAttestRecoveryPolicy.registrationWasAlreadyCompleted(serverCode: "KEY_ALREADY_REGISTERED"))
        XCTAssertFalse(AppAttestRecoveryPolicy.registrationWasAlreadyCompleted(serverCode: "INVALID_APP_ATTEST"))
    }

    @MainActor
    func testCanceledOperationCannotPassPreSendCheckpoint() async {
        let task = Task { () -> Bool in
            do { try await Task<Never, Never>.sleep(nanoseconds: 60_000_000_000) }
            catch { /* Continue to the explicit dispatch checkpoint. */ }
            do {
                try OnlineOperationCheckpoint.requireActive()
                return false
            } catch is CancellationError {
                return true
            } catch {
                return false
            }
        }

        task.cancel()
        let wasCanceledAtCheckpoint = await task.value
        XCTAssertTrue(wasCanceledAtCheckpoint)
    }
}
