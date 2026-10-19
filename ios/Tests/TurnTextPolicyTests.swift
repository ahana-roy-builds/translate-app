import XCTest
@testable import LocalLingo

final class TurnTextPolicyTests: XCTestCase {
    func testValidationUsesUTF8BytesForEveryRoute() throws {
        let accepted = String(repeating: "é", count: TurnTextPolicy.maximumUTF8Bytes / 2)
        XCTAssertEqual(try TurnTextPolicy.validated(accepted), accepted)

        let rejected = accepted + "é"
        XCTAssertThrowsError(try TurnTextPolicy.validated(rejected))
    }

    func testClampPreservesWholeExtendedGraphemeClusters() throws {
        let oversized = String(repeating: "🌍", count: TurnTextPolicy.maximumUTF8Bytes)
        let clamped = TurnTextPolicy.clamped(oversized)

        XCTAssertLessThanOrEqual(clamped.utf8.count, TurnTextPolicy.maximumUTF8Bytes)
        XCTAssertTrue(clamped.allSatisfy { $0 == "🌍" })
        XCTAssertEqual(try TurnTextPolicy.validated(clamped), clamped)
    }

    func testFinalOutputBoundaryRejectsInsteadOfTruncating() throws {
        let accepted = String(repeating: "a", count: TurnTextPolicy.maximumFinalUTF8Bytes)
        XCTAssertEqual(try TurnTextPolicy.validatedFinal(accepted, field: "translation"), accepted)

        let rejected = accepted + "a"
        XCTAssertThrowsError(try TurnTextPolicy.validatedFinal(rejected, field: "translation"))
    }

    func testPartialClampUsesFinalOutputBoundaryAndWholeCharacters() {
        let oversized = String(repeating: "🌍", count: TurnTextPolicy.maximumFinalUTF8Bytes)
        let clamped = TurnTextPolicy.clampedPartial(oversized)

        XCTAssertLessThanOrEqual(clamped.utf8.count, TurnTextPolicy.maximumFinalUTF8Bytes)
        XCTAssertTrue(clamped.allSatisfy { $0 == "🌍" })
    }
}
