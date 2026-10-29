import XCTest
@testable import XcpurgeKit

/// Keeps the README's `xcpurge.json` reference in step with `Config`.
final class DocsTests: XCTestCase {
    func testReadmeDocumentsEveryConfigKey() throws {
        let readme = FixtureSupport.fixturesURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("README.md")
        let text = try String(contentsOf: readme, encoding: .utf8)
        let keys = Mirror(reflecting: Config()).children.compactMap(\.label)
        XCTAssertFalse(keys.isEmpty)
        for key in keys {
            XCTAssertTrue(text.contains("| `\(key)` |"), "README.md is missing xcpurge.json key \(key)")
        }
    }
}
