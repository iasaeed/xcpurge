import XCTest
@testable import SyncedApp

final class SyncedAppTests: XCTestCase {
    func testHelperName() {
        XCTAssertEqual(TestHelpers.fixtureName, "sample")
    }
}
