import AVFoundation
import Foundation
import XCTest
@testable import LocalLingo

final class AudioLifecycleTests: XCTestCase {
    func testPlaybackRouteNotificationsCanKeepUsingTheActiveMicrophone() {
        let initial = CaptureAudioRoute(inputs: ["mic"], outputs: ["speaker"], sampleRate: 48_000, channels: 1)
        let receiver = CaptureAudioRoute(inputs: ["mic"], outputs: ["receiver"], sampleRate: 48_000, channels: 1)
        for reason: AVAudioSession.RouteChangeReason? in [.categoryChange, .override, .routeConfigurationChange, .newDeviceAvailable, nil] {
            XCTAssertTrue(receiver.canContinue(from: initial, reason: reason, engineRunning: true))
        }
        XCTAssertTrue(initial.canContinue(from: initial, reason: .oldDeviceUnavailable, engineRunning: true))
        XCTAssertFalse(receiver.canContinue(from: initial, reason: .oldDeviceUnavailable, engineRunning: true))
        XCTAssertFalse(initial.canContinue(from: initial, reason: .noSuitableRouteForCategory, engineRunning: true))
        XCTAssertFalse(initial.canContinue(from: initial, reason: .routeConfigurationChange, engineRunning: false))
        for route in [
            CaptureAudioRoute(inputs: [], outputs: ["speaker"], sampleRate: 48_000, channels: 1),
            CaptureAudioRoute(inputs: ["headset"], outputs: ["speaker"], sampleRate: 48_000, channels: 1),
            CaptureAudioRoute(inputs: ["mic"], outputs: ["speaker"], sampleRate: 16_000, channels: 1),
            CaptureAudioRoute(inputs: ["mic"], outputs: ["speaker"], sampleRate: 48_000, channels: 2)
        ] {
            XCTAssertFalse(route.canContinue(from: initial, reason: .routeConfigurationChange, engineRunning: true))
        }
    }

    func testAudioInputFormatRequiresAvailableInputAndValidDimensions() {
        XCTAssertTrue(
            AudioInputFormatPolicy.isUsable(
                isInputAvailable: true,
                sampleRate: 48_000,
                channelCount: 1
            )
        )
        XCTAssertFalse(
            AudioInputFormatPolicy.isUsable(
                isInputAvailable: false,
                sampleRate: 48_000,
                channelCount: 1
            )
        )
        XCTAssertFalse(
            AudioInputFormatPolicy.isUsable(
                isInputAvailable: true,
                sampleRate: 0,
                channelCount: 1
            )
        )
        XCTAssertFalse(
            AudioInputFormatPolicy.isUsable(
                isInputAvailable: true,
                sampleRate: .infinity,
                channelCount: 1
            )
        )
        XCTAssertFalse(
            AudioInputFormatPolicy.isUsable(
                isInputAvailable: true,
                sampleRate: 48_000,
                channelCount: 0
            )
        )
    }

    @MainActor
    func testDelayedNotificationsCannotStopReopenedPhysicalMicrophone() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SPEAK_DUET_LIVE_MIC"] == "1",
                          "Requires an opt-in physical microphone run.")
        let center = NotificationCenter()
        let microphone = MicrophoneCaptureSession(notificationCenter: center)
        let permission = await microphone.requestPermission()
        XCTAssertTrue(permission)
        defer { microphone.cancel() }
        var interruptions = 0
        microphone.onCaptureInterrupted = { _ in interruptions += 1 }
        let conversation = UUID()
        func post(_ type: AVAudioSession.InterruptionType) {
            center.post(name: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(),
                        userInfo: [AVAudioSessionInterruptionTypeKey: NSNumber(value: type.rawValue)])
        }
        try microphone.start(generation: conversation) { _ in .continueCapture }
        post(.began)
        // The queued begin belongs to the first tap. Reopen synchronously before it can be delivered.
        microphone.cancel()
        var buffers = 0
        try microphone.start(generation: conversation) { _ in
            buffers += 1
            return .continueCapture
        }
        post(.ended)
        center.post(name: AVAudioSession.routeChangeNotification, object: AVAudioSession.sharedInstance(),
                    userInfo: [AVAudioSessionRouteChangeReasonKey: AVAudioSession.RouteChangeReason.routeConfigurationChange.rawValue])
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while buffers < 3, ContinuousClock.now < deadline, interruptions == 0 {
            try await Task.sleep(for: .milliseconds(25))
        }
        XCTAssertGreaterThanOrEqual(buffers, 3)
        XCTAssertEqual(interruptions, 0)
        XCTAssertTrue(microphone.isActive)
        post(.began)
        let stopDeadline = ContinuousClock.now.advanced(by: .seconds(1))
        while microphone.isActive, ContinuousClock.now < stopDeadline { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertEqual(interruptions, 1)
        XCTAssertFalse(microphone.isActive)
    }

    @MainActor
    func testStaleTapCannotAppendIntoReplacementAccumulatorGeneration() throws {
        let accumulator = AudioBufferAccumulator()
        let first = UUID()
        let second = UUID()
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 48))
        buffer.frameLength = 48

        accumulator.begin(generation: first)
        XCTAssertEqual(accumulator.append(buffer, generation: first), .accepted)
        accumulator.begin(generation: second)

        XCTAssertEqual(accumulator.append(buffer, generation: first), .staleGeneration)
        XCTAssertEqual(accumulator.append(buffer, generation: second), .accepted)
        XCTAssertEqual(accumulator.finish(generation: second)?.count, 1)
        XCTAssertEqual(accumulator.append(buffer, generation: second), .staleGeneration)
    }

    func testInactiveSceneCancelsEveryCaptureTranslationAndPlaybackPhase() {
        let cancellable: [ConversationState] = [
            .preparing(.traveler),
            .listening(.traveler),
            .finalizing(.traveler),
            .reviewing(.traveler),
            .translating(.traveler),
            .speaking(outputFor: .traveler, recoverTo: .local)
        ]

        for state in cancellable {
            XCTAssertTrue(
                ConversationSceneLifecyclePolicy.shouldCancel(
                    state: state,
                    isRequestingMicrophonePermission: false
                ),
                "Expected inactive scene to cancel \(state)"
            )
        }
    }

    func testPermissionPromptInactivityDoesNotCancelPreparation() {
        XCTAssertFalse(
            ConversationSceneLifecyclePolicy.shouldCancel(
                state: .preparing(.traveler),
                isRequestingMicrophonePermission: true
            )
        )
        XCTAssertTrue(
            ConversationSceneLifecyclePolicy.shouldCancel(
                state: .preparing(.traveler),
                isRequestingMicrophonePermission: false
            )
        )
    }

    func testAudioStartIsGatedOnAnActiveSceneAfterPermissionReturns() {
        XCTAssertTrue(ConversationSceneLifecyclePolicy.mayStartAudio(isSceneActive: true))
        XCTAssertFalse(ConversationSceneLifecyclePolicy.mayStartAudio(isSceneActive: false))
    }

    func testInactiveScenePreservesReviewAndIdleStates() {
        let preserved: [ConversationState] = [
            .notReady,
            .ready(.traveler),
            .confirming(.traveler),
            .failed(message: "retry", recoverTo: .traveler)
        ]

        for state in preserved {
            XCTAssertFalse(
                ConversationSceneLifecyclePolicy.shouldCancel(
                    state: state,
                    isRequestingMicrophonePermission: false
                )
            )
        }
    }
}
