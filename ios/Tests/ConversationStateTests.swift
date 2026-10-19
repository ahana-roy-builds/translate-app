import XCTest
@testable import LocalLingo

final class ConversationStateTests: XCTestCase {
    func testHappyPath() throws {
        var machine = ConversationStateMachine()
        machine.reset()
        try machine.transition(to: .preparing(.traveler))
        try machine.transition(to: .listening(.traveler))
        try machine.transition(to: .finalizing(.traveler))
        try machine.transition(to: .reviewing(.traveler))
        try machine.transition(to: .translating(.traveler))
        try machine.transition(to: .speaking(outputFor: .traveler, recoverTo: .local))
        try machine.transition(to: .ready(.local))
        XCTAssertEqual(machine.state, .ready(.local))
    }

    func testCannotTranslateBeforeFinalizing() {
        var machine = ConversationStateMachine(); machine.reset()
        XCTAssertThrowsError(try machine.transition(to: .translating(.traveler)))
    }

    func testPreparingRejectsASecondMicrophoneStart() throws {
        var machine = ConversationStateMachine(); machine.reset()
        try machine.transition(to: .preparing(.traveler))
        XCTAssertFalse(machine.state.acceptsMicrophoneTap)
        XCTAssertThrowsError(try machine.transition(to: .preparing(.local)))
    }

    func testReplayCanSpeakOnlyFromReady() throws {
        var machine = ConversationStateMachine(); machine.reset(speaker: .local)
        try machine.transition(to: .speaking(outputFor: .traveler, recoverTo: .local))
        try machine.transition(to: .ready(.local))
        XCTAssertEqual(machine.state, .ready(.local))
    }

    func testBusyStatesRejectStartingTypedOrMicrophoneTurns() {
        let busy: [ConversationState] = [
            .preparing(.traveler), .listening(.traveler), .finalizing(.traveler),
            .reviewing(.traveler), .translating(.traveler), .confirming(.traveler)
        ]
        XCTAssertTrue(busy.allSatisfy { !$0.acceptsMicrophoneTap })
        XCTAssertTrue(ConversationState.ready(.traveler).acceptsMicrophoneTap)
        XCTAssertTrue(ConversationState.speaking(outputFor: .traveler, recoverTo: .local).acceptsMicrophoneTap)
        XCTAssertTrue(ConversationState.failed(message: "retry", recoverTo: .traveler).acceptsMicrophoneTap)
    }

    func testSpeakingCarriesExplicitRecoverySpeaker() {
        let autoSpeech = ConversationState.speaking(outputFor: .traveler, recoverTo: .local)
        let replay = ConversationState.speaking(outputFor: .traveler, recoverTo: .traveler)

        XCTAssertEqual(autoSpeech.speaker, .traveler)
        XCTAssertEqual(autoSpeech.recoverySpeaker, .local)
        XCTAssertEqual(replay.recoverySpeaker, .traveler)
    }

    func testResourcePressureOnlyCancelsBusyWork() {
        XCTAssertTrue(ResourcePressurePolicy.shouldCancel(pressure: .memoryWarning, stateIsBusy: true))
        XCTAssertFalse(ResourcePressurePolicy.shouldCancel(pressure: .memoryWarning, stateIsBusy: false))
        XCTAssertTrue(ResourcePressurePolicy.shouldCancel(pressure: .thermal(.serious), stateIsBusy: true))
        XCTAssertTrue(ResourcePressurePolicy.shouldCancel(pressure: .thermal(.critical), stateIsBusy: true))
        XCTAssertFalse(ResourcePressurePolicy.shouldCancel(pressure: .thermal(.fair), stateIsBusy: true))
    }
}
