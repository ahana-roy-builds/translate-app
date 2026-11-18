import Combine
import Foundation
import StoreKit

struct ProEntitlement: Equatable, Sendable {
    enum State: String, Equatable, Sendable { case inactive, active, gracePeriod }
    var state: State = .inactive
    var productID: String?
    var signedTransaction: String?
    var expirationDate: Date?
    var isTrial = false
    var willAutoRenew: Bool?
    var hasPro: Bool { state == .active || state == .gracePeriod }
}

@MainActor
protocol SubscriptionEntitlementObserving: AnyObject {
    var entitlementUpdates: AnyPublisher<ProEntitlement, Never> { get }
}

@MainActor
final class SubscriptionManager: ObservableObject, SubscriptionEntitlementObserving {
    enum LoadingState: Equatable { case idle, loadingProducts, purchasing(String), restoring }

    static var productIDs: [String] {
        ["STOREKIT_MONTHLY_PRODUCT_ID", "STOREKIT_ANNUAL_PRODUCT_ID"].compactMap {
            guard let value = Bundle.main.object(forInfoDictionaryKey: $0) as? String,
                  !value.isEmpty, !value.contains("REPLACE") else { return nil }
            return value
        }
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlement = ProEntitlement()
    @Published private(set) var loadingState: LoadingState = .idle
    @Published var errorMessage: String?
    @Published private(set) var eligibleIntroductoryProductIDs: Set<String> = []
    @Published private(set) var hasCheckedEntitlements = false

    var hasPro: Bool { entitlement.hasPro }
    var entitlementJWS: String? { entitlement.signedTransaction }
    var entitlementUpdates: AnyPublisher<ProEntitlement, Never> { $entitlement.eraseToAnyPublisher() }
    let isEnabled: Bool

    private var updatesTask: Task<Void, Never>?
    private var storefrontTask: Task<Void, Never>?
    private let operationGate = SubscriptionOperationGate()
    private var operationGeneration = 0
    private let productLoader: ([String]) async throws -> [Product]
    private let entitlementLoader: (() async -> ProEntitlement)?

    init(isEnabled: Bool = false,
         productLoader: @escaping ([String]) async throws -> [Product] = { try await Product.products(for: $0) },
         entitlementLoader: (() async -> ProEntitlement)? = nil) {
        self.isEnabled = isEnabled
        self.productLoader = productLoader
        self.entitlementLoader = entitlementLoader
        guard isEnabled else { return }

        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                await self?.refresh()
                if case let .verified(transaction) = update { await transaction.finish() }
            }
        }
        storefrontTask = Task { [weak self] in
            for await _ in Storefront.updates { await self?.refresh() }
        }
        Task { await refresh() }
    }

    deinit { updatesTask?.cancel(); storefrontTask?.cancel() }

    func refresh() async {
        guard isEnabled else {
            resetDisabledState()
            return
        }
        await operationGate.acquire()
        operationGeneration += 1
        let generation = operationGeneration
        defer { Task { await operationGate.release() } }
        errorMessage = nil
        loadingState = .loadingProducts
        // The local verified transaction sequence does not depend on fetching
        // product prices. An offline pricing failure must not lock out a buyer.
        entitlement = await readEntitlement()
        hasCheckedEntitlements = true
        do {
            products = try await productLoader(Self.productIDs).sorted { $0.price < $1.price }
            var eligible: Set<String> = []
            for product in products {
                if let info = product.subscription, info.introductoryOffer != nil,
                   await info.isEligibleForIntroOffer { eligible.insert(product.id) }
            }
            eligibleIntroductoryProductIDs = eligible
        } catch {
            guard generation == operationGeneration else { return }
            errorMessage = "The App Store could not load pricing. Existing verified access is still available until its expiration. Reconnect to purchase or check a renewal."
        }
        loadingState = .idle
    }

    func purchase(_ product: Product) async {
        guard isEnabled else {
            resetDisabledState()
            return
        }
        await operationGate.acquire()
        operationGeneration += 1
        let generation = operationGeneration
        defer { Task { await operationGate.release() } }
        errorMessage = nil
        loadingState = .purchasing(product.id)
        defer { loadingState = .idle }
        do {
            switch try await product.purchase() {
            case let .success(result):
                guard case let .verified(transaction) = result else {
                    errorMessage = "The App Store transaction could not be verified."
                    entitlement = ProEntitlement()
                    return
                }
                let updated = await readEntitlement()
                guard generation == operationGeneration else { return }
                entitlement = updated
                hasCheckedEntitlements = true
                await transaction.finish()
            case .pending: errorMessage = "Purchase approval is pending."
            case .userCancelled: break
            @unknown default: errorMessage = "The App Store returned an unknown purchase state."
            }
        } catch {
            guard generation == operationGeneration else { return }
            entitlement = await readEntitlement()
            errorMessage = error.localizedDescription
        }
    }

    func restore() async {
        guard isEnabled else {
            resetDisabledState()
            return
        }
        await operationGate.acquire()
        operationGeneration += 1
        let generation = operationGeneration
        defer { Task { await operationGate.release() } }
        errorMessage = nil
        loadingState = .restoring
        defer { loadingState = .idle }
        do {
            try await AppStore.sync()
            let updated = await readEntitlement()
            guard generation == operationGeneration else { return }
            entitlement = updated
            hasCheckedEntitlements = true
        } catch {
            guard generation == operationGeneration else { return }
            entitlement = await readEntitlement()
            errorMessage = error.localizedDescription
        }
    }

    private func readEntitlement() async -> ProEntitlement {
        if let entitlementLoader { return await entitlementLoader() }
        return await currentEntitlement()
    }

    private func currentEntitlement() async -> ProEntitlement {
        var candidates: [ProEntitlement] = []
        var groups: Set<String> = []
        let now = Date()
        for await result in Transaction.currentEntitlements {
            guard case let .verified(transaction) = result,
                  Self.productIDs.contains(transaction.productID),
                  transaction.revocationDate == nil,
                  transaction.ownershipType != .familyShared else { continue }
            if let group = transaction.subscriptionGroupID { groups.insert(group) }
            if let expiry = transaction.expirationDate, expiry > now {
                candidates.append(ProEntitlement(
                    state: .active, productID: transaction.productID,
                    signedTransaction: result.jwsRepresentation,
                    expirationDate: expiry,
                    isTrial: transaction.offer?.paymentMode == .freeTrial
                ))
            } else if entitlement.state == .gracePeriod,
                      entitlement.signedTransaction == result.jwsRepresentation,
                      let graceEnd = entitlement.expirationDate, graceEnd > now {
                // Preserve already verified grace only while the same current
                // transaction is still present and its known grace hasn't ended.
                candidates.append(entitlement)
            }
        }
        // Status supplies the signed renewal deadline when a transaction's
        // paid period has ended but Apple has granted billing grace.
        for group in groups {
            guard let statuses = try? await Product.SubscriptionInfo.status(for: group) else { continue }
            for status in statuses {
                guard case let .verified(transaction) = status.transaction,
                      Self.productIDs.contains(transaction.productID) else { continue }
                candidates.removeAll { $0.productID == transaction.productID }
                guard status.state == .subscribed || status.state == .inGracePeriod,
                      case let .verified(renewal) = status.renewalInfo,
                      transaction.revocationDate == nil,
                      transaction.ownershipType != .familyShared,
                      Self.productIDs.contains(transaction.productID) else { continue }
                let expiration = status.state == .inGracePeriod
                    ? renewal.gracePeriodExpirationDate : transaction.expirationDate
                guard let expiration, expiration > now else { continue }
                candidates.append(ProEntitlement(
                    state: status.state == .inGracePeriod ? .gracePeriod : .active,
                    productID: transaction.productID,
                    signedTransaction: status.transaction.jwsRepresentation,
                    expirationDate: expiration,
                    isTrial: transaction.offer?.paymentMode == .freeTrial,
                    willAutoRenew: renewal.willAutoRenew
                ))
            }
        }
        return candidates.max { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) } ?? ProEntitlement()
    }

    private func resetDisabledState() {
        products = []
        eligibleIntroductoryProductIDs = []
        hasCheckedEntitlements = true
        entitlement = ProEntitlement()
        loadingState = .idle
        errorMessage = nil
    }
}

private actor SubscriptionOperationGate {
    private var locked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func acquire() async {
        if !locked { locked = true; return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func release() {
        if waiters.isEmpty { locked = false }
        else { waiters.removeFirst().resume() }
    }
}
