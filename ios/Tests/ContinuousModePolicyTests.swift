import AVFoundation
import CoreMedia
import Combine
import Foundation
import XCTest
import Translation
@testable import LocalLingo

final class ContinuousModePolicyTests: XCTestCase {
    private var expectedNonEnglishCodes: [String] {
        var codes = [
            "es-ES", "fr-FR", "de-DE", "it-IT", "pt-BR", "ja-JP", "ko-KR"
        ]
#if DEBUG || PRIVATE_BETA
        codes.append("hi-IN")
#endif
        return codes
    }

    func testEveryDistinctPairWithoutHindiRemainsSupported() {
        let establishedLanguages = AppLanguage.conversationLanguages.filter {
            $0 != .hindiIndia
        }
        for traveler in establishedLanguages {
            for local in establishedLanguages where local != traveler {
                let pair = LanguagePair(traveler: traveler, local: local)
                XCTAssertTrue(
                    ContinuousModePolicy.supports(pair),
                    "Expected \(traveler.code) and \(local.code) to be supported"
                )
            }
        }
    }

    func testHindiIsSupportedOnlyWithEnglishInBothOrientations() {
        XCTAssertTrue(ContinuousModePolicy.supports(LanguagePair(
            traveler: .englishUS,
            local: .hindiIndia
        )))
        XCTAssertTrue(ContinuousModePolicy.supports(LanguagePair(
            traveler: .hindiIndia,
            local: .englishUS
        )))

        for language in AppLanguage.conversationLanguages
            where language != .englishUS && language != .hindiIndia {
            XCTAssertFalse(ContinuousModePolicy.supports(LanguagePair(
                traveler: .hindiIndia,
                local: language
            )))
            XCTAssertFalse(ContinuousModePolicy.supports(LanguagePair(
                traveler: language,
                local: .hindiIndia
            )))
        }
    }

    func testStandardCatalogRejectsEnglishHindiPair() {
        XCTAssertFalse(LocalConversationLanguagePolicy.supports(
            LanguagePair(traveler: .englishUS, local: .hindiIndia),
            availableLanguages: AppLanguage.catalog(
                includingExperimentalHindi: false
            )
        ))
        XCTAssertTrue(LocalConversationLanguagePolicy.supports(
            LanguagePair(traveler: .englishUS, local: .hindiIndia),
            availableLanguages: AppLanguage.catalog(
                includingExperimentalHindi: true
            )
        ))
    }

    func testPickerCandidatesEnforceHindiPairingWithoutHidingEstablishedPairs() {
        let spanishPair = LanguagePair(
            traveler: .englishUS,
            local: .spanishSpain
        )
        let replacingSpanish = LocalConversationLanguagePolicy.availableLanguages(
            replacing: .local,
            in: spanishPair
        )
        XCTAssertTrue(replacingSpanish.contains(.hindiIndia))
        XCTAssertFalse(replacingSpanish.contains(.englishUS))

        let frenchSpanishPair = LanguagePair(
            traveler: .frenchFrance,
            local: .spanishSpain
        )
        let replacingSpanishWithoutEnglish = LocalConversationLanguagePolicy.availableLanguages(
            replacing: .local,
            in: frenchSpanishPair
        )
        XCTAssertFalse(replacingSpanishWithoutEnglish.contains(.hindiIndia))
        XCTAssertTrue(replacingSpanishWithoutEnglish.contains(.germanGermany))

        let hindiPair = LanguagePair(
            traveler: .englishUS,
            local: .hindiIndia
        )
        XCTAssertEqual(
            LocalConversationLanguagePolicy.availableLanguages(
                replacing: .traveler,
                in: hindiPair
            ),
            [.englishUS]
        )
    }

    func testSupportRejectsEverySameLanguagePair() {
        for language in AppLanguage.conversationLanguages {
            let pair = LanguagePair(traveler: language, local: language)
            XCTAssertFalse(
                ContinuousModePolicy.supports(pair),
                "Expected duplicate \(language.code) pair to be rejected"
            )
        }
    }

    func testLanguageCorrectionIsLimitedToStableSessionStates() {
        XCTAssertTrue(ContinuousModePolicy.canCorrectLanguage(in: .listening))
        XCTAssertTrue(ContinuousModePolicy.canCorrectLanguage(
            in: .catchingUp(pendingTurns: 1)
        ))
        XCTAssertTrue(ContinuousModePolicy.canCorrectLanguage(in: .pausedByUser))

        let blockedStates: [ContinuousConversationState] = [
            .idle,
            .preparing,
            .pausedForPlayback,
            .pausing,
            .resuming,
            .ending,
            .ended,
            .failed("failed"),
        ]
        for state in blockedStates {
            XCTAssertFalse(
                ContinuousModePolicy.canCorrectLanguage(in: state),
                "Expected language correction to be blocked in \(state)"
            )
        }
    }

    func testReadinessRequiresBothListenAndTranslationDirectionsButNotVoices() throws {
        for code in expectedNonEnglishCodes {
            let pair = LanguagePair(
                traveler: .englishUS,
                local: try language(code: code)
            )
            let ready = TripReadiness(
                pair: pair,
                listenTraveler: .ready,
                listenLocal: .ready,
                listenPair: .ready,
                translateForward: .ready,
                translateReverse: .ready,
                speakTraveler: .unavailable,
                speakLocal: .unavailable
            )

            XCTAssertTrue(
                ContinuousModePolicy.isReady(pair: pair, readiness: ready),
                "Expected \(code) readiness to ignore voices"
            )
        }
    }

    func testReadinessRejectsStalePairAndMissingCoreAsset() {
        let pair = LanguagePair(traveler: .englishUS, local: .spanishSpain)
        var readiness = TripReadiness(
            pair: LanguagePair(traveler: .englishUS, local: .japaneseJapan),
            listenTraveler: .ready,
            listenLocal: .ready,
            listenPair: .ready,
            translateForward: .ready,
            translateReverse: .ready
        )
        XCTAssertFalse(ContinuousModePolicy.isReady(pair: pair, readiness: readiness))

        readiness.pair = pair
        readiness.listenLocal = .downloadRequired
        XCTAssertFalse(ContinuousModePolicy.isReady(pair: pair, readiness: readiness))
    }

    func testBackpressureUsesSeparatePauseAndResumeWatermarks() {
        XCTAssertFalse(ContinuousModePolicy.shouldPauseCapture(pendingTurns: 3))
        XCTAssertTrue(ContinuousModePolicy.shouldPauseCapture(pendingTurns: 4))
        XCTAssertFalse(ContinuousModePolicy.shouldResumeCapture(pendingTurns: 2))
        XCTAssertTrue(ContinuousModePolicy.shouldResumeCapture(pendingTurns: 1))
        XCTAssertTrue(ContinuousModePolicy.canEnqueueWork(pendingTurns: 3))
        XCTAssertFalse(ContinuousModePolicy.canEnqueueWork(pendingTurns: 4))
    }

    func testSpeakPreferenceAppliesOnlyToUtterancesQueuedWhileEnabled() {
        XCTAssertTrue(ContinuousModePolicy.shouldSpeakTranslation(
            wasEnabledAtBoundary: true,
            isEnabledNow: true
        ))
        XCTAssertFalse(ContinuousModePolicy.shouldSpeakTranslation(
            wasEnabledAtBoundary: false,
            isEnabledNow: true
        ))
        XCTAssertFalse(ContinuousModePolicy.shouldSpeakTranslation(
            wasEnabledAtBoundary: true,
            isEnabledNow: false
        ))
    }

    func testHindiBetaAutoSpeaksOrdinaryTurnsButNotEntityReviewTurns() {
        let hindiPair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let establishedPair = LanguagePair(traveler: .englishUS, local: .spanishSpain)

        XCTAssertTrue(ContinuousModePolicy.shouldSpeakTranslation(
            wasEnabledAtBoundary: true,
            isEnabledNow: true,
            pair: hindiPair
        ))
        XCTAssertTrue(ContinuousModePolicy.shouldSpeakTranslation(
            wasEnabledAtBoundary: true,
            isEnabledNow: true,
            pair: hindiPair,
            requiresLanguageReview: true
        ))
        XCTAssertFalse(ContinuousModePolicy.shouldSpeakTranslation(
            wasEnabledAtBoundary: true,
            isEnabledNow: true,
            pair: hindiPair,
            requiresEntityReview: true
        ))
        XCTAssertTrue(ContinuousModePolicy.shouldSpeakTranslation(
            wasEnabledAtBoundary: true,
            isEnabledNow: true,
            pair: establishedPair,
            requiresLanguageReview: true,
            requiresEntityReview: true
        ))
    }

    private func language(code: String) throws -> AppLanguage {
        try XCTUnwrap(
            AppLanguage.conversationLanguages.first(where: { $0.code == code }),
            "Missing continuous language \(code)"
        )
    }
}

final class ContinuousTalkPresentationTests: XCTestCase {
    func testPrimaryActionMatchesEverySessionState() {
        let cases: [(ContinuousConversationState, ContinuousTalkPrimaryAction)] = [
            (.idle, .start),
            (.preparing, .unavailable),
            (.listening, .pause),
            (.catchingUp(pendingTurns: 2), .pause),
            (.pausedForPlayback, .unavailable),
            (.pausing, .unavailable),
            (.pausedByUser, .resume),
            (.resuming, .unavailable),
            (.ending, .unavailable),
            (.ended, .start),
            (.failed("Audio route changed."), .retry),
        ]

        for (state, expected) in cases {
            XCTAssertEqual(
                ContinuousTalkPresentation.primaryAction(for: state),
                expected,
                "Unexpected primary action for \(state)"
            )
        }
    }

    func testStartAndRetryRequireAReadyIdlePack() {
        for action in [
            ContinuousTalkPrimaryAction.start,
            ContinuousTalkPrimaryAction.retry,
        ] {
            XCTAssertTrue(
                ContinuousTalkPresentation.isPrimaryActionEnabled(
                    action,
                    coreReady: true,
                    languagePackOperationInProgress: false
                )
            )
            XCTAssertFalse(
                ContinuousTalkPresentation.isPrimaryActionEnabled(
                    action,
                    coreReady: false,
                    languagePackOperationInProgress: false
                )
            )
            XCTAssertFalse(
                ContinuousTalkPresentation.isPrimaryActionEnabled(
                    action,
                    coreReady: true,
                    languagePackOperationInProgress: true
                )
            )
        }

        XCTAssertTrue(
            ContinuousTalkPresentation.isPrimaryActionEnabled(
                .pause,
                coreReady: false,
                languagePackOperationInProgress: true
            )
        )
        XCTAssertTrue(
            ContinuousTalkPresentation.isPrimaryActionEnabled(
                .resume,
                coreReady: false,
                languagePackOperationInProgress: true
            )
        )
        XCTAssertFalse(
            ContinuousTalkPresentation.isPrimaryActionEnabled(
                .unavailable,
                coreReady: true,
                languagePackOperationInProgress: false
            )
        )
    }

    func testEndAndDockPoliciesCoverTransientAndCompletedStates() {
        for state in [
            ContinuousConversationState.preparing,
            .listening,
            .catchingUp(pendingTurns: 1),
            .pausedForPlayback,
            .pausedByUser,
        ] {
            XCTAssertTrue(
                ContinuousTalkPresentation.canEndSession(in: state),
                "Expected End to be available for \(state)"
            )
            XCTAssertTrue(
                ContinuousTalkPresentation.usesBottomDock(
                    state: state,
                    hasTurns: false
                )
            )
        }

        for state in [
            ContinuousConversationState.pausing,
            .resuming,
            .ending,
            .idle,
            .ended,
            .failed("Stopped"),
        ] {
            XCTAssertFalse(
                ContinuousTalkPresentation.canEndSession(in: state),
                "Expected End to be unavailable for \(state)"
            )
        }

        XCTAssertFalse(
            ContinuousTalkPresentation.usesBottomDock(
                state: .idle,
                hasTurns: false
            )
        )
        XCTAssertTrue(
            ContinuousTalkPresentation.usesBottomDock(
                state: .idle,
                hasTurns: true
            )
        )
        XCTAssertTrue(
            ContinuousTalkPresentation.usesBottomDock(
                state: .ended,
                hasTurns: false
            )
        )
        XCTAssertTrue(
            ContinuousTalkPresentation.usesBottomDock(
                state: .failed("Stopped"),
                hasTurns: false
            )
        )
    }

    func testUserPauseTransitionStatesRemainActive() {
        for state in [
            ContinuousConversationState.pausing,
            .pausedByUser,
            .resuming,
        ] {
            XCTAssertTrue(state.isRunning)
        }
    }
}

final class ContinuousConversationCoordinatorTests: XCTestCase {
    @MainActor
    func testUnavailableContinuousSpeechFailsBeforeCaptureAndRetryRecovers() async {
        let harness = makeHarness(finishBatches: [], decisions: [])
        let error = PipelineError.assetsUnavailable(
            "Continuous on-device listening is not supported on this iPhone."
        )
        let message = error.localizedDescription
        harness.recognition.startError = error

        harness.coordinator.start(pair: harness.pair)
        let failed = await waitUntil {
            harness.coordinator.state == .failed(message)
        }

        XCTAssertTrue(failed)
        XCTAssertEqual(harness.coordinator.errorMessage, message)
        XCTAssertEqual(harness.recognition.startCount, 1)
        XCTAssertEqual(harness.capture.startCount, 0)

        harness.recognition.startError = nil
        harness.coordinator.retrySession(pair: harness.pair)
        let recovered = await waitUntil {
            harness.coordinator.state == .listening
        }

        XCTAssertTrue(recovered)
        XCTAssertEqual(harness.recognition.startCount, 2)
        XCTAssertEqual(harness.capture.startCount, 1)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testUnavailableContinuousTranslationFailsBeforeRecognitionAndRetryRecovers() async {
        let harness = makeHarness(finishBatches: [], decisions: [])
        let error = PipelineError.assetsUnavailable(
            "On-device translation is unavailable for this language pair."
        )
        let message = error.localizedDescription
        harness.translation.prepareError = error

        harness.coordinator.start(pair: harness.pair)
        let failed = await waitUntil {
            harness.coordinator.state == .failed(message)
        }

        XCTAssertTrue(failed)
        XCTAssertEqual(harness.coordinator.errorMessage, message)
        XCTAssertEqual(harness.translation.preparations.count, 1)
        XCTAssertEqual(harness.recognition.startCount, 0)
        XCTAssertEqual(harness.capture.startCount, 0)

        harness.translation.prepareError = nil
        harness.coordinator.retrySession(pair: harness.pair)
        let recovered = await waitUntil {
            harness.coordinator.state == .listening
        }

        XCTAssertTrue(recovered)
        XCTAssertEqual(harness.translation.preparations.count, 2)
        XCTAssertEqual(harness.recognition.startCount, 1)
        XCTAssertEqual(harness.capture.startCount, 1)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testEachNewSessionUsesTheSelectedTranslationStrategy() async {
        let harness = makeHarness(finishBatches: [], decisions: [])

        harness.coordinator.start(pair: harness.pair)
        let firstStarted = await waitUntil {
            harness.coordinator.state == .listening
        }
        XCTAssertTrue(firstStarted)
        XCTAssertEqual(
            harness.translation.preparations,
            [.init(pair: harness.pair, strategy: .lowLatency)]
        )

        harness.coordinator.cancelSession()
        harness.settings.value.continuousTranslationStrategy = .highFidelity
        harness.coordinator.start(pair: harness.pair)
        let secondStarted = await waitUntil {
            harness.coordinator.state == .listening
        }
        XCTAssertTrue(secondStarted)
        XCTAssertEqual(
            harness.translation.preparations,
            [
                .init(pair: harness.pair, strategy: .lowLatency),
                .init(pair: harness.pair, strategy: .highFidelity),
            ]
        )
    }

    @MainActor
    func testHindiLanguageReviewTurnPersistsAndHonorsAutoSpeak() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(
                text: "hello",
                reviewReasons: [.closeScores]
            )],
            pair: pair,
            translations: ["नमस्ते"]
        )
        harness.settings.value.saveHistoryOnDevice = true

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.speakTranslations = true
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        XCTAssertTrue(paused)

        let turn = harness.coordinator.turns.first
        XCTAssertEqual(turn?.languageReviewStatus, .needsReview)
        XCTAssertTrue(turn?.warnings.contains(.uncertainRecognition) == true)
        XCTAssertFalse(turn?.warnings.contains(.entityMismatch) == true)
        XCTAssertEqual(
            harness.synthesis.spoken,
            [.init(text: "नमस्ते", localeIdentifier: "hi-IN")]
        )
        XCTAssertEqual(harness.history.conversations.count, 1)
        XCTAssertEqual(harness.history.conversations.first?.turns, harness.coordinator.turns)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testHindiEntityMismatchTurnPersistsWithoutAutoSpeak() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "I take insulin")],
            pair: pair,
            translations: ["मैं इबुप्रोफेन लेता हूँ"]
        )
        harness.settings.value.saveHistoryOnDevice = true

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.speakTranslations = true
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        XCTAssertTrue(paused)

        let turn = harness.coordinator.turns.first
        XCTAssertEqual(turn?.languageReviewStatus, .confident)
        XCTAssertTrue(turn?.warnings.contains(.entityMismatch) == true)
        XCTAssertTrue(harness.synthesis.spoken.isEmpty)
        XCTAssertEqual(harness.history.conversations.count, 1)
        XCTAssertEqual(harness.history.conversations.first?.turns, harness.coordinator.turns)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testHindiPreservedCriticalEntityRequiresReviewBeforeSpeaking() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "I take insulin")],
            pair: pair,
            translations: ["मैं इंसुलिन लेता हूँ"]
        )
        harness.settings.value.saveHistoryOnDevice = true

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.speakTranslations = true
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        XCTAssertTrue(paused)

        let turn = harness.coordinator.turns.first
        XCTAssertEqual(turn?.languageReviewStatus, .confident)
        XCTAssertFalse(turn?.warnings.contains(.entityMismatch) == true)
        XCTAssertTrue(harness.synthesis.spoken.isEmpty)
        XCTAssertEqual(harness.history.conversations.first?.turns, harness.coordinator.turns)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testConfidentHindiTurnAutoSpeaks() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "hello")],
            pair: pair,
            translations: ["नमस्ते"]
        )

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.speakTranslations = true
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        XCTAssertTrue(paused)

        XCTAssertEqual(
            harness.synthesis.spoken,
            [.init(text: "नमस्ते", localeIdentifier: "hi-IN")]
        )
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testExplicitHindiReplayPausesAndResumesCapture() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "hello")],
            pair: pair,
            translations: ["नमस्ते"]
        )

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        XCTAssertTrue(paused)
        harness.coordinator.resumeSession()
        let resumed = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(resumed)
        guard let turnID = harness.coordinator.turns.first?.id else {
            return XCTFail("Expected a persisted Hindi turn.")
        }
        let startsBeforeReplay = harness.capture.startCount
        let stopsBeforeReplay = harness.capture.stopCount
        harness.synthesis.unavailableVoiceIdentifiers = ["en-US"]

        XCTAssertTrue(harness.coordinator.canReplayTranslation(for: turnID))
        harness.coordinator.replayTranslation(for: turnID)

        let replayed = await waitUntil {
            harness.synthesis.spoken.map(\.text) == ["नमस्ते"]
                && harness.coordinator.reviewedPlaybackTurnID == nil
                && harness.coordinator.state == .listening
        }
        XCTAssertTrue(replayed)
        XCTAssertEqual(harness.capture.stopCount, stopsBeforeReplay + 1)
        XCTAssertEqual(harness.capture.startCount, startsBeforeReplay + 1)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testHindiToEnglishReplayRequiresOnlyEnglishVoice() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(
                text: "नमस्ते",
                language: .hindiIndia
            )],
            pair: pair,
            translations: ["Hello"]
        )

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        XCTAssertTrue(paused)
        guard let turnID = harness.coordinator.turns.first?.id else {
            return XCTFail("Expected a persisted Hindi turn.")
        }
        harness.synthesis.unavailableVoiceIdentifiers = ["hi-IN"]

        XCTAssertTrue(harness.coordinator.canReplayTranslation(for: turnID))
        harness.coordinator.replayTranslation(for: turnID)

        let replayed = await waitUntil {
            harness.synthesis.spoken == [
                .init(text: "Hello", localeIdentifier: "en-US")
            ] && harness.coordinator.reviewedPlaybackTurnID == nil
        }
        XCTAssertTrue(replayed)
        XCTAssertNil(harness.coordinator.errorMessage)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testEstablishedPairReplayUsesExactTargetVoiceInBothDirections() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(
            traveler: .englishUS,
            local: .spanishSpain
        )
        let harness = makeHarness(
            finishBatches: [
                [.speechEnded(range: range, reason: .silence)],
                [.speechEnded(range: range, reason: .silence)],
            ],
            decisions: [
                Self.decision(text: "hello"),
                Self.decision(text: "gracias", language: .spanishSpain),
            ],
            pair: pair,
            translations: ["Hola", "Thank you"]
        )

        harness.coordinator.start(pair: pair)
        await assertEventually { harness.coordinator.state == .listening }
        harness.coordinator.pauseSession()
        await assertEventually {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        guard let firstTurnID = harness.coordinator.turns.first?.id else {
            return XCTFail("Expected the English turn.")
        }
        harness.synthesis.unavailableVoiceIdentifiers = ["en-US"]

        harness.coordinator.replayTranslation(for: firstTurnID)

        await assertEventually {
            harness.synthesis.spoken == [
                .init(text: "Hola", localeIdentifier: "es-ES")
            ]
                && harness.coordinator.reviewedPlaybackTurnID == nil
                && harness.coordinator.state == .pausedByUser
        }

        harness.coordinator.resumeSession()
        await assertEventually { harness.coordinator.state == .listening }
        harness.coordinator.pauseSession()
        await assertEventually {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 2
        }
        guard let secondTurnID = harness.coordinator.turns.last?.id else {
            return XCTFail("Expected the Spanish turn.")
        }
        harness.synthesis.unavailableVoiceIdentifiers = ["es-ES"]

        harness.coordinator.replayTranslation(for: secondTurnID)

        await assertEventually {
            harness.synthesis.spoken == [
                .init(text: "Hola", localeIdentifier: "es-ES"),
                .init(text: "Thank you", localeIdentifier: "en-US"),
            ]
                && harness.coordinator.reviewedPlaybackTurnID == nil
                && harness.coordinator.state == .pausedByUser
        }
        XCTAssertNil(harness.coordinator.errorMessage)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testEverySupportedPairRoutesBothSpeakersAndReplaysInTheTargetLocale() async throws {
        let greetings: [(language: AppLanguage, locale: String, text: String)] = [
            (.englishUS, "en-US", "Hello"), (.spanishSpain, "es-ES", "Hola"),
            (.frenchFrance, "fr-FR", "Bonjour"), (.germanGermany, "de-DE", "Hallo"),
            (.italianItaly, "it-IT", "Ciao"), (.portugueseBrazil, "pt-BR", "Olá"),
            (.japaneseJapan, "ja-JP", "こんにちは"), (.koreanSouthKorea, "ko-KR", "안녕하세요"),
            (.hindiIndia, "hi-IN", "नमस्ते"),
        ]
        let available = greetings.filter { AppLanguage.conversationLanguages.contains($0.language) }
        XCTAssertEqual(Set(available.map(\.language)), Set(AppLanguage.conversationLanguages))
        let first = CMTimeRange(start: .zero, duration: CMTime(value: 1, timescale: 1))
        let second = CMTimeRange(start: first.end, duration: first.duration)

        for primary in available {
            for partner in available where primary.language != partner.language {
                let languages = Set([primary.language, partner.language])
                if languages.contains(.hindiIndia) && !languages.contains(.englishUS) { continue }
                let pair = LanguagePair(traveler: primary.language, local: partner.language)
                let label = "\(primary.locale) ↔ \(partner.locale)"
                let harness = makeHarness(
                    finishBatches: [],
                    processBatches: [[.speechEnded(range: first, reason: .silence)],
                                     [.speechEnded(range: second, reason: .silence)]],
                    decisions: [Self.decision(text: primary.text, language: primary.language),
                                Self.decision(text: partner.text, language: partner.language)],
                    pair: pair, translations: [partner.text, primary.text]
                )
                defer { harness.coordinator.cancelSession() }
                harness.coordinator.start(pair: pair)
                await assertEventually { harness.coordinator.state == .listening }
                for count in 1...2 {
                    _ = try await harness.capture.emitBuffer()
                    await assertEventually { harness.coordinator.turns.count == count }
                }
                let turns = harness.coordinator.turns
                XCTAssertEqual(turns.map(\.speaker), [.traveler, .local], label)
                XCTAssertEqual(turns.map(\.sourceLocale), [primary.locale, partner.locale], label)
                XCTAssertEqual(turns.map(\.targetLocale), [partner.locale, primary.locale], label)
                XCTAssertEqual(turns.map(\.sourceText), [primary.text, partner.text], label)
                XCTAssertEqual(turns.map(\.translatedText), [partner.text, primary.text], label)
                XCTAssertEqual(harness.translation.calls, [
                    .init(text: primary.text, speaker: .traveler, pair: pair),
                    .init(text: partner.text, speaker: .local, pair: pair),
                ], label)

                harness.coordinator.pauseSession()
                await assertEventually { harness.coordinator.state == .pausedByUser }
                for (index, turn) in turns.enumerated() {
                    harness.coordinator.replayTranslation(for: turn.id)
                    await assertEventually {
                        harness.synthesis.spoken.count == index + 1 && harness.coordinator.reviewedPlaybackTurnID == nil
                    }
                }
                XCTAssertEqual(harness.synthesis.spoken, [
                    .init(text: partner.text, localeIdentifier: partner.locale),
                    .init(text: primary.text, localeIdentifier: primary.locale),
                ], label)
            }
        }
    }

    @MainActor
    func testEstablishedPairReplayIsSingleFlightAndRestoresListening() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(
            traveler: .englishUS,
            local: .spanishSpain
        )
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "hello")],
            pair: pair,
            translations: ["Hola"]
        )

        harness.coordinator.start(pair: pair)
        await assertEventually { harness.coordinator.state == .listening }
        harness.coordinator.pauseSession()
        await assertEventually {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        harness.coordinator.resumeSession()
        await assertEventually { harness.coordinator.state == .listening }
        guard let turnID = harness.coordinator.turns.first?.id else {
            return XCTFail("Expected a committed turn.")
        }
        let startsBeforeReplay = harness.capture.startCount
        let stopsBeforeReplay = harness.capture.stopCount
        harness.synthesis.blocksSpeech = true

        harness.coordinator.replayTranslation(for: turnID)
        await assertEventually {
            harness.coordinator.reviewedPlaybackTurnID == turnID
                && harness.synthesis.spoken == [
                    .init(text: "Hola", localeIdentifier: "es-ES")
                ]
        }
        XCTAssertFalse(harness.coordinator.canReplayTranslation(for: turnID))

        harness.coordinator.replayTranslation(for: turnID)
        await Task.yield()
        XCTAssertEqual(harness.synthesis.spoken.count, 1)
        XCTAssertEqual(harness.capture.stopCount, stopsBeforeReplay + 1)

        harness.synthesis.finishBlockedSpeech()
        await assertEventually {
            harness.coordinator.reviewedPlaybackTurnID == nil
                && harness.coordinator.state == .listening
                && harness.coordinator.isCaptureActive
        }
        XCTAssertEqual(harness.capture.startCount, startsBeforeReplay + 1)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testEstablishedPairEntityMismatchCannotBeReplayed() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(
            traveler: .englishUS,
            local: .spanishSpain
        )
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "I take insulin")],
            pair: pair,
            translations: ["Tomo ibuprofeno"]
        )

        harness.coordinator.start(pair: pair)
        await assertEventually { harness.coordinator.state == .listening }
        harness.coordinator.pauseSession()
        await assertEventually {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        guard let turn = harness.coordinator.turns.first else {
            return XCTFail("Expected a committed turn.")
        }
        XCTAssertTrue(turn.warnings.contains(.entityMismatch))

        XCTAssertFalse(harness.coordinator.canReplayTranslation(for: turn.id))
        harness.coordinator.replayTranslation(for: turn.id)
        await Task.yield()

        XCTAssertTrue(harness.synthesis.spoken.isEmpty)
        XCTAssertNil(harness.coordinator.reviewedPlaybackTurnID)
        XCTAssertEqual(harness.coordinator.state, .pausedByUser)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testEstablishedPairEndedReplayRemainsEndedAndBlocksNewSession() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(
            traveler: .englishUS,
            local: .spanishSpain
        )
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "hello")],
            pair: pair,
            translations: ["Hola"]
        )

        harness.coordinator.start(pair: pair)
        await assertEventually { harness.coordinator.state == .listening }
        harness.coordinator.pauseSession()
        await assertEventually {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        harness.coordinator.endSession()
        await assertEventually { harness.coordinator.state == .ended }
        guard let turnID = harness.coordinator.turns.first?.id else {
            return XCTFail("Expected a committed turn.")
        }
        harness.synthesis.blocksSpeech = true

        harness.coordinator.replayTranslation(for: turnID)
        await assertEventually {
            harness.coordinator.reviewedPlaybackTurnID == turnID
                && harness.synthesis.spoken == [
                    .init(text: "Hola", localeIdentifier: "es-ES")
                ]
        }
        XCTAssertEqual(harness.coordinator.state, .ended)
        XCTAssertTrue(harness.coordinator.isSessionActive)

        harness.coordinator.start(pair: pair)
        XCTAssertEqual(harness.coordinator.state, .ended)
        XCTAssertEqual(harness.coordinator.reviewedPlaybackTurnID, turnID)

        harness.synthesis.finishBlockedSpeech()
        await assertEventually {
            harness.coordinator.reviewedPlaybackTurnID == nil
                && harness.coordinator.state == .ended
                && !harness.coordinator.isSessionActive
        }
    }

    @MainActor
    func testHindiAutoSpeakPausesAndResumesContinuousCapture() async throws {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [],
            processBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "hello")],
            pair: pair,
            translations: ["नमस्ते"]
        )

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.speakTranslations = true

        _ = try await harness.capture.emitBuffer()
        let committed = await waitUntil {
            harness.coordinator.turns.count == 1
                && harness.synthesis.spoken == [
                    .init(text: "नमस्ते", localeIdentifier: "hi-IN")
                ]
                && harness.coordinator.state == .listening
        }

        XCTAssertTrue(committed)
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertEqual(harness.capture.startCount, 2)
        XCTAssertTrue(harness.coordinator.isCaptureActive)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testReplayIsUnavailableWhileVADHasAnActiveUtterance() async throws {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            processBatches: [[.speechStarted(at: .zero)]],
            decisions: [Self.decision(text: "hello")],
            pair: pair,
            translations: ["नमस्ते"]
        )

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        XCTAssertTrue(paused)
        harness.coordinator.resumeSession()
        let resumed = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(resumed)
        _ = try await harness.capture.emitBuffer()
        guard let turnID = harness.coordinator.turns.first?.id else {
            return XCTFail("Expected a persisted Hindi turn.")
        }

        XCTAssertFalse(harness.coordinator.canReplayTranslation(for: turnID))
        harness.coordinator.replayTranslation(for: turnID)
        await Task.yield()
        XCTAssertTrue(harness.synthesis.spoken.isEmpty)
        XCTAssertTrue(harness.coordinator.isCaptureActive)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testEndedReplayBlocksStartingAnotherContinuousSession() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "hello")],
            pair: pair,
            translations: ["नमस्ते"]
        )

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        XCTAssertTrue(paused)
        harness.coordinator.endSession()
        let ended = await waitUntil { harness.coordinator.state == .ended }
        XCTAssertTrue(ended)
        guard let turnID = harness.coordinator.turns.first?.id else {
            return XCTFail("Expected a persisted Hindi turn.")
        }

        harness.synthesis.blocksSpeech = true
        harness.coordinator.replayTranslation(for: turnID)
        let replaying = await waitUntil {
            harness.coordinator.reviewedPlaybackTurnID == turnID
                && harness.synthesis.spoken.count == 1
        }
        XCTAssertTrue(replaying)
        XCTAssertTrue(harness.coordinator.isSessionActive)

        harness.coordinator.start(pair: pair)
        XCTAssertEqual(harness.coordinator.state, .ended)
        XCTAssertEqual(harness.coordinator.reviewedPlaybackTurnID, turnID)
        XCTAssertEqual(harness.coordinator.turns.count, 1)

        harness.synthesis.finishBlockedSpeech()
        let replayFinished = await waitUntil {
            harness.coordinator.reviewedPlaybackTurnID == nil
                && !harness.coordinator.isSessionActive
        }
        XCTAssertTrue(replayFinished)
    }

    @MainActor
    func testEntityMismatchCannotBeReplayed() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let harness = makeHarness(
            finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "I take insulin")],
            pair: pair,
            translations: ["मैं इबुप्रोफेन लेता हूँ"]
        )

        harness.coordinator.start(pair: pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 1
        }
        XCTAssertTrue(paused)
        guard let turnID = harness.coordinator.turns.first?.id else {
            return XCTFail("Expected a persisted Hindi turn.")
        }

        XCTAssertFalse(harness.coordinator.canReplayTranslation(for: turnID))
        harness.coordinator.replayTranslation(for: turnID)
        await Task.yield()
        XCTAssertTrue(harness.synthesis.spoken.isEmpty)
        XCTAssertNil(harness.coordinator.reviewedPlaybackTurnID)
        harness.coordinator.cancelSession()
    }

    @MainActor
    func testNonEnglishPairCommitsBothDirectionsAndCorrectsLanguage() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let pair = LanguagePair(
            traveler: .frenchFrance,
            local: .japaneseJapan
        )
        let harness = makeHarness(
            finishBatches: [
                [.speechEnded(range: range, reason: .silence)],
                [.speechEnded(range: range, reason: .silence)]
            ],
            decisions: [
                Self.decision(
                    text: "bonjour",
                    language: .frenchFrance,
                    alternate: Self.candidate(
                        text: "こんにちは",
                        language: .japaneseJapan
                    ),
                    reviewReasons: [.closeScores]
                ),
                Self.decision(
                    text: "ありがとう",
                    language: .japaneseJapan
                )
            ],
            pair: pair
        )

        harness.coordinator.start(pair: pair)
        let started = await waitUntil {
            harness.coordinator.state == .listening
        }
        XCTAssertTrue(started)
        harness.coordinator.pauseSession()
        let firstPauseFinished = await waitUntil {
            harness.coordinator.state == .pausedByUser
        }
        XCTAssertTrue(firstPauseFinished)

        harness.coordinator.resumeSession()
        let resumed = await waitUntil {
            harness.coordinator.state == .listening
        }
        XCTAssertTrue(resumed)
        harness.coordinator.pauseSession()
        let secondPauseFinished = await waitUntil {
            harness.coordinator.state == .pausedByUser
                && harness.coordinator.turns.count == 2
        }
        XCTAssertTrue(secondPauseFinished)

        XCTAssertEqual(harness.coordinator.turns.map(\.speaker), [
            .traveler,
            .local,
        ])
        XCTAssertEqual(harness.coordinator.turns.map(\.sourceLocale), [
            AppLanguage.frenchFrance.code,
            AppLanguage.japaneseJapan.code,
        ])
        XCTAssertEqual(harness.coordinator.turns.map(\.targetLocale), [
            AppLanguage.japaneseJapan.code,
            AppLanguage.frenchFrance.code,
        ])
        XCTAssertEqual(harness.translation.calls.map(\.speaker), [
            .traveler,
            .local,
        ])
        XCTAssertTrue(harness.translation.calls.allSatisfy { $0.pair == pair })

        guard let firstTurnID = harness.coordinator.turns.first?.id else {
            return XCTFail("Expected the first non-English turn.")
        }
        harness.coordinator.swapLanguage(for: firstTurnID)
        let correctedLanguage = await waitUntil {
            harness.coordinator.turns.first?.languageReviewStatus == .corrected
        }
        XCTAssertTrue(correctedLanguage)

        let corrected = harness.coordinator.turns.first
        XCTAssertEqual(corrected?.speaker, .local)
        XCTAssertEqual(corrected?.sourceLocale, AppLanguage.japaneseJapan.code)
        XCTAssertEqual(corrected?.targetLocale, AppLanguage.frenchFrance.code)
        XCTAssertEqual(corrected?.sourceText, "こんにちは")
        XCTAssertEqual(harness.translation.calls.last?.speaker, .local)
        XCTAssertEqual(harness.translation.calls.last?.pair, pair)
    }

    @MainActor
    func testUserPauseFinalizesAndDrainsBeforeResumeStartsFreshInput() async throws {
        let firstRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let secondRange = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 2, preferredTimescale: 1_000)
        )
        let harness = makeHarness(
            finishBatches: [
                [.speechEnded(range: firstRange, reason: .silence)],
                [.speechEnded(range: secondRange, reason: .silence)]
            ],
            processBatches: [[.speechStarted(at: .zero)]],
            decisions: [
                Self.decision(text: "hello"),
                Self.decision(text: "good morning")
            ]
        )

        harness.coordinator.start(pair: harness.pair)
        let started = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(started)
        XCTAssertTrue(harness.coordinator.isSessionActive)
        XCTAssertTrue(harness.coordinator.isCaptureActive)

        let previousDraft = harness.recognition.onDraft
        let previousFailure = harness.recognition.onFailure
        harness.coordinator.pauseSession()
        let firstPauseFinished = await waitUntil {
            harness.coordinator.state == .pausedByUser
        }
        XCTAssertTrue(firstPauseFinished)
        XCTAssertEqual(harness.coordinator.turns.map(\.sequence), [0])
        XCTAssertEqual(harness.coordinator.turns.first?.sourceText, "hello")
        XCTAssertEqual(harness.capture.startCount, 1)
        XCTAssertEqual(harness.capture.stopCount, 1)
        XCTAssertFalse(harness.coordinator.isCaptureActive)
        XCTAssertTrue(harness.coordinator.isSessionActive)

        harness.coordinator.resumeSession()
        let resumed = await waitUntil { harness.coordinator.state == .listening }
        XCTAssertTrue(resumed)
        _ = try await harness.capture.emitBuffer()
        let reply = ContinuousDraft(language: .spanishSpain, text: "Buenos días", confidence: 1, score: 1)
        harness.recognition.onDraft?(reply)
        previousDraft?(nil)
        previousFailure?(PipelineError.server("Retired stream"))
        XCTAssertEqual(harness.coordinator.draft, reply)
        XCTAssertEqual(harness.coordinator.state, .listening)
        XCTAssertEqual(harness.capture.startCount, 2)
        XCTAssertEqual(harness.recognition.startCount, 2)
        XCTAssertEqual(harness.coordinator.turns.map(\.sequence), [0])

        harness.coordinator.pauseSession()
        let secondPauseFinished = await waitUntil {
            harness.coordinator.state == .pausedByUser
        }
        XCTAssertTrue(secondPauseFinished)
        XCTAssertEqual(harness.coordinator.turns.map(\.sequence), [0, 1])
        XCTAssertEqual(harness.capture.startCount, 2)
        XCTAssertEqual(harness.capture.stopCount, 2)

        let finalizationCount = harness.recognition.finishInputCount
        harness.coordinator.endSession()
        let ended = await waitUntil { harness.coordinator.state == .ended }
        XCTAssertTrue(ended)
        XCTAssertEqual(harness.capture.startCount, 2)
        XCTAssertEqual(harness.recognition.finishInputCount, finalizationCount)
        XCTAssertEqual(harness.coordinator.turns.map(\.sequence), [0, 1])
        XCTAssertFalse(harness.coordinator.isSessionActive)
    }

    @MainActor
    func testSamePairRetryPreservesTurnsAndSequence() async {
        let range = CMTimeRange(
            start: .zero,
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let harness = makeHarness(
            finishBatches: [
                [.speechEnded(range: range, reason: .silence)],
                [.speechEnded(range: range, reason: .silence)]
            ],
            decisions: [
                Self.decision(text: "one"),
                Self.decision(text: "two")
            ]
        )

        harness.coordinator.start(pair: harness.pair)
        let started = await waitUntil {
            harness.coordinator.state == .listening
        }
        XCTAssertTrue(started)
        harness.coordinator.pauseSession()
        let paused = await waitUntil {
            harness.coordinator.state == .pausedByUser
        }
        XCTAssertTrue(paused)
        XCTAssertEqual(harness.coordinator.turns.map(\.sequence), [0])

        harness.capture.fail("Audio route changed.")
        guard case .failed = harness.coordinator.state else {
            return XCTFail("Expected the interrupted session to fail.")
        }
        XCTAssertEqual(harness.coordinator.turns.map(\.sequence), [0])

        harness.coordinator.retrySession(pair: harness.pair)
        let retried = await waitUntil {
            harness.coordinator.state == .listening
        }
        XCTAssertTrue(retried)
        XCTAssertEqual(harness.coordinator.turns.map(\.sequence), [0])

        harness.coordinator.pauseSession()
        let pausedAfterRetry = await waitUntil {
            harness.coordinator.state == .pausedByUser
        }
        XCTAssertTrue(pausedAfterRetry)
        XCTAssertEqual(harness.coordinator.turns.map(\.sequence), [0, 1])
        XCTAssertEqual(harness.capture.startCount, 2)
    }

    @MainActor
    func testMicrophoneBackgroundNotificationBeforeSceneChangePausesUntilResume() async {
        let harness = makeHarness(finishBatches: [], decisions: [])
        let talk = harness.coordinator
        talk.start(pair: harness.pair)
        defer { talk.cancelSession() }
        await assertEventually { talk.state == .listening }
        harness.capture.onCaptureInterrupted?(.background)
        talk.handleSceneActivity(isActive: false)
        talk.handleSceneActivity(isActive: true)
        XCTAssertEqual(talk.state, .interrupted)
        XCTAssertNil(talk.errorMessage)
        XCTAssertFalse(harness.capture.isActive)
        talk.resumeSession()
        await assertEventually { talk.state == .listening && harness.capture.isActive }
    }

    /// With the phone near an external speaker, play each station-question fixture
    /// when prompted. This exercises both sides of the actual audio-session handoff.
    @MainActor
    func testHindiAndEnglishPhysicalMicrophoneReopensAfterAutoSpeak() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEAK_DUET_LIVE_MIC"] == "1",
                          "Requires an iPhone and an external acoustic speech source.")
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let microphone = MicrophoneCaptureSession()
        let settings = SettingsStore(defaults: try XCTUnwrap(UserDefaults(suiteName: UUID().uuidString)))
        settings.value.autoSpeak = true
        let talk = ContinuousConversationCoordinator(
            capture: microphone, voiceActivity: SileroVoiceActivityDetector(),
            recognition: AppleContinuousSpeechRecognizer(), translation: ContinuousBidirectionalTranslationEngine(),
            playback: PlaybackService(synthesis: AppleSpeechSynthesisEngine()), settings: settings,
            history: HistoryStore(local: LocalHistoryStore(inMemory: true)), access: TestTranslationAuthorization()
        )
        var plays = 0
        let observer = talk.$state.sink { if $0 == .pausedForPlayback { plays += 1 } }
        defer { observer.cancel(); talk.cancelSession() }
        talk.speakTranslations = true
        talk.start(pair: pair)
        func wait(_ ready: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(35))
            while !ready() {
                if let message = talk.errorMessage { throw PipelineError.server(message) }
                guard ContinuousClock.now < deadline else {
                    throw PipelineError.server("Live microphone timeout in \(talk.state), saved \(talk.turns.count), playbacks \(plays)")
                }
                try await Task.sleep(for: .milliseconds(30))
            }
        }
        try await wait { talk.state == .listening && microphone.isActive }
        for (index, language) in [pair.local, pair.traveler].enumerated() {
            print("LIVE_MIC_READY \(language.code)")
            try await wait { plays == index + 1 && talk.turns.count == index + 1 && talk.state == .listening && microphone.isActive }
            let turn = talk.turns[index]
            XCTAssertEqual(turn.sourceLocale, language.code)
            XCTAssertEqual(turn.targetLocale, language == pair.local ? pair.traveler.code : pair.local.code)
            XCTAssertFalse(turn.translatedText.isEmpty)
        }
        // Leave time for the trailing TTS route and interruption notifications.
        try await Task.sleep(for: .seconds(2))
        XCTAssertEqual(talk.state, .listening)
        XCTAssertTrue(microphone.isActive)
        XCTAssertEqual(talk.turns.count, 2)
        talk.endSession()
        try await wait { talk.state == .ended }
    }

    @MainActor
    func testInstalledAppleModelsTranslateRecordedPausesOnDevice() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires installed physical-device speech and translation models.")
#else
        let pair = LanguagePair(traveler: .englishUS, local: .spanishSpain)
        let speech = AppleSpeechRecognitionEngine()
        let listen = await speech.continuousAssetReadiness(pair: pair)
        try XCTSkipUnless(listen == .ready, "English/Spanish device speech assets: \(listen).")
        // Probe the same installed-only strategy as Talk. Inventory can report
        // downloadRequired on launch even when these sessions can translate.
        let translation = AppleTranslationEngine(strategy: .lowLatency)
        do {
            _ = try await translation.translate("Good morning", source: pair.traveler.language, target: pair.local.language)
            _ = try await translation.translate("Gracias", source: pair.local.language, target: pair.traveler.language)
        } catch TranslationError.notInstalled {
            throw XCTSkip("Install the English/Spanish translation languages on this iPhone.")
        }
        for side in [SpeakerSide.traveler, .local] {
            let readiness = await translation.availability(source: pair.source(for: side).language,
                                                           target: pair.target(for: side).language)
            XCTAssertEqual(readiness, .ready, "Talk must allow a direction the installed model just translated")
        }
        translation.cancel()
        let synthesis = AppleSpeechSynthesisEngine()
        let voicesReady = synthesis.isVoiceAvailable(locale: pair.traveler.locale)
            && synthesis.isVoiceAvailable(locale: pair.local.locale)
        let harness = makeHarness(finishBatches: [], decisions: [])
        let coordinator = ContinuousConversationCoordinator(
            capture: harness.capture, voiceActivity: SileroVoiceActivityDetector(),
            recognition: AppleContinuousSpeechRecognizer(), translation: ContinuousBidirectionalTranslationEngine(),
            playback: PlaybackService(synthesis: synthesis), settings: harness.settings,
            history: harness.history, access: TestTranslationAuthorization()
        )
        defer { coordinator.cancelSession() }
        coordinator.start(pair: pair)

        func waitFor(_ predicate: () -> Bool) async throws {
            let deadline = ContinuousClock.now.advanced(by: .seconds(30))
            while !predicate() {
                if let error = coordinator.errorMessage { throw PipelineError.server(error) }
                guard ContinuousClock.now < deadline else {
                    throw PipelineError.server("Device timed out in \(coordinator.state), \(coordinator.turns.count) committed turns")
                }
                try await Task.sleep(for: .milliseconds(50))
            }
        }
        try await waitFor { coordinator.state == .listening }
        var sample: AVAudioFramePosition = 0
        for (index, name) in ["SpokenTurn", "SpokenReply", "SpokenTurn"].enumerated() {
            // Exercise a continuously open stream and automatic restart for playback.
            coordinator.speakTranslations = voicesReady && index != 0
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "wav"))
            let recording = try AVAudioFile(forReading: url)
            let format = recording.processingFormat
            let started = ContinuousClock.now
            var firstDraftAt: ContinuousClock.Instant?
            var firstPendingAt: ContinuousClock.Instant?
            var committedAt: ContinuousClock.Instant?
            let pending = coordinator.$pendingDrafts.sink { bySequence in
                if bySequence[index] != nil, firstPendingAt == nil { firstPendingAt = .now }
            }
            let drafts = coordinator.$draft.sink { draft in
                if draft != nil, firstDraftAt == nil { firstDraftAt = .now }
            }
            let commits = coordinator.$turns.sink { turns in
                if turns.count == index + 1 { committedAt = .now }
            }
            defer { drafts.cancel(); pending.cancel(); commits.cancel() }
            // Allow enough continuous audio for Apple's progressive results on a cold device.
            var remainingRepeats = index == 2 ? 2 : 0
            var speechFileEnded = started
            for _ in 0..<500 {
                // AnalyzerInput retains the buffer until the system consumes it.
                let chunk = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1024))
                if recording.framePosition == recording.length, remainingRepeats > 0 {
                    recording.framePosition = 0
                    remainingRepeats -= 1
                }
                if recording.framePosition < recording.length {
                    try recording.read(into: chunk, frameCount: 1024)
                    speechFileEnded = .now
                } else {
                    chunk.frameLength = 1024
                    chunk.floatChannelData![0].initialize(repeating: 0, count: 1024)
                }
                let time = AVAudioTime(sampleTime: sample, atRate: format.sampleRate)
                sample += AVAudioFramePosition(chunk.frameLength)
                let disposition = try await harness.capture.emit(chunk, at: time)
                if case .finish = disposition { break }
                if coordinator.turns.count > index { break }
                if let error = coordinator.errorMessage { throw PipelineError.server(error) }
                try await Task.sleep(for: .seconds(Double(chunk.frameLength) / format.sampleRate))
            }
            try await waitFor { coordinator.turns.count == index + 1 && coordinator.state == .listening && harness.capture.isActive }
            let firstDraft = try XCTUnwrap(firstDraftAt ?? firstPendingAt, "Turn must show source words before translation")
            if index == 2 { XCTAssertNotNil(firstDraftAt, "Sustained speech must show words while the utterance is open") }
            let commit = try XCTUnwrap(committedAt)
            XCTAssertLessThan(firstDraft, commit)
            print("Turn \(index + 1) first draft \(started.duration(to: firstDraft)), last speech buffer to commit \(speechFileEnded.duration(to: commit))")
            let turn = coordinator.turns[index]
            XCTAssertEqual(turn.speaker, index == 1 ? .local : .traveler)
            XCTAssertFalse(turn.translatedText.isEmpty)
            print("Device turn \(index + 1), Auto Speak \(coordinator.speakTranslations), listening \(speechFileEnded.duration(to: .now)) after the last speech buffer")
        }
        let completedTurns = coordinator.turns
        coordinator.handleSceneActivity(isActive: false)
        coordinator.handleSceneActivity(isActive: true)
        XCTAssertEqual(coordinator.state, .interrupted)
        if voicesReady {
            for turn in completedTurns.prefix(2) {
                XCTAssertTrue(coordinator.canReplayTranslation(for: turn))
                coordinator.replayTranslation(for: turn.id)
                try await waitFor { !coordinator.isReviewedPlaybackActive }
                XCTAssertNil(coordinator.errorMessage)
                XCTAssertFalse(coordinator.isCaptureActive)
            }
        }
        coordinator.resumeSession()
        try await waitFor { coordinator.state == .listening }
        XCTAssertEqual(coordinator.turns, completedTurns)
        coordinator.endSession()
        try await waitFor { coordinator.state == .ended }
        XCTAssertEqual(coordinator.turns.count, 3)
#endif
    }

    @MainActor
    func testLateDraftCannotBlockReplayAndUnlockKeepsMicrophoneOff() async throws {
        let end = CMTime(seconds: 1, preferredTimescale: 16000)
        let h = makeHarness(
            finishBatches: [], processBatches: [[.speechStarted(at: .zero),
                .speechEnded(range: CMTimeRange(start: .zero, end: end), reason: .silence)]],
            decisions: [Self.decision(text: "Hi, how are you?")], translations: ["Hola, ¿cómo estás?"]
        )
        let session = h.coordinator
        session.start(pair: h.pair)
        defer { session.cancelSession() }
        await assertEventually { session.state == .listening }
        _ = try await h.capture.emitBuffer()
        await assertEventually { session.turns.count == 1 && session.canReplayTranslation(for: session.turns[0]) }

        let turn = try XCTUnwrap(session.turns.first)
        h.recognition.onDraft?(ContinuousDraft(language: .spanishSpain, text: "How.", confidence: 0.5, score: 0.5))
        XCTAssertNil(session.draft)
        XCTAssertEqual(turn.translatedText, "Hola, ¿cómo estás?")
        XCTAssertTrue(session.canReplayTranslation(for: turn))

        h.synthesis.blocksSpeech = true
        session.replayTranslation(for: turn.id)
        await assertEventually { !h.synthesis.spoken.isEmpty }
        session.handleSceneActivity(isActive: false)
        XCTAssertEqual(session.state, .interrupted)
        XCTAssertNil(session.reviewedPlaybackTurnID)
        XCTAssertFalse(session.canReplayTranslation(for: turn))

        session.handleSceneActivity(isActive: true)
        XCTAssertTrue(session.canReplayTranslation(for: turn))
        session.replayTranslation(for: turn.id)
        await assertEventually { h.synthesis.spoken.count == 2 }
        session.resumeSession()
        XCTAssertEqual(h.capture.startCount, 1)
        h.synthesis.finishBlockedSpeech()
        await assertEventually { !session.isReviewedPlaybackActive }
        XCTAssertEqual(session.state, .interrupted)
        XCTAssertFalse(session.isCaptureActive)
        XCTAssertEqual(session.turns.map(\.id), [turn.id])

        session.resumeSession()
        await assertEventually { session.state == .listening }
        XCTAssertEqual(h.capture.startCount, 2)
        XCTAssertEqual(session.turns.map(\.id), [turn.id])
    }

    @MainActor
    func testLiveReplySurvivesEarlierTranslationAndLayoutSwitch() async throws {
        let end = CMTime(seconds: 1, preferredTimescale: 16000)
        let h = makeHarness(
            finishBatches: [], processBatches: [[.speechStarted(at: .zero)],
                [.speechEnded(range: CMTimeRange(start: .zero, end: end), reason: .silence)],
                [.speechStarted(at: end)]],
            decisions: [Self.decision(text: "Where is the station?")],
            translations: ["¿Dónde está la estación?"]
        )
        h.coordinator.start(pair: h.pair)
        defer { h.coordinator.cancelSession() }
        await assertEventually { h.coordinator.state == .listening }
        let first = ContinuousDraft(language: .englishUS, text: "Where is the station?", confidence: 1, score: 1)
        let reply = ContinuousDraft(language: .spanishSpain, text: "A cinco", confidence: 1, score: 1)
        _ = try await h.capture.emitBuffer()
        h.recognition.snapshot = first
        h.recognition.onDraft?(first)
        XCTAssertEqual(h.coordinator.draft, first)
        XCTAssertTrue(h.coordinator.turns.isEmpty)
        h.recognition.delayFinalization = true
        h.translation.delayNextTranslation = true
        _ = try await h.capture.emitBuffer()
        await assertEventually { h.recognition.resumeFinalization != nil }
        XCTAssertEqual(h.coordinator.pendingDrafts[0]?.text, first.text)
        h.recognition.snapshot = reply
        h.recognition.onDraft?(reply)
        XCTAssertNil(h.coordinator.draft)
        _ = try await h.capture.emitBuffer()
        XCTAssertEqual(h.coordinator.draft, reply)
        h.settings.value.talkLayout = .heldPhone
        XCTAssertTrue(h.coordinator.hasActiveSpeech)
        let revision = ContinuousDraft(language: .englishUS, text: "Where is the station", confidence: 0.9, score: 0.9)
        h.recognition.onClosingRevision?(revision)
        XCTAssertEqual(h.coordinator.pendingDrafts[0], revision)
        XCTAssertEqual(h.coordinator.draft, reply)
        h.recognition.resumeFinalization?.resume()
        await assertEventually { h.translation.resumeTranslation != nil }
        h.translation.resumeTranslation?.resume()
        await assertEventually { h.coordinator.turns.count == 1 }
        XCTAssertEqual(h.coordinator.draft, reply)
        XCTAssertTrue(h.coordinator.pendingDrafts.isEmpty)
        XCTAssertEqual(h.capture.startCount, 1)
        XCTAssertEqual(h.coordinator.turns.first?.translatedText, "¿Dónde está la estación?")
    }

    @MainActor
    func testThreeLiveTurnsResumeWithoutStopOrDuplicateFlush() async throws {
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 16000))
        let boundary: [VoiceActivityEvent] = [.speechStarted(at: .zero), .speechEnded(range: range, reason: .silence)]
        let harness = makeHarness(
            finishBatches: [], processBatches: Array(repeating: boundary, count: 3),
            decisions: [Self.decision(text: "hello"), Self.decision(text: "hola", language: .spanishSpain),
                        Self.decision(text: "goodbye")],
            translations: ["hola", "hello", "adiós"], access: TestTranslationAuthorization()
        )
        harness.coordinator.start(pair: harness.pair)
        await assertEventually { harness.coordinator.state == .listening }
        harness.coordinator.speakTranslations = true
        for count in 1...3 {
            _ = try await harness.capture.emitBuffer()
            await assertEventually {
                harness.coordinator.turns.count == count && harness.capture.startCount == count + 1
            }
            XCTAssertEqual(harness.recognition.finishInputCount, count)
            XCTAssertEqual(harness.recognition.startCount, count + 1)
        }
        harness.coordinator.endSession()
        await assertEventually { harness.coordinator.state == .ended }
        XCTAssertEqual(harness.coordinator.turns.map(\.translatedText), ["hola", "hello", "adiós"])
    }

    @MainActor
    func testLockedTranslationCannotStartCapture() async {
        let access = TestTranslationAuthorization()
        access.allowed = false
        let harness = makeHarness(finishBatches: [], decisions: [], access: access)
        harness.coordinator.start(pair: harness.pair)
        XCTAssertEqual(harness.capture.startCount, 0)
        XCTAssertEqual(harness.coordinator.state, .idle)
        XCTAssertEqual(harness.coordinator.errorMessage, "Translation access ended.")
    }

    @MainActor
    func testExpiryStopsNextContinuousUtteranceAndRetainsCompletedText() async throws {
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        let access = TestTranslationAuthorization()
        let harness = makeHarness(
            finishBatches: [],
            processBatches: [[.speechEnded(range: range, reason: .silence)], [.speechStarted(at: .zero)]],
            decisions: [Self.decision(text: "hello")], translations: ["hola"], access: access
        )
        harness.coordinator.start(pair: harness.pair)
        await assertEventually { harness.coordinator.state == .listening }
        _ = try await harness.capture.emitBuffer()
        await assertEventually { harness.coordinator.turns.count == 1 }
        access.allowed = false
        do {
            _ = try await harness.capture.emitBuffer()
            XCTFail("An expired session accepted new speech")
        } catch { harness.capture.fail("Translation access ended.") }
        XCTAssertFalse(harness.capture.isActive)
        XCTAssertEqual(harness.coordinator.turns.count, 1)
        XCTAssertEqual(harness.coordinator.turns.first?.translatedText, "hola")
    }

    @MainActor
    func testUtteranceStartedWithAccessCanFinishAfterExpiry() async throws {
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1_000))
        let access = TestTranslationAuthorization()
        let harness = makeHarness(
            finishBatches: [],
            processBatches: [[.speechStarted(at: .zero)], [.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "hello")], translations: ["hola"], access: access
        )
        harness.coordinator.start(pair: harness.pair)
        await assertEventually { harness.coordinator.state == .listening }
        _ = try await harness.capture.emitBuffer()
        access.allowed = false
        _ = try await harness.capture.emitBuffer()
        await assertEventually { harness.coordinator.turns.count == 1 }
        XCTAssertEqual(harness.coordinator.turns.first?.translatedText, "hola")
        harness.coordinator.cancelSession()
    }

    @MainActor
    private func makeHarness(
        finishBatches: [[VoiceActivityEvent]],
        processBatches: [[VoiceActivityEvent]] = [],
        decisions: [LanguageDecision],
        pair: LanguagePair = LanguagePair(
            traveler: .englishUS,
            local: .spanishSpain
        ),
        translations: [String] = [],
        access: (any TranslationAuthorizing)? = nil
    ) -> (
        coordinator: ContinuousConversationCoordinator,
        capture: FakeContinuousCapture,
        voiceActivity: FakeContinuousVoiceActivity,
        recognition: FakeContinuousRecognition,
        translation: FakeContinuousTranslation,
        synthesis: FakeContinuousSynthesis,
        settings: SettingsStore,
        history: HistoryStore,
        pair: LanguagePair
    ) {
        let capture = FakeContinuousCapture()
        let voiceActivity = FakeContinuousVoiceActivity(
            finishBatches: finishBatches,
            processBatches: processBatches
        )
        let recognition = FakeContinuousRecognition(decisions: decisions)
        let defaultsName = "ContinuousConversationCoordinatorTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: defaultsName)!
        defaults.removePersistentDomain(forName: defaultsName)
        let settings = SettingsStore(defaults: defaults)
        settings.value.autoSpeak = false
        let translation = FakeContinuousTranslation(translations: translations)
        let synthesis = FakeContinuousSynthesis()
        let history = HistoryStore(local: LocalHistoryStore(inMemory: true))
        let coordinator = ContinuousConversationCoordinator(
            capture: capture,
            voiceActivity: voiceActivity,
            recognition: recognition,
            translation: translation,
            playback: PlaybackService(synthesis: synthesis),
            settings: settings,
            history: history,
            access: access
        )
        return (
            coordinator,
            capture,
            voiceActivity,
            recognition,
            translation,
            synthesis,
            settings,
            history,
            pair
        )
    }

    @MainActor
    private func assertEventually(
        _ condition: @escaping @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        let matched = await waitUntil(condition)
        XCTAssertTrue(matched, file: file, line: line)
    }

    @MainActor
    private func waitUntil(
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    private static func decision(
        text: String,
        language: AppLanguage = .englishUS,
        alternate: RecognitionCandidate? = nil,
        reviewReasons: Set<LanguageReviewReason> = []
    ) -> LanguageDecision {
        LanguageDecision(
            selected: candidate(text: text, language: language),
            alternate: alternate,
            reviewReasons: reviewReasons
        )
    }

    private static func candidate(
        text: String,
        language: AppLanguage
    ) -> RecognitionCandidate {
        RecognitionCandidate(
            language: language,
            text: text,
            isFinal: true,
            confidence: 0.95,
            lowConfidenceFraction: 0,
            constrainedLanguageProbability: 0.95,
            score: 0.95
        )
    }
}

@MainActor
final class TestTranslationAuthorization: TranslationAuthorizing {
    var allowed = true
    func authorizeTranslation() throws {
        if !allowed { throw PipelineError.server("Translation access ended.") }
    }
}

@MainActor
final class FakeContinuousCapture: MicrophoneCapturing {
    var onCaptureInterrupted: ((CaptureLifecycleEvent) -> Void)?
    var onCaptureLimitReached: (() -> Void)?
    var onCaptureFailed: ((String) -> Void)?
    private(set) var isActive = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private var generation: UUID?
    private var onBuffer: (@MainActor (CapturedAudioBuffer) async throws -> CaptureBufferDisposition)?

    func requestPermission() async -> Bool { true }

    func start(
        generation: UUID,
        onBuffer: @escaping @MainActor (CapturedAudioBuffer) async throws -> CaptureBufferDisposition
    ) throws -> UUID {
        guard !isActive else {
            throw PipelineError.server("Capture already active.")
        }
        isActive = true
        startCount += 1
        self.generation = generation
        self.onBuffer = onBuffer
        return generation
    }

    func stop() async throws {
        guard isActive else { throw PipelineError.noSpeech }
        isActive = false
        stopCount += 1
    }

    func cancel() {
        isActive = false
        generation = nil
        onBuffer = nil
    }

    func emitBuffer() async throws -> CaptureBufferDisposition {
        let format = AVAudioFormat(
            standardFormatWithSampleRate: 16_000,
            channels: 1
        )!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 160)!
        buffer.frameLength = 160
        return try await emit(buffer, at: AVAudioTime(sampleTime: 0, atRate: 16_000))
    }

    func emit(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime) async throws -> CaptureBufferDisposition {
        guard isActive, let generation, let onBuffer else {
            throw PipelineError.server("Capture is not active.")
        }
        return try await onBuffer(CapturedAudioBuffer(
            buffer: buffer,
            audioTime: time,
            generation: generation
        ))
    }

    func fail(_ message: String) {
        onCaptureFailed?(message)
    }
}

private actor FakeContinuousVoiceActivity: VoiceActivityDetecting {
    private var finishBatches: [[VoiceActivityEvent]]
    private var processBatches: [[VoiceActivityEvent]]

    init(
        finishBatches: [[VoiceActivityEvent]],
        processBatches: [[VoiceActivityEvent]] = []
    ) {
        self.finishBatches = finishBatches
        self.processBatches = processBatches
    }

    func prepare() async throws {}

    func process(_ input: VoiceActivityInput) async throws -> VoiceActivityResult {
        let events = processBatches.isEmpty ? [] : processBatches.removeFirst()
        return VoiceActivityResult(
            probabilities: [],
            events: events,
            processedThrough: .zero
        )
    }

    func finish() async throws -> VoiceActivityResult {
        let events = finishBatches.isEmpty ? [] : finishBatches.removeFirst()
        return VoiceActivityResult(
            probabilities: [],
            events: events,
            processedThrough: events.compactMap { event in
                guard case let .speechEnded(range, _) = event else { return nil }
                return CMTimeRangeGetEnd(range)
            }.max(by: { CMTimeCompare($0, $1) < 0 }) ?? .zero
        )
    }

    func reset() async {}
}

@MainActor
private final class FakeContinuousRecognition: ContinuousSpeechRecognizing {
    private var decisions: [LanguageDecision]
    var onDraft: ((ContinuousDraft?) -> Void)?
    var onFailure: ((Error) -> Void)?
    var onClosingRevision: ((ContinuousDraft?) -> Void)?
    var snapshot: ContinuousDraft?
    var delayFinalization = false
    var resumeFinalization: CheckedContinuation<Void, Never>?
    var startError: Error?
    private(set) var startCount = 0
    private(set) var finishInputCount = 0

    init(decisions: [LanguageDecision]) {
        self.decisions = decisions
    }

    func start(
        pair: LanguagePair,
        onDraft: @escaping @MainActor (ContinuousDraft?) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) async throws {
        self.onDraft = onDraft
        self.onFailure = onFailure
        startCount += 1
        if let startError { throw startError }
    }

    func append(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime?) throws {}

    func beginUtterance(at start: CMTime) {
        onDraft?(snapshot)
    }

    func takeDraft(in range: CMTimeRange, onRevision: @escaping @MainActor (ContinuousDraft?) -> Void) -> ContinuousDraft? {
        onClosingRevision = onRevision
        defer { snapshot = nil }
        onDraft?(nil)
        return snapshot
    }

    func finishInput() throws -> CMTime? {
        finishInputCount += 1
        return nil
    }

    func finalizeUtterance(in range: CMTimeRange) async throws -> LanguageDecision {
        if delayFinalization {
            delayFinalization = false
            await withCheckedContinuation { resumeFinalization = $0 }
            resumeFinalization = nil
        }
        guard !decisions.isEmpty else { throw PipelineError.noSpeech }
        return decisions.removeFirst()
    }

    func cancelAnalysis(before time: CMTime) {}
    func stop() {}
}

@MainActor
private final class FakeContinuousTranslation: ContinuousBidirectionalTranslating {
    struct Preparation: Equatable {
        let pair: LanguagePair
        let strategy: OnDeviceTranslationStrategy
    }

    struct Call: Equatable {
        let text: String
        let speaker: SpeakerSide
        let pair: LanguagePair
    }

    var delayNextTranslation = false
    var resumeTranslation: CheckedContinuation<Void, Never>?
    var prepareError: Error?
    private var translations: [String]
    private(set) var preparations: [Preparation] = []
    private(set) var calls: [Call] = []

    init(translations: [String] = []) {
        self.translations = translations
    }

    func prepare(
        pair: LanguagePair,
        strategy: OnDeviceTranslationStrategy
    ) async throws {
        preparations.append(Preparation(pair: pair, strategy: strategy))
        if let prepareError { throw prepareError }
    }

    func translate(
        _ text: String,
        speaker: SpeakerSide,
        pair: LanguagePair
    ) async throws -> String {
        calls.append(Call(text: text, speaker: speaker, pair: pair))
        if delayNextTranslation {
            delayNextTranslation = false
            await withCheckedContinuation { resumeTranslation = $0 }
            resumeTranslation = nil
        }
        return translations.isEmpty ? "translated \(text)" : translations.removeFirst()
    }

    func cancel() {}
}

@MainActor
private final class FakeContinuousSynthesis: SpeechSynthesisEngine {
    struct Spoken: Equatable {
        let text: String
        let localeIdentifier: String
    }

    private(set) var spoken: [Spoken] = []
    var unavailableVoiceIdentifiers: Set<String> = []
    var blocksSpeech = false
    private var blockedSpeechContinuation: CheckedContinuation<Void, Error>?

    func isVoiceAvailable(locale: Locale) -> Bool {
        !unavailableVoiceIdentifiers.contains(locale.identifier)
    }
    func speak(_ text: String, locale: Locale, rate: Float) async throws {
        spoken.append(Spoken(text: text, localeIdentifier: locale.identifier))
        if blocksSpeech {
            try await withCheckedThrowingContinuation { continuation in
                blockedSpeechContinuation = continuation
            }
        }
    }
    func play(data: Data, format: String?) async throws {}
    func cancel() {
        blockedSpeechContinuation?.resume(throwing: CancellationError())
        blockedSpeechContinuation = nil
    }

    func finishBlockedSpeech() {
        blockedSpeechContinuation?.resume()
        blockedSpeechContinuation = nil
    }
}

extension ContinuousConversationCoordinatorTests {
    @MainActor
    func testCompetingFinalsBlockPlaybackUntilTheGermanSpeakerIsConfirmed() async throws {
        let pair = LanguagePair(traveler: .frenchFrance, local: .germanGermany)
        let german = Self.candidate(text: "Wo ist der Bahnhof?", language: .germanGermany)
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1000))
        let harness = makeHarness(finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "Vous Esteban Hof", language: .frenchFrance,
                                       alternate: german, reviewReasons: [.closeScores, .competingFinals])],
            pair: pair, translations: ["Où est la gare ?"])
        let talk = harness.coordinator
        talk.start(pair: pair)
        defer { talk.cancelSession() }
        await assertEventually { talk.state == .listening }
        talk.speakTranslations = true
        talk.pauseSession()
        await assertEventually { talk.state == .pausedByUser && talk.turns.count == 1 }
        let pending = try XCTUnwrap(talk.turns.first)
        XCTAssertTrue(pending.warnings.contains(.unresolvedSpeaker))
        XCTAssertFalse(talk.canReplayTranslation(for: pending))
        XCTAssertTrue(harness.synthesis.spoken.isEmpty)
        XCTAssertTrue(harness.translation.calls.isEmpty)
        XCTAssertTrue(talk.confirmSpeaker(for: pending.id, language: .germanGermany, text: german.text))
        await assertEventually { talk.turns.first?.languageReviewStatus == .corrected }
        let corrected = try XCTUnwrap(talk.turns.first)
        XCTAssertEqual(corrected.id, pending.id)
        XCTAssertEqual(corrected.targetLocale, pair.traveler.code)
        XCTAssertEqual(corrected.translatedText, "Où est la gare ?")
    }

    @MainActor
    func testUnresolvedSpeakerCanChooseLanguageAndEditWithoutAnAlternate() async throws {
        let range = CMTimeRange(start: .zero, duration: CMTime(seconds: 1, preferredTimescale: 1000))
        let harness = makeHarness(finishBatches: [[.speechEnded(range: range, reason: .silence)]],
            decisions: [Self.decision(text: "Two tickets cost thirty", language: .spanishSpain, reviewReasons: [.conflictingSpeakerEvidence])],
            translations: ["Dos billetes cuestan treinta euros."])
        let talk = harness.coordinator
        talk.start(pair: harness.pair)
        await assertEventually { talk.state == .listening }
        talk.speakTranslations = true
        talk.pauseSession()
        await assertEventually { talk.state == .pausedByUser && talk.turns.count == 1 }
        let pending = try XCTUnwrap(talk.turns.first)
        XCTAssertTrue(pending.warnings.contains(.unresolvedSpeaker))
        XCTAssertTrue(harness.translation.calls.isEmpty)
        XCTAssertFalse(talk.canReplayTranslation(for: pending))
        // Resolve this saved turn after an interruption. The phone must translate
        // the correction without restarting capture or playing unconfirmed audio.
        talk.handleSceneActivity(isActive: false)
        XCTAssertFalse(talk.canResolveSpeaker)
        talk.handleSceneActivity(isActive: true)
        XCTAssertEqual(talk.state, .interrupted)
        let captureStarts = harness.capture.startCount
        talk.confirmSpeaker(for: pending.id, language: .englishUS, text: "Two tickets cost thirty euros.")
        await assertEventually { talk.turns.first?.languageReviewStatus == .corrected }
        let final = try XCTUnwrap(talk.turns.first)
        XCTAssertEqual(final.id, pending.id)
        XCTAssertEqual(final.sequence, pending.sequence)
        XCTAssertEqual(final.sourceLocale, "en-US")
        XCTAssertEqual(final.targetLocale, "es-ES")
        XCTAssertEqual(final.translatedText, "Dos billetes cuestan treinta euros.")
        XCTAssertFalse(final.warnings.contains(.unresolvedSpeaker))
        XCTAssertEqual(harness.translation.calls.count, 1)
        XCTAssertEqual(talk.state, .interrupted)
        XCTAssertEqual(harness.capture.startCount, captureStarts)
        talk.cancelSession()
    }
}
