import AVFoundation
import CoreMedia
import Speech

/// Buffers are owned by the capture/conversion pipeline and immutable after delivery.
/// Retain pre-roll until the detector identifies the start of each turn.
struct TurnSpeechAudio {
    struct Chunk {
        let buffer: AVAudioPCMBuffer
        let range: CMTimeRange

        func samples(in turn: CMTimeRange) throws -> AVAudioPCMBuffer? {
            let overlap = CMTimeRangeGetIntersection(range, otherRange: turn)
            guard overlap.isValid, !overlap.isEmpty else { return nil }
            if overlap == range { return buffer }
            let rate = CMTimeScale(buffer.format.sampleRate.rounded())
            func offset(_ time: CMTime) -> Int {
                Int(CMTimeConvertScale(time - range.start, timescale: rate, method: .roundTowardPositiveInfinity).value)
            }
            let first = max(0, offset(overlap.start))
            let end = min(Int(buffer.frameLength), offset(overlap.end))
            guard first < end else { return nil }
            let count = AVAudioFrameCount(end - first)
            guard let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else {
                throw PipelineError.server("Could not allocate speech audio.")
            }
            slice.frameLength = count
            let stride = Int(buffer.format.streamDescription.pointee.mBytesPerFrame)
            let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
            let dst = UnsafeMutableAudioBufferListPointer(slice.mutableAudioBufferList)
            for i in src.indices {
                guard let from = src[i].mData, let to = dst[i].mData else { throw PipelineError.noSpeech }
                memcpy(to, from.advanced(by: first * stride), Int(count) * stride)
            }
            return slice
        }
    }

    private var chunks: [Chunk] = []

    mutating func append(_ buffer: AVAudioPCMBuffer, through end: CMTime, speechStart: CMTime?) {
        let duration = CMTime(
            value: Int64(buffer.frameLength), timescale: CMTimeScale(buffer.format.sampleRate.rounded()))
        // Before VAD confirms a start, retain enough audio for its confirmation and leading padding.
        if speechStart == nil {
            let cutoff = end - CMTime(value: 1, timescale: 1)
            chunks.removeAll { $0.range.end <= cutoff }
        }
        chunks.append(Chunk(buffer: buffer, range: CMTimeRange(start: end - duration, duration: duration)))
    }

    mutating func take(_ turn: CMTimeRange) -> [Chunk] {
        let matching = chunks.filter { CMTimeRangeGetIntersection($0.range, otherRange: turn).duration > .zero }
        chunks.removeAll { $0.range.end <= turn.end }
        return matching
    }
}

/// A DictationTranscriber can report the next Hindi reply on the previous turn's
/// timeline. Finish a single bilingual analyzer at each pause. Captured audio
/// for a following speaker can queue while the previous analyzer is draining.
@MainActor
final class TurnSpeechSession {
    var observeFixtureDiagnostic: ((String, [String: String]) -> Void)?
    private let pair: LanguagePair
    private let plans: [AppleSpeechModulePlan]
    private let format: AVAudioFormat
    private let converter: SpeechAnalyzerInputConverter
    private let onDraft: (ContinuousDraft?) -> Void
    private var audio = TurnSpeechAudio()
    private var active: Turn?
    private var closing: [(CMTimeRange, Turn)] = []
    private var previous: Task<LanguageDecision, Error>?
    private var fedThrough = CMTime.zero
    private var lastClosedEnd = CMTime.zero
    private var receivedAudio = false

    init(pair: LanguagePair, plans: [AppleSpeechModulePlan], onDraft: @escaping (ContinuousDraft?) -> Void) async throws
    {
        let roles = AppleSpeechModulePlan.continuousRoles(for: pair)
        let modules = plans.flatMap { plan in roles.map { plan.makeModule(for: $0).analyzerModule } }
        guard await AssetInventory.status(forModules: modules) == .installed,
            let format = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: modules)
        else {
            throw PipelineError.assetsUnavailable(
                "The Listen models for both selected languages must be installed and available together.")
        }
        try Task.checkCancellation()
        self.pair = pair
        self.plans = plans
        self.format = format
        self.onDraft = onDraft
        converter = SpeechAnalyzerInputConverter(analyzerFormat: format)
    }

    func append(_ buffer: AVAudioPCMBuffer, at time: AVAudioTime?) throws {
        let inputs = try converter.convert(buffer, at: receivedAudio ? nil : time)
        if buffer.frameLength > 0 { receivedAudio = true }
        try deliver(inputs)
    }

    private func deliver(_ inputs: [AnalyzerInput]) throws {
        for input in inputs {
            let end = try converter.recordDelivery(of: input)
            audio.append(input.buffer, through: end, speechStart: active?.start)
        }
        // The detector runs immediately after this call. Leave a little audio in
        // hand so its exact maximum-duration split can fall inside a PCM buffer.
        if let last = inputs.last, let end = converter.deliveredThrough {
            let bufferDuration = CMTime(
                value: Int64(last.buffer.frameLength), timescale: CMTimeScale(format.sampleRate.rounded()))
            try feed(through: end - bufferDuration - CMTime(value: 1, timescale: 20))
        }
    }

    func finishInput() throws -> CMTime? {
        try deliver(converter.flush())
        return converter.deliveredThrough
    }

    private func feed(through end: CMTime) throws {
        guard let active, fedThrough < end else { return }
        let range = CMTimeRange(start: fedThrough, end: end)
        for chunk in audio.take(range) {
            if let buffer = try chunk.samples(in: range) {
                active.append(buffer, keepForRetry: !pair.isEnglishHindi)
            }
        }
        fedThrough = end
    }

    func begin(at start: CMTime) {
        guard active == nil else { return }
        let turn = Turn(start: start, publish: onDraft)
        turn.diagnostic = observeFixtureDiagnostic
        let predecessor = previous
        turn.result = Task { [plans, pair, format] in
            _ = await predecessor?.result
            try Task.checkCancellation()
            return try await turn.analyze(plans: plans, pair: pair, format: format)
        }
        active = turn
        previous = turn.result
        // Include quiet initial syllables from the already captured pre-roll,
        // while keeping the previous participant’s audio out of this turn.
        fedThrough = CMTimeMaximum(lastClosedEnd, start - CMTime(value: 1, timescale: 4))
        turn.diagnostic?(
            "turnAudioStart", ["speechStart": String(start.seconds), "audioStart": String(fedThrough.seconds)])
    }

    func close(_ range: CMTimeRange, onRevision: @escaping (ContinuousDraft?) -> Void) -> ContinuousDraft? {
        guard let turn = active else { return nil }
        do { try feed(through: range.end) } catch { turn.feedError = error }
        turn.diagnostic?(
            "turnAudioEnd", ["speechEnd": String(range.end.seconds), "audioEnd": String(fedThrough.seconds)])
        turn.input.finish()
        turn.publish = onRevision
        closing.append((range, turn))
        lastClosedEnd = range.end
        active = nil
        onDraft(nil)
        return turn.draft
    }

    func finalize(_ range: CMTimeRange) async throws -> LanguageDecision {
        guard let turn = closing.first(where: { $0.0 == range })?.1, let result = turn.result else {
            throw PipelineError.noSpeech
        }
        // Start the deadline when this sequence reaches the worker. Time spent speaking
        // or queued behind a previous turn must not count against final recognition.
        var exceededDeadline = false
        let deadline = Task { @MainActor in
            try await Task.sleep(for: .seconds(8))
            exceededDeadline = true
            result.cancel()
        }
        defer {
            deadline.cancel()
            closing.removeAll { $0.1 === turn }
        }
        let outcome = await result.result
        if exceededDeadline {
            throw PipelineError.server("Speech recognition timed out. Please repeat this turn.")
        }
        let decision = try outcome.get()
        if let error = turn.feedError { throw error }
        try Task.checkCancellation()
        return decision
    }

    func discard(before time: CMTime) {
        _ = audio.take(CMTimeRange(start: .zero, end: time))
    }

    func stop() -> Task<Void, Never> {
        for turn in closing.map(\.1) + [active].compactMap({ $0 }) {
            turn.publish = { _ in }
            turn.input.finish()
            turn.result?.cancel()
        }
        let last = previous
        return Task { _ = await last?.result }
    }

    @MainActor
    private final class Turn {
        let start: CMTime
        let stream: AsyncStream<AnalyzerInput>
        let input: AsyncStream<AnalyzerInput>.Continuation
        var result: Task<LanguageDecision, Error>?
        var feedError: Error?
        var publish: (ContinuousDraft?) -> Void
        var draft: ContinuousDraft?
        var diagnostic: ((String, [String: String]) -> Void)?
        private var selector = ContinuousDraftSelector()
        private var partials: [AppLanguage: RecognitionCandidate] = [:]

        init(start: CMTime, publish: @escaping (ContinuousDraft?) -> Void) {
            self.start = start
            self.publish = publish
            (stream, input) = AsyncStream.makeStream(of: AnalyzerInput.self)
        }

        private var captured: [AVAudioPCMBuffer] = []

        func append(_ buffer: AVAudioPCMBuffer, keepForRetry: Bool) {
            if keepForRetry { captured.append(buffer) }
            input.yield(AnalyzerInput(buffer: buffer))
        }

        private func resolveConflict(_ decision: LanguageDecision, pair: LanguagePair) async throws -> LanguageDecision
        {
            guard decision.reviewReasons.contains(.conflictingSpeakerEvidence), !captured.isEmpty else {
                return decision
            }
            let language = decision.selected.language == pair.traveler ? pair.local : pair.traveler
            diagnostic?("speakerRetry", ["initial": decision.selected.language.code, "retryLocale": language.code])
            let engine = AppleSpeechRecognitionEngine()
            let retry = Task { @MainActor in
                try await engine.start(locale: language.locale) { _ in }
                for buffer in captured {
                    try Task.checkCancellation()
                    try engine.append(buffer)
                }
                return try await engine.finish()
            }
            let watchdog = Task { @MainActor in
                try await Task.sleep(for: .milliseconds(1200))
                retry.cancel()
                engine.cancel()
            }
            defer {
                watchdog.cancel()
                engine.cancel()
            }
            let result = await withTaskCancellationHandler {
                await retry.result
            } onCancel: {
                retry.cancel()
                Task { @MainActor in engine.cancel() }
            }
            try Task.checkCancellation()
            guard case .success(let transcript) = result, !transcript.isUncertain,
                let probability = AppleContinuousSpeechRecognizer.languageProbability(
                    for: transcript.text, expected: language, pair: pair),
                probability >= 0.8,
                let candidate = ContinuousLanguageDecisionPolicy.makeCandidate(
                    language: language, transcript: transcript, constrainedLanguageProbability: probability),
                let verified = ContinuousLanguageDecisionPolicy.decide(candidates: [candidate], pair: pair),
                !verified.reviewReasons.contains(.conflictingSpeakerEvidence)
            else { return decision }
            return LanguageDecision(
                selected: candidate, alternate: decision.selected, reviewReasons: verified.reviewReasons)
        }

        func analyze(plans: [AppleSpeechModulePlan], pair: LanguagePair, format: AVAudioFormat) async throws
            -> LanguageDecision
        {
            defer { captured.removeAll() }
            let roles = AppleSpeechModulePlan.continuousRoles(for: pair)
            let entries = zip([pair.traveler, pair.local], plans).flatMap { language, plan in
                roles.map { role in (language: language, role: role, module: plan.makeModule(for: role)) }
            }
            let analyzer = SpeechAnalyzer(modules: entries.map { $0.module.analyzerModule })
            let tasks = entries.map { language, role, module in
                Task {
                    do {
                        return try await collect(
                            module, language: language, pair: pair,
                            publishesDrafts: roles.count == 1 || role == .continuousLive,
                            collectsFinals: role == .manual)
                    } catch  where role == .continuousLive {
                        // A caption stream can end independently of authoritative finals.
                        partials[language] = nil
                        diagnostic?("draftStreamEnded", ["locale": language.code])
                        return nil
                    }
                }
            }
            return try await withTaskCancellationHandler {
                do {
                    try await analyzer.prepareToAnalyze(in: format)
                    guard let end = try await analyzer.analyzeSequence(stream) else { throw PipelineError.noSpeech }
                    try await analyzer.finalizeAndFinish(through: end)
                    var candidates: [RecognitionCandidate] = []
                    for task in tasks {
                        if let candidate = try await task.value { candidates.append(candidate) }
                    }
                    try Task.checkCancellation()
                    guard let decision = ContinuousLanguageDecisionPolicy.decide(candidates: candidates, pair: pair)
                    else {
                        throw PipelineError.noSpeech
                    }
                    return try await resolveConflict(decision, pair: pair)
                } catch {
                    tasks.forEach { $0.cancel() }
                    await analyzer.cancelAndFinishNow()
                    throw error
                }
            } onCancel: {
                Task { await analyzer.cancelAndFinishNow() }
            }
        }

        private func collect(
            _ module: AppleSpeechTranscriptionModule, language: AppLanguage, pair: LanguagePair,
            publishesDrafts: Bool, collectsFinals: Bool
        ) async throws -> RecognitionCandidate? {
            var live = ContinuousRecognitionAccumulator()
            var finals = ContinuousRecognitionAccumulator()
            func candidate(_ accumulator: ContinuousRecognitionAccumulator) throws -> RecognitionCandidate? {
                guard let transcript = accumulator.transcript() else { return nil }
                guard TurnTextPolicy.isFinalTextWithinLimit(transcript.text) else {
                    throw PipelineError.server("The speech result is too long. Please split the turn and try again.")
                }
                return ContinuousLanguageDecisionPolicy.makeCandidate(
                    language: language, transcript: transcript,
                    constrainedLanguageProbability: AppleContinuousSpeechRecognizer.languageProbability(
                        for: transcript.text, expected: language, pair: pair),
                    timedWords: pair.isEnglishHindi ? accumulator.timedWords() : []
                )
            }
            for try await event in module.normalizedResults() {
                try Task.checkCancellation()
                let text = String(event.text.characters)
                let confidence = AppleContinuousSpeechRecognizer.confidenceSummary(event.text)
                func apply(to accumulator: inout ContinuousRecognitionAccumulator) throws {
                    guard
                        accumulator.apply(
                            range: event.range, text: text, isFinal: event.isFinal,
                            confidence: confidence.mean, lowConfidenceFraction: confidence.lowFraction,
                            timedText: pair.isEnglishHindi ? event.text : nil)
                    else {
                        throw PipelineError.server(
                            "The speech result was too complex. Please split the turn and try again.")
                    }
                }
                if event.isFinal && collectsFinals {
                    try apply(to: &finals)
                    diagnostic?(
                        "turnFinal",
                        [
                            "locale": language.code, "text": text,
                            "start": String(event.range.start.seconds), "end": String(event.range.end.seconds),
                            "finalizedThrough": String(event.resultsFinalizationTime.seconds),
                        ])
                }
                guard publishesDrafts else { continue }
                try apply(to: &live)
                partials[language] = try candidate(live)
                let candidates = partials.values.filter { $0.text.contains { $0.isLetter || $0.isNumber } }
                draft = selector.select(candidates: candidates, pair: pair).map {
                    ContinuousDraft(
                        language: $0.language, text: TurnTextPolicy.clampedPartial($0.text),
                        confidence: $0.confidence, score: $0.score)
                }
                publish(draft)
            }
            return try candidate(finals)
        }
    }
}
