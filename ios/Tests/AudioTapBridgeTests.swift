import AVFoundation
import Dispatch
import XCTest
@testable import LocalLingo

final class AudioTapBridgeTests: XCTestCase {
    func testTapHandlerCanRunOffMainExecutor() async {
        let bridge = AudioTapBridge()
        let handler = bridge.makeTapHandler()
        let consumer = markerConsumer(for: bridge)

        await runAudioTapOffMain {
            handler(makeAudioTapTestBuffer(marker: 0.25), makeAudioTapTestTime())
            bridge.close(.finished)
        }

        let markers = await consumer.value
        XCTAssertEqual(markers, [0.25])
        XCTAssertEqual(bridge.termination, .finished)
    }

    func testTapCopiesBufferBeforeCallbackReturns() async {
        let bridge = AudioTapBridge()
        let handler = bridge.makeTapHandler()

        await runAudioTapOffMain {
            let source = makeAudioTapTestBuffer(marker: 0.25)
            handler(source, makeAudioTapTestTime())
            source.floatChannelData?.pointee[0] = 0.75
            bridge.close(.finished)
        }

        let markers = await markers(in: bridge)
        XCTAssertEqual(markers, [0.25])
    }

    func testTapPreservesBufferOrder() async {
        let bridge = AudioTapBridge()
        let handler = bridge.makeTapHandler()
        let consumer = markerConsumer(for: bridge)

        await runAudioTapOffMain {
            for marker: Float in [1, 2, 3] {
                handler(makeAudioTapTestBuffer(marker: marker), makeAudioTapTestTime())
            }
            bridge.close(.finished)
        }

        let markers = await consumer.value
        XCTAssertEqual(markers, [1, 2, 3])
    }

    func testTapPreservesTimestampAndCaptureGeneration() async throws {
        let generation = UUID()
        let bridge = AudioTapBridge(id: generation)
        let handler = bridge.makeTapHandler()

        await runAudioTapOffMain {
            handler(
                makeAudioTapTestBuffer(marker: 1),
                makeAudioTapTestTime(sampleTime: 12_345)
            )
            bridge.close(.finished)
        }

        var capturedBuffers: [CapturedAudioBuffer] = []
        for await captured in bridge.stream {
            capturedBuffers.append(captured)
        }
        let captured = try XCTUnwrap(capturedBuffers.first)
        XCTAssertEqual(captured.audioTime.sampleTime, 12_345)
        XCTAssertEqual(captured.audioTime.sampleRate, 48_000)
        XCTAssertEqual(captured.generation, generation)
    }

    func testTapCopiesEveryNonInterleavedChannelAndFrame() async {
        let bridge = AudioTapBridge()
        let handler = bridge.makeTapHandler()

        await runAudioTapOffMain {
            let source = makeStereoAudioTapTestBuffer()
            handler(source, makeAudioTapTestTime())
            if let channels = source.floatChannelData {
                for channel in 0..<Int(source.format.channelCount) {
                    for frame in 0..<Int(source.frameLength) {
                        channels[channel][frame] = 99
                    }
                }
            }
            bridge.close(.finished)
        }

        let samples = await channelSamples(in: bridge)
        XCTAssertEqual(samples, [[[1, 2, 3], [4, 5, 6]]])
    }

    func testBoundedStreamTerminatesWhenConsumerFallsBehind() async {
        let bridge = AudioTapBridge(bufferingLimit: 1)
        let handler = bridge.makeTapHandler()

        await runAudioTapOffMain {
            handler(makeAudioTapTestBuffer(marker: 1), makeAudioTapTestTime())
            handler(makeAudioTapTestBuffer(marker: 2), makeAudioTapTestTime())
        }

        XCTAssertEqual(bridge.termination, .overflow)
        let deliveredMarkers = await markers(in: bridge)
        XCTAssertEqual(deliveredMarkers, [1])
    }

    func testCloseIsIdempotentAndRejectsLateTapBuffers() async {
        let bridge = AudioTapBridge()
        let handler = bridge.makeTapHandler()

        XCTAssertTrue(bridge.close(.finished))
        XCTAssertFalse(bridge.close(.finished))
        await runAudioTapOffMain {
            handler(makeAudioTapTestBuffer(marker: 1), makeAudioTapTestTime())
        }

        let deliveredMarkers = await markers(in: bridge)
        XCTAssertEqual(deliveredMarkers, [])
        XCTAssertEqual(bridge.termination, .finished)
    }

    func testFailureTerminationOverridesConcurrentNormalClose() {
        let bridge = AudioTapBridge()

        XCTAssertTrue(bridge.close(.finished))
        XCTAssertFalse(bridge.close(.overflow))
        XCTAssertEqual(bridge.termination, .overflow)
        XCTAssertFalse(bridge.close(.finished))
        XCTAssertEqual(bridge.termination, .overflow)
    }

    func testTerminalActionsPreserveFailureReason() {
        XCTAssertEqual(AudioTapTermination.finished.action, .none)
        XCTAssertEqual(AudioTapTermination.limitReached.action, .limitReached)
        XCTAssertEqual(
            AudioTapTermination.overflow.action,
            .failed("Audio processing could not keep up. Please try a shorter turn.")
        )
        XCTAssertEqual(
            AudioTapTermination.copyFailed.action,
            .failed("Could not copy microphone audio.")
        )
        XCTAssertEqual(
            AudioTapTermination.consumerFailed("Analyzer failed.").action,
            .failed("Analyzer failed.")
        )
    }

    func testClosedCaptureCannotDeliverIntoReplacementCapture() async {
        let oldBridge = AudioTapBridge()
        let replacementBridge = AudioTapBridge()
        let oldHandler = oldBridge.makeTapHandler()
        let replacementHandler = replacementBridge.makeTapHandler()
        let replacementConsumer = markerConsumer(for: replacementBridge)

        oldBridge.close(.finished)
        await runAudioTapOffMain {
            oldHandler(makeAudioTapTestBuffer(marker: 1), makeAudioTapTestTime())
            replacementHandler(makeAudioTapTestBuffer(marker: 2), makeAudioTapTestTime())
            replacementBridge.close(.finished)
        }

        let replacementMarkers = await replacementConsumer.value
        let oldMarkers = await markers(in: oldBridge)
        XCTAssertEqual(replacementMarkers, [2])
        XCTAssertEqual(oldMarkers, [])
    }

    private func markerConsumer(for bridge: AudioTapBridge) -> Task<[Float], Never> {
        Task { await markers(in: bridge) }
    }
}

private func markers(in bridge: AudioTapBridge) async -> [Float] {
    var result: [Float] = []
    for await captured in bridge.stream {
        result.append(captured.buffer.floatChannelData?.pointee[0] ?? .nan)
    }
    return result
}

private func channelSamples(in bridge: AudioTapBridge) async -> [[[Float]]] {
    var result: [[[Float]]] = []
    for await captured in bridge.stream {
        let buffer = captured.buffer
        guard let channels = buffer.floatChannelData else {
            result.append([])
            continue
        }
        result.append((0..<Int(buffer.format.channelCount)).map { channel in
            Array(UnsafeBufferPointer(
                start: channels[channel],
                count: Int(buffer.frameLength)
            ))
        })
    }
    return result
}

private func runAudioTapOffMain(_ work: @escaping @Sendable () -> Void) async {
    await withCheckedContinuation { continuation in
        DispatchQueue(label: "LocalLingoTests.AudioTap").async {
            dispatchPrecondition(condition: .notOnQueue(.main))
            work()
            continuation.resume()
        }
    }
}

private func makeAudioTapTestTime(
    sampleTime: AVAudioFramePosition = 0
) -> AVAudioTime {
    AVAudioTime(sampleTime: sampleTime, atRate: 48_000)
}

private func makeAudioTapTestBuffer(marker: Float) -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 1,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1)!
    buffer.frameLength = 1
    buffer.floatChannelData?.pointee[0] = marker
    return buffer
}

private func makeStereoAudioTapTestBuffer() -> AVAudioPCMBuffer {
    let format = AVAudioFormat(
        commonFormat: .pcmFormatFloat32,
        sampleRate: 48_000,
        channels: 2,
        interleaved: false
    )!
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 3)!
    buffer.frameLength = 3
    let channels = buffer.floatChannelData!
    for frame in 0..<3 {
        channels[0][frame] = Float(frame + 1)
        channels[1][frame] = Float(frame + 4)
    }
    return buffer
}
