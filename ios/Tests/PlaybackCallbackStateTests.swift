import Foundation
import XCTest
@testable import LocalLingo

final class PlaybackCallbackStateTests: XCTestCase {
    @MainActor
    func testSpeechSynthesizerUsesSystemManagedAudioSession() {
        XCTAssertFalse(AppleSpeechSynthesisEngine().usesApplicationAudioSession)
    }

    @MainActor
    func testTargetVoicePreparationDoesNotRequireTheOtherPairVoice() throws {
        let synthesis = TargetVoiceSynthesis(availableLocaleIDs: ["hi-IN"])
        let playback = PlaybackService(synthesis: synthesis)

        XCTAssertNoThrow(try playback.prepare(locale: Locale(identifier: "hi-IN")))
        XCTAssertThrowsError(try playback.prepare(locale: Locale(identifier: "en-US")))
        XCTAssertThrowsError(try playback.prepare(
            pair: LanguagePair(traveler: .englishUS, local: .hindiIndia)
        ))
    }

    func testStaleSpeechCallbackCannotMatchReplacementUtterance() {
        let state = PlaybackCallbackState()
        let firstObject = NSObject()
        let secondObject = NSObject()
        let first = ObjectIdentifier(firstObject)
        let second = ObjectIdentifier(secondObject)
        let firstGeneration = UUID()
        let secondGeneration = UUID()

        state.activateSpeech(objectID: first, generation: firstGeneration)
        state.activateSpeech(objectID: second, generation: secondGeneration)

        XCTAssertNil(state.speechGeneration(matching: first))
        XCTAssertEqual(state.speechGeneration(matching: second), secondGeneration)
        state.clearSpeech(generation: firstGeneration)
        XCTAssertEqual(state.speechGeneration(matching: second), secondGeneration)
    }

    func testStalePlayerCallbackCannotMatchReplacementPlayer() {
        let state = PlaybackCallbackState()
        let firstObject = NSObject()
        let secondObject = NSObject()
        let first = ObjectIdentifier(firstObject)
        let second = ObjectIdentifier(secondObject)
        let firstGeneration = UUID()
        let secondGeneration = UUID()

        state.activatePlayer(objectID: first, generation: firstGeneration)
        state.activatePlayer(objectID: second, generation: secondGeneration)

        XCTAssertNil(state.playerGeneration(matching: first))
        XCTAssertEqual(state.playerGeneration(matching: second), secondGeneration)
        state.clearPlayer(generation: firstGeneration)
        XCTAssertEqual(state.playerGeneration(matching: second), secondGeneration)
    }

    func testStaleCancellationCannotClearReplacementGenerationAtReusedIdentity() {
        let state = PlaybackCallbackState()
        let object = NSObject()
        let objectID = ObjectIdentifier(object)
        let firstGeneration = UUID()
        let replacementGeneration = UUID()

        state.activateSpeech(objectID: objectID, generation: firstGeneration)
        state.activateSpeech(objectID: objectID, generation: replacementGeneration)
        state.clearSpeech(generation: firstGeneration)
        XCTAssertEqual(state.speechGeneration(matching: objectID), replacementGeneration)

        state.activatePlayer(objectID: objectID, generation: firstGeneration)
        state.activatePlayer(objectID: objectID, generation: replacementGeneration)
        state.clearPlayer(generation: firstGeneration)
        XCTAssertEqual(state.playerGeneration(matching: objectID), replacementGeneration)
    }
}

@MainActor
private final class TargetVoiceSynthesis: SpeechSynthesisEngine {
    private let availableLocaleIDs: Set<String>

    init(availableLocaleIDs: Set<String>) {
        self.availableLocaleIDs = availableLocaleIDs
    }

    func isVoiceAvailable(locale: Locale) -> Bool {
        availableLocaleIDs.contains(locale.identifier)
    }

    func speak(_ text: String, locale: Locale, rate: Float) async throws {}
    func play(data: Data, format: String?) async throws {}
    func cancel() {}
}
