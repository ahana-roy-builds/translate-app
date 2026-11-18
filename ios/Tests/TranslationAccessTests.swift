import Combine
import Foundation
import XCTest
@testable import LocalLingo

@MainActor
final class TranslationAccessTests: XCTestCase {
    private final class MemoryStorage: FreeAccessStorage {
        var data: Data?
        var fails = false
        func read() throws -> Data? {
            if fails { throw FreeAccessStorageError.unavailable }
            return data
        }
        func write(_ data: Data) throws {
            if fails { throw FreeAccessStorageError.unavailable }
            self.data = data
        }
    }

    private final class Entitlements: SubscriptionEntitlementObserving {
        let subject = CurrentValueSubject<ProEntitlement, Never>(ProEntitlement())
        var entitlementUpdates: AnyPublisher<ProEntitlement, Never> { subject.eraseToAnyPublisher() }
    }

    func testFreePeriodBeginsOnlyOnActivationAndDoesNotReset() throws {
        let storage = MemoryStorage()
        let subscription = Entitlements()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = TranslationAccessManager(subscription: subscription, isRequired: true,
                                              storage: storage, now: { now }, runsTimer: false)
        XCTAssertEqual(access.state, .notStarted)
        XCTAssertThrowsError(try access.authorizeTranslation())
        XCTAssertNil(storage.data)
        XCTAssertTrue(access.activateFreeAccess())
        let first = try JSONDecoder().decode(FreeAccessRecord.self, from: XCTUnwrap(storage.data))
        now = now.addingTimeInterval(24 * 60 * 60)
        XCTAssertTrue(access.activateFreeAccess())
        let second = try JSONDecoder().decode(FreeAccessRecord.self, from: XCTUnwrap(storage.data))
        XCTAssertEqual(first.startedAt, second.startedAt)
        XCTAssertEqual(first.expiresAt, second.expiresAt)
        XCTAssertEqual(first.expiresAt.timeIntervalSince(first.startedAt), 14 * 24 * 60 * 60)
    }

    func testExactExpiryAndRelaunchDoNotIssueAnotherFreePeriod() throws {
        let storage = MemoryStorage()
        let subscription = Entitlements()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = TranslationAccessManager(subscription: subscription, isRequired: true,
                                              storage: storage, now: { now }, runsTimer: false)
        XCTAssertTrue(access.activateFreeAccess())
        now = now.addingTimeInterval(FreeAccessRecord.duration - 1)
        XCTAssertNoThrow(try access.authorizeTranslation())
        now = now.addingTimeInterval(1)
        XCTAssertThrowsError(try access.authorizeTranslation())
        XCTAssertEqual(access.state, .expired)
        XCTAssertTrue(access.requestsPaywall)
        let restored = TranslationAccessManager(subscription: subscription, isRequired: true,
                                                storage: storage, now: { now }, runsTimer: false)
        XCTAssertEqual(restored.state, .expired)
        XCTAssertTrue(restored.activateFreeAccess()) // May complete onboarding, never extend the pass.
        XCTAssertThrowsError(try restored.authorizeTranslation())
    }

    func testStorageFailureAndCorruptionCannotGenerateNewAccess() {
        let storage = MemoryStorage()
        let subscription = Entitlements()
        storage.fails = true
        let access = TranslationAccessManager(subscription: subscription, isRequired: true,
                                              storage: storage, runsTimer: false)
        XCTAssertFalse(access.activateFreeAccess())
        XCTAssertEqual(access.state, .storageUnavailable)
        storage.fails = false
        storage.data = Data("invalid".utf8)
        XCTAssertFalse(access.activateFreeAccess())
        XCTAssertEqual(access.state, .storageUnavailable)
        XCTAssertEqual(storage.data, Data("invalid".utf8))
    }

    func testClockRollbackIsDetectedAcrossRelaunch() throws {
        let storage = MemoryStorage()
        let subscription = Entitlements()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = TranslationAccessManager(subscription: subscription, isRequired: true,
                                              storage: storage, now: { now }, runsTimer: false)
        XCTAssertTrue(access.activateFreeAccess())
        now = now.addingTimeInterval(2 * 24 * 60 * 60)
        access.refresh()
        now = now.addingTimeInterval(-24 * 60 * 60)
        let restored = TranslationAccessManager(subscription: subscription, isRequired: true,
                                                storage: storage, now: { now }, runsTimer: false)
        XCTAssertEqual(restored.state, .clockChanged)
        XCTAssertThrowsError(try restored.authorizeTranslation())
        now = now.addingTimeInterval(24 * 60 * 60)
        restored.refresh()
        XCTAssertTrue(restored.state.allowsTranslation)
    }

    func testPaidAndGraceAccessUseTheirDeadlinesWithoutChangingFreeAccess() throws {
        let storage = MemoryStorage()
        let subscription = Entitlements()
        var now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = TranslationAccessManager(subscription: subscription, isRequired: true,
                                              storage: storage, now: { now }, runsTimer: false)
        XCTAssertTrue(access.activateFreeAccess())
        now = now.addingTimeInterval(FreeAccessRecord.duration)
        let deadline = now.addingTimeInterval(60)
        subscription.subject.send(ProEntitlement(state: .active, expirationDate: deadline, isTrial: true))
        XCTAssertEqual(access.state, .subscribed(until: deadline, isTrial: true))
        XCTAssertNoThrow(try access.authorizeTranslation())
        subscription.subject.send(ProEntitlement(state: .gracePeriod, expirationDate: deadline))
        XCTAssertEqual(access.state, .billingGrace(until: deadline))
        now = deadline
        XCTAssertThrowsError(try access.authorizeTranslation())
        subscription.subject.send(ProEntitlement())
        XCTAssertEqual(access.state, .expired)
    }

    func testVerifiedPaidAccessDoesNotDependOnFreePassStorage() throws {
        let storage = MemoryStorage()
        storage.fails = true
        let subscription = Entitlements()
        let now = Date()
        subscription.subject.send(ProEntitlement(state: .active, expirationDate: now.addingTimeInterval(3600)))
        let access = TranslationAccessManager(subscription: subscription, isRequired: true,
                                              storage: storage, now: { now }, runsTimer: false)
        XCTAssertNoThrow(try access.authorizeTranslation())
    }

    func testDisabledEnforcementDoesNotTouchKeychain() throws {
        let storage = MemoryStorage()
        storage.fails = true
        let access = TranslationAccessManager(subscription: Entitlements(), isRequired: false,
                                              storage: storage, runsTimer: false)
        XCTAssertEqual(access.state, .unrestricted)
        XCTAssertNoThrow(try access.authorizeTranslation())
    }

    func testPriceLoadingFailurePreservesEntitlementButVerifiedLossRemovesIt() async {
        var verified = ProEntitlement(state: .active, expirationDate: Date().addingTimeInterval(3600))
        let subscription = SubscriptionManager(
            isEnabled: true,
            productLoader: { _ in throw URLError(.notConnectedToInternet) },
            entitlementLoader: { verified }
        )
        await subscription.refresh()
        XCTAssertTrue(subscription.hasPro)
        XCTAssertNotNil(subscription.errorMessage)
        verified = ProEntitlement()
        await subscription.refresh()
        XCTAssertFalse(subscription.hasPro, "A previously paid state must not survive a verified absence of entitlement")
    }
}
