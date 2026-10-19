import AVFoundation
import XCTest
@testable import LocalLingo

final class WAVEncoderTests: XCTestCase {
    func testCanonicalWAVHeaderAndMono16kPayload() throws {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800)!
        buffer.frameLength = 4_800
        for frame in 0..<Int(buffer.frameLength) { buffer.floatChannelData![0][frame] = 0.1 }
        let encoded = try WAVEncoder.encode(buffers: [buffer])
        XCTAssertEqual(String(decoding: encoded.prefix(4), as: UTF8.self), "RIFF")
        XCTAssertEqual(String(decoding: encoded[8..<12], as: UTF8.self), "WAVE")
        XCTAssertEqual(String(decoding: encoded[36..<40], as: UTF8.self), "data")
        XCTAssertGreaterThan(encoded.count, 44)
        XCTAssertLessThanOrEqual(abs((encoded.count - 44) - 3_200), 64)
    }

    func testEmptyAudioIsRejected() {
        XCTAssertThrowsError(try WAVEncoder.encode(buffers: []))
    }

    func testCanonicalPayloadCannotExceedThirtySeconds() {
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)!
        let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_488_000)!
        buffer.frameLength = 1_488_000
        XCTAssertThrowsError(try WAVEncoder.encode(buffers: [buffer]))
    }
}
