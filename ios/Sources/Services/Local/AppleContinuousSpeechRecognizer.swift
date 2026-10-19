import AVFoundation
import CoreMedia
import Foundation
import NaturalLanguage
import Speech

@MainActor
final class AppleContinuousSpeechRecognizer: ContinuousSpeechRecognizing {
    private enum ResultKind {
        case liveDraft
        case finalOnly
    }

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

        let sessionGeneration = generation
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
            pair: pair,
            generation: sessionGeneration
        )
        let candidates = finalizedCandidates(in: finalizableRange, pair: pair)
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
            if pair.traveler == .hindiIndia || pair.local == .hindiIndia {
                throw PipelineError.server(
                    "Hindi listening did not finish this turn in time. Please try again."
                )
            }
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
        let text = String(result.text.characters).trimmingCharacters(in: .whitespacesAndNewlines)
        guard TurnTextPolicy.isFinalTextWithinLimit(text) else {
            recordFailure(
                PipelineError.server(
                    "The speech result is too long. Please split the turn and try again."
                ),
                generation: generation
            )
            return
        }
        let confidence = Self.confidenceSummary(result.text)
        guard liveAccumulators[language]?.apply(
            range: result.range,
            text: text,
            isFinal: result.isFinal,
            confidence: confidence.mean,
            lowConfidenceFraction: confidence.lowFraction
        ) == true else {
            recordFailure(
                PipelineError.server(
                    "The speech result was too complex. Please split the turn and try again."
                ),
                generation: generation
            )
            return
        }
        if let accumulatedText = liveAccumulators[language]?.transcript()?.text,
           !TurnTextPolicy.isFinalTextWithinLimit(accumulatedText) {
            recordFailure(
                PipelineError.server(
                    "The speech result is too long. Please split the turn and try again."
                ),
                generation: generation
            )
            return
        }
        publishDraft()
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
        let confidence = Self.confidenceSummary(result.text)
        guard finalAccumulators[language]?.apply(
            range: result.range,
            text: text,
            isFinal: true,
            confidence: confidence.mean,
            lowConfidenceFraction: confidence.lowFraction
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

    private func publishDraft() {
        guard let pair = activePair else { return }
        let candidates = [pair.traveler, pair.local].compactMap { language in
            makeCandidate(
                language: language,
                range: nil,
                pair: pair,
                accumulators: liveAccumulators
            )
        }
        guard let selected = draftSelector.select(candidates: candidates) else {
            onDraft?(nil)
            return
        }
        onDraft?(ContinuousDraft(
            language: selected.language,
            text: TurnTextPolicy.clampedPartial(selected.text),
            confidence: selected.confidence,
            score: selected.score
        ))
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
        pair: LanguagePair,
        generation: UUID
    ) async throws -> Bool {
        let languages = [pair.traveler, pair.local]
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: Self.finalResultDrainTimeout(for: pair))
        while !finalizationProgress.includes(languages, through: target) {
            try Task.checkCancellation()
            guard self.generation == generation else { throw CancellationError() }
            if let terminalError { throw terminalError }
            guard clock.now < deadline else { return false }
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
            liveAccumulators[language]?.discard(before: end)
            finalAccumulators[language]?.discard(before: end)
        }
        draftSelector.reset()
        onDraft?(nil)
    }

    nonisolated static func finalResultDrainTimeout(for pair: LanguagePair) -> Duration {
        pair.traveler == .hindiIndia || pair.local == .hindiIndia
            ? .seconds(3)
            : .milliseconds(500)
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
        draftSelector.reset()
        onDraft = nil
        onFailure = nil
        terminalError = nil
        hasReceivedAudio = false
        inputFinished = false
        return detachedAnalyzer
    }

    nonisolated private static func confidenceSummary(
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

    nonisolated private static func languageProbability(
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
