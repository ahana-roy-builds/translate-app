import Speech
import XCTest
@testable import LocalLingo

final class SpeechAssetStatusMappingTests: XCTestCase {
    func testMapsEveryKnownAppleAssetStatus() {
        XCTAssertEqual(AppleSpeechRecognitionEngine.readiness(for: .unsupported), .unavailable)
        XCTAssertEqual(AppleSpeechRecognitionEngine.readiness(for: .supported), .downloadRequired)
        XCTAssertEqual(AppleSpeechRecognitionEngine.readiness(for: .downloading), .downloading)
        XCTAssertEqual(AppleSpeechRecognitionEngine.readiness(for: .installed), .ready)
    }

    func testDownloadingTripPackIsNotReady() {
        var readiness = TripReadiness(pair: LanguagePair(), generation: 1)
        readiness.listenTraveler = .downloading
        readiness.listenLocal = .ready
        readiness.translateForward = .ready
        readiness.translateReverse = .ready
        readiness.speakTraveler = .ready
        readiness.speakLocal = .ready

        XCTAssertFalse(readiness.isReady)
        XCTAssertFalse(readiness.isReady(requiringVoices: false))
    }
}
