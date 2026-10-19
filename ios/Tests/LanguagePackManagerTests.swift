import Foundation
import XCTest
@testable import LocalLingo

@MainActor
final class LanguagePackManagerTests: XCTestCase {
    private let spanishPair = LanguagePair()
    private let frenchJapanesePair = LanguagePair(
        traveler: .frenchFrance,
        local: .japaneseJapan
    )

    func testCheckSupportsNonEnglishPairAndUsesExactTranslationDirections() async {
        let speech = FakeSpeechAssetManager(readiness: [
            "fr-FR": .ready,
            "ja-JP": .ready,
        ])
        let translation = FakeTripPackTranslationEngine([.ready, .downloadRequired])
        let synthesis = FakeTripPackSynthesisEngine(
            availableLocaleIDs: ["fr-FR", "ja-JP"]
        )
        let manager = makeManager(
            speech: speech,
            translation: translation,
            synthesis: synthesis
        )

        await manager.check(frenchJapanesePair)

        XCTAssertEqual(manager.readiness.pair, frenchJapanesePair)
        XCTAssertEqual(manager.readiness.listenTraveler, .ready)
        XCTAssertEqual(manager.readiness.listenLocal, .ready)
        XCTAssertEqual(manager.readiness.translateForward, .ready)
        XCTAssertEqual(manager.readiness.translateReverse, .downloadRequired)
        XCTAssertEqual(manager.readiness.speakTraveler, .ready)
        XCTAssertEqual(manager.readiness.speakLocal, .ready)
        XCTAssertEqual(
            translation.availabilityCalls,
            ["fr->ja", "ja->fr"]
        )
    }

    func testInstallPreparesBothNonEnglishListenAssets() async {
        let speech = FakeSpeechAssetManager(
            readiness: [
                "fr-FR": .downloadRequired,
                "ja-JP": .downloadRequired,
            ],
            reservedLocaleIDs: []
        )
        speech.postInstallReadiness = [
            "fr-FR": .ready,
            "ja-JP": .ready,
        ]
        let translation = FakeTripPackTranslationEngine([.ready, .ready])
        let manager = makeManager(
            speech: speech,
            translation: translation,
            synthesis: FakeTripPackSynthesisEngine(
                availableLocaleIDs: ["fr-FR", "ja-JP"]
            )
        )

        await manager.check(frenchJapanesePair)
        await manager.install(frenchJapanesePair)

        XCTAssertEqual(speech.installCalls, ["fr-FR", "ja-JP"])
        XCTAssertTrue(manager.readiness.isReady)
        XCTAssertEqual(
            Array(translation.availabilityCalls.suffix(2)),
            ["fr->ja", "ja->fr"]
        )
    }

    func testInstallRejectsSameLanguagePair() async {
        let speech = FakeSpeechAssetManager(readiness: ["fr-FR": .ready])
        let translation = FakeTripPackTranslationEngine([.ready, .ready])
        let manager = makeManager(speech: speech, translation: translation)

        await manager.install(LanguagePair(
            traveler: .frenchFrance,
            local: .frenchFrance
        ))

        XCTAssertTrue(speech.installCalls.isEmpty)
        XCTAssertTrue(translation.availabilityCalls.isEmpty)
        XCTAssertTrue(manager.errorMessage?.contains("two different") == true)
        XCTAssertFalse(manager.isWorking)
    }

    func testCheckAcceptsEnglishHindiAndUsesBothTranslationDirections() async {
        let pair = LanguagePair(traveler: .hindiIndia, local: .englishUS)
        let speech = FakeSpeechAssetManager(readiness: [
            "hi-IN": .ready,
            "en-US": .ready,
        ])
        let translation = FakeTripPackTranslationEngine([.ready, .ready])
        let manager = makeManager(
            speech: speech,
            translation: translation,
            synthesis: FakeTripPackSynthesisEngine(
                availableLocaleIDs: ["hi-IN", "en-US"]
            )
        )

        await manager.check(pair)

        XCTAssertEqual(manager.readiness.pair, pair)
        XCTAssertTrue(manager.readiness.isReady)
        XCTAssertNil(manager.errorMessage)
        XCTAssertEqual(translation.availabilityCalls, ["hi->en", "en->hi"])
    }

    func testCheckFailsClosedWhenInstalledListenModelsCannotRunTogether() async {
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let speech = FakeSpeechAssetManager(readiness: [
            "en-US": .ready,
            "hi-IN": .ready,
        ])
        speech.continuousReadiness = .unavailable
        let manager = makeManager(speech: speech)

        await manager.check(pair)

        XCTAssertEqual(manager.readiness.listenTraveler, .ready)
        XCTAssertEqual(manager.readiness.listenLocal, .ready)
        XCTAssertEqual(manager.readiness.listenPair, .unavailable)
        XCTAssertFalse(manager.readiness.isReady(requiringVoices: false))
    }

    func testInstallPreparesManualTranslationWhenContinuousListenIsUnavailable() async {
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let speech = FakeSpeechAssetManager(readiness: [
            "en-US": .ready,
            "hi-IN": .ready,
        ])
        speech.continuousReadiness = .unavailable
        let translation = FakeTripPackTranslationEngine([.ready, .ready])
        let manager = makeManager(speech: speech, translation: translation)

        await manager.check(pair)
        await manager.install(pair)

        XCTAssertEqual(manager.readiness.listenPair, .unavailable)
        XCTAssertTrue(speech.continuousInstallCalls.isEmpty)
        XCTAssertEqual(translation.availabilityCalls.count, 4)
        XCTAssertTrue(manager.readiness.isManualReady(requiringVoices: false))
        XCTAssertFalse(manager.readiness.isReady(requiringVoices: false))
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.isWorking)
    }

    func testInstallDownloadsAndVerifiesContinuousListenAssets() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        speech.continuousReadiness = .downloadRequired
        speech.postContinuousInstallReadiness = .ready
        speech.continuousInstallProgress = 0.37
        speech.blocksContinuousInstallation = true
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        let installTask = Task { await manager.install(spanishPair) }
        await waitUntil { speech.continuousInstallStarted }

        XCTAssertEqual(manager.readiness.listenPair, .downloading)
        XCTAssertTrue(manager.progressMessage?.contains("continuous Listen") == true)
        XCTAssertEqual(manager.installationProgress ?? -1, 0.37, accuracy: 0.001)

        speech.resumeContinuousInstallation()
        await installTask.value

        XCTAssertEqual(speech.continuousInstallCalls, [spanishPair])
        XCTAssertEqual(manager.readiness.listenPair, .ready)
        XCTAssertTrue(manager.readiness.isReady(requiringVoices: false))
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.isWorking)
    }

    func testContinuousListenInstallFailureCanBeRetried() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        speech.continuousReadiness = .downloadRequired
        speech.continuousInstallError = PipelineError.server("Continuous fixture failure")
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        await manager.install(spanishPair)

        XCTAssertEqual(speech.continuousInstallCalls, [spanishPair])
        XCTAssertEqual(manager.readiness.listenPair, .downloadRequired)
        XCTAssertEqual(manager.errorMessage, "Continuous fixture failure")
        XCTAssertFalse(manager.isWorking)

        speech.continuousInstallError = nil
        speech.postContinuousInstallReadiness = .ready
        await manager.install(spanishPair)

        XCTAssertEqual(speech.continuousInstallCalls, [spanishPair, spanishPair])
        XCTAssertEqual(manager.readiness.listenPair, .ready)
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.isWorking)
    }

    func testIncompatibleContinuousListenAssetsStillPrepareManualTranslation() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        speech.continuousReadiness = .downloadRequired
        speech.postContinuousInstallReadiness = .unavailable
        speech.continuousInstallError = PipelineError.assetsUnavailable(
            "The installed Listen models cannot run together."
        )
        let translation = FakeTripPackTranslationEngine([.ready, .ready])
        let manager = makeManager(speech: speech, translation: translation)

        await manager.check(spanishPair)
        await manager.install(spanishPair)

        XCTAssertEqual(speech.continuousInstallCalls, [spanishPair])
        XCTAssertEqual(manager.readiness.listenPair, .unavailable)
        XCTAssertEqual(translation.availabilityCalls.count, 4)
        XCTAssertTrue(manager.readiness.isManualReady(requiringVoices: false))
        XCTAssertFalse(manager.readiness.isReady(requiringVoices: false))
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.isWorking)
    }

    func testCancelContinuousListenInstallNormalizesStateAndAllowsRetry() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        speech.continuousReadiness = .downloadRequired
        speech.blocksContinuousInstallation = true
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        let installTask = Task { await manager.install(spanishPair) }
        await waitUntil { speech.continuousInstallStarted }

        installTask.cancel()
        manager.cancelInstallation()
        await installTask.value

        XCTAssertEqual(manager.readiness.listenPair, .unknown)
        XCTAssertNil(manager.installationProgress)
        XCTAssertNil(manager.errorMessage)
        XCTAssertFalse(manager.isWorking)

        speech.blocksContinuousInstallation = false
        speech.postContinuousInstallReadiness = .ready
        await manager.install(spanishPair)

        XCTAssertEqual(speech.continuousInstallCalls, [spanishPair, spanishPair])
        XCTAssertEqual(manager.readiness.listenPair, .ready)
        XCTAssertNil(manager.errorMessage)
    }

    func testCheckAndInstallRejectHindiWithNonEnglishLanguage() async {
        let pair = LanguagePair(traveler: .hindiIndia, local: .spanishSpain)
        let speech = FakeSpeechAssetManager(readiness: [
            "hi-IN": .ready,
            "es-ES": .ready,
        ])
        let translation = FakeTripPackTranslationEngine([.ready, .ready])
        let manager = makeManager(speech: speech, translation: translation)

        await manager.check(pair)
        await manager.install(pair)

        XCTAssertEqual(manager.readiness.pair, pair)
        XCTAssertTrue(manager.errorMessage?.contains("only with English") == true)
        XCTAssertTrue(speech.installCalls.isEmpty)
        XCTAssertTrue(translation.availabilityCalls.isEmpty)
        XCTAssertFalse(manager.isWorking)
    }

    func testCheckPublishesExactComponentStatuses() async {
        let speech = FakeSpeechAssetManager(readiness: [
            "en-US": .ready,
            "es-ES": .downloading,
        ])
        let translation = FakeTripPackTranslationEngine([.ready, .downloadRequired])
        let synthesis = FakeTripPackSynthesisEngine(availableLocaleIDs: ["en-US"])
        let manager = makeManager(speech: speech, translation: translation, synthesis: synthesis)

        await manager.check(spanishPair)

        XCTAssertEqual(manager.readiness.listenTraveler, .ready)
        XCTAssertEqual(manager.readiness.listenLocal, .downloading)
        XCTAssertEqual(manager.readiness.translateForward, .ready)
        XCTAssertEqual(manager.readiness.translateReverse, .downloadRequired)
        XCTAssertEqual(manager.readiness.speakTraveler, .ready)
        XCTAssertEqual(manager.readiness.speakLocal, .downloadRequired)
        XCTAssertFalse(manager.isWorking)
        XCTAssertNil(manager.progressMessage)
        XCTAssertNil(manager.installationProgress)
        XCTAssertNil(manager.translationDownloadConfiguration)
        XCTAssertNil(manager.errorMessage)
    }

    func testInstallSkipsListeningAssetsThatAreAlreadyReady() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        await manager.install(spanishPair)

        XCTAssertTrue(speech.installCalls.isEmpty)
        XCTAssertTrue(speech.reserveCalls.isEmpty)
        XCTAssertTrue(manager.readiness.isReady)
        XCTAssertFalse(manager.isWorking)
        XCTAssertNil(manager.progressMessage)
        XCTAssertNil(manager.installationProgress)
        XCTAssertNil(manager.translationDownloadConfiguration)
    }

    func testInstallPublishesLanguageProgressAndVerifiesReadiness() async {
        let speech = FakeSpeechAssetManager(readiness: [
            "en-US": .downloadRequired,
            "es-ES": .ready,
        ])
        speech.postInstallReadiness["en-US"] = .ready
        speech.installProgress = 0.42
        speech.blocksInstallation = true
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        let installTask = Task { await manager.install(spanishPair) }
        await waitUntil { speech.installStarted }

        XCTAssertEqual(manager.readiness.listenTraveler, .downloading)
        XCTAssertTrue(manager.progressMessage?.contains("English") == true)
        XCTAssertEqual(manager.installationProgress ?? -1, 0.42, accuracy: 0.001)
        XCTAssertTrue(manager.isWorking)

        speech.resumeInstallation()
        await installTask.value

        XCTAssertEqual(speech.installCalls, ["en-US"])
        XCTAssertEqual(manager.readiness.listenTraveler, .ready)
        XCTAssertEqual(manager.readiness.listenLocal, .ready)
        XCTAssertFalse(manager.isWorking)
        XCTAssertNil(manager.progressMessage)
        XCTAssertNil(manager.installationProgress)
    }

    func testInstallRejectsAFalsePostInstallSuccess() async {
        let speech = FakeSpeechAssetManager(readiness: [
            "en-US": .downloadRequired,
            "es-ES": .ready,
        ])
        speech.postInstallReadiness["en-US"] = .downloading
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        await manager.install(spanishPair)

        XCTAssertEqual(manager.readiness.listenTraveler, .downloading)
        XCTAssertTrue(manager.errorMessage?.contains("has not finished installing") == true)
        XCTAssertFalse(manager.isWorking)
        XCTAssertNil(manager.progressMessage)
        XCTAssertNil(manager.installationProgress)
        XCTAssertNil(manager.translationDownloadConfiguration)
    }

    func testUnavailableListenDoesNotAttemptInstallation() async {
        let speech = FakeSpeechAssetManager(readiness: [
            "en-US": .unavailable,
            "es-ES": .ready,
        ])
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        await manager.install(spanishPair)

        XCTAssertTrue(speech.installCalls.isEmpty)
        XCTAssertEqual(manager.readiness.listenTraveler, .unavailable)
        XCTAssertTrue(manager.errorMessage?.contains("unavailable for English") == true)
        XCTAssertFalse(manager.isWorking)
    }

    func testUnavailableTranslationDoesNotRequestModelPreparation() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        let translation = FakeTripPackTranslationEngine([.unavailable, .ready])
        let manager = makeManager(speech: speech, translation: translation)

        await manager.install(spanishPair)

        XCTAssertEqual(manager.readiness.translateForward, .unavailable)
        XCTAssertEqual(manager.readiness.translateReverse, .ready)
        XCTAssertNil(manager.translationDownloadConfiguration)
        XCTAssertTrue(
            manager.errorMessage?.contains(
                "On-device translation is unavailable for this language pair."
            ) == true
        )
        XCTAssertFalse(manager.isWorking)
    }

    func testCancelClearsProgressAndIgnoresLateUpdates() async {
        let speech = FakeSpeechAssetManager(readiness: [
            "en-US": .downloadRequired,
            "es-ES": .ready,
        ])
        speech.installProgress = 0.25
        speech.blocksInstallation = true
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        let installTask = Task { await manager.install(spanishPair) }
        await waitUntil { speech.installStarted }
        XCTAssertEqual(manager.installationProgress ?? -1, 0.25, accuracy: 0.001)

        installTask.cancel()
        manager.cancelInstallation()
        speech.emitProgress(0.9)
        await installTask.value

        XCTAssertEqual(manager.readiness.listenTraveler, .unknown)
        XCTAssertFalse(manager.isWorking)
        XCTAssertNil(manager.progressMessage)
        XCTAssertNil(manager.installationProgress)
        XCTAssertNil(manager.translationDownloadConfiguration)
        XCTAssertNil(manager.errorMessage)
    }

    func testCancelNormalizesPendingContinuousPairReadiness() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        let manager = makeManager(speech: speech)
        await manager.check(spanishPair)
        speech.blocksContinuousReadiness = true

        let installTask = Task { await manager.install(spanishPair) }
        await waitUntil { speech.continuousReadinessStarted }
        XCTAssertEqual(manager.readiness.listenPair, .checking)

        installTask.cancel()
        manager.cancelInstallation()
        speech.resumeContinuousReadiness()
        await installTask.value

        XCTAssertEqual(manager.readiness.listenPair, .unknown)
        XCTAssertFalse(manager.isWorking)
    }

    func testTranslationPreparationAdvancesBothDirectionsAndCompletes() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        let translation = FakeTripPackTranslationEngine([.downloadRequired, .downloadRequired])
        let manager = makeManager(speech: speech, translation: translation)

        await manager.check(spanishPair)
        await manager.install(spanishPair)

        XCTAssertTrue(manager.isWorking)
        XCTAssertNotNil(manager.translationDownloadConfiguration)
        XCTAssertEqual(manager.readiness.translateForward, .checking)
        XCTAssertEqual(manager.readiness.translateReverse, .downloadRequired)

        await manager.preparePendingTranslation {}

        XCTAssertTrue(manager.isWorking)
        XCTAssertEqual(manager.readiness.translateForward, .ready)
        XCTAssertEqual(manager.readiness.translateReverse, .checking)
        XCTAssertNotNil(manager.translationDownloadConfiguration)

        await manager.preparePendingTranslation {}

        XCTAssertFalse(manager.isWorking)
        XCTAssertEqual(manager.readiness.translateForward, .ready)
        XCTAssertEqual(manager.readiness.translateReverse, .ready)
        XCTAssertNil(manager.translationDownloadConfiguration)
        XCTAssertNil(manager.progressMessage)
    }

    func testTranslationPreparationDoesNotClaimReadyBeforeAppleReportsReady() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        let translation = FakeTripPackTranslationEngine([.downloadRequired, .downloadRequired])
        let manager = makeManager(speech: speech, translation: translation)

        await manager.check(spanishPair)
        await manager.install(spanishPair)
        await manager.preparePendingTranslation({}, isReady: { false })

        XCTAssertFalse(manager.isWorking)
        XCTAssertEqual(manager.readiness.translateForward, .unknown)
        XCTAssertEqual(manager.readiness.translateReverse, .downloadRequired)
        XCTAssertNil(manager.translationDownloadConfiguration)
        XCTAssertTrue(
            manager.errorMessage?.contains("Translation download has not finished") == true
        )
    }

    func testInstallReservesInstalledButUnreservedAssetWithoutDownloading() async {
        let speech = FakeSpeechAssetManager(
            readiness: readySpeechReadiness,
            maximumReservedLocales: 3,
            reservedLocaleIDs: ["en-US"]
        )
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        XCTAssertEqual(manager.readiness.listenLocal, .downloadRequired)

        await manager.install(spanishPair)

        XCTAssertEqual(speech.reserveCalls, ["es-ES"])
        XCTAssertTrue(speech.installCalls.isEmpty)
        XCTAssertTrue(manager.speechInventory.contains(.spanishSpain))
        XCTAssertEqual(manager.readiness.listenLocal, .ready)
    }

    func testInstallAutomaticallyReleasesLeastRecentlyUsedInactiveReservation() async {
        let speech = FakeSpeechAssetManager(
            readiness: readySpeechReadiness.merging([
                "fr-FR": .ready,
                "de-DE": .ready,
            ]) { _, new in new },
            maximumReservedLocales: 3,
            reservedLocaleIDs: ["en-US", "es-ES", "fr-FR"]
        )
        var currentDate = Date(timeIntervalSince1970: 100)
        let manager = makeManager(speech: speech, now: { currentDate })
        manager.markUsed(.spanishSpain)
        currentDate = Date(timeIntervalSince1970: 200)
        manager.markUsed(.frenchFrance)

        let germanPair = LanguagePair(traveler: .englishUS, local: .germanGermany)
        await manager.install(germanPair)

        XCTAssertEqual(speech.releaseCalls, ["es-ES"])
        XCTAssertEqual(speech.reserveCalls, ["de-DE"])
        XCTAssertFalse(manager.speechInventory.contains(.spanishSpain))
        XCTAssertTrue(manager.speechInventory.contains(.frenchFrance))
        XCTAssertTrue(manager.speechInventory.contains(.germanGermany))
        XCTAssertTrue(manager.state(for: .germanGermany).isListenReady)
    }

    func testInstallReleasesHiddenHindiReservationAfterCatalogDowngrade() async {
        let speech = FakeSpeechAssetManager(
            readiness: [
                "en-US": .ready,
                "es-ES": .ready,
                "hi-IN": .ready,
            ],
            maximumReservedLocales: 2,
            reservedLocaleIDs: ["en-US", "hi-IN"]
        )
        let manager = makeManager(speech: speech)

        await manager.check(spanishPair)
        await manager.install(spanishPair)

        XCTAssertEqual(speech.releaseCalls, ["hi-IN"])
        XCTAssertEqual(speech.reserveCalls, ["es-ES"])
        XCTAssertFalse(manager.speechInventory.contains(.hindiIndia))
        XCTAssertTrue(manager.speechInventory.contains(.englishUS))
        XCTAssertTrue(manager.speechInventory.contains(.spanishSpain))
    }

    func testFullInventoryProtectsSelectedAndUnknownReservations() async {
        let speech = FakeSpeechAssetManager(
            readiness: readySpeechReadiness.merging([
                "de-DE": .ready,
            ]) { _, new in new },
            maximumReservedLocales: 2,
            reservedLocaleIDs: ["es-ES", "und"]
        )
        let manager = makeManager(speech: speech)
        await manager.check(spanishPair)

        let germanPair = LanguagePair(traveler: .englishUS, local: .germanGermany)
        await manager.install(germanPair)

        XCTAssertTrue(speech.releaseCalls.isEmpty)
        XCTAssertTrue(speech.reserveCalls.isEmpty)
        XCTAssertTrue(speech.installCalls.isEmpty)
        XCTAssertEqual(speech.reservedLocaleIDs, ["es-ES", "und"])
        XCTAssertTrue(
            manager.state(for: .germanGermany).errorMessage?
                .contains("no inactive LocalLingo language can be released") == true
        )
        XCTAssertTrue(
            manager.errorMessage?
                .contains("no inactive LocalLingo language can be released") == true
        )
    }

    func testAutomaticReleaseUsesExactNormalizedLocaleFromInventory() async {
        let speech = FakeSpeechAssetManager(
            readiness: readySpeechReadiness.merging([
                "de-DE": .ready,
            ]) { _, new in new },
            maximumReservedLocales: 2,
            reservedLocaleIDs: ["en-US", "es"]
        )
        let manager = makeManager(speech: speech)
        let germanPair = LanguagePair(traveler: .englishUS, local: .germanGermany)

        await manager.install(germanPair)

        XCTAssertEqual(speech.releaseCalls, ["es"])
        XCTAssertEqual(speech.reserveCalls, ["de-DE"])
    }

    func testManualReleaseUpdatesReservationAndReadiness() async {
        let speech = FakeSpeechAssetManager(readiness: readySpeechReadiness)
        let manager = makeManager(speech: speech)

        await manager.releaseListen(for: .spanishSpain)

        XCTAssertEqual(speech.releaseCalls, ["es-ES"])
        XCTAssertFalse(manager.speechInventory.contains(.spanishSpain))
        XCTAssertTrue(manager.speechInventory.contains(.englishUS))
        XCTAssertFalse(manager.state(for: .spanishSpain).listenReserved)
        XCTAssertEqual(
            manager.state(for: .spanishSpain).listenReadiness,
            .downloadRequired
        )
        XCTAssertNil(manager.errorMessage)
        XCTAssertTrue(manager.noticeMessage?.contains("reservation released") == true)
        XCTAssertFalse(manager.isWorking)
    }

    func testInstallInvalidatesCatalogRefreshUsingOlderInventory() async {
        let speech = FakeSpeechAssetManager(
            readiness: readySpeechReadiness,
            reservedLocaleIDs: []
        )
        let manager = makeManager(speech: speech)
        speech.blocksNextReadiness = true

        let refresh = Task { await manager.refreshAll() }
        await waitUntil { speech.readinessStarted }
        await manager.install(spanishPair)
        speech.resumeReadiness()
        await refresh.value

        XCTAssertTrue(manager.state(for: .englishUS).listenReserved)
        XCTAssertTrue(manager.state(for: .spanishSpain).listenReserved)
        XCTAssertTrue(manager.readiness.isReady(requiringVoices: false))
    }

    func testReleaseInvalidatesCatalogRefreshUsingOlderInventory() async {
        let speech = FakeSpeechAssetManager(
            readiness: [
                "en-US": .ready,
                "es-ES": .ready,
                "fr-FR": .ready,
            ],
            reservedLocaleIDs: ["en-US", "es-ES", "fr-FR"]
        )
        let manager = makeManager(speech: speech)
        await manager.check(spanishPair)
        speech.blocksNextReadiness = true

        let refresh = Task { await manager.refreshAll() }
        await waitUntil { speech.readinessStarted }
        await manager.releaseListen(for: .frenchFrance)
        speech.resumeReadiness()
        await refresh.value

        XCTAssertFalse(manager.state(for: .frenchFrance).listenReserved)
        XCTAssertFalse(manager.speechInventory.contains(.frenchFrance))
    }

    func testReleaseBlocksEitherLanguageInSelectedPair() async {
        let speech = FakeSpeechAssetManager(readiness: [
            "fr-FR": .ready,
            "ja-JP": .ready,
        ])
        let manager = makeManager(speech: speech)
        await manager.check(frenchJapanesePair)

        await manager.releaseListen(for: .frenchFrance)
        await manager.releaseListen(for: .japaneseJapan)

        XCTAssertTrue(speech.releaseCalls.isEmpty)
        XCTAssertTrue(manager.errorMessage?.contains("selected conversation pair") == true)
    }

    func testReservationEvictionCanReleaseInactiveEnglish() async {
        let speech = FakeSpeechAssetManager(
            readiness: [
                "en-US": .ready,
                "es-ES": .ready,
                "fr-FR": .ready,
                "ja-JP": .ready,
            ],
            maximumReservedLocales: 2,
            reservedLocaleIDs: ["en-US", "es-ES"]
        )
        let manager = makeManager(
            speech: speech,
            synthesis: FakeTripPackSynthesisEngine(
                availableLocaleIDs: ["fr-FR", "ja-JP"]
            )
        )

        await manager.check(frenchJapanesePair)
        await manager.install(frenchJapanesePair)

        XCTAssertEqual(speech.releaseCalls.first, "en-US")
        XCTAssertFalse(manager.speechInventory.contains(.englishUS))
        XCTAssertTrue(manager.speechInventory.contains(.frenchFrance))
        XCTAssertTrue(manager.speechInventory.contains(.japaneseJapan))
    }

    func testReservationEvictionProtectsSelectedAndActivePairLanguages() async {
        let selectedPair = LanguagePair(
            traveler: .spanishSpain,
            local: .frenchFrance
        )
        let activePair = LanguagePair(
            traveler: .japaneseJapan,
            local: .koreanSouthKorea
        )
        let speech = FakeSpeechAssetManager(
            readiness: [
                "es-ES": .ready,
                "fr-FR": .ready,
                "ja-JP": .ready,
                "ko-KR": .ready,
            ],
            maximumReservedLocales: 2,
            reservedLocaleIDs: ["es-ES", "fr-FR"]
        )
        let manager = makeManager(speech: speech)
        await manager.check(selectedPair)

        await manager.install(activePair)

        XCTAssertTrue(speech.releaseCalls.isEmpty)
        XCTAssertTrue(
            manager.errorMessage?
                .contains("no inactive LocalLingo language can be released") == true
        )
    }

    func testUsageMigrationKeepsKnownLanguagesIncludingEnglish() {
        let defaults = isolatedDefaults()
        defaults.set(
            [
                AppLanguage.englishUS.rawValue: 100.0,
                AppLanguage.spanishSpain.rawValue: 200.0,
                "removedLanguage": 300.0,
            ],
            forKey: "LocalLingo.LanguagePackUsage.v1"
        )
        let manager = makeManager(
            speech: FakeSpeechAssetManager(readiness: [:]),
            defaults: defaults
        )

        XCTAssertEqual(
            manager.state(for: .englishUS).lastUsedAt,
            Date(timeIntervalSince1970: 100)
        )
        XCTAssertEqual(
            manager.state(for: .spanishSpain).lastUsedAt,
            Date(timeIntervalSince1970: 200)
        )

        manager.markUsed(.koreanSouthKorea)
        let stored = defaults.dictionary(
            forKey: "LocalLingo.LanguagePackUsage.v1"
        )
        XCTAssertNotNil(stored?[AppLanguage.englishUS.rawValue])
        XCTAssertNotNil(stored?[AppLanguage.spanishSpain.rawValue])
        XCTAssertNotNil(stored?[AppLanguage.koreanSouthKorea.rawValue])
        XCTAssertNil(stored?["removedLanguage"])
    }

    private var readySpeechReadiness: [String: ComponentReadiness] {
        ["en-US": .ready, "es-ES": .ready]
    }

    private func makeManager(
        speech: FakeSpeechAssetManager,
        translation: FakeTripPackTranslationEngine = FakeTripPackTranslationEngine([.ready, .ready]),
        synthesis: FakeTripPackSynthesisEngine = FakeTripPackSynthesisEngine(
            availableLocaleIDs: ["en-US", "es-ES"]
        ),
        defaults: UserDefaults? = nil,
        now: @escaping () -> Date = Date.init
    ) -> LanguagePackManager {
        LanguagePackManager(
            speech: speech,
            translation: translation,
            synthesis: synthesis,
            defaults: defaults ?? isolatedDefaults(),
            now: now
        )
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "LocalLingoTests.LanguagePackManager.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<1_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("Timed out waiting for asynchronous test state.", file: file, line: line)
    }
}

@MainActor
private final class FakeSpeechAssetManager: SpeechAssetManaging {
    var readiness: [String: ComponentReadiness]
    var continuousReadiness: ComponentReadiness = .ready
    var postInstallReadiness: [String: ComponentReadiness] = [:]
    var postContinuousInstallReadiness: ComponentReadiness?
    var installProgress = 0.5
    var continuousInstallProgress = 0.5
    var blocksInstallation = false
    var blocksContinuousInstallation = false
    var blocksNextReadiness = false
    var blocksContinuousReadiness = false
    var continuousInstallError: Error?
    let maximumReservedLocales: Int
    private(set) var installCalls: [String] = []
    private(set) var continuousInstallCalls: [LanguagePair] = []
    private(set) var reserveCalls: [String] = []
    private(set) var releaseCalls: [String] = []
    private(set) var installStarted = false
    private(set) var continuousInstallStarted = false
    private(set) var readinessStarted = false
    private(set) var continuousReadinessStarted = false
    private var reservedLocales: [Locale]
    private var progressHandler: (@MainActor (Double) -> Void)?
    private var continuousProgressHandler: (@MainActor (Double) -> Void)?
    private var installContinuation: CheckedContinuation<Void, Error>?
    private var continuousInstallContinuation: CheckedContinuation<Void, Error>?
    private var readinessContinuation: CheckedContinuation<Void, Never>?
    private var continuousReadinessContinuation: CheckedContinuation<Void, Never>?

    init(
        readiness: [String: ComponentReadiness],
        maximumReservedLocales: Int = 8,
        reservedLocaleIDs: [String]? = nil
    ) {
        self.readiness = readiness
        self.maximumReservedLocales = maximumReservedLocales
        let identifiers = reservedLocaleIDs
            ?? readiness
                .filter { $0.value == .ready }
                .map(\.key)
                .sorted()
        reservedLocales = identifiers.map(Locale.init(identifier:))
    }

    var reservedLocaleIDs: [String] {
        reservedLocales.map(\.identifier)
    }

    func assetReadiness(locale: Locale) async -> ComponentReadiness {
        if blocksNextReadiness {
            blocksNextReadiness = false
            await withCheckedContinuation { continuation in
                readinessStarted = true
                readinessContinuation = continuation
            }
        }
        return readiness[locale.identifier] ?? .unknown
    }

    func continuousAssetReadiness(pair: LanguagePair) async -> ComponentReadiness {
        if blocksContinuousReadiness {
            await withCheckedContinuation { continuation in
                continuousReadinessStarted = true
                continuousReadinessContinuation = continuation
            }
        }
        return continuousReadiness
    }

    func resumeContinuousReadiness() {
        blocksContinuousReadiness = false
        continuousReadinessContinuation?.resume()
        continuousReadinessContinuation = nil
    }

    func inventorySnapshot() async -> SpeechAssetInventorySnapshot {
        SpeechAssetInventorySnapshot(
            maximumReservedLocales: maximumReservedLocales,
            reservedLocales: reservedLocales
        )
    }

    func reserveAssets(locale: Locale) async throws {
        reserveCalls.append(locale.identifier)
        guard !containsLanguage(locale) else { return }
        reservedLocales.append(locale)
    }

    func releaseAssets(reservedLocale: Locale) async -> Bool {
        releaseCalls.append(reservedLocale.identifier)
        guard let index = reservedLocales.firstIndex(where: {
            $0.identifier == reservedLocale.identifier
        }) else {
            return false
        }
        reservedLocales.remove(at: index)
        return true
    }

    func installAssets(
        locale: Locale,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        let identifier = locale.identifier
        installCalls.append(identifier)
        progressHandler = onProgress
        onProgress(installProgress)

        if blocksInstallation {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    installContinuation = continuation
                    installStarted = true
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelBlockedInstallation()
                }
            }
        } else {
            installStarted = true
        }

        if let final = postInstallReadiness[identifier] {
            readiness[identifier] = final
        }
        if !containsLanguage(locale) {
            reservedLocales.append(locale)
        }
        onProgress(1)
    }

    func installContinuousAssets(
        pair: LanguagePair,
        onProgress: @escaping @MainActor (Double) -> Void
    ) async throws {
        continuousInstallCalls.append(pair)
        continuousProgressHandler = onProgress
        onProgress(continuousInstallProgress)

        if blocksContinuousInstallation {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { continuation in
                    continuousInstallContinuation = continuation
                    continuousInstallStarted = true
                }
            } onCancel: {
                Task { @MainActor [weak self] in
                    self?.cancelBlockedContinuousInstallation()
                }
            }
        } else {
            continuousInstallStarted = true
        }

        if let postContinuousInstallReadiness {
            continuousReadiness = postContinuousInstallReadiness
        }
        if let continuousInstallError {
            throw continuousInstallError
        }
        onProgress(1)
    }

    func emitProgress(_ value: Double) {
        progressHandler?(value)
    }

    func emitContinuousProgress(_ value: Double) {
        continuousProgressHandler?(value)
    }

    func resumeInstallation() {
        installContinuation?.resume()
        installContinuation = nil
    }

    func resumeContinuousInstallation() {
        continuousInstallContinuation?.resume()
        continuousInstallContinuation = nil
    }

    func resumeReadiness() {
        readinessContinuation?.resume()
        readinessContinuation = nil
    }

    private func cancelBlockedInstallation() {
        installContinuation?.resume(throwing: CancellationError())
        installContinuation = nil
    }

    private func cancelBlockedContinuousInstallation() {
        continuousInstallContinuation?.resume(throwing: CancellationError())
        continuousInstallContinuation = nil
    }

    private func containsLanguage(_ locale: Locale) -> Bool {
        guard let expected = locale.language.languageCode?.identifier else {
            return false
        }
        return reservedLocales.contains {
            $0.language.languageCode?.identifier.caseInsensitiveCompare(expected) == .orderedSame
        }
    }
}

@MainActor
private final class FakeTripPackTranslationEngine: TranslationEngine {
    private let responses: [ComponentReadiness]
    private var responseIndex = 0
    private(set) var availabilityCalls: [String] = []

    init(_ responses: [ComponentReadiness]) {
        self.responses = responses
    }

    func availability(
        source: Locale.Language,
        target: Locale.Language
    ) async -> ComponentReadiness {
        availabilityCalls.append(
            "\(source.languageCode?.identifier ?? "?")->\(target.languageCode?.identifier ?? "?")"
        )
        guard !responses.isEmpty else { return .unknown }
        defer { responseIndex += 1 }
        return responses[min(responseIndex, responses.count - 1)]
    }

    func prepare(source: Locale.Language, target: Locale.Language) async throws {}

    func translate(
        _ text: String,
        source: Locale.Language,
        target: Locale.Language
    ) async throws -> String {
        text
    }

    func cancel() {}
}

@MainActor
private final class FakeTripPackSynthesisEngine: SpeechSynthesisEngine {
    private let availableLocaleIDs: Set<String>

    init(availableLocaleIDs: Set<String>) {
        self.availableLocaleIDs = availableLocaleIDs
    }

    func isVoiceAvailable(locale: Locale) -> Bool {
        availableLocaleIDs.contains(locale.identifier)
    }

    func speak(_ text: String, locale: Locale, rate: Float) async throws {}
    func play(data: Data, format: String?) async throws {}
    func cancel() {}
}
