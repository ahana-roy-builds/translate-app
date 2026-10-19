import XCTest
@testable import LocalLingo

final class ChallengeFreshnessTests: XCTestCase {
    func testPoolCoversCaptureBackendWindowAndMargin() {
        XCTAssertEqual(
            ChallengeFreshness.pooled,
            ChallengeFreshness.maximumCapture
                + ChallengeFreshness.requestWindow
                + ChallengeFreshness.schedulingMargin
        )
        XCTAssertGreaterThan(ChallengeFreshness.minimumBackendTTL, ChallengeFreshness.pooled)
        XCTAssertGreaterThan(ChallengeFreshness.assertionCreation, ChallengeFreshness.requestWindow)
    }
}
