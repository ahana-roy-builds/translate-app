import CoreMedia
import Speech
import XCTest
@testable import LocalLingo

final class ContinuousSpeechRecognitionPolicyTests: XCTestCase {
    func testCandidateUsesApprovedWeightedScore() throws {
        let transcript = Transcript(
            text: "Where is the station?",
            isFinal: true,
            confidence: 0.8,
            lowConfidenceFraction: 0.25
        )

        let candidate = try XCTUnwrap(ContinuousLanguageDecisionPolicy.makeCandidate(
            language: .englishUS,
            transcript: transcript,
            constrainedLanguageProbability: 0.9
        ))

        XCTAssertEqual(candidate.score, 0.8, accuracy: 0.000_001)
        XCTAssertEqual(candidate.confidence, 0.8)
        XCTAssertEqual(candidate.lowConfidenceFraction, 0.25)
    }

    func testMissingConfidenceAndLanguageProbabilityUseNeutralDefaults() throws {
        let candidate = try XCTUnwrap(ContinuousLanguageDecisionPolicy.makeCandidate(
            language: .englishUS,
            transcript: Transcript(
                text: "Where is the station?",
                isFinal: false,
                confidence: nil,
                lowConfidenceFraction: 0
            ),
            constrainedLanguageProbability: nil
        ))

        XCTAssertEqual(candidate.score, 0.6, accuracy: 0.000_001)
        XCTAssertNil(candidate.confidence)
    }

    func testDecisionSelectsHighestScoreAndKeepsAlternate() throws {
        let english = candidate(
            language: .englishUS,
            text: "Where is the station?",
            confidence: 0.9,
            lowFraction: 0,
            languageProbability: 0.95
        )
        let spanish = candidate(
            language: .spanishSpain,
            text: "Guer is de stasion",
            confidence: 0.55,
            lowFraction: 0.4,
            languageProbability: 0.1
        )

        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(
            candidates: [spanish, english]
        ))

        XCTAssertEqual(decision.selected.language, .englishUS)
        XCTAssertEqual(decision.alternate?.language, .spanishSpain)
        XCTAssertFalse(decision.needsReview)
    }

    func testDecisionFlagsShortCloseAndLowScoringUtterance() throws {
        let english = candidate(
            language: .englishUS,
            text: "Three",
            confidence: 0.55,
            lowFraction: 0.5,
            languageProbability: 0.7
        )
        let spanish = candidate(
            language: .spanishSpain,
            text: "Tri",
            confidence: 0.54,
            lowFraction: 0.5,
            languageProbability: 0.3
        )

        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(
            candidates: [english, spanish]
        ))

        XCTAssertTrue(decision.reviewReasons.contains(.shortUtterance))
        XCTAssertTrue(decision.reviewReasons.contains(.lowScore))
        XCTAssertTrue(decision.reviewReasons.contains(.closeScores))
    }

    func testDecisionFlagsStrongTextLanguageDisagreement() throws {
        let english = candidate(
            language: .englishUS,
            text: "This has enough letters",
            confidence: 0.95,
            lowFraction: 0,
            languageProbability: 0.1
        )

        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(
            candidates: [english]
        ))

        XCTAssertTrue(decision.reviewReasons.contains(.languageDisagreement))
    }

    func testDecisionMarksMissingFinalOnlyAlternateForReview() throws {
        let english = candidate(
            language: .englishUS,
            text: "Where is the train station?",
            confidence: 0.95,
            lowFraction: 0,
            languageProbability: 0.95
        )

        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(
            candidates: [english]
        ))

        XCTAssertEqual(decision.selected.language, .englishUS)
        XCTAssertNil(decision.alternate)
        XCTAssertTrue(decision.reviewReasons.contains(.missingAlternate))
        XCTAssertTrue(decision.needsReview)
    }

    func testDevanagariProvidesStrongEvidenceOnlyForEnglishHindiPair() {
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let text = "रेलवे स्टेशन कहाँ है"

        XCTAssertEqual(
            PairLanguageEvidencePolicy.constrainedProbability(
                base: 0.4,
                text: text,
                expected: .hindiIndia,
                pair: pair
            ),
            0.98
        )
        XCTAssertEqual(
            PairLanguageEvidencePolicy.constrainedProbability(
                base: 0.6,
                text: text,
                expected: .englishUS,
                pair: pair
            ),
            0.02
        )
    }

    func testHindiScriptEvidenceDoesNotGuessRomanizedHinglish() {
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        XCTAssertEqual(
            PairLanguageEvidencePolicy.constrainedProbability(
                base: 0.35,
                text: "station kidhar hai",
                expected: .hindiIndia,
                pair: pair
            ),
            0.35
        )
    }

    func testHindiScriptEvidenceDoesNotAlterOtherLanguagePairs() {
        let pair = LanguagePair(traveler: .englishUS, local: .spanishSpain)
        XCTAssertEqual(
            PairLanguageEvidencePolicy.constrainedProbability(
                base: 0.45,
                text: "रेलवे स्टेशन कहाँ है",
                expected: .englishUS,
                pair: pair
            ),
            0.45
        )
    }

    func testEnglishHindiDecisionUsesDevanagariBeforeCrossModelConfidence() throws {
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let english = candidate(
            language: .englishUS,
            text: "railway station kaha hai",
            confidence: 0.92,
            lowFraction: 0.02,
            languageProbability: 0.9
        )
        let hindi = candidate(
            language: .hindiIndia,
            text: "रेलवे स्टेशन कहाँ है",
            confidence: 0.68,
            lowFraction: 0.15,
            languageProbability: 0.98
        )

        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(
            candidates: [english, hindi],
            pair: pair
        ))

        XCTAssertEqual(decision.selected.language, .hindiIndia)
        XCTAssertEqual(decision.alternate?.language, .englishUS)
        XCTAssertTrue(decision.needsReview)
    }

    func testEnglishHindiDecisionTreatsLatinOnlyOutputAsEnglish() throws {
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let english = candidate(
            language: .englishUS,
            text: "where is the railway station",
            confidence: 0.7,
            lowFraction: 0.1,
            languageProbability: 0.9
        )
        let hindi = candidate(
            language: .hindiIndia,
            text: "where is the railway station",
            confidence: 0.9,
            lowFraction: 0,
            languageProbability: 0.6
        )

        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(
            candidates: [hindi, english],
            pair: pair
        ))

        XCTAssertEqual(decision.selected.language, .englishUS)
        XCTAssertEqual(decision.alternate?.language, .hindiIndia)
        XCTAssertTrue(decision.needsReview)
    }

    func testEnglishHindiDecisionAlwaysRequiresReviewEvenWithClearScoreLead() throws {
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let english = candidate(
            language: .englishUS,
            text: "where is the railway station",
            confidence: 0.99,
            lowFraction: 0,
            languageProbability: 0.99
        )
        let hindi = candidate(
            language: .hindiIndia,
            text: "वेयर इज़ द रेलवे स्टेशन",
            confidence: 0.4,
            lowFraction: 0.6,
            languageProbability: 0.98
        )

        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(
            candidates: [english, hindi],
            pair: pair
        ))

        XCTAssertEqual(decision.selected.language, .hindiIndia)
        XCTAssertTrue(decision.reviewReasons.contains(.experimentalLanguagePair))
        XCTAssertTrue(decision.needsReview)
    }

    func testFinalizationProgressRequiresEveryCompanionThroughTarget() {
        var progress = ContinuousFinalizationProgress()
        let target = CMTime(seconds: 3, preferredTimescale: 16_000)

        progress.record(
            CMTime(seconds: 3, preferredTimescale: 16_000),
            for: .englishUS
        )
        XCTAssertFalse(progress.includes(
            [.englishUS, .spanishSpain],
            through: target
        ))

        progress.record(
            CMTime(seconds: 2.9, preferredTimescale: 16_000),
            for: .spanishSpain
        )
        XCTAssertFalse(progress.includes(
            [.englishUS, .spanishSpain],
            through: target
        ))

        progress.record(
            CMTime(seconds: 3.1, preferredTimescale: 16_000),
            for: .spanishSpain
        )
        XCTAssertTrue(progress.includes(
            [.englishUS, .spanishSpain],
            through: target
        ))
    }

    func testHindiDictationGetsALongerBoundedFinalResultDrain() {
        XCTAssertEqual(
            AppleContinuousSpeechRecognizer.finalResultDrainTimeout(
                for: LanguagePair(traveler: .englishUS, local: .spanishSpain)
            ),
            .milliseconds(500)
        )
        XCTAssertEqual(
            AppleContinuousSpeechRecognizer.finalResultDrainTimeout(
                for: LanguagePair(traveler: .englishUS, local: .hindiIndia)
            ),
            .seconds(3)
        )
    }

    func testFinalDrainAcceptsOneRecognizerWhenAlternateStaysSilent() {
        XCTAssertTrue(AppleContinuousSpeechRecognizer.shouldAcceptFinalizedCandidates(
            allModulesDrained: false,
            candidateCount: 1
        ))
        XCTAssertTrue(AppleContinuousSpeechRecognizer.shouldAcceptFinalizedCandidates(
            allModulesDrained: true,
            candidateCount: 0
        ))
        XCTAssertFalse(AppleContinuousSpeechRecognizer.shouldAcceptFinalizedCandidates(
            allModulesDrained: false,
            candidateCount: 0
        ))
    }

    func testFinalizableRangeCapsVadEndAtDeliveredAudio() throws {
        let requested = range(start: 1, duration: 2)
        let delivered = CMTime(seconds: 2.75, preferredTimescale: 16_000)

        let capped = try XCTUnwrap(
            ContinuousRecognitionTimingPolicy.finalizableRange(
                requested: requested,
                deliveredThrough: delivered
            )
        )

        XCTAssertEqual(capped.start.seconds, 1, accuracy: 0.000_001)
        XCTAssertEqual(CMTimeRangeGetEnd(capped).seconds, 2.75, accuracy: 0.000_001)
        XCTAssertNil(ContinuousRecognitionTimingPolicy.finalizableRange(
            requested: requested,
            deliveredThrough: requested.start
        ))
    }

    func testDraftRequiresTwoConsecutiveLeadsBeforeSwitchingLanguage() throws {
        var selector = ContinuousDraftSelector()
        let initialEnglish = candidate(
            language: .englishUS,
            text: "English draft",
            confidence: 0.8,
            lowFraction: 0,
            languageProbability: 0.8
        )
        let weakSpanish = candidate(
            language: .spanishSpain,
            text: "Spanish draft",
            confidence: 0.6,
            lowFraction: 0.2,
            languageProbability: 0.2
        )
        let strongSpanish = candidate(
            language: .spanishSpain,
            text: "Borrador en español",
            confidence: 0.95,
            lowFraction: 0,
            languageProbability: 0.95
        )

        XCTAssertEqual(
            selector.select(candidates: [initialEnglish, weakSpanish])?.language,
            .englishUS
        )
        XCTAssertEqual(
            selector.select(candidates: [initialEnglish, strongSpanish])?.language,
            .englishUS
        )
        XCTAssertEqual(
            selector.select(candidates: [initialEnglish, strongSpanish])?.language,
            .spanishSpain
        )
    }

    func testAccumulatorReplacesVolatileRangeAndBuildsWeightedTranscript() throws {
        var accumulator = ContinuousRecognitionAccumulator()
        let first = range(start: 1, duration: 1)
        let second = range(start: 2.1, duration: 1)
        XCTAssertTrue(accumulator.apply(
            range: first,
            text: "stale",
            isFinal: false,
            confidence: 0.2,
            lowConfidenceFraction: 0.8
        ))
        XCTAssertTrue(accumulator.apply(
            range: first,
            text: "hello",
            isFinal: true,
            confidence: 0.8,
            lowConfidenceFraction: 0.2
        ))
        XCTAssertTrue(accumulator.apply(
            range: second,
            text: "world",
            isFinal: true,
            confidence: 1,
            lowConfidenceFraction: 0
        ))

        let transcript = try XCTUnwrap(accumulator.transcript())

        XCTAssertEqual(transcript.text, "hello world")
        XCTAssertTrue(transcript.isFinal)
        XCTAssertEqual(transcript.confidence ?? 0, 0.9, accuracy: 0.000_001)
        XCTAssertEqual(transcript.lowConfidenceFraction, 0.1, accuracy: 0.000_001)
    }

    func testAccumulatorFiltersAndDiscardsCompletedRanges() throws {
        var accumulator = ContinuousRecognitionAccumulator()
        XCTAssertTrue(accumulator.apply(
            range: range(start: 0, duration: 1),
            text: "old",
            isFinal: true,
            confidence: 1,
            lowConfidenceFraction: 0
        ))
        XCTAssertTrue(accumulator.apply(
            range: range(start: 2, duration: 1),
            text: "current",
            isFinal: false,
            confidence: 0.8,
            lowConfidenceFraction: 0.1
        ))

        XCTAssertEqual(
            accumulator.transcript(in: range(start: 1.5, duration: 2))?.text,
            "current"
        )
        accumulator.discard(before: CMTime(seconds: 1.1, preferredTimescale: 1_000))
        XCTAssertEqual(accumulator.transcript()?.text, "current")
    }

    func testBoundarySplitsTimedWordsAndKeepsBufferedReply() {
        var accumulator = ContinuousRecognitionAccumulator()
        var lastWord = AttributedString("thanks")
        lastWord[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = range(start: 0, duration: 1)
        var reply = AttributedString("hola")
        reply[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = range(start: 1, duration: 0.5)
        let words = lastWord + AttributedString(" ") + reply
        accumulator.apply(range: range(start: 0, duration: 1.5), text: "thanks hola", isFinal: false,
                          confidence: 0.9, lowConfidenceFraction: 0, timedText: words)
        accumulator.apply(range: range(start: 1.5, duration: 0.5), text: "amiga", isFinal: false,
                          confidence: 0.9, lowConfidenceFraction: 0, timedText: AttributedString("amiga"))
        let firstTurn = range(start: 0, duration: 1)
        XCTAssertEqual(accumulator.transcript(in: firstTurn)?.text, "thanks")
        accumulator.retireLiveDraft(through: firstTurn.end)
        XCTAssertEqual(accumulator.transcript()?.text, "hola amiga")
    }

    func testAccumulatorTreatsEmptyPointRevisionAsRetraction() {
        var accumulator = ContinuousRecognitionAccumulator()
        XCTAssertTrue(accumulator.apply(
            range: range(start: 1, duration: 2),
            text: "volatile words",
            isFinal: false,
            confidence: 0.7,
            lowConfidenceFraction: 0.2
        ))

        XCTAssertTrue(accumulator.apply(
            range: range(start: 1.5, duration: 0),
            text: "",
            isFinal: false,
            confidence: nil,
            lowConfidenceFraction: 1
        ))

        XCTAssertNil(accumulator.transcript())
    }

    private func candidate(
        language: AppLanguage,
        text: String,
        confidence: Double,
        lowFraction: Double,
        languageProbability: Double
    ) -> RecognitionCandidate {
        ContinuousLanguageDecisionPolicy.makeCandidate(
            language: language,
            transcript: Transcript(
                text: text,
                isFinal: true,
                confidence: confidence,
                lowConfidenceFraction: lowFraction
            ),
            constrainedLanguageProbability: languageProbability
        )!
    }

    private func range(start: Double, duration: Double) -> CMTimeRange {
        CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 1_000),
            duration: CMTime(seconds: duration, preferredTimescale: 1_000)
        )
    }
}
