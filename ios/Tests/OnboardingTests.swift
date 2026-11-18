import Foundation
import XCTest
@testable import LocalLingo

@MainActor
final class OnboardingTests: XCTestCase {
    func testLanguageSelectionIsExplicitAndProgressSurvivesRelaunch() throws {
        let suite = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = OnboardingStore(defaults: defaults)
        let settings = SettingsStore(defaults: defaults)
        XCTAssertFalse(onboarding.isComplete)
        XCTAssertFalse(onboarding.complete(settings: settings))
        onboarding.progress.step = 2
        onboarding.progress.defaultLanguage = .frenchFrance
        let restored = OnboardingStore(defaults: defaults)
        XCTAssertEqual(restored.progress.step, 2)
        XCTAssertEqual(restored.progress.defaultLanguage, .frenchFrance)
        XCTAssertFalse(restored.complete(settings: settings))
        restored.progress.partnerLanguage = .japaneseJapan
        XCTAssertTrue(restored.complete(settings: settings))
        XCTAssertTrue(OnboardingStore(defaults: defaults).isComplete)
        XCTAssertEqual(settings.value.defaultLanguage, .frenchFrance)
        XCTAssertEqual(settings.value.pair, LanguagePair(traveler: .frenchFrance, local: .japaneseJapan))
        settings.value.pair = settings.value.pair.swapped
        XCTAssertEqual(settings.value.defaultLanguage, .frenchFrance)
    }

    func testSameLanguageAndUnsupportedHindiPairCannotCompleteOnboarding() throws {
        let suite = "OnboardingTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let onboarding = OnboardingStore(defaults: defaults)
        let settings = SettingsStore(defaults: defaults)
        onboarding.progress.defaultLanguage = .spanishSpain
        onboarding.progress.partnerLanguage = .spanishSpain
        XCTAssertFalse(onboarding.complete(settings: settings))
        onboarding.progress.partnerLanguage = .hindiIndia
        XCTAssertFalse(onboarding.complete(settings: settings))
        XCTAssertFalse(onboarding.isComplete)
    }

    func testLegacySettingsAdoptExistingLanguageWithoutLosingSettings() throws {
        let data = Data(#"{"pair":{"traveler":"frenchFrance","local":"germanGermany"},"saveHistoryOnDevice":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: data)
        XCTAssertEqual(settings.defaultLanguage, .frenchFrance)
        XCTAssertTrue(settings.saveHistoryOnDevice)
        XCTAssertEqual(settings.pair.local, .germanGermany)
    }

    func testUnconfiguredAuthenticationKeepsGuestAccessAvailable() {
        let auth = AuthenticationManager(isEnabled: false)
        XCTAssertFalse(auth.isConfigured)
        XCTAssertNil(auth.user)
        XCTAssertFalse(auth.handleURL(URL(string: "test://callback")!))
        auth.signOut()
        XCTAssertNil(auth.errorMessage)
    }
}
