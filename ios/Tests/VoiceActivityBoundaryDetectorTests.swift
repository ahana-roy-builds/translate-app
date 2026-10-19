import AVFoundation
import XCTest
@testable import LocalLingo

final class VoiceActivityBoundaryDetectorTests: XCTestCase {
    @MainActor
    func testBundledSileroModelLoadsAndRunsSilence() async throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(
            pcmFormat: format,
            frameCapacity: 4_096
        ))
        buffer.frameLength = 4_096

        let detector = SileroVoiceActivityDetector()
        try await detector.prepare()
        let result = try await detector.process(VoiceActivityInput(
            buffer: buffer,
            audioTime: AVAudioTime(sampleTime: 0, atRate: 16_000)
        ))

        let probability = try XCTUnwrap(result.probabilities.first)
        XCTAssertEqual(result.probabilities.count, 1)
        XCTAssertTrue(probability.isFinite)
        XCTAssertGreaterThanOrEqual(probability, 0)
        XCTAssertLessThanOrEqual(probability, 1)
        XCTAssertEqual(result.processedThrough.seconds, 0.256, accuracy: 0.000_001)
        XCTAssertTrue(result.events.isEmpty)
    }

    func testSpeechEndsAfterConfiguredSilenceWithPadding() {
        var detector = VoiceActivityBoundaryDetector(
            sampleRate: 100,
            minimumSpeechDuration: 0.1,
            minimumSilenceDuration: 0.9,
            maximumSpeechDuration: 14,
            speechPadding: 0.1
        )

        XCTAssertEqual(
            detector.process(probability: 0.95, sampleCount: 20),
            [.speechStarted(sample: 0)]
        )
        XCTAssertTrue(detector.process(probability: 0.1, sampleCount: 30).isEmpty)
        XCTAssertTrue(detector.process(probability: 0.1, sampleCount: 30).isEmpty)
        XCTAssertEqual(
            detector.process(probability: 0.1, sampleCount: 30),
            [.speechEnded(
                startSample: 0,
                endSample: 30,
                reason: .silence
            )]
        )
    }

    func testFinishClosesAnActiveUtterance() {
        var detector = VoiceActivityBoundaryDetector(
            sampleRate: 100,
            minimumSpeechDuration: 0.1
        )
        _ = detector.process(probability: 0.95, sampleCount: 20)

        XCTAssertEqual(
            detector.finish(),
            [.speechEnded(
                startSample: 0,
                endSample: 20,
                reason: .silence
            )]
        )
    }

    func testFinishDropsSpeechBelowMinimumDuration() {
        var detector = VoiceActivityBoundaryDetector(
            sampleRate: 100,
            minimumSpeechDuration: 0.1
        )
        _ = detector.process(probability: 0.95, sampleCount: 5)

        XCTAssertTrue(detector.finish().isEmpty)
    }

    func testTrailingPaddingDoesNotPromoteShortNoiseToSpeech() {
        var detector = VoiceActivityBoundaryDetector(
            sampleRate: 100,
            minimumSpeechDuration: 0.25,
            minimumSilenceDuration: 0.9,
            speechPadding: 0.1
        )

        XCTAssertTrue(
            detector.process(probability: 0.95, sampleCount: 20).isEmpty
        )
        XCTAssertTrue(
            detector.process(probability: 0.1, sampleCount: 90).isEmpty
        )
        XCTAssertTrue(detector.finish().isEmpty)
    }

    func testMaximumDurationSplitsLongSpeech() {
        var detector = VoiceActivityBoundaryDetector(
            sampleRate: 10,
            minimumSpeechDuration: 0,
            minimumSilenceDuration: 0.9,
            maximumSpeechDuration: 1,
            speechPadding: 0
        )
        _ = detector.process(probability: 0.95, sampleCount: 5)

        XCTAssertEqual(
            detector.process(probability: 0.95, sampleCount: 5),
            [.speechEnded(
                startSample: 0,
                endSample: 10,
                reason: .maximumDuration
            )]
        )
    }

    func testMaximumDurationContinuationDoesNotOverlap() {
        var detector = VoiceActivityBoundaryDetector(
            sampleRate: 10,
            minimumSpeechDuration: 0,
            minimumSilenceDuration: 0.9,
            maximumSpeechDuration: 1,
            speechPadding: 0
        )
        _ = detector.process(probability: 0.95, sampleCount: 6)

        XCTAssertEqual(
            detector.process(probability: 0.95, sampleCount: 6),
            [
                .speechEnded(
                    startSample: 0,
                    endSample: 10,
                    reason: .maximumDuration
                ),
                .speechStarted(sample: 10)
            ]
        )
        XCTAssertEqual(
            detector.finish(),
            [.speechEnded(
                startSample: 10,
                endSample: 12,
                reason: .silence
            )]
        )
    }
}
