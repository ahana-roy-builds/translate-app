import AVFoundation
import Foundation
import OSLog
import UIKit

enum CaptureBufferDisposition: Sendable {
    case continueCapture
    case finish(AudioTapTermination)
}

@MainActor
protocol MicrophoneCapturing: AnyObject {
    var onCaptureInterrupted: (() -> Void)? { get set }
    var onCaptureLimitReached: (() -> Void)? { get set }
    var onCaptureFailed: ((String) -> Void)? { get set }
    var isActive: Bool { get }

    func requestPermission() async -> Bool
    @discardableResult
    func start(
        generation: UUID,
        onBuffer: @escaping @MainActor (CapturedAudioBuffer) async throws -> CaptureBufferDisposition
    ) throws -> UUID
    func stop() async throws
    func cancel()
}

@MainActor
final class MicrophoneCaptureSession: MicrophoneCapturing {
    var onCaptureInterrupted: (() -> Void)?
    var onCaptureLimitReached: (() -> Void)?
    var onCaptureFailed: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var activeTapBridge: AudioTapBridge?
    private var deliveryTask: Task<Void, Never>?
    private var captureGeneration: UUID?
    private let lifecycleState = CaptureLifecycleState()
    private let notificationCenter: NotificationCenter
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LocalLingo",
        category: "AudioCapture"
    )
    // NotificationCenter's opaque tokens are not Sendable, but deinit can run
    // outside MainActor isolation. Only initialization and deinit touch them.
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
        let state = lifecycleState
        let names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            UIApplication.didEnterBackgroundNotification
        ]
        notificationTokens = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self] notification in
                let event: CaptureLifecycleEvent
                if name == AVAudioSession.routeChangeNotification {
                    let raw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                    let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                    if !CaptureLifecyclePolicy.shouldInterrupt(routeChangeReason: reason) { return }
                    event = .routeChange(reason?.rawValue)
                } else if name == AVAudioSession.interruptionNotification {
                    event = .interruption
                } else {
                    event = .background
                }
                guard let generation = state.activeGeneration else { return }
                Task { @MainActor [weak self] in
                    self?.handleLifecycleEvent(event, generation: generation)
                }
            }
        }
    }

    deinit {
        notificationTokens.forEach { notificationCenter.removeObserver($0) }
    }

    var isActive: Bool {
        captureGeneration != nil && (tapInstalled || engine.isRunning)
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    @discardableResult
    func start(
        generation: UUID = UUID(),
        onBuffer: @escaping @MainActor (CapturedAudioBuffer) async throws -> CaptureBufferDisposition
    ) throws -> UUID {
        guard !engine.isRunning, !tapInstalled, captureGeneration == nil else {
            throw PipelineError.server("Audio capture is already active.")
        }

        let bridge = AudioTapBridge(id: generation)
        captureGeneration = generation
        activeTapBridge = bridge
        deliveryTask = Task { @MainActor [weak self] in
            await self?.deliverBuffers(
                from: bridge,
                generation: generation,
                onBuffer: onBuffer
            )
        }

        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.defaultToSpeaker, .allowBluetoothHFP]
            )
            try session.setActive(true, options: .notifyOthersOnDeactivation)
            guard session.isInputAvailable else {
                throw PipelineError.server(
                    "The microphone is not currently available. Check the active audio input and try again."
                )
            }

            let input = engine.inputNode
            let format = input.outputFormat(forBus: 0)
            guard AudioInputFormatPolicy.isUsable(
                isInputAvailable: session.isInputAvailable,
                sampleRate: format.sampleRate,
                channelCount: format.channelCount
            ) else {
                logger.error(
                    "Refusing invalid microphone format: rate=\(format.sampleRate, privacy: .public), channels=\(format.channelCount, privacy: .public)"
                )
                throw PipelineError.server(
                    "The microphone audio route is not ready. Check the active audio input and try again."
                )
            }
            logger.info(
                "Starting microphone: rate=\(format.sampleRate, privacy: .public), channels=\(format.channelCount, privacy: .public)"
            )

            let tap: @Sendable (AVAudioPCMBuffer, AVAudioTime) -> Void = bridge.makeTapHandler()
            input.installTap(onBus: 0, bufferSize: 1_024, format: format, block: tap)
            tapInstalled = true
            engine.prepare()
            lifecycleState.activate(generation)
            try engine.start()
            return generation
        } catch {
            bridge.close(.finished)
            lifecycleState.deactivate()
            cleanupEngine()
            deliveryTask?.cancel()
            deliveryTask = nil
            if activeTapBridge?.id == bridge.id { activeTapBridge = nil }
            if captureGeneration == generation { captureGeneration = nil }
            throw error
        }
    }

    func stop() async throws {
        guard let generation = captureGeneration,
              tapInstalled || engine.isRunning || activeTapBridge != nil else {
            throw PipelineError.noSpeech
        }
        let bridge = activeTapBridge
        let task = deliveryTask
        lifecycleState.deactivate()
        bridge?.close(.finished)
        cleanupEngine()
        await bridge?.waitUntilIdle()
        await task?.value
        try Task.checkCancellation()
        guard captureGeneration == generation else { throw CancellationError() }

        deliveryTask = nil
        if activeTapBridge?.id == bridge?.id { activeTapBridge = nil }
        captureGeneration = nil
        if case let .failed(message) = bridge?.termination?.action ?? .none {
            throw PipelineError.server(message)
        }
    }

    func cancel() {
        captureGeneration = nil
        lifecycleState.deactivate()
        activeTapBridge?.close(.finished)
        cleanupEngine()
        deliveryTask?.cancel()
        deliveryTask = nil
        activeTapBridge = nil
    }

    private func cleanupEngine() {
        if tapInstalled {
            engine.inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }
        if engine.isRunning { engine.stop() }
        try? AVAudioSession.sharedInstance().setActive(
            false,
            options: .notifyOthersOnDeactivation
        )
    }

    private func deliverBuffers(
        from bridge: AudioTapBridge,
        generation: UUID,
        onBuffer: @escaping @MainActor (CapturedAudioBuffer) async throws -> CaptureBufferDisposition
    ) async {
        do {
            captureLoop: for await captured in bridge.stream {
                try Task.checkCancellation()
                guard captureGeneration == generation,
                      activeTapBridge?.id == bridge.id else { return }
                if bridge.termination?.abortsDelivery == true { break }
                switch try await onBuffer(captured) {
                case .continueCapture:
                    break
                case let .finish(reason):
                    bridge.close(reason)
                    break captureLoop
                }
            }
        } catch is CancellationError {
            bridge.close(.finished)
            return
        } catch {
            guard captureGeneration == generation,
                  activeTapBridge?.id == bridge.id else {
                bridge.close(.finished)
                return
            }
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            bridge.close(.consumerFailed(message))
        }

        guard captureGeneration == generation,
              activeTapBridge?.id == bridge.id else { return }
        let action = bridge.termination?.action ?? .none
        guard action != .none else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.captureGeneration == generation,
                  self.activeTapBridge?.id == bridge.id,
                  self.lifecycleState.activeGeneration == generation else { return }
            switch action {
            case .limitReached:
                self.onCaptureLimitReached?()
            case let .failed(message):
                self.onCaptureFailed?(message)
            case .none:
                break
            }
        }
    }

    private func handleLifecycleEvent(_: CaptureLifecycleEvent, generation: UUID) {
        guard lifecycleState.activeGeneration == generation,
              captureGeneration == generation,
              tapInstalled || engine.isRunning else { return }
        lifecycleState.deactivate()
        cancel()
        onCaptureInterrupted?()
    }
}

private enum CaptureLifecycleEvent: Sendable {
    case interruption
    case routeChange(UInt?)
    case background
}

enum CaptureLifecyclePolicy {
    static func shouldInterrupt(
        routeChangeReason: AVAudioSession.RouteChangeReason?
    ) -> Bool {
        routeChangeReason != .categoryChange
    }
}

enum AudioInputFormatPolicy {
    static func isUsable(
        isInputAvailable: Bool,
        sampleRate: Double,
        channelCount: AVAudioChannelCount
    ) -> Bool {
        isInputAvailable
            && sampleRate.isFinite
            && sampleRate > 0
            && channelCount > 0
    }
}

final class CaptureLifecycleState: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UUID?

    var activeGeneration: UUID? {
        lock.lock()
        defer { lock.unlock() }
        return generation
    }

    func activate(_ value: UUID) {
        lock.lock()
        generation = value
        lock.unlock()
    }

    func deactivate() {
        lock.lock()
        generation = nil
        lock.unlock()
    }
}
