import StoreKit
@preconcurrency import StoreKitTest
import XCTest
@testable import LocalLingo

@MainActor
final class StoreKitCommerceTests: XCTestCase {
    func testMonthlyTrialPurchaseSurvivesPriceLoadingFailureAndExpires() async throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "LocalLingo", withExtension: "storekit"))
        let session = try SKTestSession(contentsOf: url)
        session.resetToDefaultState()
        session.clearTransactions()
        session.disableDialogs = true
        session.timeRate = .realTime
        defer { session.clearTransactions(); session.resetToDefaultState() }

        // Some simulator/Xcode combinations cannot connect to the StoreKit
        // testing service (SKInternalErrorDomain 3). Verify that a test control
        // round-trips before treating absent products as an app failure.
        do {
            try await session.setSimulatedError(.generic(.notAvailableInStorefront), forAPI: .loadProducts)
            guard await session.simulatedError(forAPI: .loadProducts) != nil else {
                throw XCTSkip("The simulator StoreKitTest service cannot persist test controls. Run this integration test from an Xcode StoreKit debug session.")
            }
            try await session.setSimulatedError(nil, forAPI: .loadProducts)
        } catch let error as NSError where error.domain == "SKInternalErrorDomain" && error.code == 3 {
            throw XCTSkip("StoreKitTest service is unavailable: SKInternalErrorDomain 3.")
        }

        let subscription = SubscriptionManager(isEnabled: true)
        await subscription.refresh()
        let product = try XCTUnwrap(subscription.products.first)
        XCTAssertEqual(subscription.products.count, 1)
        XCTAssertEqual(product.price, Decimal(string: "4.99"))
        XCTAssertEqual(product.subscription?.introductoryOffer?.period.value, 2)
        XCTAssertEqual(product.subscription?.introductoryOffer?.period.unit, .week)
        XCTAssertTrue(subscription.eligibleIntroductoryProductIDs.contains(product.id))
        await subscription.purchase(product)
        XCTAssertTrue(subscription.hasPro)
        XCTAssertTrue(subscription.entitlement.isTrial)
        XCTAssertNotNil(subscription.entitlementJWS)

        try await session.setSimulatedError(.generic(.networkError(URLError(.notConnectedToInternet))), forAPI: .loadProducts)
        await subscription.refresh()
        XCTAssertNotNil(subscription.errorMessage)
        XCTAssertTrue(subscription.hasPro, "Price loading failure erased an active verified transaction")

        try await session.setSimulatedError(nil, forAPI: .loadProducts)
        try session.expireSubscription(productIdentifier: product.id)
        await subscription.refresh()
        XCTAssertFalse(subscription.hasPro)
    }
}
