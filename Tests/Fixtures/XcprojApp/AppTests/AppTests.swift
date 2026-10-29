import XCTest

final class AppTests: XCTestCase {
    func testGreeting() {
        XCTAssertEqual(Helpers.greeting, "hi")
    }
}
