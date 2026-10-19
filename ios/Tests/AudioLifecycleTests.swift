import AVFoundation
import Foundation
import XCTest
@testable import LocalLingo

final class AudioLifecycleTests: XCTestCase {
    func testSelfInducedCategoryChangeDoesNotInterruptCapture() {
        XCTAssertFalse(CaptureLifecyclePolicy.shouldInterrupt(routeChangeReason: .categoryChange))
        XCTAssertTrue(CaptureLifecyclePolicy.shouldInterrupt(routeChangeReason: .oldDeviceUnavailable))
        XCTAssertTrue(CaptureLifecyclePolicy.shouldInterrupt(routeChangeReason: nil))
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

    func testGenerationSnapshotCannotTargetLaterCapture() {
        let state = CaptureLifecycleState()
        let first = UUID()
        let second = UUID()

        XCTAssertNil(state.activeGeneration)
        state.activate(first)
        XCTAssertEqual(state.activeGeneration, first)
        state.deactivate()
        state.activate(second)
        XCTAssertNotEqual(state.activeGeneration, first)
        XCTAssertEqual(state.activeGeneration, second)
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
