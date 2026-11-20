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
    var onCaptureInterrupted: ((CaptureLifecycleEvent) -> Void)? { get set }
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
    var onCaptureInterrupted: ((CaptureLifecycleEvent) -> Void)?
    var onCaptureLimitReached: (() -> Void)?
    var onCaptureFailed: ((String) -> Void)?

    private let engine = AVAudioEngine()
    private var tapInstalled = false
    private var activeTapBridge: AudioTapBridge?
    private var deliveryTask: Task<Void, Never>?
    private let notificationCenter: NotificationCenter
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LocalLingo",
        category: "AudioCapture"
    )
    // NotificationCenter's opaque tokens are not Sendable, but deinit can run
    // outside MainActor isolation. Capture start and teardown own the registrations.
    private nonisolated(unsafe) var notificationTokens: [NSObjectProtocol] = []

    init(notificationCenter: NotificationCenter = .default) {
        self.notificationCenter = notificationCenter
    }

    private func observeLifecycle(for bridge: AudioTapBridge, route: CaptureAudioRoute) {
        let names: [Notification.Name] = [
            AVAudioSession.interruptionNotification,
            AVAudioSession.routeChangeNotification,
            UIApplication.didEnterBackgroundNotification
        ]
        notificationTokens = names.map { name in
            notificationCenter.addObserver(forName: name, object: nil, queue: nil) { [weak self, weak bridge] notification in
                let event: CaptureLifecycleEvent
                if name == AVAudioSession.routeChangeNotification {
                    let raw = (notification.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
                    let reason = raw.flatMap(AVAudioSession.RouteChangeReason.init(rawValue:))
                    event = .routeChange(reason)
                } else if name == AVAudioSession.interruptionNotification {
                    let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber
                    if type?.uintValue == AVAudioSession.InterruptionType.ended.rawValue { return }
                    event = .interruption
                } else {
                    event = .background
                }
                Task { @MainActor [weak self, weak bridge] in
                    guard let bridge else { return }
                    self?.handleLifecycleEvent(event, bridge: bridge, initialRoute: route)
                }
            }
        }
    }

    deinit {
        notificationTokens.forEach { notificationCenter.removeObserver($0) }
    }

    var isActive: Bool {
        activeTapBridge != nil && (tapInstalled || engine.isRunning)
    }

    func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    @discardableResult
    func start(
        generation: UUID = UUID(),
        onBuffer: @escaping @MainActor (CapturedAudioBuffer) async throws -> CaptureBufferDisposition
    ) throws -> UUID {
        guard !engine.isRunning, !tapInstalled, activeTapBridge == nil else {
            throw PipelineError.server("Audio capture is already active.")
        }

        let bridge = AudioTapBridge(id: generation)
        activeTapBridge = bridge
        deliveryTask = Task { @MainActor [weak self] in
            await self?.deliverBuffers(
                from: bridge,
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
            try session.setActive(true)
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
            observeLifecycle(for: bridge, route: CaptureAudioRoute(session))
            try engine.start()
            return generation
        } catch {
            bridge.close(.finished)
            cleanupEngine()
            deliveryTask?.cancel()
            deliveryTask = nil
            activeTapBridge = nil
            throw error
        }
    }

    func stop() async throws {
        guard let bridge = activeTapBridge else { throw PipelineError.noSpeech }
        let task = deliveryTask
        bridge.close(.finished)
        cleanupEngine()
        await bridge.waitUntilIdle()
        await task?.value
        try Task.checkCancellation()
        guard activeTapBridge === bridge else { throw CancellationError() }

        deliveryTask = nil
        activeTapBridge = nil
        if case let .failed(message) = bridge.termination?.action ?? .none {
            throw PipelineError.server(message)
        }
    }

    func cancel() {
        guard activeTapBridge != nil else { return }
        activeTapBridge?.close(.finished)
        cleanupEngine()
        deliveryTask?.cancel()
        deliveryTask = nil
        activeTapBridge = nil
    }

    private func cleanupEngine() {
        notificationTokens.forEach { notificationCenter.removeObserver($0) }
        notificationTokens.removeAll()
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
        onBuffer: @escaping @MainActor (CapturedAudioBuffer) async throws -> CaptureBufferDisposition
    ) async {
        do {
            captureLoop: for await captured in bridge.stream {
                try Task.checkCancellation()
                guard activeTapBridge === bridge else { return }
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
            guard activeTapBridge === bridge else {
                bridge.close(.finished)
                return
            }
            let message = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            bridge.close(.consumerFailed(message))
        }

        guard activeTapBridge === bridge else { return }
        let action = bridge.termination?.action ?? .none
        guard action != .none else { return }
        Task { @MainActor [weak self] in
            guard let self,
                  self.activeTapBridge === bridge, self.tapInstalled else { return }
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

    private func handleLifecycleEvent(_ event: CaptureLifecycleEvent, bridge: AudioTapBridge, initialRoute: CaptureAudioRoute) {
        // Talk reuses its conversation ID across playback. A queued callback
        // belongs to the tap that observed it, even if capture has since reopened.
        guard activeTapBridge === bridge, tapInstalled else { return }
        if case let .routeChange(reason) = event {
            let current = CaptureAudioRoute(AVAudioSession.sharedInstance())
            let usable = current.canContinue(from: initialRoute, reason: reason, engineRunning: engine.isRunning)
            logger.info("Microphone route notification: reason=\(reason?.rawValue.description ?? "unknown", privacy: .public), continuing=\(usable, privacy: .public)")
            guard !usable else { return }
        }
        logger.info("Microphone stopped: \(event.message, privacy: .public)")
        cancel()
        onCaptureInterrupted?(event)
    }
}

enum CaptureLifecycleEvent: Sendable {
    case interruption
    case routeChange(AVAudioSession.RouteChangeReason?)
    case background

    var message: String {
        switch self {
        case .interruption: "iOS interrupted the microphone. Tap retry to continue."
        case .routeChange: "The microphone’s audio route changed. Check the input and tap retry."
        case .background: "Listening paused when Speak Duet went into the background."
        }
    }
}

struct CaptureAudioRoute {
    let inputs: Set<String>
    let outputs: Set<String>
    let sampleRate: Double
    let channels: Int

    func canContinue(from initial: Self, reason: AVAudioSession.RouteChangeReason?, engineRunning: Bool) -> Bool {
        guard engineRunning, !inputs.isEmpty, inputs == initial.inputs,
              sampleRate > 0, sampleRate == initial.sampleRate,
              channels > 0, channels == initial.channels else { return false }
        // Unplugging the active headset can change where private audio plays.
        // A late notification with the same route describes no such removal.
        return reason != .noSuitableRouteForCategory
            && (reason != .oldDeviceUnavailable || initial.outputs.isSubset(of: outputs))
    }
}

private extension CaptureAudioRoute {
    init(_ session: AVAudioSession) {
        let route = session.currentRoute
        self.init(inputs: Set(route.inputs.map(\.uid)), outputs: Set(route.outputs.map(\.uid)),
                  sampleRate: session.sampleRate, channels: session.inputNumberOfChannels)
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
