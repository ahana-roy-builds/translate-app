import Combine
import Foundation
import UIKit

@MainActor
final class ConversationOrchestrator: ObservableObject {
    @Published private(set) var state: ConversationState = .notReady
    @Published private(set) var partialTranscript = ""
    @Published private(set) var turns: [ConversationTurn] = []
    @Published private(set) var activeRoute: EngineRoute = .local
    @Published private(set) var routeDisclosure = "Conversation processing and Local history stay on this device."
    @Published private(set) var pendingResult: PipelineResult?
    @Published private(set) var pendingIntegrity: EntityIntegrityReport?
    @Published private(set) var pendingErrorMessage: String?
    @Published private(set) var isCommitting = false
    @Published var editableSource = ""

    private var pendingUserEdited = false
    private var machine = ConversationStateMachine()
    private let audio: AudioCaptureService
    private let local: LocalConversationPipeline
    private let online: OnlineConversationPipeline
    private let playback: PlaybackService
    private let settings: SettingsStore
    private let network: NetworkStatus
    private let subscription: SubscriptionManager
    private let history: HistoryStore
    private let notificationCenter: NotificationCenter
    private let extractor = CriticalEntityExtractor()
    private let router: ConversationRouter
    private var currentPipeline: (any ConversationPipeline)?
    private var activeContext: TurnContext?
    private var record: ConversationRecord?
    private var locallyPersistedTurns: [ConversationTurn] = []
    private var operationID = UUID()
    private var workTask: Task<Void, Never>?
    private var workGeneration = ConversationWorkGeneration()
    private var commitGeneration = ConversationCommitGeneration()
    private var isSceneActive = true
    private var permissionRequestOperation: UUID?
    // NotificationCenter's opaque tokens are not Sendable, but deinit can run
    // outside MainActor isolation. Only initialization and deinit touch them.
    private nonisolated(unsafe) var resourceNotificationTokens: [NSObjectProtocol] = []

    init(
        audio: AudioCaptureService,
        local: LocalConversationPipeline,
        online: OnlineConversationPipeline,
        playback: PlaybackService,
        settings: SettingsStore,
        network: NetworkStatus,
        subscription: SubscriptionManager,
        history: HistoryStore,
        onlineFeaturesEnabled: Bool = false,
        notificationCenter: NotificationCenter = .default
    ) {
        self.audio = audio
        self.local = local
        self.online = online
        self.playback = playback
        self.settings = settings
        self.network = network
        self.subscription = subscription
        self.history = history
        router = ConversationRouter(onlineFeaturesEnabled: onlineFeaturesEnabled)
        self.notificationCenter = notificationCenter
        audio.onCaptureInterrupted = { [weak self] in self?.captureInterrupted() }
        audio.onCaptureLimitReached = { [weak self] in self?.finishCaptureAtLimit() }
        audio.onCaptureFailed = { [weak self] message in self?.captureFailed(message) }
        resourceNotificationTokens = [
            notificationCenter.addObserver(
                forName: UIApplication.didReceiveMemoryWarningNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.handleResourcePressure(.memoryWarning) }
            },
            notificationCenter.addObserver(
                forName: ProcessInfo.thermalStateDidChangeNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                let state = ProcessInfo.processInfo.thermalState
                Task { @MainActor in self?.handleResourcePressure(.thermal(state)) }
            }
        ]
    }

    deinit {
        resourceNotificationTokens.forEach { notificationCenter.removeObserver($0) }
    }

    var pair: LanguagePair { settings.value.pair }
    var autoSpeakEnabled: Bool { settings.value.autoSpeak }

    func configure() {
        cancelAll()
        machine.reset()
        state = machine.state
        let now = Date()
        record = ConversationRecord(id: UUID(), createdAt: now, updatedAt: now, languageA: pair.traveler.code, languageB: pair.local.code, title: "\(pair.traveler.displayName) – \(pair.local.displayName)", turns: [])
        turns = []
        locallyPersistedTurns = []
        clearEphemeralState()
        if var decision = try? router.decide(
            preference: settings.value.routing,
            pair: pair,
            hasPro: subscription.hasPro,
            isOnline: network.isOnline
        ) {
            if decision.route == .online, !settings.value.hasCurrentOnlineProcessingConsent, settings.value.routing == .automatic {
                decision = RouteDecision(route: .local, disclosure: "Auto will use on-device processing until Online Quality consent is granted.")
            }
            activeRoute = decision.route
            routeDisclosure = decision.disclosure
        } else {
            activeRoute = .local
            routeDisclosure = "Online Quality is unavailable. Select Local Only or reconnect before recording."
        }
    }

    /// Synchronous at the tap boundary so a second tap observes `.preparing` or
    /// `.finalizing` before the first asynchronous operation can suspend.
    func microphoneTapped(for speaker: SpeakerSide) {
        switch state {
        case .listening where state.speaker == speaker: startFinishingTurn(speaker: speaker)
        case .ready, .failed, .speaking: startPreparingTurn(speaker: speaker)
        default: break
        }
    }

    private func startPreparingTurn(speaker: SpeakerSide) {
        let operation = beginOperation()
        do {
            guard turns.count < ConversationContentPolicy.maximumTurns else {
                throw PipelineError.server("This conversation reached 500 turns. Start a new conversation to continue.")
            }
            try transition(.preparing(speaker))
            let selectedPair = pair
            var decision = try router.decide(
                preference: settings.value.routing,
                pair: selectedPair,
                hasPro: subscription.hasPro,
                isOnline: network.isOnline
            )
            if settings.value.routing == .localOnly, decision.route != .local { throw PipelineError.offlineRequired }
            if decision.route == .online, !settings.value.hasCurrentOnlineProcessingConsent {
                if settings.value.routing == .automatic {
                    decision = RouteDecision(route: .local, disclosure: "Auto selected on-device processing because Online Quality consent has not been granted.")
                } else { throw PipelineError.server("Review and accept the Online Quality disclosure before recording.") }
            }
            activeRoute = decision.route
            routeDisclosure = decision.disclosure
            let saveOnDevice = settings.value.saveHistoryOnDevice
            startWork(operation: operation) { [weak self] in
                await self?.prepareTurn(
                    speaker: speaker,
                    pair: selectedPair,
                    initialDecision: decision,
                    saveOnDevice: saveOnDevice,
                    operation: operation
                )
            }
        } catch { fail(error, speaker: speaker, operation: operation) }
    }

    private func prepareTurn(
        speaker: SpeakerSide,
        pair: LanguagePair,
        initialDecision: RouteDecision,
        saveOnDevice: Bool,
        operation: UUID
    ) async {
        do {
            try validate(operation)
            if settings.value.autoSpeak {
                try playback.prepare(locale: pair.target(for: speaker).locale)
            }
            var decision = initialDecision
            var pipeline: any ConversationPipeline = decision.route == .local ? local : online
            currentPipeline = pipeline
            do {
                try await pipeline.prepare(pair: pair)
                try validate(operation)
            } catch {
                try validate(operation)
                guard settings.value.routing == .automatic, decision.route == .online else { throw error }
                decision = RouteDecision(route: .local, disclosure: "Online Quality was unavailable, so Auto selected on-device processing before recording.")
                pipeline = local
                currentPipeline = local
                activeRoute = .local
                routeDisclosure = decision.disclosure
                try await local.prepare(pair: pair)
                try validate(operation)
            }

            permissionRequestOperation = operation
            defer {
                if permissionRequestOperation == operation { permissionRequestOperation = nil }
            }
            let permissionGranted = await audio.requestPermission()
            try validate(operation)
            guard permissionGranted else { throw PipelineError.permissionDenied }
            guard ConversationSceneLifecyclePolicy.mayStartAudio(isSceneActive: isSceneActive) else {
                throw CancellationError()
            }
            let context = TurnContext(
                id: UUID(), speaker: speaker, pair: pair, route: decision.route, startedAt: Date(),
                saveOnDevice: saveOnDevice
            )
            activeContext = context
            partialTranscript = ""
            try await pipeline.beginRecognition(locale: pair.source(for: speaker).locale) { [weak self] update in
                guard let self, self.operationID == operation, self.activeContext?.id == context.id else { return }
                self.partialTranscript = TurnTextPolicy.clampedPartial(update.text)
            }
            try validate(operation)
            // Recognition setup can suspend while the app lifecycle changes.
            // Recheck immediately before activating the microphone.
            guard ConversationSceneLifecyclePolicy.mayStartAudio(isSceneActive: isSceneActive) else {
                throw CancellationError()
            }
            try audio.start { buffer in try pipeline.append(buffer) }
            try transition(.listening(speaker))
        } catch is CancellationError {
            recoverFromCancellation(operation: operation, speaker: speaker)
        } catch { fail(error, speaker: speaker, operation: operation) }
    }

    private func startFinishingTurn(speaker: SpeakerSide) {
        guard let context = activeContext, context.speaker == speaker, let pipeline = currentPipeline else { return }
        let operation = operationID
        do { try transition(.finalizing(speaker)) }
        catch { fail(error, speaker: speaker, operation: operation); return }
        startWork(operation: operation) { [weak self] in
            await self?.finishTurn(context: context, pipeline: pipeline, operation: operation)
        }
    }

    private func finishTurn(context: TurnContext, pipeline: any ConversationPipeline, operation: UUID) async {
        do {
            try validate(operation)
            let captured = try await audio.stop()
            try validate(operation)
            guard captured.duration <= 30 else { throw PipelineError.server("Please keep each turn under 30 seconds.") }
            try transition(.reviewing(context.speaker))
            try transition(.translating(context.speaker))
            let rawResult = try await pipeline.process(
                audio: captured,
                source: context.pair.source(for: context.speaker),
                target: context.pair.target(for: context.speaker)
            )
            var result = try boundedResult(rawResult)
            try validate(operation)
            let integrity = integrityReport(source: result.sourceText, translation: result.translatedText, context: context)
            if integrity.hasMismatch { result.warnings.insert(.entityMismatch) }
            pendingResult = result
            pendingIntegrity = integrity
            editableSource = result.sourceText
            pendingUserEdited = false
            pendingErrorMessage = nil
            if integrity.requiresConfirmation || !result.warnings.isEmpty {
                try transition(.confirming(context.speaker))
            } else {
                await commitAndOptionallySpeak(result, context: context, operation: operation)
            }
        } catch is CancellationError {
            recoverFromCancellation(operation: operation, speaker: context.speaker)
        } catch { fail(error, speaker: context.speaker, operation: operation) }
    }

    func editAndRetranslate() {
        guard !isCommitting, let prior = pendingResult, let context = activeContext, case .confirming = state else { return }
        guard !editableSource.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let operation = operationID
        let cleaned: String
        do {
            cleaned = try TurnTextPolicy.validated(editableSource)
            try transition(.translating(context.speaker))
        } catch {
            pendingErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            return
        }
        startWork(operation: operation) { [weak self] in
            await self?.retranslate(
                prior: prior,
                cleaned: cleaned,
                context: context,
                operation: operation
            )
        }
    }

    private func retranslate(
        prior: PipelineResult,
        cleaned: String,
        context: TurnContext,
        operation: UUID
    ) async {
        do {
            try validate(operation)
            let pipeline: any ConversationPipeline = prior.route == .online ? online : local
            currentPipeline = pipeline
            let rawResponse = try await pipeline.translateText(
                cleaned,
                source: context.pair.source(for: context.speaker),
                target: context.pair.target(for: context.speaker)
            )
            let revisedResponse = try boundedResult(rawResponse)
            try validate(operation)
            var revised = revisedResponse
            let integrity = integrityReport(source: cleaned, translation: revised.translatedText, context: context)
            if integrity.hasMismatch { revised.warnings.insert(.entityMismatch) }
            pendingResult = revised
            pendingIntegrity = integrity
            pendingUserEdited = true
            pendingErrorMessage = nil
            try transition(.confirming(context.speaker))
        } catch is CancellationError {
            if operationID == operation { try? transition(.confirming(context.speaker)) }
        } catch {
            guard operationID == operation else { return }
            pendingErrorMessage = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            try? transition(.confirming(context.speaker))
        }
    }

    func approvePending() {
        guard !isCommitting, let result = pendingResult, let context = activeContext, case .confirming = state else { return }
        guard pendingIntegrity?.extractionLimitExceeded != true else {
            pendingErrorMessage = "Too many safety-critical details were detected. Edit and split this into shorter turns before speaking it."
            return
        }
        let operation = operationID
        // Claim the commit synchronously at the button boundary. The lease is
        // operation-bound so a stale task's defer cannot unlock its successor.
        guard let commit = claimCommit(for: operation) else { return }
        startWork(operation: operation) { [weak self] in
            await self?.commitAndOptionallySpeak(
                result,
                context: context,
                operation: operation,
                claimedCommit: commit
            )
        }
    }

    func submitTyped(_ text: String, speaker: SpeakerSide) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        // Typed input is another way to start a turn. It must not cancel a turn
        // that is already recording, translating, or awaiting confirmation.
        guard state.acceptsMicrophoneTap else { return }
        let operation = beginOperation()
        do {
            guard turns.count < ConversationContentPolicy.maximumTurns else {
                throw PipelineError.server("This conversation reached 500 turns. Start a new conversation to continue.")
            }
            let cleaned = try TurnTextPolicy.validated(text)
            try transition(.preparing(speaker))
            let selectedPair = pair
            startWork(operation: operation) { [weak self] in
                await self?.prepareTypedTurn(
                    cleaned,
                    speaker: speaker,
                    pair: selectedPair,
                    operation: operation
                )
            }
        } catch { fail(error, speaker: speaker, operation: operation) }
    }

    private func prepareTypedTurn(
        _ cleaned: String,
        speaker: SpeakerSide,
        pair selectedPair: LanguagePair,
        operation: UUID
    ) async {
        do {
            try validate(operation)
            var decision = try router.decide(
                preference: settings.value.routing,
                pair: selectedPair,
                hasPro: subscription.hasPro,
                isOnline: network.isOnline
            )
            if decision.route == .online, !settings.value.hasCurrentOnlineProcessingConsent {
                if settings.value.routing == .automatic {
                    decision = RouteDecision(route: .local, disclosure: "Auto kept typed text on this device because Online Quality consent has not been granted.")
                } else { throw PipelineError.server("Review and accept the Online Quality disclosure before translating.") }
            }
            var pipeline: any ConversationPipeline = decision.route == .online ? online : local
            currentPipeline = pipeline
            activeRoute = decision.route
            routeDisclosure = decision.route == .online ? "Typed text is sent to Google Cloud for translation." : "Typed text is translated on this device."
            do {
                if settings.value.autoSpeak {
                    try playback.prepare(
                        locale: selectedPair.target(for: speaker).locale
                    )
                }
                try await pipeline.prepare(pair: selectedPair)
                try validate(operation)
            } catch {
                try validate(operation)
                guard settings.value.routing == .automatic, decision.route == .online else { throw error }
                decision = RouteDecision(route: .local, disclosure: "Online Quality was unavailable, so typed text stayed on this device.")
                pipeline = local
                currentPipeline = local
                activeRoute = .local
                routeDisclosure = decision.disclosure
                try await local.prepare(pair: selectedPair)
                try validate(operation)
            }
            let context = TurnContext(
                id: UUID(), speaker: speaker, pair: selectedPair, route: decision.route, startedAt: Date(),
                saveOnDevice: settings.value.saveHistoryOnDevice
            )
            activeContext = context
            try transition(.reviewing(speaker))
            try transition(.translating(speaker))
            let rawResult = try await pipeline.translateText(
                cleaned,
                source: selectedPair.source(for: speaker),
                target: selectedPair.target(for: speaker)
            )
            var result = try boundedResult(rawResult)
            try validate(operation)
            let integrity = integrityReport(source: cleaned, translation: result.translatedText, context: context)
            if integrity.hasMismatch { result.warnings.insert(.entityMismatch) }
            pendingResult = result
            pendingIntegrity = integrity
            editableSource = cleaned
            pendingUserEdited = false
            pendingErrorMessage = nil
            try transition(.confirming(speaker))
        } catch is CancellationError {
            recoverFromCancellation(operation: operation, speaker: speaker)
        } catch { fail(error, speaker: speaker, operation: operation) }
    }

    func discardPending() {
        guard !isCommitting, let speaker = state.speaker else { return }
        _ = beginOperation()
        clearEphemeralState()
        activeContext = nil
        machine.reset(speaker: speaker)
        state = machine.state
    }

    func replayLast() {
        guard let latest = turns.last, case let .ready(readySpeaker) = state,
              let target = AppLanguage.allCases.first(where: { $0.code == latest.targetLocale }) else { return }
        let operation = beginOperation()
        do {
            try playback.prepare(locale: target.locale)
            try transition(.speaking(outputFor: latest.speaker, recoverTo: readySpeaker))
            startWork(operation: operation) { [weak self] in
                await self?.replay(
                    latest,
                    target: target,
                    readySpeaker: readySpeaker,
                    operation: operation
                )
            }
        } catch { fail(error, speaker: readySpeaker, operation: operation) }
    }

    private func replay(
        _ latest: ConversationTurn,
        target: AppLanguage,
        readySpeaker: SpeakerSide,
        operation: UUID
    ) async {
        do {
            try validate(operation)
            try await playback.speak(latest.translatedText, locale: target.locale, slower: settings.value.slowerSpeech)
            try validate(operation)
            try transition(.ready(readySpeaker))
        } catch is CancellationError {
            recoverFromCancellation(operation: operation, speaker: readySpeaker)
        } catch { fail(error, speaker: readySpeaker, operation: operation) }
    }

    func endSession() {
        cancelAll()
        clearEphemeralState()
        turns = []
        locallyPersistedTurns = []
        record = nil
        machine.reset()
        state = machine.state
    }

    func handleSceneActivity(isActive: Bool) {
        isSceneActive = isActive
        guard !isActive,
              ConversationSceneLifecyclePolicy.shouldCancel(
                state: state,
                isRequestingMicrophonePermission: permissionRequestOperation == operationID
              ) else { return }
        let recoverSpeaker = state.recoverySpeaker ?? .traveler
        cancelAll()
        clearEphemeralState()
        machine.reset(speaker: recoverSpeaker)
        state = machine.state
    }

    func handleEnteredBackground() {
        handleSceneActivity(isActive: false)
    }

    func handleResourcePressure(_ pressure: ConversationResourcePressure) {
        guard ResourcePressurePolicy.shouldCancel(pressure: pressure, stateIsBusy: state.isBusy) else { return }
        let speaker = state.recoverySpeaker ?? .traveler
        let operation = beginOperation()
        let message: String
        switch pressure {
        case .memoryWarning:
            message = "The turn stopped because this iPhone is low on memory. Close other apps and try again."
        case .thermal:
            message = "The turn stopped because this iPhone needs to cool down. Try again in a few minutes."
        }
        fail(PipelineError.server(message), speaker: speaker, operation: operation)
    }

    private func commitAndOptionallySpeak(
        _ result: PipelineResult,
        context: TurnContext,
        operation: UUID,
        claimedCommit: ConversationCommitGeneration.Lease? = nil
    ) async {
        let commit: ConversationCommitGeneration.Lease
        if let claimedCommit {
            guard commitGeneration.isCurrent(claimedCommit, for: operation) else { return }
            commit = claimedCommit
        } else {
            guard let lease = claimCommit(for: operation) else { return }
            commit = lease
        }
        defer { finishCommitIfCurrent(commit) }
        do {
            try validate(operation)
            guard turns.count < ConversationContentPolicy.maximumTurns else {
                throw PipelineError.server("This conversation reached 500 turns. Start a new conversation to continue.")
            }
            let result = try boundedResult(result)
            let report = pendingIntegrity ?? integrityReport(source: result.sourceText, translation: result.translatedText, context: context)
            guard !report.extractionLimitExceeded else {
                throw PipelineError.server("Too many safety-critical details were detected. Split this into shorter turns.")
            }
            let now = Date()
            let turn = ConversationTurn(
                id: UUID(), sequence: turns.count, speaker: context.speaker,
                sourceLocale: context.pair.source(for: context.speaker).code,
                targetLocale: context.pair.target(for: context.speaker).code,
                sourceText: result.sourceText, translatedText: result.translatedText,
                userEdited: pendingUserEdited, createdAt: now, entities: report.source,
                route: context.route, recognitionConfidence: result.recognitionConfidence,
                warnings: result.warnings
            )
            turns.append(turn)
            record?.turns = turns
            record?.updatedAt = now

            var localRecordToSave: ConversationRecord?
            if context.saveOnDevice, settings.value.saveHistoryOnDevice, let base = record {
                locallyPersistedTurns.append(turn)
                var localRecord = base
                localRecord.turns = locallyPersistedTurns
                localRecordToSave = localRecord
            }
            if let localRecordToSave {
                history.saveOnDevice(localRecordToSave, enabled: true)
                // Publishing the refreshed history can synchronously invoke UI
                // observers. Revalidate ownership before any later mutation.
                try validate(operation)
                guard commitGeneration.isCurrent(commit, for: operation) else {
                    throw CancellationError()
                }
            }

            pendingResult = nil
            pendingIntegrity = nil
            pendingErrorMessage = nil
            pendingUserEdited = false
            partialTranscript = ""
            editableSource = ""
            if settings.value.autoSpeak {
                try transition(.speaking(outputFor: context.speaker, recoverTo: context.speaker.other))
                try await playback.speak(result.translatedText, locale: context.pair.target(for: context.speaker).locale, slower: settings.value.slowerSpeech)
                try validate(operation)
            }
            activeContext = nil
            try transition(.ready(context.speaker.other))
        } catch is CancellationError {
            recoverFromCancellation(operation: operation, speaker: context.speaker.other)
        } catch { fail(error, speaker: context.speaker.other, operation: operation) }
    }

    private func integrityReport(source: String, translation: String, context: TurnContext) -> EntityIntegrityReport {
        extractor.compare(
            source: source,
            translation: translation,
            sourceLocale: context.pair.source(for: context.speaker).locale,
            targetLocale: context.pair.target(for: context.speaker).locale,
            referenceDate: context.startedAt,
            timeZone: .current
        )
    }

    private func boundedResult(_ unvalidated: PipelineResult) throws -> PipelineResult {
        var result = unvalidated
        result.sourceText = try TurnTextPolicy.validatedFinal(result.sourceText, field: "source")
        result.translatedText = try TurnTextPolicy.validatedFinal(result.translatedText, field: "translation")
        if let confidence = result.recognitionConfidence,
           !confidence.isFinite || !(0...1).contains(confidence) {
            throw PipelineError.malformedResponse
        }
        return result
    }

    private func transition(_ next: ConversationState) throws {
        try machine.transition(to: next)
        state = machine.state
    }

    private func beginOperation() -> UUID {
        operationID = UUID()
        workTask?.cancel()
        workTask = nil
        workGeneration.invalidate()
        invalidateCommit()
        audio.cancel()
        currentPipeline?.cancel()
        playback.cancel()
        return operationID
    }

    private func startWork(operation: UUID, body: @escaping @MainActor () async -> Void) {
        workTask?.cancel()
        let generation = workGeneration.begin()
        workTask = Task { @MainActor [weak self] in
            await body()
            guard let self, self.operationID == operation,
                  self.workGeneration.clearIfCurrent(generation) else { return }
            self.workTask = nil
        }
    }

    private func validate(_ operation: UUID) throws {
        try Task.checkCancellation()
        guard operationID == operation else { throw CancellationError() }
    }

    private func recoverFromCancellation(operation: UUID, speaker: SpeakerSide) {
        guard operationID == operation else { return }
        audio.cancel()
        currentPipeline?.cancel()
        playback.cancel()
        activeContext = nil
        clearEphemeralState()
        machine.reset(speaker: speaker)
        state = machine.state
    }

    private func fail(_ error: Error, speaker: SpeakerSide, operation: UUID) {
        guard operationID == operation else { return }
        audio.cancel()
        currentPipeline?.cancel()
        playback.cancel()
        activeContext = nil
        clearEphemeralState()
        let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        if (try? machine.transition(to: .failed(message: message, recoverTo: speaker))) != nil { state = machine.state }
        else { machine.reset(speaker: speaker); state = .failed(message: message, recoverTo: speaker) }
    }

    private func captureInterrupted() {
        guard let speaker = state.speaker, case .listening = state else { return }
        let operation = beginOperation()
        fail(PipelineError.server("Recording stopped because the audio route or app state changed."), speaker: speaker, operation: operation)
    }

    private func captureFailed(_ message: String) {
        guard let speaker = state.speaker, case .listening = state else { return }
        let operation = beginOperation()
        fail(PipelineError.server(message), speaker: speaker, operation: operation)
    }

    private func finishCaptureAtLimit() {
        guard let speaker = state.speaker, case .listening = state else { return }
        startFinishingTurn(speaker: speaker)
    }

    private func cancelAll() {
        operationID = UUID()
        workTask?.cancel()
        workTask = nil
        workGeneration.invalidate()
        invalidateCommit()
        permissionRequestOperation = nil
        audio.cancel()
        currentPipeline?.cancel()
        currentPipeline = nil
        playback.cancel()
        activeContext = nil
    }

    private func clearEphemeralState() {
        partialTranscript = ""
        pendingResult = nil
        pendingIntegrity = nil
        pendingErrorMessage = nil
        pendingUserEdited = false
        editableSource = ""
        invalidateCommit()
    }

    private func claimCommit(for operation: UUID) -> ConversationCommitGeneration.Lease? {
        guard operationID == operation,
              let commit = commitGeneration.claim(for: operation) else { return nil }
        isCommitting = true
        return commit
    }

    private func finishCommitIfCurrent(_ commit: ConversationCommitGeneration.Lease) {
        guard commitGeneration.finishIfCurrent(commit) else { return }
        isCommitting = false
    }

    private func invalidateCommit() {
        commitGeneration.invalidate()
        isCommitting = false
    }
}

enum ConversationResourcePressure: Equatable {
    case memoryWarning
    case thermal(ProcessInfo.ThermalState)
}

enum ResourcePressurePolicy {
    static func shouldCancel(pressure: ConversationResourcePressure, stateIsBusy: Bool) -> Bool {
        guard stateIsBusy else { return false }
        return switch pressure {
        case .memoryWarning: true
        case let .thermal(state): state == .serious || state == .critical
        }
    }
}

/// A completed task may clear the orchestrator's cancellation handle only when
/// it is still the currently retained task. Conversation operations can have
/// same-operation successors (for example finalize -> approve), so checking the
/// conversation operation UUID alone is insufficient.
struct ConversationWorkGeneration {
    private(set) var active: UUID?

    mutating func begin() -> UUID {
        let generation = UUID()
        active = generation
        return generation
    }

    mutating func clearIfCurrent(_ generation: UUID) -> Bool {
        guard active == generation else { return false }
        active = nil
        return true
    }

    mutating func invalidate() { active = nil }
}

/// Owns the UI commit lock. A lease includes the conversation operation so an
/// old task cannot release or mutate a later operation's commit after an await.
struct ConversationCommitGeneration {
    struct Lease: Equatable {
        fileprivate let id: UUID
        fileprivate let operation: UUID
    }

    private(set) var active: Lease?

    mutating func claim(for operation: UUID) -> Lease? {
        guard active == nil else { return nil }
        let lease = Lease(id: UUID(), operation: operation)
        active = lease
        return lease
    }

    func isCurrent(_ lease: Lease, for operation: UUID) -> Bool {
        lease.operation == operation && active == lease
    }

    mutating func finishIfCurrent(_ lease: Lease) -> Bool {
        guard active == lease else { return false }
        active = nil
        return true
    }

    mutating func invalidate() { active = nil }
}

enum ConversationSceneLifecyclePolicy {
    static func shouldCancel(state: ConversationState, isRequestingMicrophonePermission: Bool) -> Bool {
        if case .preparing = state, isRequestingMicrophonePermission { return false }
        return switch state {
        case .preparing, .listening, .finalizing, .reviewing, .translating, .speaking:
            true
        case .notReady, .ready, .confirming, .failed:
            false
        }
    }

    static func mayStartAudio(isSceneActive: Bool) -> Bool { isSceneActive }
}
