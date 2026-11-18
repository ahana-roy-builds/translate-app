import Combine
import Foundation
import Security

protocol FreeAccessStorage {
    func read() throws -> Data?
    func write(_ data: Data) throws
}

struct KeychainFreeAccessStorage: FreeAccessStorage {
    private var query: [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: "\(Bundle.main.bundleIdentifier ?? "SpeakDuet").free-access",
         kSecAttrAccount as String: "first-use-v1",
         kSecAttrSynchronizable as String: false]
    }

    func read() throws -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw FreeAccessStorageError.unavailable
        }
        return data
    }

    func write(_ data: Data) throws {
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            guard SecItemAdd(item as CFDictionary, nil) == errSecSuccess else {
                throw FreeAccessStorageError.unavailable
            }
        } else if status != errSecSuccess {
            throw FreeAccessStorageError.unavailable
        }
    }
}

enum FreeAccessStorageError: Error { case unavailable, corrupt }

struct FreeAccessRecord: Codable, Equatable, Sendable {
    static let duration: TimeInterval = 14 * 24 * 60 * 60
    let schemaVersion: Int
    let startedAt: Date
    let expiresAt: Date
    var latestObservedDate: Date

    init(startedAt: Date) {
        schemaVersion = 1
        self.startedAt = startedAt
        expiresAt = startedAt.addingTimeInterval(Self.duration)
        latestObservedDate = startedAt
    }

    var isValid: Bool {
        schemaVersion == 1 && startedAt.timeIntervalSince1970.isFinite
            && expiresAt.timeIntervalSince1970.isFinite
            && latestObservedDate.timeIntervalSince1970.isFinite
            && abs(expiresAt.timeIntervalSince(startedAt) - Self.duration) < 1
            && latestObservedDate >= startedAt
    }
}

enum TranslationAccessState: Equatable {
    case unrestricted, notStarted, freeAccess(until: Date)
    case subscribed(until: Date, isTrial: Bool), billingGrace(until: Date)
    case expired, clockChanged, storageUnavailable

    var allowsTranslation: Bool {
        switch self {
        case .unrestricted, .freeAccess, .subscribed, .billingGrace: true
        default: false
        }
    }

    var message: String {
        switch self {
        case .unrestricted: "Translation access is available."
        case .notStarted: "Complete setup to start your 14 free days."
        case let .freeAccess(until): "Free access until \(until.formatted(date: .abbreviated, time: .omitted))."
        case let .subscribed(until, isTrial): "\(isTrial ? "Subscription trial" : "Subscription") active until \(until.formatted(date: .abbreviated, time: .omitted))."
        case let .billingGrace(until): "Access continues until \(until.formatted(date: .abbreviated, time: .omitted)) while Apple retries payment."
        case .expired: "Subscribe to continue translating. If your subscription renewed while offline, reconnect and restore purchases."
        case .clockChanged: "Check your iPhone’s date and time to verify translation access."
        case .storageUnavailable: "Free access could not be read securely. Unlock your iPhone and try again, or restore your subscription."
        }
    }
}

@MainActor
protocol TranslationAuthorizing: AnyObject {
    func authorizeTranslation() throws
}

@MainActor
final class TranslationAccessManager: ObservableObject, TranslationAuthorizing {
    @Published private(set) var state: TranslationAccessState = .notStarted
    @Published var requestsPaywall = false
    private let storage: any FreeAccessStorage
    private let now: () -> Date
    private let isRequired: Bool
    private var entitlement = ProEntitlement()
    private var subscriptionObservation: AnyCancellable?
    private var timerTask: Task<Void, Never>?
    private var highestObservedTime: Date?

    init(
        subscription: any SubscriptionEntitlementObserving,
        isRequired: Bool,
        storage: any FreeAccessStorage = KeychainFreeAccessStorage(),
        now: @escaping () -> Date = Date.init,
        runsTimer: Bool = true
    ) {
        self.storage = storage
        self.now = now
        self.isRequired = isRequired
        subscriptionObservation = subscription.entitlementUpdates.sink { [weak self] value in
            self?.entitlement = value
            self?.refresh()
        }
        refresh()
        if runsTimer {
            timerTask = Task { [weak self] in
                while !Task.isCancelled {
                    do { try await Task.sleep(for: .seconds(30)) } catch { break }
                    self?.refresh()
                }
            }
        }
    }

    deinit { timerTask?.cancel() }

    @discardableResult
    func activateFreeAccess() -> Bool {
        guard isRequired else { return true }
        do {
            if try storage.read() == nil {
                try storage.write(JSONEncoder().encode(FreeAccessRecord(startedAt: now())))
            }
            refresh()
            return state.allowsTranslation || state == .expired
        } catch {
            state = .storageUnavailable
            return false
        }
    }

    func refresh() {
        guard isRequired else { state = .unrestricted; return }
        let current = now()
        let clockMovedBack = highestObservedTime.map { current < $0.addingTimeInterval(-300) } ?? false
        highestObservedTime = max(highestObservedTime ?? current, current)
        if let expiry = entitlement.expirationDate, entitlement.hasPro, expiry > current,
           !clockMovedBack {
            state = entitlement.state == .gracePeriod
                ? .billingGrace(until: expiry)
                : .subscribed(until: expiry, isTrial: entitlement.isTrial)
            return
        }
        do {
            guard let data = try storage.read() else { state = .notStarted; return }
            var record = try JSONDecoder().decode(FreeAccessRecord.self, from: data)
            guard record.isValid else { throw FreeAccessStorageError.corrupt }
            guard !clockMovedBack, current >= record.latestObservedDate.addingTimeInterval(-300) else {
                state = .clockChanged
                return
            }
            if current.timeIntervalSince(record.latestObservedDate) >= 60 {
                record.latestObservedDate = current
                try storage.write(JSONEncoder().encode(record))
            }
            state = current < record.expiresAt ? .freeAccess(until: record.expiresAt) : .expired
        } catch { state = .storageUnavailable }
    }

    func authorizeTranslation() throws {
        refresh()
        guard state.allowsTranslation else {
            requestsPaywall = true
            throw PipelineError.server(state.message)
        }
    }
}
