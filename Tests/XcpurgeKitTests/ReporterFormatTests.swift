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
        ])
        XCTAssertEqual(XcodeReporter().render(r), XcodeReporter().render(r), "deterministic")
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
            "::notice::xcpurge: 4 findings (1 high, 2 medium, 1 low)",
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
}
