import XCTest
@testable import XcpurgeKit

final class CoreReporterTests: XCTestCase {
    private func result() async throws -> ScanResult {
        let ctx = try await FixtureSupport.context("SyncedApp", config: { var c = Config(); c.noSwift = true; return c }())
        let findings = [
            Finding(kind: .unusedAsset, category: .assets, path: "SyncedApp/Assets.xcassets", name: "old_logo",
                    module: "SyncedApp", confidence: .high, reasons: ["no reference"], sizeBytes: 2048),
            Finding(kind: .orphanFile, category: .files, path: "SyncedApp/Excluded/Legacy.swift", module: "unknown",
                    confidence: .medium, reasons: ["excluded from every target"], sizeBytes: 100),
            Finding(kind: .unusedAsset, category: .assets, path: "SyncedApp/Assets.xcassets", line: 4, name: "beta_badge",
                    module: "SyncedApp", confidence: .low, reasons: ["may be built dynamically at A.swift:3"]),
        ]
        return ScanResult(context: ctx, findings: findings.sorted(by: Finding.reportOrder))
    }

    func testTextReportGroupsAndTotals() async throws {
        let r = try await result()
        let text = TextReporter().render(r)
        XCTAssertTrue(text.contains("Assets (2, 2.0 KB)"))
        XCTAssertTrue(text.contains("  unused-asset"))
        XCTAssertTrue(text.contains("    SyncedApp"))
        XCTAssertTrue(text.contains("[high]   SyncedApp/Assets.xcassets  old_logo  (2.0 KB)"))
        XCTAssertTrue(text.contains("[low]    SyncedApp/Assets.xcassets:4  beta_badge"))
        XCTAssertTrue(text.contains("may be built dynamically"), "reasons shown for non-high findings")
        XCTAssertFalse(text.contains("no reference"), "reasons hidden for high findings unless verbose")
        XCTAssertTrue(text.contains("Files (1, 100 B)"))
        XCTAssertTrue(text.contains("Total: 3 findings (1 high, 1 medium, 1 low), 2.1 KB reclaimable"))
        XCTAssertFalse(text.contains("\u{1B}["), "no ANSI codes without colors")
        XCTAssertTrue(TextReporter(colors: true).render(r).contains("\u{1B}[31m"))
        XCTAssertTrue(TextReporter(verbose: true).render(r).contains("no reference"))
    }

    func testJSONReportSchemaAndStability() async throws {
        let r = try await result()
        let json = JSONReporter().render(r)
        XCTAssertEqual(json, JSONReporter().render(r))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(object["schemaVersion"] as? Int, 2)
        XCTAssertEqual((object["tool"] as? [String: String])?["name"], "xcpurge")
        let summary = try XCTUnwrap(object["summary"] as? [String: Any])
        XCTAssertEqual(summary["count"] as? Int, 3)
        XCTAssertEqual(summary["bytes"] as? Int, 2148)
        XCTAssertEqual((summary["byKind"] as? [String: Int])?["unusedAsset"], 2)
        let names = (object["findings"] as? [[String: Any]])?.map { $0["name"] as? String ?? $0["path"] as! String }
        XCTAssertEqual(names, ["beta_badge", "old_logo", "SyncedApp/Excluded/Legacy.swift"])
        let modules = try XCTUnwrap(object["modules"] as? [[String: Any]])
        XCTAssertEqual(modules.count, 2)
        XCTAssertNotNil(modules.first?["dependsOn"])
        XCTAssertTrue(json.contains("\"category\" : \"assets\""), "sorted keys, pretty printed")
    }

    /// `--baseline` adds a header (warnings always, the fixed list under `--verbose`); `--git` adds `· age, author`.
    func testTextBaselineHeaderAndHistorySuffix() async throws {
        let r = try await result()
        let commit = FindingHistory.Commit(sha: "0123456789abcdef", date: "2023-04-05T10:00:00Z", authorName: "J. Appleseed",
                                           authorEmail: "j@example.com", subject: "Add logo")
        var findings = r.findings
        findings[0].history = FindingHistory(status: .ok, lastCommit: commit, ageDays: 3 * 365 + 20, bucket: .leftover)
        findings[1].history = FindingHistory(status: .shallow, note: "n/a (shallow clone; use fetch-depth: 0)")
        findings[2].history = FindingHistory(status: .ok, lastCommit: commit, ageDays: 12, bucket: .recentlyAdded)
        var withBoth = ScanResult(context: r.context, findings: findings)
        withBoth.baseline = BaselineReport(file: ".xcpurge-baseline.json", createdAt: "2026-10-01T00:00:00Z", ageDays: 12,
                                           toolVersion: "0.4.0", baselinedCount: 140, newCount: 3,
                                           fixed: [BaselineEntry(key: "unusedAsset|App|old_icon", kind: .unusedAsset, category: .assets,
                                                                 module: "App", path: "App/Assets.xcassets/old_icon.imageset", name: "old_icon", count: 2)],
                                           warnings: ["baseline is 12 days old"])
        let text = TextReporter().render(withBoth)
        XCTAssertTrue(text.hasPrefix("Baseline: 140 baselined, 3 new, 1 fixed (12 days old)\n  warning: baseline is 12 days old\n\nAssets"), text)
        XCTAssertFalse(text.contains("Fixed baseline entries"), "fixed list only under --verbose")
        XCTAssertTrue(text.contains("  · 3y, J. Appleseed\n"), text)
        XCTAssertTrue(text.contains("  · n/a (shallow)\n"), text)
        XCTAssertTrue(text.contains("  · 12d, J. Appleseed\n"), text)
        XCTAssertFalse(text.contains("j@example.com"), "emails never shown")
        let verbose = TextReporter(verbose: true).render(withBoth)
        XCTAssertTrue(verbose.contains("  Fixed baseline entries (regenerate with xcpurge baseline):\n    unused-asset App old_icon ×2\n"), verbose)
        XCTAssertEqual(TextReporter.age(days: 45), "1mo")
        XCTAssertEqual(TextReporter.age(days: 800), "2y")
        XCTAssertFalse(TextReporter().render(r).contains("Baseline:"), "no baseline, no header")
        XCTAssertFalse(TextReporter().render(r).contains(" · "), "no history, no suffix")
    }

    func testEmptyReport() async throws {
        let ctx = try await FixtureSupport.context("SyncedApp", config: { var c = Config(); c.noSwift = true; return c }())
        XCTAssertEqual(TextReporter().render(ScanResult(context: ctx, findings: [])), "No findings.\n")
        XCTAssertTrue(OutputFormat.allCases.allSatisfy { !"\($0.reporter())".isEmpty })
    }
}
