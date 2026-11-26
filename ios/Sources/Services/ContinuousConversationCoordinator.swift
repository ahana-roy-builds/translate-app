import Combine
import CoreMedia
import Foundation
import OSLog

@MainActor
final class ContinuousConversationCoordinator: ObservableObject {
    @Published private(set) var state: ContinuousConversationState = .idle
    @Published private(set) var turns: [ConversationTurn] = []
    @Published private(set) var draft: ContinuousDraft?
    @Published private(set) var pendingDrafts: [Int: ContinuousDraft] = [:]
    private var recognitionStream = UUID()
    @Published private(set) var errorMessage: String?
    @Published private(set) var reviewedPlaybackTurnID: UUID?
    @Published var speakTranslations = false

    private struct PendingUtterance {
        let sequence: Int
        let range: CMTimeRange
        let createdAt: Date
        let speakTranslation: Bool
        let authorizedAtSpeechStart: Bool
    }

    private enum WorkItem {
        case utterance(PendingUtterance)
        case languageCorrection(UUID, AlternateTranscript)
    }

    private enum ReviewedPlaybackOrigin: Equatable {
        case listening
        case paused(ListeningPauseReason)
        case microphoneOff
    }

    private struct ReviewedPlaybackRequest {
        let turnID: UUID
        let translatedText: String
        let targetLanguage: AppLanguage
        let origin: ReviewedPlaybackOrigin
    }

    private let capture: any MicrophoneCapturing
    private let voiceActivity: any VoiceActivityDetecting
    private let recognition: any ContinuousSpeechRecognizing
    private let translation: any ContinuousBidirectionalTranslating
    private let playback: PlaybackService
    private let settings: SettingsStore
    private let history: HistoryStore
    private let access: (any TranslationAuthorizing)?
    private let extractor = CriticalEntityExtractor()

    private var pair = LanguagePair()
    private var record: ConversationRecord?
    private var workQueue: [WorkItem] = []
    private var nextSequence = 0
    private var sessionGeneration = UUID()
    private var workerGeneration: UUID?
    private var preparationTask: Task<Void, Never>?
    private var workerTask: Task<Void, Never>?
    private var endingTask: Task<Void, Never>?
    private var pauseTask: Task<Void, Never>?
    private var listeningPauseTask: Task<Void, Never>?
    private var resumeTask: Task<Void, Never>?
    private var reviewedPlaybackTask: Task<Void, Never>?
    private var resetTask: Task<Void, Never>?
    private var isProcessingWork = false
    private var activeCorrectionTurnID: UUID?
    private var silenceStartedAt: CMTime?
    private var isCapturePaused = false
    private var recognitionInputClosedForPlayback = false
    private let logger = Logger(subsystem: Bundle.main.bundleIdentifier ?? "SpeakDuet", category: "ContinuousTalk")
    @Published private(set) var hasActiveSpeech = false
    private var utteranceWasAuthorized = false
    private var isPauseRequested = false
    private var isEnding = false
    @Published private var isSceneActive = true
    private var isRequestingPermission = false

    init(
        capture: any MicrophoneCapturing,
        voiceActivity: any VoiceActivityDetecting,
        recognition: any ContinuousSpeechRecognizing,
        translation: any ContinuousBidirectionalTranslating,
        playback: PlaybackService,
        settings: SettingsStore,
        history: HistoryStore,
        access: (any TranslationAuthorizing)? = nil
    ) {
        self.capture = capture
        self.voiceActivity = voiceActivity
        self.recognition = recognition
        self.translation = translation
        self.playback = playback
        self.settings = settings
        self.history = history
        self.access = access

        capture.onCaptureInterrupted = { [weak self] event in
            if case .background = event {
                self?.handleSceneActivity(isActive: false)
            } else {
                self?.captureFailed(event.message)
            }
        }
        capture.onCaptureLimitReached = { [weak self] in
            self?.captureFailed(
                "Continuous listening stopped because the microphone buffer limit was reached."
            )
        }
        capture.onCaptureFailed = { [weak self] message in
            self?.captureFailed(message)
        }
    }

    var isRunning: Bool { state.isRunning }
    var isSessionActive: Bool { state.isRunning || reviewedPlaybackTurnID != nil }
    var isCaptureActive: Bool { capture.isActive && !isCapturePaused }
    var isReviewedPlaybackActive: Bool { reviewedPlaybackTurnID != nil }
    var canRequestLanguageCorrection: Bool {
        ContinuousModePolicy.canCorrectLanguage(in: state)
            && reviewedPlaybackTask == nil
            && !isEnding
    }

    var canResolveSpeaker: Bool {
        canRequestLanguageCorrection || (isSceneActive && reviewedPlaybackTask == nil && (state == .interrupted || state == .ended))
    }

    var statusText: String {
        if reviewedPlaybackTurnID != nil {
            switch state {
            case .pausedForPlayback, .ended, .interrupted, .failed:
                return "Playing reviewed translation; microphone paused"
            case .idle, .preparing, .listening, .catchingUp, .pausing,
                 .paused, .resuming, .ending:
                break
            }
        }
        return switch state {
        case .idle:
            "Not started"
        case .preparing:
            "Preparing offline listening"
        case .listening:
            "Listening in \(ContinuousModePolicy.languageNames(for: pair))"
        case let .catchingUp(pendingTurns):
            isCapturePaused
                ? "Catching up on \(pendingTurns) turn\(pendingTurns == 1 ? "" : "s"); microphone paused"
                : "Processing \(pendingTurns) turn\(pendingTurns == 1 ? "" : "s"); microphone open"
        case .pausedForPlayback:
            "Speaking translation; microphone paused"
        case .pausing:
            "Finishing the current thought"
        case .paused(.silence):
            "Paused after 20 seconds of silence"
        case .paused(.user), .interrupted:
            "Listening paused"
        case .resuming:
            "Resuming offline listening"
        case .ending:
            "Finishing the conversation"
        case .ended:
            "Conversation ended"
        case .failed:
            "Continuous listening stopped"
        }
    }

    func start(pair: LanguagePair) {
        guard !state.isRunning, reviewedPlaybackTask == nil else { return }
        do { try access?.authorizeTranslation() } catch {
            errorMessage = localizedMessage(for: error)
            return
        }
        stopImmediately(finalState: .idle, clearConversation: true)
        guard ContinuousModePolicy.supports(pair) else {
            state = .failed(
                "Continuous conversation is not available for \(ContinuousModePolicy.languageNames(for: pair))."
            )
            errorMessage = "Select a different supported language pair."
            return
        }

        let generation = UUID()
        let translationStrategy = settings.value.continuousTranslationStrategy
        sessionGeneration = generation
        self.pair = pair
        errorMessage = nil
        turns = []
        pendingDrafts = [:]
        workQueue = []
        nextSequence = 0
        isCapturePaused = false
        recognitionInputClosedForPlayback = false
        hasActiveSpeech = false
        utteranceWasAuthorized = false
        isPauseRequested = false
        isProcessingWork = false
        isEnding = false
        let now = Date()
        record = ConversationRecord(
            id: UUID(),
            createdAt: now,
            updatedAt: now,
            languageA: pair.traveler.code,
            languageB: pair.local.code,
            title: "\(pair.traveler.displayName) - \(pair.local.displayName)",
            turns: []
        )
        state = .preparing

        let priorReset = resetTask
        preparationTask = Task { @MainActor [weak self] in
            await priorReset?.value
            await self?.prepareAndStart(
                pair: pair,
                strategy: translationStrategy,
                generation: generation
            )
        }
    }

    func retrySession(pair: LanguagePair) {
        guard case .failed = state else { return }
        restartSession(pair: pair)
    }

    private func restartSession(pair: LanguagePair) {
        guard isSceneActive, reviewedPlaybackTask == nil else { return }
        guard pair == self.pair,
              record != nil,
              ContinuousModePolicy.supports(pair) else {
            start(pair: pair)
            return
        }

        let generation = UUID()
        let translationStrategy = settings.value.continuousTranslationStrategy
        sessionGeneration = generation
        errorMessage = nil
        draft = nil
        pendingDrafts = [:]
        workQueue = []
        isCapturePaused = false
        recognitionInputClosedForPlayback = false
        hasActiveSpeech = false
        utteranceWasAuthorized = false
        isPauseRequested = false
        isProcessingWork = false
        activeCorrectionTurnID = nil
        isEnding = false
        state = .preparing

        let priorReset = resetTask
        preparationTask = Task { @MainActor [weak self] in
            await priorReset?.value
            await self?.prepareAndStart(
                pair: pair,
                strategy: translationStrategy,
                generation: generation
            )
        }
    }

    func pauseSession(reason: ListeningPauseReason = .user) {
        switch state {
        case .listening, .catchingUp:
            break
        case .idle, .preparing, .pausedForPlayback, .pausing,
             .paused, .resuming, .ending, .ended, .interrupted, .failed:
            return
        }
        guard !isEnding, listeningPauseTask == nil else { return }

        isPauseRequested = true
        state = .pausing
        let generation = sessionGeneration
        listeningPauseTask = Task { @MainActor [weak self] in
            await self?.finishListeningPause(reason: reason, generation: generation)
        }
    }

    func resumeSession() {
        if state == .interrupted {
            restartSession(pair: pair)
            return
        }
        guard isSceneActive, case .paused = state,
              !isEnding,
              reviewedPlaybackTask == nil,
              resumeTask == nil else { return }

        isPauseRequested = false
        state = .resuming
        let generation = sessionGeneration
        resumeTask = Task { @MainActor [weak self] in
            await self?.resumeListening(generation: generation)
        }
    }

    func canReplayTranslation(for turnID: UUID) -> Bool {
        guard let turn = turns.first(where: { $0.id == turnID }) else {
            return false
        }
        return canReplayTranslation(for: turn)
    }

    func canReplayTranslation(for turn: ConversationTurn) -> Bool {
        guard reviewedPlaybackTask == nil,
              reviewedPlaybackTurnID == nil,
              !isEnding,
              isSceneActive,
              makeReviewedPlaybackRequest(for: turn) != nil else {
            return false
        }

        switch state {
        case .listening:
            return capture.isActive
                && !isCapturePaused
                && !isPauseRequested
                && !hasActiveSpeech
                && draft == nil
                && pendingWorkCount == 0
                && workerTask == nil
                && listeningPauseTask == nil
                && resumeTask == nil
        case .paused:
            return !capture.isActive
                && pendingWorkCount == 0
                && workerTask == nil
                && listeningPauseTask == nil
                && resumeTask == nil
        case .ended, .interrupted, .failed:
            return !capture.isActive
                && pendingWorkCount == 0
                && workerTask == nil
        case .idle, .preparing, .catchingUp, .pausedForPlayback, .pausing,
             .resuming, .ending:
            return false
        }
    }

    func replayTranslation(for turnID: UUID) {
        guard let turn = turns.first(where: { $0.id == turnID }),
              canReplayTranslation(for: turn),
              let request = makeReviewedPlaybackRequest(for: turn) else {
            return
        }

        errorMessage = nil
        reviewedPlaybackTurnID = request.turnID
        switch request.origin {
        case .listening:
            isPauseRequested = true
            state = .pausing
        case .paused:
            state = .pausedForPlayback
        case .microphoneOff:
            break
        }

        let generation = sessionGeneration
        reviewedPlaybackTask = Task { @MainActor [weak self] in
            await self?.performReviewedPlayback(
                request,
                generation: generation
            )
        }
    }

    func endSession() {
        guard state.isRunning, !isEnding else { return }
        guard state != .pausing, state != .resuming else { return }
        if state == .preparing {
            stopImmediately(finalState: .ended, clearConversation: false)
            return
        }

        if reviewedPlaybackTask != nil {
            guard state == .pausedForPlayback else { return }
            cancelReviewedPlayback()
            isPauseRequested = false
            isEnding = true
            state = .ending
            draft = nil
            let generation = sessionGeneration
            endingTask = Task { @MainActor [weak self] in
                await self?.finishSession(
                    generation: generation,
                    inputNeedsFinalization: false
                )
            }
            return
        }

        let inputNeedsFinalization = if case .paused = state { false } else { true }
        isEnding = true
        state = .ending
        draft = nil
        let generation = sessionGeneration
        endingTask = Task { @MainActor [weak self] in
            await self?.finishSession(
                generation: generation,
                inputNeedsFinalization: inputNeedsFinalization
            )
        }
    }

    func cancelSession() {
        stopImmediately(finalState: .idle, clearConversation: true)
    }

    func handleSceneActivity(isActive: Bool) {
        guard isSceneActive != isActive else { return }
        isSceneActive = isActive
        if !isActive, !state.isRunning, workerTask != nil {
            stopImmediately(finalState: state, clearConversation: false)
            return
        }
        if !isActive,
           reviewedPlaybackTask != nil,
           !state.isRunning {
            cancelReviewedPlayback()
            return
        }
        guard !isActive, state.isRunning else { return }
        // The system permission sheet temporarily makes the scene inactive.
        guard !isRequestingPermission else { return }
        stopImmediately(finalState: isEnding ? .ended : .interrupted, clearConversation: false)
        errorMessage = nil
    }

    func swapLanguage(for turnID: UUID) {
        guard let turn = turns.first(where: { $0.id == turnID }),
              let alternate = turn.alternateTranscript else { return }
        enqueueCorrection(for: turn, using: alternate)
    }

    @discardableResult
    func confirmSpeaker(for turnID: UUID, language: AppLanguage, text: String) -> Bool {
        guard let turn = turns.first(where: { $0.id == turnID }),
              turn.warnings.contains(.unresolvedSpeaker),
              language.code == turn.sourceLocale || language.code == turn.targetLocale,
              let verified = try? TurnTextPolicy.validated(text),
              verified.contains(where: { $0.isLetter || $0.isNumber }) else { return false }
        return enqueueCorrection(for: turn, using: AlternateTranscript(locale: language.code, text: verified, recognitionConfidence: nil))
    }

    @discardableResult
    private func enqueueCorrection(for turn: ConversationTurn, using transcript: AlternateTranscript) -> Bool {
        let turnID = turn.id
        guard (turn.warnings.contains(.unresolvedSpeaker) ? canResolveSpeaker : canRequestLanguageCorrection),
              turn.languageReviewStatus == .needsReview,
              activeCorrectionTurnID != turnID,
              !workQueue.contains(where: {
                  if case let .languageCorrection(queuedID, _) = $0 { return queuedID == turnID }
                  return false
              }) else { return false }
        guard ContinuousModePolicy.canEnqueueWork(
            pendingTurns: pendingWorkCount
        ) else {
            errorMessage = "Wait for the pending turns to finish before correcting the language."
            return false
        }
        workQueue.append(.languageCorrection(turnID, transcript))
        startWorkerIfNeeded(generation: sessionGeneration)
        publishOperationalState()
        return true
    }

    private func makeReviewedPlaybackRequest(
        for turn: ConversationTurn
    ) -> ReviewedPlaybackRequest? {
        let origin: ReviewedPlaybackOrigin
        switch state {
        case .listening:
            origin = .listening
        case let .paused(reason):
            origin = .paused(reason)
        case .ended, .interrupted, .failed:
            origin = .microphoneOff
        case .idle, .preparing, .catchingUp, .pausedForPlayback, .pausing,
             .resuming, .ending:
            return nil
        }

        guard ContinuousModePolicy.supports(pair),
              turn.route == .local,
              !turn.warnings.contains(.entityMismatch),
              !turn.warnings.contains(.unresolvedSpeaker),
              let sourceLanguage = AppLanguage.allCases.first(where: {
                  $0.code == turn.sourceLocale
              }),
              let targetLanguage = AppLanguage.allCases.first(where: {
                  $0.code == turn.targetLocale
              }),
              sourceLanguage == pair.source(for: turn.speaker),
              targetLanguage == pair.target(for: turn.speaker),
              let translatedText = try? TurnTextPolicy.validatedFinal(
                  turn.translatedText,
                  field: "translation"
              ) else {
            return nil
        }

        return ReviewedPlaybackRequest(
            turnID: turn.id,
            translatedText: translatedText,
            targetLanguage: targetLanguage,
            origin: origin
        )
    }

    private func performReviewedPlayback(
        _ request: ReviewedPlaybackRequest,
        generation: UUID
    ) async {
        do {
            if case .listening = request.origin {
                await pauseCapture(generation: generation)
            }
            try validate(generation)
            guard reviewedPlaybackTurnID == request.turnID,
                  reviewedPlaybackTask != nil else {
                throw CancellationError()
            }
            if request.origin != .microphoneOff {
                state = .pausedForPlayback
            }
            try playback.prepare(locale: request.targetLanguage.locale)
            try await playback.speak(
                request.translatedText,
                locale: request.targetLanguage.locale,
                slower: settings.value.slowerSpeech
            )
            try validate(generation)
        } catch is CancellationError {
            // Explicit teardown clears the playback identity before this task
            // resumes; an isolated synthesis cancellation still restores the
            // prior capture state below.
        } catch {
            if sessionGeneration == generation {
                errorMessage = localizedMessage(for: error)
            }
        }

        guard sessionGeneration == generation,
              reviewedPlaybackTurnID == request.turnID,
              reviewedPlaybackTask != nil else { return }
        reviewedPlaybackTask = nil
        reviewedPlaybackTurnID = nil

        switch request.origin {
        case .listening:
            isPauseRequested = false
            await resumeCapture(generation: generation)
        case let .paused(reason):
            state = .paused(reason)
        case .microphoneOff:
            break
        }
    }

    private func cancelReviewedPlayback() {
        reviewedPlaybackTask?.cancel()
        reviewedPlaybackTask = nil
        reviewedPlaybackTurnID = nil
        playback.cancel()
    }

    private func prepareAndStart(
        pair: LanguagePair,
        strategy: OnDeviceTranslationStrategy,
        generation: UUID
    ) async {
        do {
            try access?.authorizeTranslation()
            try validate(generation)
            isRequestingPermission = true
            let permissionGranted = await capture.requestPermission()
            isRequestingPermission = false
            try validate(generation)
            guard permissionGranted else { throw PipelineError.permissionDenied }
            guard isSceneActive else { throw CancellationError() }

            try await voiceActivity.prepare()
            try validate(generation)
            try await translation.prepare(pair: pair, strategy: strategy)
            try validate(generation)
            try await startRecognition(pair: pair, generation: generation)
            try validate(generation)
            guard isSceneActive else { throw CancellationError() }
            try startCapture(generation: generation)
            try validate(generation)
            preparationTask = nil
            state = .listening
        } catch is CancellationError {
            isRequestingPermission = false
            if sessionGeneration == generation, !isSceneActive {
                stopImmediately(finalState: .interrupted, clearConversation: false)
            }
        } catch {
            isRequestingPermission = false
            failSession(error, generation: generation)
        }
    }

    private func startCapture(generation: UUID) throws {
        try access?.authorizeTranslation()
        try validate(generation)
        try capture.start(generation: generation) { [weak self] captured in
            guard let self else { return .finish(.finished) }
            return try await self.consume(captured, generation: generation)
        }
        isCapturePaused = false
        silenceStartedAt = nil
    }

    private func startRecognition(
        pair: LanguagePair,
        generation: UUID
    ) async throws {
        let stream = UUID()
        recognitionStream = stream
        try await recognition.start(
            pair: pair,
            onDraft: { [weak self] update in
                guard let self,
                      self.sessionGeneration == generation, self.recognitionStream == stream,
                      update == nil || (self.hasActiveSpeech && !self.isEnding && !self.isPauseRequested) else { return }
                self.draft = update
            },
            onFailure: { [weak self] error in
                guard let self, self.recognitionStream == stream else { return }
                self.recognitionFailed(error, generation: generation)
            }
        )
    }

    private func consume(
        _ captured: CapturedAudioBuffer,
        generation: UUID
    ) async throws -> CaptureBufferDisposition {
        try validate(generation)
        guard captured.generation == generation else { throw CancellationError() }
        try recognition.append(captured.buffer, at: captured.audioTime)
        let result = try await voiceActivity.process(VoiceActivityInput(
            buffer: captured.buffer,
            audioTime: captured.audioTime
        ))
        try validate(generation)
        if result.events.contains(where: { if case .speechStarted = $0 { true } else { false } }) {
            try access?.authorizeTranslation()
            utteranceWasAuthorized = true
        }
        let shouldPauseForPlayback = handleVoiceActivityEvents(
            result.events,
            generation: generation
        )

        if shouldPauseForPlayback {
            // Auto Speak stops capture at this boundary. Signal end of input so
            // the analyzer can drain the turn without waiting for more buffers.
            _ = try recognition.finishInput()
            recognitionInputClosedForPlayback = true
        }
        if shouldPauseForPlayback
            || ContinuousModePolicy.shouldPauseCapture(
                pendingTurns: pendingWorkCount
            ) {
            scheduleCapturePause(generation: generation)
            return .finish(.finished)
        }
        // Detector timestamps count analyzed microphone audio, so time spent
        // preparing models or playing a translation cannot trigger a pause.
        if silenceStartedAt == nil { silenceStartedAt = result.processedThrough }
        if let silenceStartedAt, !hasActiveSpeech, isCaptureActive, !isEnding, !isPauseRequested,
           CMTimeSubtract(result.processedThrough, silenceStartedAt).seconds >= ContinuousModePolicy.silenceTimeout {
            pauseSession(reason: .silence)
            return .finish(.finished)
        }
        return .continueCapture
    }

    @discardableResult
    private func handleVoiceActivityEvents(
        _ events: [VoiceActivityEvent],
        generation: UUID
    ) -> Bool {
        guard sessionGeneration == generation else { return false }
        var shouldPauseForPlayback = false
        for event in events {
            if case let .speechStarted(start) = event {
                logger.debug("Speech started")
                hasActiveSpeech = true
                recognition.beginUtterance(at: start)
                continue
            }
            guard case let .speechEnded(range, _) = event else { continue }
            hasActiveSpeech = false
            silenceStartedAt = range.end
            draft = nil
            let duration = CMTimeGetSeconds(range.duration)
            guard duration.isFinite, duration > 0 else { continue }
            guard nextSequence < ConversationContentPolicy.maximumTurns else {
                errorMessage = "This conversation reached 500 turns. End it and start a new conversation."
                isEnding = true
                state = .ending
                endingTask = Task { @MainActor [weak self] in
                    await self?.finishSession(
                        generation: generation,
                        inputNeedsFinalization: true
                    )
                }
                return shouldPauseForPlayback
            }
            let speakTranslation = ContinuousModePolicy.shouldSpeakTranslation(
                wasEnabledAtBoundary: speakTranslations,
                isEnabledNow: true,
                pair: pair
            )
            let sequence = nextSequence
            pendingDrafts[sequence] = recognition.takeDraft(in: range) { [weak self] revision in
                guard let self, self.sessionGeneration == generation else { return }
                self.pendingDrafts[sequence] = revision
            }
            logger.debug("Queueing detected turn \(self.nextSequence)")
            workQueue.append(.utterance(PendingUtterance(
                sequence: nextSequence,
                range: range,
                createdAt: Date(),
                speakTranslation: speakTranslation,
                authorizedAtSpeechStart: utteranceWasAuthorized
            )))
            utteranceWasAuthorized = false
            shouldPauseForPlayback = shouldPauseForPlayback || speakTranslation
            nextSequence += 1
        }
        guard !events.isEmpty else { return shouldPauseForPlayback }
        startWorkerIfNeeded(generation: generation)
        publishOperationalState()
        return shouldPauseForPlayback
    }

    private var pendingWorkCount: Int {
        workQueue.count + (isProcessingWork ? 1 : 0)
    }

    private func startWorkerIfNeeded(generation: UUID) {
        guard workerTask == nil, !workQueue.isEmpty else { return }
        let workerGeneration = UUID()
        self.workerGeneration = workerGeneration
        workerTask = Task { @MainActor [weak self] in
            await self?.processWorkQueue(
                sessionGeneration: generation,
                workerGeneration: workerGeneration
            )
        }
    }

    private func processWorkQueue(
        sessionGeneration generation: UUID,
        workerGeneration: UUID
    ) async {
        while sessionGeneration == generation,
              self.workerGeneration == workerGeneration,
              !Task.isCancelled,
              !workQueue.isEmpty {
            let item = workQueue.removeFirst()
            isProcessingWork = true
            if case let .languageCorrection(turnID, _) = item {
                activeCorrectionTurnID = turnID
            } else {
                activeCorrectionTurnID = nil
            }
            publishOperationalState()
            do {
                if case let .utterance(pending) = item, pending.authorizedAtSpeechStart {
                    // A bounded utterance that started with access may finish.
                } else { try access?.authorizeTranslation() }
            } catch {
                failSession(error, generation: generation)
                return
            }
            do {
                switch item {
                case let .utterance(pending):
                    try await processUtterance(pending, generation: generation)
                case let .languageCorrection(turnID, transcript):
                    try await processLanguageCorrection(
                        turnID: turnID, transcript: transcript,
                        generation: generation
                    )
                }
                try validate(generation)
            } catch is CancellationError {
                activeCorrectionTurnID = nil
                isProcessingWork = false
                break
            } catch PipelineError.noSpeech {
                logger.debug("Recognition returned no text for detected speech")
                // A VAD boundary can legitimately contain no recognizer text.
            } catch {
                guard sessionGeneration == generation else { break }
                errorMessage = localizedMessage(for: error)
            }
            activeCorrectionTurnID = nil
            isProcessingWork = false

            if !isEnding,
               !isPauseRequested,
               isCapturePaused,
               !recognitionInputClosedForPlayback,
               !speakTranslations,
               ContinuousModePolicy.shouldResumeCapture(
                pendingTurns: pendingWorkCount
               ) {
                await resumeCapture(generation: generation)
            }
            publishOperationalState()
        }

        guard sessionGeneration == generation,
              self.workerGeneration == workerGeneration else { return }
        isProcessingWork = false
        self.workerGeneration = nil
        workerTask = nil

        if !workQueue.isEmpty {
            startWorkerIfNeeded(generation: generation)
            return
        }
        if !isEnding, !isPauseRequested, isCapturePaused {
            await resumeCapture(generation: generation)
        }
        publishOperationalState()
    }

    private func processUtterance(
        _ pending: PendingUtterance,
        generation: UUID
    ) async throws {
        defer {
            if sessionGeneration == generation { pendingDrafts[pending.sequence] = nil }
        }
        logger.debug("Finalizing turn \(pending.sequence)")
        let decision = try await recognition.finalizeUtterance(in: pending.range)
        try validate(generation)

        let selected = decision.selected
        let speaker: SpeakerSide
        if selected.language == pair.traveler {
            speaker = .traveler
        } else if selected.language == pair.local {
            speaker = .local
        } else {
            throw PipelineError.unsupportedLocale(selected.language.code)
        }
        let sourceText = try TurnTextPolicy.validatedFinal(
            selected.text,
            field: "source"
        )
        pendingDrafts[pending.sequence] = ContinuousDraft(
            language: selected.language, text: sourceText, confidence: selected.confidence, score: selected.score
        )
        let alternate = makeAlternateTranscript(from: decision.alternate, expectedLanguage: pair.target(for: speaker))
        if decision.requiresSpeakerChoice {
            commit(ConversationTurn(id: UUID(), sequence: pending.sequence, speaker: speaker,
                sourceLocale: selected.language.code, targetLocale: pair.target(for: speaker).code,
                sourceText: sourceText, translatedText: "", userEdited: false, createdAt: pending.createdAt,
                entities: [], route: .local, recognitionConfidence: selected.confidence,
                warnings: [.unresolvedSpeaker, .uncertainRecognition], languageReviewStatus: .needsReview,
                alternateTranscript: alternate))
            return
        }
        let translatedText = try await translation.translate(
            sourceText,
            speaker: speaker,
            pair: pair
        )
        try validate(generation)
        let boundedTranslation = try TurnTextPolicy.validatedFinal(
            translatedText,
            field: "translation"
        )
        let integrity = extractor.compare(
            source: sourceText,
            translation: boundedTranslation,
            sourceLocale: pair.source(for: speaker).locale,
            targetLocale: pair.target(for: speaker).locale,
            referenceDate: pending.createdAt,
            timeZone: .current
        )
        var warnings = Set<TranslationWarning>()
        if decision.needsReview { warnings.insert(.uncertainRecognition) }
        if integrity.hasMismatch { warnings.insert(.entityMismatch) }

        let turn = ConversationTurn(
            id: UUID(),
            sequence: pending.sequence,
            speaker: speaker,
            sourceLocale: pair.source(for: speaker).code,
            targetLocale: pair.target(for: speaker).code,
            sourceText: sourceText,
            translatedText: boundedTranslation,
            userEdited: false,
            createdAt: pending.createdAt,
            entities: integrity.source,
            route: .local,
            recognitionConfidence: selected.confidence,
            warnings: warnings,
            languageReviewStatus: decision.needsReview ? .needsReview : .confident,
            alternateTranscript: alternate
        )
        pendingDrafts[pending.sequence] = nil
        commit(turn)
        logger.debug("Committed turn \(pending.sequence)")
        errorMessage = nil

        guard ContinuousModePolicy.shouldSpeakTranslation(
            wasEnabledAtBoundary: pending.speakTranslation,
            isEnabledNow: speakTranslations,
            pair: pair,
            requiresLanguageReview: decision.needsReview,
            requiresEntityReview: integrity.requiresConfirmation,
            hasEntityMismatch: integrity.hasMismatch
        ), !isEnding else {
            return
        }
        await pauseCapture(generation: generation)
        try validate(generation)
        do {
            try playback.prepare(pair: pair)
            state = .pausedForPlayback
            try await playback.speak(
                boundedTranslation,
                locale: pair.target(for: speaker).locale,
                slower: settings.value.slowerSpeech
            )
            try validate(generation)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            speakTranslations = false
            errorMessage = localizedMessage(for: error)
        }
    }

    private func processLanguageCorrection(
        turnID: UUID, transcript: AlternateTranscript,
        generation: UUID
    ) async throws {
        guard let index = turns.firstIndex(where: { $0.id == turnID }),
              turns[index].languageReviewStatus == .needsReview else { return }
        let prior = turns[index]
        let alternate = transcript
        guard alternate.locale == prior.targetLocale || alternate.locale == prior.sourceLocale else {
            throw PipelineError.malformedResponse
        }
        let correctedSpeaker = alternate.locale == prior.sourceLocale ? prior.speaker : prior.speaker.other
        let sourceText = try TurnTextPolicy.validatedFinal(
            alternate.text,
            field: "source"
        )
        let reviewingStoppedTurn = !state.isRunning
        defer {
            if reviewingStoppedTurn && sessionGeneration == generation { translation.cancel() }
        }
        if reviewingStoppedTurn {
            try await translation.prepare(pair: pair, strategy: settings.value.continuousTranslationStrategy)
            try validate(generation)
        }
        let translatedText = try await translation.translate(
            sourceText,
            speaker: correctedSpeaker,
            pair: pair
        )
        try validate(generation)
        let boundedTranslation = try TurnTextPolicy.validatedFinal(
            translatedText,
            field: "translation"
        )
        let integrity = extractor.compare(
            source: sourceText,
            translation: boundedTranslation,
            sourceLocale: pair.source(for: correctedSpeaker).locale,
            targetLocale: pair.target(for: correctedSpeaker).locale,
            referenceDate: prior.createdAt,
            timeZone: .current
        )
        var warnings = prior.warnings
        warnings.remove(.unresolvedSpeaker)
        warnings.remove(.uncertainRecognition)
        warnings.remove(.entityMismatch)
        if integrity.hasMismatch { warnings.insert(.entityMismatch) }

        turns[index] = ConversationTurn(
            id: prior.id,
            sequence: prior.sequence,
            speaker: correctedSpeaker,
            sourceLocale: pair.source(for: correctedSpeaker).code,
            targetLocale: pair.target(for: correctedSpeaker).code,
            sourceText: sourceText,
            translatedText: boundedTranslation,
            userEdited: prior.warnings.contains(.unresolvedSpeaker) && alternate.text != prior.sourceText && alternate.text != prior.alternateTranscript?.text,
            createdAt: prior.createdAt,
            entities: integrity.source,
            route: .local,
            recognitionConfidence: alternate.recognitionConfidence,
            warnings: warnings,
            languageReviewStatus: .corrected,
            alternateTranscript: correctedSpeaker == prior.speaker ? prior.alternateTranscript : AlternateTranscript(
                locale: prior.sourceLocale,
                text: prior.sourceText,
                recognitionConfidence: prior.recognitionConfidence
            )
        )
        persistCurrentRecord(updatedAt: Date())
        errorMessage = nil
    }

    private func makeAlternateTranscript(
        from candidate: RecognitionCandidate?,
        expectedLanguage: AppLanguage
    ) -> AlternateTranscript? {
        guard let candidate, candidate.text.contains(where: { $0.isLetter || $0.isNumber }),
              candidate.language == expectedLanguage,
              let text = try? TurnTextPolicy.validatedFinal(
                candidate.text,
                field: "source"
              ) else { return nil }
        return AlternateTranscript(
            locale: candidate.language.code,
            text: text,
            recognitionConfidence: candidate.confidence
        )
    }

    private func commit(_ turn: ConversationTurn) {
        guard turns.count < ConversationContentPolicy.maximumTurns else { return }
        turns.append(turn)
        turns.sort { $0.sequence < $1.sequence }
        persistCurrentRecord(updatedAt: Date())
    }

    private func persistCurrentRecord(updatedAt: Date) {
        record?.turns = turns
        record?.updatedAt = updatedAt
        guard settings.value.saveHistoryOnDevice, let record else { return }
        history.saveOnDevice(record, enabled: true)
    }

    private func scheduleCapturePause(generation: UUID) {
        guard sessionGeneration == generation,
              !isCapturePaused,
              pauseTask == nil else { return }
        isCapturePaused = true
        pauseTask = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                if self.capture.isActive {
                    try await self.capture.stop()
                }
            } catch is CancellationError {
                return
            } catch {
                self.capture.cancel()
                if self.sessionGeneration == generation {
                    self.errorMessage = self.localizedMessage(for: error)
                }
            }
            guard self.sessionGeneration == generation,
                  self.pauseTask != nil else { return }
            self.pauseTask = nil
        }
    }

    private func pauseCapture(generation: UUID) async {
        if let pauseTask {
            await pauseTask.value
            return
        }
        guard sessionGeneration == generation, !isCapturePaused else { return }
        isCapturePaused = true
        do {
            if capture.isActive { try await capture.stop() }
        } catch {
            capture.cancel()
            if sessionGeneration == generation {
                errorMessage = localizedMessage(for: error)
            }
        }
    }

    private func resumeCapture(generation: UUID) async {
        if let pauseTask { await pauseTask.value }
        guard sessionGeneration == generation,
              !isEnding,
              !isPauseRequested,
              isSceneActive,
              isCapturePaused,
              !capture.isActive else { return }
        do {
            if recognitionInputClosedForPlayback {
                try await voiceActivity.prepare()
                try validate(generation)
                guard state.isRunning, !isEnding, !isPauseRequested else { return }
                try await startRecognition(pair: pair, generation: generation)
                try validate(generation)
                guard state.isRunning, !isEnding, !isPauseRequested, isSceneActive else {
                    if !state.isRunning { recognition.stop() }
                    return
                }
                recognitionInputClosedForPlayback = false
            }
            try startCapture(generation: generation)
            publishOperationalState()
        } catch is CancellationError {
            return
        } catch {
            failSession(error, generation: generation)
        }
    }

    private func finishListeningPause(reason: ListeningPauseReason, generation: UUID) async {
        do {
            if let pauseTask { await pauseTask.value }
            try validate(generation)
            if capture.isActive {
                try await capture.stop()
            }
            try validate(generation)
            isCapturePaused = true
            _ = try recognition.finishInput()
            let finalResult = try await voiceActivity.finish()
            try validate(generation)
            handleVoiceActivityEvents(finalResult.events, generation: generation)

            while let task = workerTask {
                await task.value
                try validate(generation)
            }

            recognition.stop()
            await voiceActivity.reset()
            try validate(generation)
            hasActiveSpeech = false
            listeningPauseTask = nil
            draft = nil
            state = .paused(reason)
        } catch is CancellationError {
            return
        } catch {
            failSession(error, generation: generation)
        }
    }

    private func resumeListening(generation: UUID) async {
        do {
            try validate(generation)
            try await voiceActivity.prepare()
            try validate(generation)
            try await startRecognition(pair: pair, generation: generation)
            try validate(generation)
            guard isSceneActive else { throw CancellationError() }
            try startCapture(generation: generation)
            try validate(generation)
            recognitionInputClosedForPlayback = false
            resumeTask = nil
            state = .listening
        } catch is CancellationError {
            return
        } catch {
            failSession(error, generation: generation)
        }
    }

    private func finishSession(
        generation: UUID,
        inputNeedsFinalization: Bool
    ) async {
        do {
            if let pauseTask { await pauseTask.value }
            try validate(generation)
            if inputNeedsFinalization {
                if capture.isActive {
                    try await capture.stop()
                }
                try validate(generation)
                isCapturePaused = true
                _ = try recognition.finishInput()
                let finalResult = try await voiceActivity.finish()
                try validate(generation)
                handleVoiceActivityEvents(finalResult.events, generation: generation)
            }

            while let task = workerTask {
                await task.value
                try validate(generation)
            }

            capture.cancel()
            recognition.stop()
            translation.cancel()
            playback.cancel()
            await voiceActivity.reset()
            try validate(generation)
            hasActiveSpeech = false
            preparationTask = nil
            endingTask = nil
            pauseTask = nil
            listeningPauseTask = nil
            resumeTask = nil
            isEnding = false
            isCapturePaused = false
            isPauseRequested = false
            draft = nil
            state = .ended
        } catch is CancellationError {
            return
        } catch {
            failSession(error, generation: generation)
        }
    }

    private func publishOperationalState() {
        guard !isEnding, state.isRunning else { return }
        if isPauseRequested {
            switch state {
            case .pausedForPlayback, .pausing, .paused:
                return
            case .idle, .preparing, .listening, .catchingUp, .resuming,
                 .ending, .ended, .interrupted, .failed:
                state = .pausing
                return
            }
        }
        let pending = pendingWorkCount
        if pending > 0 {
            state = .catchingUp(pendingTurns: pending)
        } else if capture.isActive, !isCapturePaused {
            state = .listening
        }
    }

    private func recognitionFailed(_ error: Error, generation: UUID) {
        failSession(error, generation: generation)
    }

    private func captureFailed(_ message: String) {
        guard state.isRunning, !isEnding else { return }
        failSession(PipelineError.server(message), generation: sessionGeneration)
    }

    private func failSession(_ error: Error, generation: UUID) {
        guard sessionGeneration == generation else { return }
        let message = localizedMessage(for: error)
        stopImmediately(finalState: .failed(message), clearConversation: false)
        errorMessage = message
    }

    private func stopImmediately(
        finalState: ContinuousConversationState,
        clearConversation: Bool
    ) {
        sessionGeneration = UUID()
        preparationTask?.cancel()
        workerTask?.cancel()
        endingTask?.cancel()
        pauseTask?.cancel()
        listeningPauseTask?.cancel()
        resumeTask?.cancel()
        reviewedPlaybackTask?.cancel()
        preparationTask = nil
        workerTask = nil
        endingTask = nil
        pauseTask = nil
        listeningPauseTask = nil
        resumeTask = nil
        reviewedPlaybackTask = nil
        reviewedPlaybackTurnID = nil
        workerGeneration = nil
        capture.cancel()
        recognition.stop()
        translation.cancel()
        playback.cancel()
        pendingDrafts = [:]
        workQueue = []
        isProcessingWork = false
        activeCorrectionTurnID = nil
        isCapturePaused = false
        recognitionInputClosedForPlayback = false
        hasActiveSpeech = false
        utteranceWasAuthorized = false
        isPauseRequested = false
        isEnding = false
        isRequestingPermission = false
        draft = nil

        let detector = voiceActivity
        resetTask = Task {
            await detector.reset()
        }
        if clearConversation {
            turns = []
            record = nil
            nextSequence = 0
            errorMessage = nil
        }
        state = finalState
    }

    private func validate(_ generation: UUID) throws {
        try Task.checkCancellation()
        guard sessionGeneration == generation else { throw CancellationError() }
    }

    private func localizedMessage(for error: Error) -> String {
        (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
    }
}
