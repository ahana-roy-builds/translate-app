import AVFoundation
import CoreMedia
import Foundation
import NaturalLanguage
import OSLog
import Speech

@MainActor
final class AppleContinuousSpeechRecognizer: ContinuousSpeechRecognizing {
    // Only the opt-in synthetic-fixture runner supplies this observer.
    var observeFixtureDiagnostic: ((String, [String: String]) -> Void)? {
        didSet { turnSession?.observeFixtureDiagnostic = observeFixtureDiagnostic }
    }
    private let usesSharedAnalyzer: Bool

    init(usesSharedAnalyzer: Bool = false) {
        self.usesSharedAnalyzer = usesSharedAnalyzer
    }

    private enum ResultKind {
        case liveDraft
        case finalOnly
    }

    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpeakDuet", category: "Recognition")
    private var turnSession: TurnSpeechSession?
    private var analyzer: SpeechAnalyzer?
    private var converter: SpeechAnalyzerInputConverter?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultTasks: [Task<Void, Never>] = []
    private var cleanupTask: Task<Void, Never>?
    private var liveAccumulators: [AppLanguage: ContinuousRecognitionAccumulator] = [:]
    private var finalAccumulators: [AppLanguage: ContinuousRecognitionAccumulator] = [:]
    private var finalizationProgress = ContinuousFinalizationProgress()
    private var activePair: LanguagePair?
    private var liveBoundary: CMTime?
    private var activeSpeechStart: CMTime?
    private struct ClosingDraft {
        let range: CMTimeRange
        var selector: ContinuousDraftSelector
        let publish: @MainActor (ContinuousDraft?) -> Void
    }
    private var closingDrafts: [ClosingDraft] = []
    private var draftSelector = ContinuousDraftSelector()
    private var onDraft: (@MainActor (ContinuousDraft?) -> Void)?
    private var onFailure: (@MainActor (Error) -> Void)?
    private var terminalError: Error?
    private var generation = UUID()
    private var hasReceivedAudio = false
    private var inputFinished = false

    func start(
        pair: LanguagePair,
        onDraft: @escaping @MainActor (ContinuousDraft?) -> Void,
        onFailure: @escaping @MainActor (Error) -> Void
    ) async throws {
        let previousAnalyzer = detachCurrentSession()
        if let cleanupTask {
            await cleanupTask.value
            self.cleanupTask = nil
        }
        if let previousAnalyzer { await previousAnalyzer.cancelAndFinishNow() }
        try Task.checkCancellation()

        let languageNames = ContinuousModePolicy.languageNames(for: pair)
        guard ContinuousModePolicy.supports(pair) else {
            throw PipelineError.unsupportedLocale(
                "\(languageNames) for continuous conversation. Select a different supported language pair."
            )
        }
        let travelerPlan = try await AppleSpeechModulePlan.resolve(
            for: pair.traveler.locale
        )
        let localPlan = try await AppleSpeechModulePlan.resolve(
            for: pair.local.locale
        )
        if !usesSharedAnalyzer || pair.isEnglishHindi {
            turnSession = try await TurnSpeechSession(pair: pair, plans: [travelerPlan, localPlan], onDraft: onDraft)
            turnSession?.observeFixtureDiagnostic = observeFixtureDiagnostic
            return
        }
        // Apple may not reissue an unchanged volatile result when finalizing.
        // Final-only companions are therefore authoritative for committed turns.
        let travelerLive = travelerPlan.makeModule(for: .continuousLive)
        let localLive = localPlan.makeModule(for: .continuousLive)
        let travelerFinal = travelerPlan.makeModule(for: .continuousFinal)
        let localFinal = localPlan.makeModule(for: .continuousFinal)
        let transcriptionModules = [
            travelerLive,
            localLive,
            travelerFinal,
            localFinal
        ]
        let modules = transcriptionModules.map { $0.analyzerModule }
        let status = await AssetInventory.status(forModules: modules)
        try Task.checkCancellation()
        guard status == .installed else {
            throw PipelineError.assetsUnavailable(
                "The Listen models for \(languageNames) must be installed before continuous conversation."
            )
        }
        guard let analyzerFormat = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules) else {
            throw PipelineError.assetsUnavailable(
                "The Listen models for \(languageNames) cannot run together on this iPhone."
            )
        }
        try Task.checkCancellation()

        let options = SpeechAnalyzer.Options(priority: .userInitiated, modelRetention: .whileInUse)
        let analyzer = SpeechAnalyzer(modules: modules, options: options)
        try await analyzer.prepareToAnalyze(in: analyzerFormat)
        try Task.checkCancellation()

        let (stream, continuation) = AsyncStream.makeStream(
            of: AnalyzerInput.self,
            bufferingPolicy: .bufferingOldest(128)
        )
        let sessionGeneration = UUID()
        generation = sessionGeneration
        self.analyzer = analyzer
        converter = SpeechAnalyzerInputConverter(analyzerFormat: analyzerFormat)
        inputContinuation = continuation
        activePair = pair
        liveAccumulators = [
            pair.traveler: ContinuousRecognitionAccumulator(),
            pair.local: ContinuousRecognitionAccumulator()
        ]
        finalAccumulators = [
            pair.traveler: ContinuousRecognitionAccumulator(),
            pair.local: ContinuousRecognitionAccumulator()
        ]
        finalizationProgress = ContinuousFinalizationProgress()
        draftSelector.reset()
        self.onDraft = onDraft
        self.onFailure = onFailure
        terminalError = nil
        hasReceivedAudio = false
        inputFinished = false

        resultTasks = [
            consumeResults(
                from: travelerLive,
                language: pair.traveler,
                kind: .liveDraft,
                generation: sessionGeneration
            ),
            consumeResults(
                from: localLive,
                language: pair.local,
                kind: .liveDraft,
                generation: sessionGeneration
            ),
            consumeResults(
                from: travelerFinal,
                language: pair.traveler,
                kind: .finalOnly,
                generation: sessionGeneration
            ),
            consumeResults(
                from: localFinal,
                language: pair.local,
                kind: .finalOnly,
                generation: sessionGeneration
            )
        ]
        analysisTask = Task { @MainActor [weak self] in
            do {
                _ = try await analyzer.analyzeSequence(stream)
                guard !Task.isCancelled,
                      let self,
                      self.generation == sessionGeneration,
                      !self.inputFinished else { return }
                self.recordFailure(
                    PipelineError.server("Continuous listening ended unexpectedly."),
                    generation: sessionGeneration
                )
            } catch is CancellationError {
                return
            } catch {
                self?.recordFailure(error, generation: sessionGeneration)
            }
        }
    }

    func append(_ buffer: AVAudioPCMBuffer, at audioTime: AVAudioTime?) throws {
        if let turnSession { return try turnSession.append(buffer, at: audioTime) }
        if let terminalError { throw terminalError }
        guard let converter, let inputContinuation else {
            throw PipelineError.server("Continuous listening has not started.")
        }
        let analyzerTime = hasReceivedAudio ? nil : audioTime
        let inputs = try converter.convert(buffer, at: analyzerTime)
        if buffer.frameLength > 0 { hasReceivedAudio = true }
        try deliver(inputs, using: inputContinuation, converter: converter)
    }

    func finishInput() throws -> CMTime? {
        if let turnSession { return try turnSession.finishInput() }
        if let terminalError { throw terminalError }
        guard let converter, let inputContinuation else {
            throw PipelineError.server("Continuous listening has not started.")
        }
        if inputFinished { return converter.deliveredThrough }
        let tail = try converter.flush()
        try deliver(tail, using: inputContinuation, converter: converter)
        inputFinished = true
        inputContinuation.finish()
        return converter.deliveredThrough
    }

    func finalizeUtterance(in range: CMTimeRange) async throws -> LanguageDecision {
        if let turnSession { return try await turnSession.finalize(range) }
        let sessionGeneration = generation
        defer {
            if sessionGeneration == generation {
                closingDrafts.removeAll { $0.range == range }
                trimLiveBuffer(through: range.end)
            }
        }
        if let terminalError { throw terminalError }
        guard let analyzer, let pair = activePair else {
            throw PipelineError.server("Continuous listening has not started.")
        }
        guard let finalizableRange = ContinuousRecognitionTimingPolicy.finalizableRange(
            requested: range,
            deliveredThrough: converter?.deliveredThrough
        ) else {
            throw PipelineError.noSpeech
        }
        let startSeconds = CMTimeGetSeconds(finalizableRange.start)
        let end = CMTimeRangeGetEnd(finalizableRange)
        let endSeconds = CMTimeGetSeconds(end)
        guard startSeconds.isFinite, endSeconds.isFinite, endSeconds > startSeconds else {
            throw PipelineError.server("Continuous listening supplied an invalid utterance range.")
        }

        do {
            try await analyzer.finalize(through: end)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            recordFailure(error, generation: sessionGeneration)
            throw error
        }
        try Task.checkCancellation()
        if let terminalError { throw terminalError }

        let finalResultsReady = try await waitForFinalResults(
            through: end,
            range: finalizableRange,
            pair: pair,
            generation: sessionGeneration
        )
        if let observeFixtureDiagnostic {
            observeFixtureDiagnostic("finalization", [
                "drained": String(finalResultsReady), "requestedEnd": String(range.end.seconds),
                "deliveredThrough": String(converter?.deliveredThrough?.seconds ?? 0),
                "finalizedEnd": String(finalizableRange.end.seconds)
            ])
        }
        let candidates = finalizedCandidates(in: finalizableRange, pair: pair)
        logger.debug("Finalized range \(startSeconds) to \(endSeconds), candidates \(candidates.count)")
        guard Self.shouldAcceptFinalizedCandidates(
            allModulesDrained: finalResultsReady,
            candidateCount: candidates.count
        ) else {
            try await discardCompletedAnalysis(
                before: end,
                pair: pair,
                analyzer: analyzer,
                generation: sessionGeneration
            )
            throw PipelineError.noSpeech
        }
        guard generation == sessionGeneration else { throw CancellationError() }
        if let terminalError { throw terminalError }
        guard let decision = ContinuousLanguageDecisionPolicy.decide(
            candidates: candidates,
            pair: pair
        ) else {
            try await discardCompletedAnalysis(
                before: end,
                pair: pair,
                analyzer: analyzer,
                generation: sessionGeneration
            )
            throw PipelineError.noSpeech
        }
        guard TurnTextPolicy.isFinalTextWithinLimit(decision.selected.text) else {
            throw PipelineError.server(
                "The speech result is too long. Please split the turn and try again."
            )
        }

        try await discardCompletedAnalysis(
            before: end,
            pair: pair,
            analyzer: analyzer,
            generation: sessionGeneration
        )
        return decision
    }

    func cancelAnalysis(before time: CMTime) {
        if let turnSession { return turnSession.discard(before: time) }
        guard CMTimeGetSeconds(time).isFinite else { return }
        for language in Array(liveAccumulators.keys) {
            liveAccumulators[language]?.discard(before: time)
            finalAccumulators[language]?.discard(before: time)
        }
        if let analyzer {
            Task { await analyzer.cancelAnalysis(before: time) }
        }
    }

    func stop() {
        let canceledAnalyzer = detachCurrentSession()
        if let canceledAnalyzer {
            let priorCleanup = cleanupTask
            cleanupTask = Task {
                await priorCleanup?.value
                await canceledAnalyzer.cancelAndFinishNow()
            }
        }
    }

    private func consumeResults(
        from transcriptionModule: AppleSpeechTranscriptionModule,
        language: AppLanguage,
        kind: ResultKind,
        generation: UUID
    ) -> Task<Void, Never> {
        Task { @MainActor [weak self] in
            do {
                for try await result in transcriptionModule.normalizedResults() {
                    guard !Task.isCancelled else { return }
                    switch kind {
                    case .liveDraft:
                        self?.consumeLive(
                            result,
                            language: language,
                            generation: generation
                        )
                    case .finalOnly:
                        self?.consumeFinal(
                            result,
                            language: language,
                            generation: generation
                        )
                    }
                }
                guard !Task.isCancelled,
                      let self,
                      self.generation == generation,
                      !self.inputFinished else { return }
                self.recordFailure(
                    PipelineError.server("A continuous Listen model stopped unexpectedly."),
                    generation: generation
                )
            } catch is CancellationError {
                return
            } catch {
                self?.recordFailure(error, generation: generation)
            }
        }
    }

    private func consumeLive(
        _ result: NormalizedAppleSpeechResult,
        language: AppLanguage,
        generation: UUID
    ) {
        guard generation == self.generation, terminalError == nil else { return }
        var range = result.range
        var words = result.text
        if let boundary = liveBoundary {
            let end = CMTimeRangeGetEnd(range)
            guard CMTimeCompare(end, boundary) > 0 else { return }
            if CMTimeCompare(range.start, boundary) < 0 {
                let segment = ContinuousRecognitionSegment(
                    range: range, text: String(words.characters), isFinal: result.isFinal,
                    confidence: nil, lowConfidenceFraction: 0, timedText: words
                )
                range = CMTimeRange(start: boundary, end: end)
                words = segment.clipped(to: range)?.timedText ?? AttributedString()
            }
        }
        let text = String(words.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard TurnTextPolicy.isFinalTextWithinLimit(text) else {
            recordFailure(
                PipelineError.server(
                    "The speech result is too long. Please split the turn and try again."
                ),
                generation: generation
            )
            return
        }
        let confidence = Self.confidenceSummary(words)
        guard liveAccumulators[language]?.apply(
            range: range,
            text: text,
            isFinal: result.isFinal,
            confidence: confidence.mean,
            lowConfidenceFraction: confidence.lowFraction,
            timedText: words
        ) == true else {
            recordFailure(
                PipelineError.server(
                    "The speech result was too complex. Please split the turn and try again."
                ),
                generation: generation
            )
            return
        }
        for index in closingDrafts.indices {
            let interval = closingDrafts[index].range
            guard CMTimeRangeGetIntersection(interval, otherRange: range).duration > .zero else { continue }
            let revision = makeDraft(in: interval, selector: &closingDrafts[index].selector)
            closingDrafts[index].publish(revision)
        }
        if let activeSpeechStart, range.end > activeSpeechStart {
            publishActiveDraft(from: activeSpeechStart)
        }
    }

    private func consumeFinal(
        _ result: NormalizedAppleSpeechResult,
        language: AppLanguage,
        generation: UUID
    ) {
        guard generation == self.generation, terminalError == nil else { return }
        guard result.isFinal else { return }
        let text = String(result.text.characters)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard TurnTextPolicy.isFinalTextWithinLimit(text) else {
            recordFailure(
                PipelineError.server(
                    "The speech result is too long. Please split the turn and try again."
                ),
                generation: generation
            )
            return
        }
        if let observeFixtureDiagnostic {
            let timedWords = result.text.runs.compactMap { run -> String? in
                guard let time = run[AttributeScopes.SpeechAttributes.TimeRangeAttribute.self] else { return nil }
                return "\(String(result.text[run.range].characters))@\(time.start.seconds)-\(time.end.seconds)"
            }
            observeFixtureDiagnostic("rawFinal", ["locale": language.code, "text": text, "timedWords": timedWords.joined(separator: "|")])
        }
        let confidence = Self.confidenceSummary(result.text)
        guard finalAccumulators[language]?.apply(
            range: result.range,
            text: text,
            isFinal: true,
            confidence: confidence.mean,
            lowConfidenceFraction: confidence.lowFraction,
            timedText: result.text
        ) == true else {
            recordFailure(
                PipelineError.server(
                    "The speech result was too complex. Please split the turn and try again."
                ),
                generation: generation
            )
            return
        }
        if let accumulatedText = finalAccumulators[language]?.transcript()?.text,
           !TurnTextPolicy.isFinalTextWithinLimit(accumulatedText) {
            recordFailure(
                PipelineError.server(
                    "The speech result is too long. Please split the turn and try again."
                ),
                generation: generation
            )
            return
        }
        finalizationProgress.record(
            result.resultsFinalizationTime,
            for: language
        )
    }

    func beginUtterance(at start: CMTime) {
        if let turnSession { return turnSession.begin(at: start) }
        activeSpeechStart = start
        trimLiveBuffer(through: start)
        draftSelector.reset()
        publishActiveDraft(from: start)
    }

    private func publishActiveDraft(from start: CMTime) {
        // Audio is fed to recognition before VAD confirms the onset. Include
        // those buffered words, but never text from the preceding silence.
        guard let end = converter?.deliveredThrough, end > start else { return }
        onDraft?(makeDraft(in: CMTimeRange(start: start, end: end), selector: &draftSelector))
    }

    func takeDraft(in range: CMTimeRange, onRevision: @escaping @MainActor (ContinuousDraft?) -> Void) -> ContinuousDraft? {
        if let turnSession { return turnSession.close(range, onRevision: onRevision) }
        let snapshot = makeDraft(in: range, selector: &draftSelector)
        closingDrafts.append(ClosingDraft(range: range, selector: draftSelector, publish: onRevision))
        activeSpeechStart = nil
        draftSelector.reset()
        onDraft?(nil)
        return snapshot
    }

    private func trimLiveBuffer(through time: CMTime) {
        // Finalization and new speech can overlap. Retain words for every
        // outstanding range until its final-only candidates are available.
        var boundary = closingDrafts.reduce(time) { CMTimeMinimum($0, $1.range.start) }
        if let activeSpeechStart { boundary = CMTimeMinimum(boundary, activeSpeechStart) }
        if let liveBoundary, boundary <= liveBoundary { return }
        liveBoundary = boundary
        for language in Array(liveAccumulators.keys) {
            liveAccumulators[language]?.retireLiveDraft(through: boundary)
        }
    }

    private func makeDraft(in range: CMTimeRange, selector: inout ContinuousDraftSelector) -> ContinuousDraft? {
        guard let pair = activePair else { return nil }
        let candidates = [pair.traveler, pair.local].compactMap { language in
            makeCandidate(
                language: language,
                range: range,
                pair: pair,
                accumulators: liveAccumulators
            )
        }
        guard let selected = selector.select(candidates: candidates, pair: pair) else {
            return nil
        }
        return ContinuousDraft(
            language: selected.language,
            text: TurnTextPolicy.clampedPartial(selected.text),
            confidence: selected.confidence,
            score: selected.score
        )
    }

    private func makeCandidate(
        language: AppLanguage,
        range: CMTimeRange?,
        pair: LanguagePair,
        accumulators: [AppLanguage: ContinuousRecognitionAccumulator]
    ) -> RecognitionCandidate? {
        guard let transcript = accumulators[language]?.transcript(in: range) else { return nil }
        return ContinuousLanguageDecisionPolicy.makeCandidate(
            language: language,
            transcript: transcript,
            constrainedLanguageProbability: Self.languageProbability(
                for: transcript.text,
                expected: language,
                pair: pair
            )
        )
    }

    private func finalizedCandidates(
        in range: CMTimeRange,
        pair: LanguagePair
    ) -> [RecognitionCandidate] {
        [pair.traveler, pair.local].compactMap { language in
            guard let candidate = makeCandidate(
                language: language,
                range: range,
                pair: pair,
                accumulators: finalAccumulators
            ), candidate.isFinal else {
                return nil
            }
            return candidate
        }
    }

    private func waitForFinalResults(
        through target: CMTime,
        range: CMTimeRange,
        pair: LanguagePair,
        generation: UUID
    ) async throws -> Bool {
        let languages = [pair.traveler, pair.local]
        let clock = ContinuousClock()
        let start = clock.now
        let alternateDeadline = start.advanced(by: .milliseconds(500))
        let firstResultDeadline = start.advanced(by: .seconds(3))
        while !finalizationProgress.includes(languages, through: target) {
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            if let terminalError { throw terminalError }
            if clock.now >= alternateDeadline {
                if clock.now >= firstResultDeadline { return false }
                if languages.contains(where: { finalAccumulators[$0]?.transcript(in: range) != nil }) {
                    return false
                }
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        return true
    }

    private func discardCompletedAnalysis(
        before end: CMTime,
        pair: LanguagePair,
        analyzer: SpeechAnalyzer,
        generation sessionGeneration: UUID
    ) async throws {
        await analyzer.cancelAnalysis(before: end)
        guard generation == sessionGeneration else { throw CancellationError() }
        for language in [pair.traveler, pair.local] {
            finalAccumulators[language]?.discard(before: end)
        }
    }

    nonisolated static func shouldAcceptFinalizedCandidates(
        allModulesDrained: Bool,
        candidateCount: Int
    ) -> Bool {
        allModulesDrained || candidateCount > 0
    }

    private func deliver(
        _ inputs: [AnalyzerInput],
        using continuation: AsyncStream<AnalyzerInput>.Continuation,
        converter: SpeechAnalyzerInputConverter
    ) throws {
        for input in inputs {
            switch continuation.yield(input) {
            case .enqueued:
                try converter.recordDelivery(of: input)
            case .dropped:
                let error = PipelineError.server(
                    "Continuous listening could not keep up with microphone audio."
                )
                recordFailure(error, generation: generation)
                throw error
            case .terminated:
                let error = PipelineError.server(
                    "Continuous listening input ended unexpectedly."
                )
                recordFailure(error, generation: generation)
                throw error
            @unknown default:
                let error = PipelineError.server(
                    "Continuous listening could not deliver microphone audio."
                )
                recordFailure(error, generation: generation)
                throw error
            }
        }
    }

    private func recordFailure(_ error: Error, generation: UUID) {
        guard generation == self.generation, terminalError == nil else { return }
        terminalError = error
        onFailure?(error)
    }

    @discardableResult
    private func detachCurrentSession() -> SpeechAnalyzer? {
        generation = UUID()
        if let turnSession {
            cleanupTask = turnSession.stop()
            self.turnSession = nil
        }
        inputContinuation?.finish()
        analysisTask?.cancel()
        resultTasks.forEach { $0.cancel() }
        let detachedAnalyzer = analyzer
        analyzer = nil
        converter = nil
        inputContinuation = nil
        analysisTask = nil
        resultTasks = []
        liveAccumulators = [:]
        finalAccumulators = [:]
        finalizationProgress = ContinuousFinalizationProgress()
        activePair = nil
        liveBoundary = nil
        activeSpeechStart = nil
        closingDrafts = []
        draftSelector.reset()
        onDraft = nil
        onFailure = nil
        terminalError = nil
        hasReceivedAudio = false
        inputFinished = false
        return detachedAnalyzer
    }

    nonisolated static func confidenceSummary(
        _ text: AttributedString
    ) -> (mean: Double?, lowFraction: Double) {
        var weightedTotal = 0.0
        var attributedCharacters = 0
        var lowCharacters = 0
        for run in text.runs {
            let count = text[run.range].characters.count
            guard count > 0,
                  let value = run[AttributeScopes.SpeechAttributes.ConfidenceAttribute.self] else {
                continue
            }
            let confidence = ContinuousLanguageDecisionPolicy.clamp(Double(value))
            weightedTotal += confidence * Double(count)
            attributedCharacters += count
            if confidence < 0.45 { lowCharacters += count }
        }
        guard attributedCharacters > 0 else { return (nil, 1) }
        return (
            weightedTotal / Double(attributedCharacters),
            Double(lowCharacters) / Double(attributedCharacters)
        )
    }

    nonisolated static func languageProbability(
        for text: String,
        expected: AppLanguage,
        pair: LanguagePair
    ) -> Double? {
        let constraints = Set([pair.traveler, pair.local]).compactMap { language in
            language.locale.language.languageCode?.identifier
        }.map(NLLanguage.init(rawValue:))
        guard let expectedCode = expected.locale.language.languageCode?.identifier,
              !constraints.isEmpty else {
            return nil
        }
        let recognizer = NLLanguageRecognizer()
        recognizer.languageConstraints = constraints
        recognizer.processString(text)
        let base = recognizer.languageHypotheses(withMaximum: constraints.count)[
            NLLanguage(rawValue: expectedCode)
        ]
        return PairLanguageEvidencePolicy.constrainedProbability(
            base: base,
            text: text,
            expected: expected,
            pair: pair
        )
    }
}
