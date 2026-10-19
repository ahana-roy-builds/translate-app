import Foundation
import XCTest
@testable import LocalLingo

final class AppCapabilitiesTests: XCTestCase {
    func testCapabilityDefaultsAreDisabled() {
        XCTAssertEqual(
            AppCapabilities.allDisabled,
            AppCapabilities(onlineFeaturesEnabled: false, faceToFaceEnabled: false)
        )
    }

    func testExplicitCapabilitiesPreserveValues() {
        let capabilities = AppCapabilities(
            onlineFeaturesEnabled: true,
            faceToFaceEnabled: false
        )

        XCTAssertTrue(capabilities.onlineFeaturesEnabled)
        XCTAssertFalse(capabilities.faceToFaceEnabled)
    }

    func testMissingAndMalformedBundleFlagsFailClosed() throws {
        let missing = try makeBundle(info: [:])
        let malformed = try makeBundle(info: [
            "ONLINE_FEATURES_ENABLED": "enabled",
            "FACE_TO_FACE_ENABLED": 1,
        ])

        XCTAssertEqual(
            AppCapabilities(bundle: missing),
            AppCapabilities(onlineFeaturesEnabled: false, faceToFaceEnabled: false)
        )
        XCTAssertEqual(
            AppCapabilities(bundle: malformed),
            AppCapabilities(onlineFeaturesEnabled: false, faceToFaceEnabled: false)
        )
    }

    func testBundleFlagsAcceptCanonicalBuildSettingValues() throws {
        let enabled = try makeBundle(info: [
            "ONLINE_FEATURES_ENABLED": "YES",
            "FACE_TO_FACE_ENABLED": true,
        ])
        let disabled = try makeBundle(info: [
            "ONLINE_FEATURES_ENABLED": "0",
            "FACE_TO_FACE_ENABLED": "false",
        ])

        XCTAssertEqual(enabledCapabilities(in: enabled), .allEnabled)
        XCTAssertEqual(
            enabledCapabilities(in: disabled),
            AppCapabilities(onlineFeaturesEnabled: false, faceToFaceEnabled: false)
        )
    }

    @MainActor
    func testOfflineClientDoesNotRequireAPIConfiguration() throws {
        let bundle = try makeBundle(info: [:])

        let client = OnlineTranslationClientFactory.make(
            capabilities: .allDisabled,
            bundle: bundle,
            expectedBuildIdentity: nil
        )

        XCTAssertTrue(client is UnavailableOnlineTranslationClient)
    }

    @MainActor
    func testOnlineClientStillUsesConfiguredGoogleImplementation() throws {
        let bundle = try makeBundle(info: [
            "API_BASE_URL": "https://api.locallingo.example",
        ])

        let client = OnlineTranslationClientFactory.make(
            capabilities: .allEnabled,
            bundle: bundle,
            expectedBuildIdentity: nil
        )

        XCTAssertTrue(client is GoogleConversationClient)
    }

    @MainActor
    func testOfflineClientFailsClosed() async throws {
        let client = UnavailableOnlineTranslationClient()

        do {
            try await client.prepareSecurity(signedTransaction: "unused")
            XCTFail("Disabled online dependencies must fail closed")
        } catch PipelineError.onlineUnavailable {
            // Expected: an offline-only build cannot start App Attest or a request.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }

        do {
            _ = try await client.translateText(
                "hello",
                source: .englishUS,
                target: .spanishSpain,
                signedTransaction: "unused"
            )
            XCTFail("Disabled online dependencies must fail closed")
        } catch PipelineError.onlineUnavailable {
            // Expected.
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testSettingsStoreNormalizesLoadedAndFutureValues() throws {
        let suite = "AppCapabilitiesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var saved = AppSettings()
        saved.routing = .onlineQuality
        saved.layout = .faceToFace
        defaults.set(try JSONEncoder().encode(saved), forKey: "LocalLingo.AppSettings.v1")

        let store = SettingsStore(
            defaults: defaults,
            capabilities: AppCapabilities(
                onlineFeaturesEnabled: false,
                faceToFaceEnabled: false
            )
        )

        XCTAssertEqual(store.value.routing, .localOnly)
        XCTAssertEqual(store.value.layout, .heldPhone)

        store.value.routing = .automatic
        store.value.layout = .faceToFace
        XCTAssertEqual(store.value.routing, .localOnly)
        XCTAssertEqual(store.value.layout, .heldPhone)

        let rewritten = try XCTUnwrap(defaults.data(forKey: "LocalLingo.AppSettings.v1"))
        let canonical = try JSONDecoder().decode(AppSettings.self, from: rewritten)
        XCTAssertEqual(canonical.routing, .localOnly)
        XCTAssertEqual(canonical.layout, .heldPhone)
    }

    @MainActor
    func testSettingsStoreOnlyNormalizesDisabledCapability() throws {
        let suite = "AppCapabilitiesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(
            defaults: defaults,
            capabilities: AppCapabilities(
                onlineFeaturesEnabled: true,
                faceToFaceEnabled: false
            )
        )

        store.value.routing = .onlineQuality
        store.value.layout = .faceToFace

        XCTAssertEqual(store.value.routing, .onlineQuality)
        XCTAssertEqual(store.value.layout, .heldPhone)
    }

    @MainActor
    func testSettingsStoreForcesUnsupportedOnlinePairBackToLocalOnly() throws {
        let suite = "AppCapabilitiesTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = SettingsStore(
            defaults: defaults,
            capabilities: .allEnabled
        )

        store.value.pair = LanguagePair(
            traveler: .frenchFrance,
            local: .germanGermany
        )
        store.value.routing = .onlineQuality

        XCTAssertEqual(store.value.routing, .localOnly)
    }

    @MainActor
    func testSubscriptionManagerDefaultsToDisabledAndStaysInactive() async {
        let manager = SubscriptionManager()
        manager.errorMessage = "stale"

        await manager.refresh()
        await manager.restore()

        XCTAssertFalse(manager.isEnabled)
        XCTAssertFalse(manager.hasPro)
        XCTAssertNil(manager.entitlementJWS)
        XCTAssertTrue(manager.products.isEmpty)
        XCTAssertEqual(manager.loadingState, .idle)
        XCTAssertNil(manager.errorMessage)
    }

    private func enabledCapabilities(in bundle: Bundle) -> AppCapabilities {
        AppCapabilities(bundle: bundle)
    }

    private func makeBundle(info: [String: Any]) throws -> Bundle {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        var plist = info
        plist["CFBundleIdentifier"] = "com.example.\(UUID().uuidString)"
        let data = try PropertyListSerialization.data(
            fromPropertyList: plist,
            format: .xml,
            options: 0
        )
        try data.write(to: url.appendingPathComponent("Info.plist"))
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return try XCTUnwrap(Bundle(url: url))
    }
}
