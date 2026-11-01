import XCTest
@testable import XcpurgeKit

/// The headline counts actionable findings only; dynamic lookups and duplicate sets are named beside it.
final class HeadlineCountTests: XCTestCase {
    private func make(_ rows: [(FindingKind, Confidence, String?)]) async throws -> ScanResult {
        let ctx = try await FixtureSupport.context("SyncedApp", config: { var c = Config(); c.noSwift = true; return c }())
        let findings = rows.enumerated().map { i, row in
            Finding(kind: row.0, category: row.0 == .duplicate ? .duplicates : row.0 == .dynamicLookup ? .assets : .files,
                    path: "P/f\(i)", line: row.0 == .dynamicLookup ? i + 1 : nil, name: "n\(i)", module: "App",
                    confidence: row.1, groupID: row.2)
        }
        return ScanResult(context: ctx, findings: findings.sorted(by: Finding.reportOrder))
    }

    private let rows: [(FindingKind, Confidence, String?)] = [
        (.unusedAsset, .high, nil), (.orphanFile, .medium, nil), (.unusedString, .low, nil),
        (.dynamicLookup, .low, nil), (.dynamicLookup, .low, nil), (.dynamicLookup, .low, nil),
        (.duplicate, .medium, "g1"), (.duplicate, .medium, "g1"), (.duplicate, .medium, "g1"), (.duplicate, .high, "g2"),
    ]

    func testTally() async throws {
        let r = try await make(rows)
        let t = FindingTally(r.findings)
        XCTAssertEqual([t.high, t.medium, t.low], [1, 1, 1])
        XCTAssertEqual(t.actionable, 3)
        XCTAssertEqual(t.dynamicLookups, 3)
        XCTAssertEqual(t.duplicateSets, 2, "four members, two sets")
        XCTAssertEqual(t.informationalText, "3 dynamic lookups, 2 duplicate sets")
        XCTAssertEqual(t.headline, "3 findings (1 high, 1 medium, 1 low)")
        XCTAssertEqual(FindingTally(high: 0, medium: 0, low: 0, dynamicLookups: 1, duplicateSets: 1).informationalText,
                       "1 dynamic lookup, 1 duplicate set")
        XCTAssertNil(FindingTally([]).informationalText)
    }

    func testTextTotalExcludesInformationalRecords() async throws {
        let text = TextReporter().render(try await make(rows))
        XCTAssertTrue(text.contains("Total: 3 findings (1 high, 1 medium, 1 low) + 3 dynamic lookups, 2 duplicate sets"), text)
        let only = TextReporter().render(try await make([(.dynamicLookup, .low, nil)]))
        XCTAssertTrue(only.contains("No findings + 1 dynamic lookup."), only)
        let empty = TextReporter().render(try await make([]))
        XCTAssertTrue(empty.contains("No findings."), empty)
    }

    func testScanSummaryLine() async throws {
        let result = try await make(rows)
        let line = ScanSummary(result, seconds: 1.0).line
        XCTAssertTrue(line.hasSuffix(" — 3 findings (1 high, 1 medium, 1 low) + 3 dynamic lookups, 2 duplicate sets"), line)
        XCTAssertEqual(ScanSummary(files: 1, modules: 1, seconds: 1, high: 0, medium: 0, low: 0, dynamicLookups: 4).line,
                       "Scanned 1 file in 1 module in 1.0s — No findings + 4 dynamic lookups")
        XCTAssertEqual(ScanSummary(files: 12_480, modules: 9, seconds: 2.3, high: 8, medium: 30, low: 0).line,
                       "Scanned 12,480 files in 9 modules in 2.3s — 38 findings (8 high, 30 medium, 0 low)")
    }

    func testJSONSummaryAddsActionableAndInformationalAndKeepsCount() async throws {
        let json = JSONReporter().render(try await make(rows))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let summary = try XCTUnwrap(object["summary"] as? [String: Any])
        XCTAssertEqual(summary["actionable"] as? Int, 3)
        XCTAssertEqual(summary["count"] as? Int, 10, "count keeps its v2 meaning: every finding")
        let info = try XCTUnwrap(summary["informational"] as? [String: Int])
        XCTAssertEqual(info, ["dynamicLookups": 3, "duplicateSets": 2])
        XCTAssertEqual((summary["byKind"] as? [String: Int])?["dynamicLookup"], 3)
    }

    func testHTMLCountPlaceholderIsActionable() async throws {
        let html = HTMLReporter(date: Date(timeIntervalSince1970: 0)).render(try await make(rows))
        XCTAssertTrue(html.contains("Loading 3 findings…"), "placeholder counts actionable findings")
        XCTAssertTrue(html.contains("id=\"s-info\""), "the header names informational records beside the count")
    }
}
