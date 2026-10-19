import XCTest
@testable import LocalLingo

final class ConversationRouterTests: XCTestCase {
    func testLocalOnlyCanNeverRouteOnline() throws {
        let decision = try ConversationRouter(onlineFeaturesEnabled: true).decide(
            preference: .localOnly,
            pair: LanguagePair(),
            hasPro: true,
            isOnline: true
        )
        XCTAssertEqual(decision.route, .local)
    }

    func testAutoUsesLocalWithoutEntitlement() throws {
        let decision = try ConversationRouter(onlineFeaturesEnabled: true).decide(
            preference: .automatic,
            pair: LanguagePair(),
            hasPro: false,
            isOnline: true
        )
        XCTAssertEqual(decision.route, .local)
    }

    func testAutoMayUseOnlineOnlyWithNetworkAndEntitlement() throws {
        let decision = try ConversationRouter(onlineFeaturesEnabled: true).decide(
            preference: .automatic,
            pair: LanguagePair(),
            hasPro: true,
            isOnline: true
        )
        XCTAssertEqual(decision.route, .online)
        XCTAssertTrue(decision.disclosure.contains("Google Cloud"))
    }

    func testOnlinePolicyMatchesBackendLocaleContract() {
        XCTAssertTrue(OnlineLanguagePolicy.supports(LanguagePair(traveler: .englishUS, local: .spanishSpain)))
        XCTAssertTrue(OnlineLanguagePolicy.supports(LanguagePair(traveler: .spanishSpain, local: .japaneseJapan)))
        XCTAssertFalse(OnlineLanguagePolicy.supports(LanguagePair(traveler: .englishUS, local: .frenchFrance)))
        XCTAssertFalse(OnlineLanguagePolicy.supports(LanguagePair(traveler: .englishUS, local: .englishUS)))
    }

    func testHindiPairsAreAlwaysExcludedFromOnlineRouting() throws {
        let pairs = [
            LanguagePair(traveler: .englishUS, local: .hindiIndia),
            LanguagePair(traveler: .hindiIndia, local: .englishUS),
        ]
        let router = ConversationRouter(onlineFeaturesEnabled: true)

        for pair in pairs {
            XCTAssertFalse(OnlineLanguagePolicy.supports(pair))
            XCTAssertEqual(
                OnlineLanguagePolicy.normalizedRouting(.automatic, for: pair),
                .localOnly
            )
            XCTAssertEqual(
                OnlineLanguagePolicy.normalizedRouting(.onlineQuality, for: pair),
                .localOnly
            )
            let decision = try router.decide(
                preference: .automatic,
                pair: pair,
                hasPro: true,
                isOnline: true
            )
            XCTAssertEqual(decision.route, .local)
            XCTAssertFalse(decision.disclosure.contains("Google Cloud"))
        }
    }

    func testUnsupportedPairNormalizesEveryOnlinePreferenceToLocalOnly() {
        let unsupported = LanguagePair(
            traveler: .frenchFrance,
            local: .germanGermany
        )
        XCTAssertEqual(
            OnlineLanguagePolicy.normalizedRouting(.automatic, for: unsupported),
            .localOnly
        )
        XCTAssertEqual(
            OnlineLanguagePolicy.normalizedRouting(.onlineQuality, for: unsupported),
            .localOnly
        )
        XCTAssertEqual(
            OnlineLanguagePolicy.normalizedRouting(.localOnly, for: unsupported),
            .localOnly
        )

        let supported = LanguagePair(
            traveler: .spanishSpain,
            local: .japaneseJapan
        )
        XCTAssertEqual(
            OnlineLanguagePolicy.normalizedRouting(.automatic, for: supported),
            .automatic
        )
        XCTAssertEqual(
            OnlineLanguagePolicy.normalizedRouting(.onlineQuality, for: supported),
            .onlineQuality
        )
    }

    func testAutoKeepsBackendUnsupportedPairLocal() throws {
        let decision = try ConversationRouter(onlineFeaturesEnabled: true).decide(
            preference: .automatic,
            pair: LanguagePair(
                traveler: .frenchFrance,
                local: .germanGermany
            ),
            hasPro: true,
            isOnline: true
        )

        XCTAssertEqual(decision.route, .local)
        XCTAssertFalse(decision.disclosure.contains("Google Cloud"))
        XCTAssertTrue(decision.disclosure.contains("does not support"))
    }

    func testOnlineQualityRejectsBackendUnsupportedPair() {
        XCTAssertThrowsError(
            try ConversationRouter(onlineFeaturesEnabled: true).decide(
                preference: .onlineQuality,
                pair: LanguagePair(traveler: .englishUS, local: .koreanSouthKorea),
                hasPro: true,
                isOnline: true
            )
        ) { error in
            guard case PipelineError.onlineUnavailable = error else {
                return XCTFail("Expected onlineUnavailable, got \(error)")
            }
        }
    }

    func testRouterDefaultsToDisabledAndForcesEveryPreferenceLocal() throws {
        let router = ConversationRouter()

        for preference in RoutingPreference.allCases {
            let decision = try router.decide(
                preference: preference,
                pair: LanguagePair(),
                hasPro: true,
                isOnline: true
            )
            XCTAssertEqual(decision.route, .local, preference.rawValue)
            XCTAssertFalse(decision.disclosure.contains("Google Cloud"), preference.rawValue)
        }
    }
}
