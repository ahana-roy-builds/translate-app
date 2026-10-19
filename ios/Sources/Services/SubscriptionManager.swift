import Combine
import Foundation
import StoreKit

struct ProEntitlement: Equatable, Sendable {
    enum State: String, Equatable, Sendable { case inactive, active, gracePeriod }
    var state: State = .inactive
    var productID: String?
    var signedTransaction: String?
    var expirationDate: Date?
    var hasPro: Bool { state == .active || state == .gracePeriod }
}

@MainActor
final class SubscriptionManager: ObservableObject {
    enum LoadingState: Equatable { case idle, loadingProducts, purchasing(String), restoring }

    static var productIDs: [String] {
        let monthly = Bundle.main.object(forInfoDictionaryKey: "STOREKIT_MONTHLY_PRODUCT_ID") as? String ?? "pro.monthly.499"
        let annual = Bundle.main.object(forInfoDictionaryKey: "STOREKIT_ANNUAL_PRODUCT_ID") as? String ?? "pro.annual.2999"
        return [monthly, annual]
    }

    @Published private(set) var products: [Product] = []
    @Published private(set) var entitlement = ProEntitlement()
    @Published private(set) var loadingState: LoadingState = .idle
    @Published var errorMessage: String?

    var hasPro: Bool { entitlement.hasPro }
    var entitlementJWS: String? { entitlement.signedTransaction }
    let isEnabled: Bool

    private var updatesTask: Task<Void, Never>?
    private var storefrontTask: Task<Void, Never>?
    private let operationGate = SubscriptionOperationGate()
    private var operationGeneration = 0

    init(isEnabled: Bool = false) {
        self.isEnabled = isEnabled
        guard isEnabled else { return }

        updatesTask = Task { [weak self] in
            for await update in Transaction.updates {
                if case let .verified(transaction) = update { await transaction.finish() }
                await self?.refresh()
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
        do {
            let loadedProducts = try await Product.products(for: Self.productIDs).sorted { $0.price < $1.price }
            let loadedEntitlement = try await currentEntitlement(products: loadedProducts)
            guard generation == operationGeneration else { return }
            products = loadedProducts
            entitlement = loadedEntitlement
        } catch {
            guard generation == operationGeneration else { return }
            // Never preserve a previous positive entitlement after refresh fails.
            entitlement = ProEntitlement()
            errorMessage = error.localizedDescription
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
                await transaction.finish()
                let updated = try await currentEntitlement(products: products)
                guard generation == operationGeneration else { return }
                entitlement = updated
            case .pending: errorMessage = "Purchase approval is pending."
            case .userCancelled: break
            @unknown default: errorMessage = "The App Store returned an unknown purchase state."
            }
        } catch {
            guard generation == operationGeneration else { return }
            entitlement = ProEntitlement()
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
            let updated = try await currentEntitlement(products: products)
            guard generation == operationGeneration else { return }
            entitlement = updated
        } catch {
            guard generation == operationGeneration else { return }
            entitlement = ProEntitlement()
            errorMessage = error.localizedDescription
        }
    }

    private func currentEntitlement(products: [Product]) async throws -> ProEntitlement {
        var candidates: [ProEntitlement] = []
        for product in products {
            guard Self.productIDs.contains(product.id), let subscription = product.subscription else { continue }
            for status in try await subscription.status {
                guard status.state == .subscribed || status.state == .inGracePeriod,
                      case let .verified(transaction) = status.transaction,
                      transaction.revocationDate == nil,
                      transaction.ownershipType != .familyShared,
                      Self.productIDs.contains(transaction.productID) else { continue }
                if status.state == .subscribed,
                   let expiration = transaction.expirationDate,
                   expiration <= Date() { continue }
                candidates.append(ProEntitlement(
                    state: status.state == .inGracePeriod ? .gracePeriod : .active,
                    productID: transaction.productID,
                    signedTransaction: status.transaction.jwsRepresentation,
                    expirationDate: transaction.expirationDate
                ))
            }
        }
        return candidates.max { ($0.expirationDate ?? .distantPast) < ($1.expirationDate ?? .distantPast) } ?? ProEntitlement()
    }

    private func resetDisabledState() {
        products = []
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
