import XCTest
@testable import MixedApp

final class MixedAppTests: XCTestCase {
    func testBanner() {
        XCTAssertEqual(LegacyBanner().title().isEmpty, false)
    }
}
