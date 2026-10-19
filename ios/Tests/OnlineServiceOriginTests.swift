import Foundation
import XCTest
@testable import LocalLingo

final class OnlineServiceOriginTests: XCTestCase {
    func testAcceptsOnlyConfiguredHTTPSOrigin() throws {
        let origin = try XCTUnwrap(OnlineServiceOrigin(baseURL: URL(string: "https://api.example.com")!))

        XCTAssertTrue(origin.matches(URL(string: "https://api.example.com/v2/session")!))
        XCTAssertTrue(origin.matches(URL(string: "https://api.example.com:443/v2/session")!))
        XCTAssertFalse(origin.matches(URL(string: "https://other.example.com/v2/session")!))
        XCTAssertFalse(origin.matches(URL(string: "http://api.example.com/v2/session")!))
        XCTAssertFalse(origin.matches(URL(string: "https://api.example.com:444/v2/session")!))
    }

    func testRejectsUnsafeConfiguredURLs() {
        XCTAssertNil(OnlineServiceOrigin(baseURL: URL(string: "http://api.example.com")!))
        XCTAssertNil(OnlineServiceOrigin(baseURL: URL(string: "ftp://api.example.com")!))
        XCTAssertNil(OnlineServiceOrigin(baseURL: URL(string: "https://user:secret@api.example.com")!))
        XCTAssertNil(OnlineServiceOrigin(baseURL: URL(string: "https://api.example.com?redirect=evil")!))
        XCTAssertNil(OnlineServiceOrigin(baseURL: URL(string: "https://api.example.com/v2")!))
    }

    func testDebugHTTPExceptionIsLimitedToLiteralLoopback() {
        #if DEBUG
        let localhost = OnlineServiceOrigin(baseURL: URL(string: "http://localhost:8080")!)
        let ipv4 = OnlineServiceOrigin(baseURL: URL(string: "http://127.0.0.1:8080")!)
        let ipv6 = OnlineServiceOrigin(baseURL: URL(string: "http://[::1]:8080")!)
        XCTAssertNotNil(localhost)
        XCTAssertNotNil(ipv4)
        XCTAssertNotNil(ipv6)
        XCTAssertTrue(ipv6?.matches(URL(string: "http://[::1]:8080/v2/session")!) == true)
        #else
        XCTAssertNil(OnlineServiceOrigin(baseURL: URL(string: "http://localhost:8080")!))
        #endif
        XCTAssertNil(OnlineServiceOrigin(baseURL: URL(string: "http://localhost.example.com:8080")!))
    }
}
