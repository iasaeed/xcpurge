import XCTest
@testable import XcpurgeKit

/// Xcode (`path:line: warning:`) and GitHub Actions (`::warning …`) output on a synthetic scan result.
final class ReporterFormatTests: XCTestCase {
    private func result() async throws -> ScanResult {
        let ctx = try await FixtureSupport.context("SyncedApp", config: { var c = Config(); c.noSwift = true; return c }())
        let findings = [
            Finding(kind: .unusedAsset, category: .assets, path: "SyncedApp/Assets.xcassets/AppIcon.appiconset",
                    name: "AppIcon", module: "SyncedApp", confidence: .medium, reasons: ["no APPICON setting names it"]),
            Finding(kind: .orphanFile, category: .files, path: "SyncedApp/Excluded/Legacy.swift", module: "unknown",
                    confidence: .medium, reasons: ["excluded from every target"]),
            Finding(kind: .deadSource, category: .files, path: "Odd, name: 100%.swift", line: 7, module: "SyncedApp",
                    confidence: .high, reasons: ["line one\nline two"]),
            Finding(kind: .dynamicLookup, category: .assets, path: "SyncedApp/SyncedAppApp.swift", line: 3,
                    name: "icon_*", module: "SyncedApp", confidence: .low),
        ]
        return ScanResult(context: ctx, findings: findings.sorted(by: Finding.reportOrder))
    }

    func testXcodeFormat() async throws {
        let r = try await result()
        let root = r.context.root.path
        let lines = XcodeReporter().render(r).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            "\(root)/SyncedApp/SyncedAppApp.swift:3: note: [xcpurge] dynamic-lookup: 'icon_*' in SyncedApp (low)",
            "\(root)/SyncedApp/Assets.xcassets/AppIcon.appiconset/Contents.json:1: warning: [xcpurge] unused-asset: "
                + "'AppIcon' in SyncedApp: no APPICON setting names it (medium)",
            "\(root)/Odd, name: 100%.swift:7: warning: [xcpurge] dead-source: 'Odd, name: 100%.swift' in SyncedApp: "
                + "line one line two (high)",
            "\(root)/SyncedApp/Excluded/Legacy.swift:1: warning: [xcpurge] orphan-file: 'Legacy.swift': "
                + "excluded from every target (medium)",
            "note: [xcpurge] 3 findings (1 high, 2 medium, 0 low) + 1 dynamic lookup",
        ])
        XCTAssertEqual(XcodeReporter().render(r), XcodeReporter().render(r), "deterministic")
    }

    /// `--max-warnings N` keeps the first N lines (report order), says how many are hidden, and still summarises.
    func testXcodeMaxWarningsCapAndSummary() async throws {
        let r = try await result()
        let root = r.context.root.path
        let capped = XcodeReporter(maxWarnings: 2).render(r).split(separator: "\n").map(String.init)
        XCTAssertEqual(capped, [
            "\(root)/SyncedApp/SyncedAppApp.swift:3: note: [xcpurge] dynamic-lookup: 'icon_*' in SyncedApp (low)",
            "\(root)/SyncedApp/Assets.xcassets/AppIcon.appiconset/Contents.json:1: warning: [xcpurge] unused-asset: "
                + "'AppIcon' in SyncedApp: no APPICON setting names it (medium)",
            "warning: [xcpurge] 2 more findings not shown (run xcpurge scan for all)",
            "note: [xcpurge] 3 findings (1 high, 2 medium, 0 low) + 1 dynamic lookup",
        ])
        let one = XcodeReporter(maxWarnings: 3).render(r)
        XCTAssertTrue(one.contains("warning: [xcpurge] 1 more finding not shown"), one)
        let uncapped = XcodeReporter(maxWarnings: 10).render(r)
        XCTAssertEqual(uncapped, XcodeReporter().render(r), "a cap above the count changes nothing")
        XCTAssertFalse(uncapped.contains("more finding"))
        let zero = XcodeReporter(maxWarnings: 0).render(r)
        XCTAssertEqual(zero, "warning: [xcpurge] 4 more findings not shown (run xcpurge scan for all)\nnote: [xcpurge] 3 findings (1 high, 2 medium, 0 low) + 1 dynamic lookup\n")
        XCTAssertEqual(XcodeReporter(maxWarnings: 0).render(ScanResult(context: r.context, findings: [])), "", "no findings, no summary")
    }

    func testGitHubFormat() async throws {
        let r = try await result()
        let lines = GitHubReporter(base: r.context.root.path).render(r).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, [
            "::notice file=SyncedApp/SyncedAppApp.swift,line=3,title=xcpurge dynamic-lookup::'icon_*' in SyncedApp (low)",
            "::warning file=SyncedApp/Assets.xcassets/AppIcon.appiconset/Contents.json,line=1,title=xcpurge unused-asset::"
                + "'AppIcon' in SyncedApp: no APPICON setting names it (medium)",
            "::warning file=Odd%2C name%3A 100%25.swift,line=7,title=xcpurge dead-source::"
                + "'Odd, name: 100%25.swift' in SyncedApp: line one%0Aline two (high)",
            "::warning file=SyncedApp/Excluded/Legacy.swift,line=1,title=xcpurge orphan-file::"
                + "'Legacy.swift': excluded from every target (medium)",
            "::notice::xcpurge: 3 findings (1 high, 2 medium, 0 low) + 1 dynamic lookup",
        ])
        // Scanning a subfolder of the checkout: paths stay relative to the checkout, not the scan root.
        let parent = RelPath.parent(r.context.root.path)
        let first = GitHubReporter(base: parent).render(r).split(separator: "\n").first.map(String.init)
        XCTAssertEqual(first, "::notice file=\(RelPath.lastComponent(r.context.root.path))/SyncedApp/SyncedAppApp.swift,line=3,"
                       + "title=xcpurge dynamic-lookup::'icon_*' in SyncedApp (low)")
    }

    func testEmptyResults() async throws {
        let ctx = try await FixtureSupport.context("SyncedApp", config: { var c = Config(); c.noSwift = true; return c }())
        let empty = ScanResult(context: ctx, findings: [])
        XCTAssertEqual(XcodeReporter().render(empty), "")
        XCTAssertEqual(GitHubReporter().render(empty), "::notice::xcpurge: 0 findings (0 high, 0 medium, 0 low)\n")
    }

    func testFormatsAreRegistered() {
        XCTAssertTrue(OutputFormat.xcode.reporter() is XcodeReporter)
        XCTAssertTrue(OutputFormat.github.reporter() is GitHubReporter)
    }

    /// The baseline summary rides on the final notice; fixed entries get one notice of their own.
    func testGitHubBaselineSummary() async throws {
        let r = try await result()
        var withBaseline = ScanResult(context: r.context, findings: r.findings)
        withBaseline.baseline = BaselineReport(file: ".xcpurge-baseline.json", createdAt: "2026-10-01T00:00:00Z", ageDays: 12,
                                               toolVersion: "0.4.0", baselinedCount: 140, newCount: 4,
                                               fixed: [BaselineEntry(key: "unusedAsset|App|old_icon", kind: .unusedAsset, category: .assets,
                                                                     module: "App", path: "App/Assets.xcassets/old_icon.imageset", name: "old_icon"),
                                                       BaselineEntry(key: "deadSource|App|App/Gone.swift", kind: .deadSource, category: .files,
                                                                     module: "App", path: "App/Gone.swift")])
        let lines = GitHubReporter(base: r.context.root.path).render(withBaseline).split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 6)
        XCTAssertEqual(lines[4], "::notice title=xcpurge baseline::2 fixed baseline entries (regenerate with xcpurge baseline): "
                       + "dead-source App App/Gone.swift; unused-asset App old_icon")
        XCTAssertEqual(lines[5], "::notice::xcpurge: 3 findings (1 high, 2 medium, 0 low) + 1 dynamic lookup; baseline: 140 baselined, 4 new, 2 fixed")
        withBaseline.baseline?.fixed = []
        let none = GitHubReporter(base: r.context.root.path).render(withBaseline)
        XCTAssertFalse(none.contains("title=xcpurge baseline"), "no fixed entries, no extra notice")
        XCTAssertTrue(none.hasSuffix("; baseline: 140 baselined, 4 new, 0 fixed\n"))
    }
}
