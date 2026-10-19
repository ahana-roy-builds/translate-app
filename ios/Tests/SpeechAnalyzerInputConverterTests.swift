import AVFoundation
import CoreMedia
import Speech
import XCTest
@testable import LocalLingo

final class SpeechAnalyzerInputConverterTests: XCTestCase {
    @MainActor
    func testSameFormatProducesAnalyzerInputWithoutResampling() throws {
        let format = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try makeBuffer(format: format, frames: 1_600)
        let converter = SpeechAnalyzerInputConverter(analyzerFormat: format)

        let inputs = try converter.convert(buffer, at: AVAudioTime(sampleTime: 8_000, atRate: 16_000))

        XCTAssertEqual(inputs.count, 1)
        XCTAssertEqual(inputs[0].buffer.frameLength, 1_600)
        XCTAssertTrue(inputs[0].buffer.format.isEqual(format))
        XCTAssertEqual(try XCTUnwrap(inputs[0].bufferStartTime).seconds, 0.5, accuracy: 0.000_001)
        XCTAssertEqual(
            try converter.recordDelivery(of: inputs[0]).seconds,
            0.6,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            try XCTUnwrap(converter.deliveredThrough).seconds,
            0.6,
            accuracy: 0.000_001
        )
        XCTAssertTrue(try converter.flush().isEmpty)
    }

    @MainActor
    func testResamplesMicrophoneBufferAndFlushesPendingAudio() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let analyzerFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let buffer = try makeBuffer(format: sourceFormat, frames: 4_800)
        let converter = SpeechAnalyzerInputConverter(analyzerFormat: analyzerFormat)

        let inputs = try converter.convert(
            buffer,
            at: AVAudioTime(sampleTime: 24_000, atRate: 48_000)
        ) + converter.flush()
        let totalFrames = inputs.reduce(0) { $0 + Int($1.buffer.frameLength) }
        let timestamps = inputs.compactMap(\.bufferStartTime)

        XCTAssertFalse(inputs.isEmpty)
        XCTAssertTrue(inputs.allSatisfy { $0.buffer.format.isEqual(analyzerFormat) })
        XCTAssertEqual(totalFrames, 1_600, accuracy: 64)
        XCTAssertEqual(timestamps.count, 1)
        XCTAssertEqual(try XCTUnwrap(timestamps.first).seconds, 0.5, accuracy: 0.000_001)
        for input in inputs {
            try converter.recordDelivery(of: input)
        }
        XCTAssertEqual(
            try XCTUnwrap(converter.deliveredThrough).seconds,
            0.6,
            accuracy: 0.004
        )
        XCTAssertTrue(try converter.flush().isEmpty)
    }

    @MainActor
    func testRejectsSourceFormatChangeWithinTurn() throws {
        let analyzerFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let firstFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let changedFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 44_100,
            channels: 1,
            interleaved: false
        ))
        let converter = SpeechAnalyzerInputConverter(analyzerFormat: analyzerFormat)

        _ = try converter.convert(makeBuffer(format: firstFormat, frames: 480), at: nil)

        XCTAssertThrowsError(try converter.convert(makeBuffer(format: changedFormat, frames: 441), at: nil))
    }

    @MainActor
    func testConsecutiveBuffersPreserveFrameCountAndSingleTimestamp() throws {
        let sourceFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 48_000,
            channels: 1,
            interleaved: false
        ))
        let analyzerFormat = try XCTUnwrap(AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: 16_000,
            channels: 1,
            interleaved: false
        ))
        let converter = SpeechAnalyzerInputConverter(analyzerFormat: analyzerFormat)
        var inputs: [AnalyzerInput] = []

        for index in 0..<30 {
            let time = index == 0 ? AVAudioTime(sampleTime: 24_000, atRate: 48_000) : nil
            inputs += try converter.convert(makeBuffer(format: sourceFormat, frames: 1_024), at: time)
        }
        inputs += try converter.flush()

        XCTAssertEqual(inputs.reduce(0) { $0 + Int($1.buffer.frameLength) }, 10_240, accuracy: 1)
        XCTAssertTrue(inputs.allSatisfy { $0.buffer.format.isEqual(analyzerFormat) })
        let timestamps = inputs.compactMap(\.bufferStartTime)
        XCTAssertEqual(timestamps.count, 1)
        XCTAssertEqual(try XCTUnwrap(timestamps.first).seconds, 0.5, accuracy: 0.000_001)
        for input in inputs {
            try converter.recordDelivery(of: input)
        }
        XCTAssertEqual(
            try XCTUnwrap(converter.deliveredThrough).seconds,
            1.14,
            accuracy: 0.000_1
        )
        XCTAssertThrowsError(try converter.convert(makeBuffer(format: sourceFormat, frames: 1_024), at: nil))
    }

    private func makeBuffer(format: AVAudioFormat, frames: AVAudioFrameCount) throws -> AVAudioPCMBuffer {
        let buffer = try XCTUnwrap(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
        buffer.frameLength = frames
        guard let samples = buffer.floatChannelData?.pointee else { return buffer }
        for index in 0..<Int(frames) {
            samples[index] = sin(Float(index) * 0.05)
        }
        return buffer
    }
}
