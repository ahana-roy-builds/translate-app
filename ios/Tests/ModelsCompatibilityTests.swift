import Foundation
import XCTest
@testable import LocalLingo

final class ModelsCompatibilityTests: XCTestCase {
    func testConversationLanguageCatalogHasStableOrderAndIncludesEveryLanguage() {
        var expectedRawValues = [
            "englishUS",
            "spanishSpain",
            "frenchFrance",
            "germanGermany",
            "italianItaly",
            "portugueseBrazil",
            "japaneseJapan",
            "koreanSouthKorea"
        ]
#if DEBUG || PRIVATE_BETA
        expectedRawValues.append("hindiIndia")
#endif
        XCTAssertEqual(
            AppLanguage.conversationLanguages.map(\.rawValue),
            expectedRawValues
        )
    }

    func testStandardAndExperimentalCatalogsStayDistinct() {
        let standard = AppLanguage.catalog(includingExperimentalHindi: false)
        let experimental = AppLanguage.catalog(includingExperimentalHindi: true)

        XCTAssertFalse(standard.contains(.hindiIndia))
        XCTAssertEqual(experimental, standard + [.hindiIndia])
        XCTAssertEqual(Set(experimental), Set(AppLanguage.allCases))
    }

    func testConversationLanguageCatalogHasStableMetadata() {
        let experimental = AppLanguage.catalog(includingExperimentalHindi: true)
        XCTAssertEqual(experimental.map(\.code), [
            "en-US", "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ja-JP", "ko-KR", "hi-IN"
        ])
        XCTAssertEqual(experimental.map(\.displayName), [
            "English", "Spanish", "French", "German", "Italian",
            "Portuguese (Brazil)", "Japanese", "Korean", "Hindi (Beta)"
        ])
        XCTAssertEqual(experimental.map(\.nativeName), [
            "English", "Español", "Français", "Deutsch", "Italiano",
            "Português (Brasil)", "日本語", "한국어", "हिन्दी"
        ])
        XCTAssertEqual(
            experimental.map(\.locale.identifier),
            experimental.map(\.code)
        )
    }

    func testLanguagePairValiditySwapAndSideReplacement() throws {
        let pair = LanguagePair(traveler: .englishUS, local: .japaneseJapan)

        XCTAssertTrue(pair.isValid)
        XCTAssertFalse(LanguagePair(
            traveler: .japaneseJapan,
            local: .japaneseJapan
        ).isValid)
        XCTAssertEqual(
            pair.swapped,
            LanguagePair(traveler: .japaneseJapan, local: .englishUS)
        )
        XCTAssertEqual(pair.swapped.swapped, pair)
        XCTAssertEqual(
            try XCTUnwrap(pair.replacing(.traveler, with: .frenchFrance)),
            LanguagePair(traveler: .frenchFrance, local: .japaneseJapan)
        )
        XCTAssertEqual(
            try XCTUnwrap(pair.replacing(.local, with: .koreanSouthKorea)),
            LanguagePair(traveler: .englishUS, local: .koreanSouthKorea)
        )
        XCTAssertNil(pair.replacing(.traveler, with: .japaneseJapan))
        XCTAssertNil(pair.replacing(.local, with: .englishUS))
    }

    func testLegacyLanguagePairRawValuesStillDecodeAndReencode() throws {
        let legacy = Data(#"{"traveler":"englishUS","local":"japaneseJapan"}"#.utf8)
        let pair = try JSONDecoder().decode(LanguagePair.self, from: legacy)

        XCTAssertEqual(pair, LanguagePair(traveler: .englishUS, local: .japaneseJapan))
        let encoded = try JSONEncoder().encode(pair)
        let roundTrip = try JSONDecoder().decode(LanguagePair.self, from: encoded)
        XCTAssertEqual(roundTrip, pair)
    }

    func testHindiLanguagePairRawValuesRoundTrip() throws {
        let data = Data(#"{"traveler":"englishUS","local":"hindiIndia"}"#.utf8)

        let pair = try JSONDecoder().decode(LanguagePair.self, from: data)
        XCTAssertEqual(pair, LanguagePair(traveler: .englishUS, local: .hindiIndia))
        XCTAssertEqual(
            try JSONDecoder().decode(LanguagePair.self, from: JSONEncoder().encode(pair)),
            pair
        )
    }

    func testLegacySyncSettingIsDiscardedFromCanonicalEncoding() throws {
        let legacy = Data(#"{"historySyncEnabled":true,"autoSpeak":true,"slowerSpeech":false}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)
        XCTAssertFalse(settings.saveHistoryOnDevice)
        let canonical = try XCTUnwrap(String(data: JSONEncoder().encode(settings), encoding: .utf8))
        XCTAssertFalse(canonical.contains("historySyncEnabled"))
        XCTAssertFalse(canonical.contains("syncOnlineHistoryToICloud"))
    }

    func testLegacySettingsDefaultContinuousTranslationToLowLatency() throws {
        let legacy = Data(#"{"autoSpeak":false,"slowerSpeech":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)

        XCTAssertEqual(settings.continuousTranslationStrategy, .lowLatency)
        XCTAssertFalse(settings.autoSpeak)
        XCTAssertTrue(settings.slowerSpeech)
    }

    func testHighFidelityContinuousTranslationStrategyRoundTrips() throws {
        var settings = AppSettings()
        settings.continuousTranslationStrategy = .highFidelity

        let encoded = try JSONEncoder().encode(settings)
        let decoded = try JSONDecoder().decode(AppSettings.self, from: encoded)

        XCTAssertEqual(decoded.continuousTranslationStrategy, .highFidelity)
    }

    func testLegacyOnlineConsentMigratesToDisclosureVersionOne() throws {
        let legacy = Data(#"{"onlineProcessingConsentGranted":true}"#.utf8)
        let settings = try JSONDecoder().decode(AppSettings.self, from: legacy)

        XCTAssertEqual(settings.acceptedOnlineDisclosureVersion, 1)
        XCTAssertTrue(settings.hasCurrentOnlineProcessingConsent)
        let canonical = try XCTUnwrap(String(data: JSONEncoder().encode(settings), encoding: .utf8))
        XCTAssertTrue(canonical.contains("acceptedOnlineDisclosureVersion"))
        XCTAssertFalse(canonical.contains("onlineProcessingConsentGranted"))
    }

    func testOldDisclosureVersionRequiresRenewedConsent() {
        var settings = AppSettings()
        settings.acceptedOnlineDisclosureVersion = OnlineProcessingDisclosure.currentVersion - 1
        XCTAssertFalse(settings.hasCurrentOnlineProcessingConsent)
        settings.acceptCurrentOnlineProcessingDisclosure()
        XCTAssertTrue(settings.hasCurrentOnlineProcessingConsent)
    }

    @MainActor
    func testSettingsStoreImmediatelyRewritesLegacyPayload() throws {
        let suite = "ModelsCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(
            Data(#"{"syncOnlineHistoryToICloud":true,"onlineProcessingConsentGranted":true}"#.utf8),
            forKey: "LocalLingo.AppSettings.v1"
        )

        _ = SettingsStore(defaults: defaults)

        let rewritten = try XCTUnwrap(defaults.data(forKey: "LocalLingo.AppSettings.v1"))
        let text = try XCTUnwrap(String(data: rewritten, encoding: .utf8))
        XCTAssertFalse(text.contains("syncOnlineHistoryToICloud"))
        XCTAssertFalse(text.contains("onlineProcessingConsentGranted"))
        XCTAssertTrue(text.contains("acceptedOnlineDisclosureVersion"))
    }

    @MainActor
    func testSettingsStorePersistsContinuousTranslationStrategy() throws {
        let suite = "ModelsCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = SettingsStore(defaults: defaults)
        store.value.continuousTranslationStrategy = .highFidelity

        let restored = SettingsStore(defaults: defaults)
        XCTAssertEqual(restored.value.continuousTranslationStrategy, .highFidelity)
    }

    @MainActor
    func testSettingsStoreNormalizesAndRewritesPersistedSameLanguagePair() throws {
        let suite = "ModelsCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let corrupt = Data(
            #"{"pair":{"traveler":"japaneseJapan","local":"japaneseJapan"}}"#.utf8
        )
        defaults.set(corrupt, forKey: "LocalLingo.AppSettings.v1")

        let decoded = try JSONDecoder().decode(AppSettings.self, from: corrupt)
        XCTAssertFalse(decoded.pair.isValid)

        let store = SettingsStore(defaults: defaults)
        XCTAssertEqual(store.value.pair, LanguagePair())

        let rewritten = try XCTUnwrap(
            defaults.data(forKey: "LocalLingo.AppSettings.v1")
        )
        let canonical = try JSONDecoder().decode(AppSettings.self, from: rewritten)
        XCTAssertEqual(canonical.pair, LanguagePair())
    }

    @MainActor
    func testSettingsStoreReplacesUnsupportedHindiPair() throws {
        let suite = "ModelsCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var unsupported = AppSettings()
        unsupported.pair = LanguagePair(
            traveler: .hindiIndia,
            local: .spanishSpain
        )
        defaults.set(
            try JSONEncoder().encode(unsupported),
            forKey: "LocalLingo.AppSettings.v1"
        )

        let store = SettingsStore(defaults: defaults)

        XCTAssertEqual(store.value.pair, LanguagePair())
    }

    @MainActor
    func testStandardCatalogRemovesPreviouslyValidBetaHindiPair() throws {
        let suite = "ModelsCompatibilityTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var betaSettings = AppSettings()
        betaSettings.pair = LanguagePair(
            traveler: .englishUS,
            local: .hindiIndia
        )
        defaults.set(
            try JSONEncoder().encode(betaSettings),
            forKey: "LocalLingo.AppSettings.v1"
        )

        let store = SettingsStore(
            defaults: defaults,
            availableLanguages: AppLanguage.catalog(
                includingExperimentalHindi: false
            )
        )

        XCTAssertEqual(store.value.pair, LanguagePair())
    }

    func testLegacyTurnDefaultsToLocalRoute() throws {
        let legacy = LegacyTurn(
            id: UUID(), sequence: 0, speaker: .traveler,
            sourceLocale: "en-US", targetLocale: "es-ES",
            sourceText: "Hello", translatedText: "Hola", userEdited: false,
            createdAt: Date(), entities: []
        )
        let decoded = try JSONDecoder().decode(ConversationTurn.self, from: JSONEncoder().encode(legacy))
        XCTAssertEqual(decoded.route, .local)
        XCTAssertNil(decoded.recognitionConfidence)
        XCTAssertTrue(decoded.warnings.isEmpty)
        XCTAssertEqual(decoded.languageReviewStatus, .confident)
        XCTAssertNil(decoded.alternateTranscript)
    }

    func testMissingConfidenceIsAlwaysUncertain() {
        XCTAssertTrue(Transcript(text: "hello", isFinal: true).isUncertain)
        XCTAssertFalse(Transcript(text: "hello", isFinal: true, confidence: 0.91, lowConfidenceFraction: 0.1, languageMatchesExpectation: true).isUncertain)
        XCTAssertTrue(Transcript(text: "hello", isFinal: true, confidence: 0.91, lowConfidenceFraction: 0.1, languageMatchesExpectation: false).isUncertain)
    }

    func testReadinessIsBoundToExactPair() {
        var readiness = TripReadiness(pair: LanguagePair(traveler: .englishUS, local: .spanishSpain), generation: 2)
        readiness.listenTraveler = .ready
        readiness.listenLocal = .ready
        readiness.listenPair = .ready
        readiness.translateForward = .ready
        readiness.translateReverse = .ready
        readiness.speakTraveler = .ready
        readiness.speakLocal = .ready
        XCTAssertTrue(readiness.isReady)
        XCTAssertNotEqual(readiness.pair, LanguagePair(traveler: .englishUS, local: .japaneseJapan))
    }

    func testTextOnlyReadinessDoesNotRequireVoices() {
        var readiness = TripReadiness(pair: LanguagePair(), generation: 1)
        readiness.listenTraveler = .ready
        readiness.listenLocal = .ready
        readiness.listenPair = .ready
        readiness.translateForward = .ready
        readiness.translateReverse = .ready
        readiness.speakTraveler = .downloadRequired
        readiness.speakLocal = .downloadRequired
        XCTAssertTrue(readiness.isReady(requiringVoices: false))
        XCTAssertFalse(readiness.isReady(requiringVoices: true))
    }

    func testManualReadinessDoesNotRequireContinuousModuleCoexistence() {
        var readiness = TripReadiness(pair: LanguagePair(), generation: 1)
        readiness.listenTraveler = .ready
        readiness.listenLocal = .ready
        readiness.listenPair = .unavailable
        readiness.translateForward = .ready
        readiness.translateReverse = .ready
        readiness.speakTraveler = .ready
        readiness.speakLocal = .ready

        XCTAssertTrue(readiness.isManualReady(requiringVoices: true))
        XCTAssertFalse(readiness.isReady(requiringVoices: true))
    }

    private struct LegacyTurn: Encodable {
        let id: UUID
        let sequence: Int
        let speaker: SpeakerSide
        let sourceLocale: String
        let targetLocale: String
        let sourceText: String
        let translatedText: String
        let userEdited: Bool
        let createdAt: Date
        let entities: [CriticalEntity]
    }
}
