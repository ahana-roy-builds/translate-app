import AVFoundation
import XCTest
@testable import LocalLingo

final class SpeechSegmentAccumulatorTests: XCTestCase {
    func testEmptyVolatileRevisionRetractsOverlappingText() {
        let range = CMTimeRange(
            start: CMTime(seconds: 1, preferredTimescale: 1_000),
            duration: CMTime(seconds: 2, preferredTimescale: 1_000)
        )
        var segments: [RecognizedSegment] = []

        SpeechSegmentAccumulator.apply(
            range: range,
            text: "stale words",
            isFinal: false,
            confidence: 0.9,
            lowConfidenceFraction: 0,
            to: &segments
        )
        SpeechSegmentAccumulator.apply(
            range: range,
            text: "   ",
            isFinal: false,
            confidence: nil,
            lowConfidenceFraction: 1,
            to: &segments
        )

        XCTAssertTrue(segments.isEmpty)
    }

    func testEmptyRevisionOnlyRemovesItsOverlappingRange() {
        let first = CMTimeRange(
            start: CMTime(seconds: 0, preferredTimescale: 1_000),
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        let second = CMTimeRange(
            start: CMTime(seconds: 2, preferredTimescale: 1_000),
            duration: CMTime(seconds: 1, preferredTimescale: 1_000)
        )
        var segments: [RecognizedSegment] = []
        SpeechSegmentAccumulator.apply(range: first, text: "keep", isFinal: true, confidence: 1, lowConfidenceFraction: 0, to: &segments)
        SpeechSegmentAccumulator.apply(range: second, text: "remove", isFinal: false, confidence: 1, lowConfidenceFraction: 0, to: &segments)

        SpeechSegmentAccumulator.apply(range: second, text: "", isFinal: false, confidence: nil, lowConfidenceFraction: 1, to: &segments)

        XCTAssertEqual(segments.map(\.text), ["keep"])
    }

    func testZeroDurationRetractionInsidePriorRangeRemovesIt() {
        let prior = CMTimeRange(
            start: CMTime(seconds: 1, preferredTimescale: 1_000),
            duration: CMTime(seconds: 3, preferredTimescale: 1_000)
        )
        let pointRetraction = CMTimeRange(
            start: CMTime(seconds: 2, preferredTimescale: 1_000),
            duration: .zero
        )
        var segments: [RecognizedSegment] = []
        SpeechSegmentAccumulator.apply(range: prior, text: "stale", isFinal: false, confidence: 1, lowConfidenceFraction: 0, to: &segments)

        SpeechSegmentAccumulator.apply(range: pointRetraction, text: "", isFinal: false, confidence: nil, lowConfidenceFraction: 1, to: &segments)

        XCTAssertTrue(segments.isEmpty)
    }

    func testSegmentLimitFailsClosed() {
        var segments: [RecognizedSegment] = []
        for index in 0..<ConversationContentPolicy.maximumSpeechSegments {
            let range = CMTimeRange(
                start: CMTime(seconds: Double(index), preferredTimescale: 1_000),
                duration: CMTime(seconds: 0.5, preferredTimescale: 1_000)
            )
            XCTAssertTrue(SpeechSegmentAccumulator.apply(
                range: range,
                text: "word",
                isFinal: true,
                confidence: 1,
                lowConfidenceFraction: 0,
                to: &segments
            ))
        }
        let overflow = CMTimeRange(
            start: CMTime(seconds: Double(ConversationContentPolicy.maximumSpeechSegments + 1), preferredTimescale: 1_000),
            duration: CMTime(seconds: 0.5, preferredTimescale: 1_000)
        )
        XCTAssertFalse(SpeechSegmentAccumulator.apply(
            range: overflow,
            text: "overflow",
            isFinal: true,
            confidence: 1,
            lowConfidenceFraction: 0,
            to: &segments
        ))
        XCTAssertEqual(segments.count, ConversationContentPolicy.maximumSpeechSegments)
    }
}
