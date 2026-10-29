import Foundation
import XCTest
@testable import XcpurgeKit

/// The compiled-in HTML template must match `Resources/report.html` byte for byte (`make template` regenerates it).
final class ReportTemplateTests: XCTestCase {
    func testEmbeddedTemplateMatchesResource() throws {
        let resource = FixtureSupport.fixturesURL.deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/XcpurgeKit/Resources/report.html")
        let source = try String(contentsOf: resource, encoding: .utf8)
        XCTAssertEqual(ReportTemplate.html, source, "ReportTemplate.swift is stale; run `make template`")
        XCTAssertTrue(HTMLReporter.template.contains("{{DATA}}"))
    }
}
