import XCTest
@testable import LocalLingo

final class OperationGenerationTests: XCTestCase {
    func testCompletedConversationTaskCannotClearSameOperationSuccessor() {
        var state = ConversationWorkGeneration()
        let finalization = state.begin()
        let approval = state.begin()

        XCTAssertFalse(state.clearIfCurrent(finalization))
        XCTAssertEqual(state.active, approval)
        XCTAssertTrue(state.clearIfCurrent(approval))
        XCTAssertNil(state.active)
    }

    func testInvalidatedConversationTaskCannotClearFutureWork() {
        var state = ConversationWorkGeneration()
        let canceled = state.begin()
        state.invalidate()
        let replacement = state.begin()

        XCTAssertFalse(state.clearIfCurrent(canceled))
        XCTAssertEqual(state.active, replacement)
    }

    func testStaleRecognitionCompletionCannotInvalidateReplacement() {
        var state = RecognitionOperationGeneration()
        let first = state.begin()
        let replacement = state.begin()

        XCTAssertFalse(state.isCurrent(first))
        XCTAssertTrue(state.isCurrent(replacement))
        XCTAssertFalse(state.invalidateIfCurrent(first))
        XCTAssertTrue(state.isCurrent(replacement))
        XCTAssertTrue(state.invalidateIfCurrent(replacement))
        XCTAssertNil(state.active)
    }

    func testStaleCommitCannotReleaseOrAffectSuccessorCommit() throws {
        var state = ConversationCommitGeneration()
        let firstOperation = UUID()
        let first = try XCTUnwrap(state.claim(for: firstOperation))
        state.invalidate()

        let successorOperation = UUID()
        let successor = try XCTUnwrap(state.claim(for: successorOperation))

        XCTAssertFalse(state.isCurrent(first, for: firstOperation))
        XCTAssertFalse(state.finishIfCurrent(first))
        XCTAssertEqual(state.active, successor)
        XCTAssertTrue(state.isCurrent(successor, for: successorOperation))
        XCTAssertTrue(state.finishIfCurrent(successor))
        XCTAssertNil(state.active)
    }

    func testCommitLeaseCannotBeClaimedTwiceForOneOperation() throws {
        var state = ConversationCommitGeneration()
        let operation = UUID()

        XCTAssertNotNil(state.claim(for: operation))
        XCTAssertNil(state.claim(for: operation))
    }
}
