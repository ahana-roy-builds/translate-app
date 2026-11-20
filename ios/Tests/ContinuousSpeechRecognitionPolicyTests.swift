import AVFoundation
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

    func testCompetingFrenchAndGermanFinalsRequireSpeakerChoice() throws {
        let pair = LanguagePair(traveler: .frenchFrance, local: .germanGermany)
        let french = candidate(language: pair.traveler, text: "Vous Esteban Hof",
                               confidence: 0.839, lowFraction: 0, languageProbability: 0.998)
        let german = candidate(language: pair.local, text: "Wo ist der Bahnhof?",
                               confidence: 0.771, lowFraction: 0, languageProbability: 1)
        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(candidates: [french, german], pair: pair))
        XCTAssertTrue(decision.requiresSpeakerChoice)
        XCTAssertTrue(decision.reviewReasons.contains(.competingFinals))
        let short = candidate(language: pair.traveler, text: "Hof",
                              confidence: 0.839, lowFraction: 0, languageProbability: 0.998)
        let weakAlternate = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(candidates: [german, short], pair: pair))
        XCTAssertFalse(weakAlternate.reviewReasons.contains(.competingFinals))
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

        XCTAssertEqual(decision.selected.language, .englishUS)
        XCTAssertTrue(decision.reviewReasons.contains(.experimentalLanguagePair))
        XCTAssertTrue(decision.needsReview)
    }

    func testPhoneticallyPlausibleEnglishWithUncertainWordsDoesNotOverrideHindi() throws {
        let english = candidate(language: .englishUS, text: "Funny miss, but hey.", confidence: 0.67,
                                lowFraction: 0.10, languageProbability: 1)
        let hindi = candidate(language: .hindiIndia, text: "पानी मेज़ पर है", confidence: 0.5,
                              lowFraction: 1, languageProbability: 1)
        let pair = LanguagePair(traveler: .hindiIndia, local: .englishUS)
        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(candidates: [english, hindi], pair: pair))
        XCTAssertEqual(decision.selected.language, .hindiIndia)
        var selector = ContinuousDraftSelector()
        _ = selector.select(candidates: [english])
        let candidates = [english, hindi]
        let preference = PairLanguageEvidencePolicy.preferredLanguage(in: candidates)
        XCTAssertEqual(selector.select(candidates: candidates, preferredLanguage: preference)?.language, .englishUS)
        XCTAssertEqual(selector.select(candidates: candidates, preferredLanguage: preference)?.language, .hindiIndia)
    }

    func testPunctuationAloneCannotWinOrBecomeAnAlternate() throws {
        let punctuation = candidate(language: .englishUS, text: "...", confidence: 0.99,
                                    lowFraction: 0, languageProbability: 1)
        let spoken = candidate(language: .hindiIndia, text: "हाँ", confidence: 0.5,
                               lowFraction: 0, languageProbability: 1)
        let pair = LanguagePair(traveler: .hindiIndia, local: .englishUS)
        let decision = try XCTUnwrap(ContinuousLanguageDecisionPolicy.decide(candidates: [punctuation, spoken], pair: pair))
        XCTAssertEqual(decision.selected.language, .hindiIndia)
        XCTAssertNil(decision.alternate)
        XCTAssertNil(ContinuousLanguageDecisionPolicy.decide(candidates: [punctuation], pair: pair))
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

    func testCrossingWordBelongsToOnlyTheTurnContainingItsMidpoint() {
        var word = AttributedString("puente")
        word[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] = range(start: 0.6, duration: 0.5)
        var accumulator = ContinuousRecognitionAccumulator()
        accumulator.apply(range: range(start: 0.6, duration: 0.5), text: "puente", isFinal: true,
                          confidence: 0.95, lowConfidenceFraction: 0, timedText: word)
        XCTAssertEqual(accumulator.transcript(in: range(start: 0, duration: 1))?.text, "puente")
        XCTAssertNil(accumulator.transcript(in: range(start: 1, duration: 1)))
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

    func testAdjacentIsolatedTurnsSplitTheSamePCMBufferWithoutLeakingAudio() throws {
        let format = try XCTUnwrap(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 32))
        buffer.frameLength = 32
        for i in 0..<32 { buffer.floatChannelData![0][i] = Float(i) }
        var audio = TurnSpeechAudio()
        let start = CMTime(value: 48_000, timescale: 16_000)
        let split = start + CMTime(value: 12, timescale: 16_000)
        let end = start + CMTime(value: 32, timescale: 16_000)
        audio.append(buffer, through: end, speechStart: start)
        let first = CMTimeRange(start: start, end: split)
        let second = CMTimeRange(start: split, end: end)
        func samples(_ turn: CMTimeRange) throws -> [Float] {
            try audio.take(turn).compactMap { try $0.samples(in: turn) }.flatMap { part in
                Array(UnsafeBufferPointer(start: part.floatChannelData![0], count: Int(part.frameLength)))
            }
        }
        XCTAssertEqual(try samples(first), (0..<12).map(Float.init))
        XCTAssertEqual(try samples(second), (12..<32).map(Float.init))
        XCTAssertTrue(audio.take(first).isEmpty)
    }

    @MainActor
    func testQueuedHindiAndEnglishTurnsUseSeparateSpeechContextsOnDevice() async throws {
#if targetEnvironment(simulator)
        throw XCTSkip("Requires installed English and Hindi speech models on an iPhone.")
#else
        let pair = LanguagePair(traveler: .englishUS, local: .hindiIndia)
        let availability = await AppleSpeechRecognitionEngine().continuousAssetReadiness(pair: pair)
        try XCTSkipUnless(ContinuousModePolicy.supports(pair) && availability == .ready, "English and Hindi models required.")
        let recognizer = AppleContinuousSpeechRecognizer()
        defer { recognizer.stop() }
        try await recognizer.start(pair: pair, onDraft: { _ in }, onFailure: { XCTFail($0.localizedDescription) })
        var time = CMTime.zero
        var ranges: [CMTimeRange] = []
        // Queue the English response before waiting for Hindi to finish.
        // The Hindi fixture is synthetic: “मुझे जयपुर जाना है, दिल्ली नहीं।”
        for name in ["SpokenHindiDestination", "SpokenTurn"] {
            let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: name, withExtension: "wav"))
            let file = try AVAudioFile(forReading: url)
            let start = time
            recognizer.beginUtterance(at: start)
            while file.framePosition < file.length {
                let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: 1024))
                try file.read(into: buffer)
                let rate = CMTimeScale(file.processingFormat.sampleRate.rounded())
                let stamp = AVAudioTime(sampleTime: CMTimeConvertScale(time, timescale: rate, method: .default).value,
                                        atRate: file.processingFormat.sampleRate)
                try recognizer.append(buffer, at: stamp)
                time = time + CMTime(value: Int64(buffer.frameLength), timescale: rate)
            }
            let turn = CMTimeRange(start: start, end: time)
            ranges.append(turn)
            _ = recognizer.takeDraft(in: turn) { _ in }
        }
        _ = try recognizer.finishInput()
        let hindi = try await recognizer.finalizeUtterance(in: ranges[0])
        let english = try await recognizer.finalizeUtterance(in: ranges[1])
        XCTAssertEqual(hindi.selected.language, .hindiIndia)
        XCTAssertTrue(hindi.selected.text.contains("जयपुर"))
        XCTAssertEqual(english.selected.language, .englishUS)
        XCTAssertFalse(english.selected.text.isEmpty)
#endif
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
