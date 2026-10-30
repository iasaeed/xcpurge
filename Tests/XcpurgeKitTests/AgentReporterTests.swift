import Foundation
import XCTest
@testable import XcpurgeKit

/// `--format agent`: the MixedApp golden, the per-kind cap and hint, the legend, determinism, the baseline line,
/// and the reason-code table over every reason the fixtures produce.
final class AgentReporterTests: XCTestCase {
    private func mixedApp() async throws -> ScanResult {
        try await ScanEngine(root: FixtureSupport.fixtureURL("MixedApp"), config: Config()).run()
    }

    func testMixedAppGolden() async throws {
        let result = try await mixedApp()
        let root = result.context.root.path
        let expected = """
        # xcpurge agent report v1 · xcpurge \(XcpurgeVersion.current) · root: \(root)
        ## Legend
        confidence: high = no reference from any module that can see it; remove, then build. medium/low = NOT proven unused: run `xcpurge explain <root> <id>` and check runtime/dynamic use first. This output is a lead, not a verdict.
        commands: remove `xcpurge remove <root> <path>` · undo `xcpurge restore <root>` · explain `xcpurge explain <root> <id>` · ignore: add the line to .xcpurgeignore with a `# reason` comment above it
        after removing: build, rescan (removal exposes more), keep removals in their own commit; work on a clean branch.
        reasons: \(ReasonCodes.codes.joined(separator: ", "))
        ## Summary
        8 findings (3 high, 1 medium, 4 low) · unused-asset 2 · dynamic-lookup 1 · unused-string 1 · orphan-file 2 · unused-resource 2
        ## unused-asset (2)
        ### MixedApp
        - id=unused-asset-ab15ed7993 high Legacy/LegacyAssets.xcassets/legacy_unused.imageset name=legacy_unused reasons=no-ref
          remove: xcpurge remove \(root) Legacy/LegacyAssets.xcassets/legacy_unused.imageset   ignore: asset:legacy_unused
        - id=unused-asset-bdd3de6eeb high Modern/ModernAssets.xcassets/modern_unused.imageset name=modern_unused reasons=no-ref
          remove: xcpurge remove \(root) Modern/ModernAssets.xcassets/modern_unused.imageset   ignore: asset:modern_unused
        ## dynamic-lookup (1)
        ### MixedApp
        - id=dynamic-lookup-d5820de9f2 low Modern/MixedAppApp.swift:12 reasons=dyn-pattern
        ## unused-string (1)
        ### MixedApp
        - id=unused-string-ee045d97e0 high Legacy/en.lproj/Localizable.strings:3 name=farewell_unused reasons=no-ref
          ignore: string:farewell_unused
        ## orphan-file (2)
        ### MixedApp
        - id=orphan-file-787d8461b8 medium Modern/Excluded.swift reasons=excluded
          remove: xcpurge remove \(root) Modern/Excluded.swift   ignore: Modern/Excluded.swift
        ### unknown
        - id=orphan-file-449b7ad154 low Stray/Stray.swift reasons=unattributed
          remove: xcpurge remove \(root) Stray/Stray.swift   ignore: Stray/Stray.swift
        ## unused-resource (2)
        ### MixedApp
        - id=unused-resource-1ae80990f6 low Content/a.json reasons=no-ref,folder-ref
          remove: xcpurge remove \(root) Content/a.json   ignore: Content/a.json
        - id=unused-resource-d760612b46 low Content/b.json reasons=no-ref,folder-ref
          remove: xcpurge remove \(root) Content/b.json   ignore: Content/b.json

        """
        let text = AgentReporter(options: ReporterOptions(agentLimit: 30)).render(result)
        XCTAssertEqual(text, expected)
        XCTAssertEqual(text, AgentReporter(options: ReporterOptions(agentLimit: 0)).render(result), "0 means all")
    }

    func testCapAndNarrowingHint() async throws {
        let result = try await mixedApp()
        let text = AgentReporter(options: ReporterOptions(agentLimit: 1)).render(result)
        let lines = text.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.filter { $0.hasPrefix("… 1 more ") }.count, 3, text)
        XCTAssertTrue(lines.contains("… 1 more unused-asset not shown: narrow with --targets <module>, --min-confidence high, or --agent-limit 0"))
        // Within a kind the highest confidence survives the cap: the medium orphan, not the low one.
        XCTAssertTrue(text.contains("- id=orphan-file-787d8461b8 medium"))
        XCTAssertFalse(text.contains("orphan-file-449b7ad154"))
        XCTAssertEqual(lines.filter { $0.hasPrefix("- id=") }.count, 5, "one row per kind")
    }

    func testLegendOnceNoColourRelativePaths() async throws {
        let result = try await mixedApp()
        let text = AgentReporter().render(result)
        XCTAssertEqual(text.components(separatedBy: "## Legend").count - 1, 1)
        XCTAssertEqual(text.components(separatedBy: "\nreasons: ").count - 1, 1)
        XCTAssertFalse(text.contains("\u{1B}["))
        XCTAssertFalse(text.contains("authoritative"))
        let root = result.context.root.path
        for line in text.split(separator: "\n") where line.hasPrefix("- id=") {
            XCTAssertFalse(line.contains(root), "row paths are root-relative: \(line)")
        }
        for line in text.split(separator: "\n") where line.contains("remove: ") {
            XCTAssertTrue(line.contains("xcpurge remove \(AgentReporter.shellArgument(root)) "), "\(line)")
        }
    }

    func testDeterministicAndRegistered() async throws {
        let synthetic = SyntheticResult.make(count: 400)
        let a = AgentReporter(options: ReporterOptions(agentLimit: 0)).render(synthetic)
        let b = AgentReporter(options: ReporterOptions(agentLimit: 0)).render(SyntheticResult.make(count: 400))
        XCTAssertEqual(a, b)
        XCTAssertTrue(OutputFormat.agent.reporter(ReporterOptions()) is AgentReporter)
        XCTAssertEqual((OutputFormat.agent.reporter(ReporterOptions(agentLimit: 7)) as? AgentReporter)?.options.agentLimit, 7)
    }

    func testRemoveLineOnlyForDeletableKindsAndGhosts() {
        let synthetic = SyntheticResult.make(count: 400)
        let text = AgentReporter(options: ReporterOptions(agentLimit: 0)).render(synthetic)
        let lines = text.split(separator: "\n").map(String.init)
        var kind = ""
        var removeByKind: [String: Bool] = [:], ignoreByKind: [String: Bool] = [:]
        for line in lines {
            if line.hasPrefix("## "), !line.hasPrefix("## Summary"), !line.hasPrefix("## Legend") {
                kind = String(line.dropFirst(3).split(separator: " ")[0])
            } else if line.hasPrefix("  ") {
                if line.contains("remove: ") { removeByKind[kind] = true }
                if line.contains("ignore: ") { ignoreByKind[kind] = true }
            }
        }
        for k in FindingKind.allCases {
            let expectsRemove = Trash.deletableKinds.contains(k) || k == .ghostReference
            XCTAssertEqual(removeByKind[k.flagName] ?? false, expectsRemove, k.flagName)
            XCTAssertEqual(ignoreByKind[k.flagName] ?? false, !k.isInformational, k.flagName)
        }
        XCTAssertTrue(text.contains("ignore: asset:"))
        XCTAssertTrue(text.contains("ignore: string:"))
        XCTAssertTrue(text.contains(" group=dup-"))
    }

    func testBaselineLineAndEmptyReport() async throws {
        let scan = try await mixedApp()
        let baseline = BaselineReport(file: ".xcpurge-baseline.json", createdAt: "2026-10-01T00:00:00Z", ageDays: 12,
                                      toolVersion: "0.4.0", baselinedCount: 140, newCount: 8,
                                      fixed: [BaselineEntry(key: "k1", kind: .unusedAsset, category: .assets, module: "App", path: "a"),
                                              BaselineEntry(key: "k2", kind: .deadSource, category: .files, module: "App", path: "b")])
        let with = ScanResult(context: scan.context, findings: scan.findings, baseline: baseline)
        XCTAssertTrue(AgentReporter().render(with).contains(
            "8 findings (3 high, 1 medium, 4 low) · unused-asset 2 · dynamic-lookup 1 · unused-string 1 · orphan-file 2 · unused-resource 2 · baseline: 140 hidden, 2 fixed\n"))
        XCTAssertFalse(AgentReporter().render(scan).contains("baseline:"))
        let empty = AgentReporter().render(ScanResult(context: scan.context, findings: []))
        XCTAssertTrue(empty.hasSuffix("## Summary\n0 findings (0 high, 0 medium, 0 low)\n"), empty)
    }

    func testShellQuoting() {
        XCTAssertEqual(AgentReporter.shellArgument("App/Assets.xcassets/old.imageset"), "App/Assets.xcassets/old.imageset")
        XCTAssertEqual(AgentReporter.shellArgument("/Users/dev/My App"), "'/Users/dev/My App'")
        XCTAssertEqual(AgentReporter.shellArgument("it's.png"), "'it'\\''s.png'")
        XCTAssertEqual(AgentReporter.shellArgument("-weird.png"), "./-weird.png")
        XCTAssertEqual(AgentReporter.shellArgument(""), "''")
    }

    func testIgnoreEntryRules() {
        func f(_ kind: FindingKind, _ category: XcpurgeKit.Category, name: String?) -> Finding {
            Finding(kind: kind, category: category, path: "P/x", name: name, module: "App", confidence: .high)
        }
        XCTAssertEqual(AgentReporter.ignoreEntry(f(.unusedAsset, .assets, name: "old")), "asset:old")
        XCTAssertEqual(AgentReporter.ignoreEntry(f(.unusedFont, .assets, name: "Brand.ttf")), "P/x")
        XCTAssertEqual(AgentReporter.ignoreEntry(f(.unusedString, .strings, name: "k")), "string:k")
        XCTAssertEqual(AgentReporter.ignoreEntry(f(.staleString, .strings, name: "k")), "string:k")
        XCTAssertEqual(AgentReporter.ignoreEntry(f(.deadSource, .files, name: "Helper")), "P/x")
        XCTAssertNil(AgentReporter.ignoreEntry(f(.dynamicLookup, .assets, name: "icon_*")))
        XCTAssertNil(AgentReporter.ignoreEntry(f(.staleIgnore, .ignores, name: "Vendor/**")))
    }

    func testCLIAgentFormat() throws {
        let root = FixtureSupport.fixtureURL("MixedApp").path
        let r = try CLISupport.run(["scan", root, "--format", "agent", "--agent-limit", "1", "--quiet"])
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertTrue(r.stdout.hasPrefix("# xcpurge agent report v1 · xcpurge "))
        XCTAssertTrue(r.stdout.contains("… 1 more unused-asset not shown"))
        XCTAssertEqual(r.stderr, "", "stdout is pure data; nothing else under --quiet")
    }

    // MARK: - Reason codes

    func testReasonCodeTableIsWellFormed() {
        XCTAssertEqual(ReasonCodes.codes.count, Set(ReasonCodes.codes).count, "codes are unique")
        XCTAssertEqual(ReasonCodes.codes.last, "other")
        XCTAssertEqual(ReasonCodes.classify("something nobody wrote"), "other")
        XCTAssertEqual(ReasonCodes.classify("no reference by name, generated symbol or accessor visible to App"), "no-ref")
        XCTAssertEqual(ReasonCodes.classify("may be built dynamically at App/A.swift:3 (\"icon_…\")"), "dyn-pattern")
        XCTAssertEqual(ReasonCodes.classify("referenced as \"Logo\" (case differs) at App/A.swift:3"), "case-only-match")
        XCTAssertEqual(ReasonCodes.classify("'Legacy' appears as a string literal (NSClassFromString?)"), "string-literal")
        XCTAssertEqual(ReasonCodes.classify("source Vendor/x.swift skipped (unreadable); capped at medium"), "skipped-source")
        XCTAssertEqual(ReasonCodes.classify("not declared in UIAppFonts and never referenced by file, PostScript, family or full name"), "no-ref")
        XCTAssertEqual(ReasonCodes.classify("declared in UIAppFonts of App but never used by file, PostScript, family or full name"), "font-declared")
        XCTAssertEqual(ReasonCodes.classify("matches no file on disk"), "stale-ignore")
        for code in ReasonCodes.codes {
            XCTAssertFalse(ReasonCodes.entry(for: code).meaning.isEmpty)
            XCTAssertFalse(ReasonCodes.entry(for: code).toMakeSafe.isEmpty)
        }
        let noReasons = Finding(kind: .orphanFile, category: .files, path: "x", module: "App", confidence: .high)
        XCTAssertEqual(ReasonCodes.codes(for: noReasons), ["other"])
    }

    /// Every reason string any fixture produces maps to a real code.
    func testEveryFixtureReasonHasACode() async throws {
        let dirs = try FileManager.default.contentsOfDirectory(atPath: FixtureSupport.fixturesURL.path)
            .filter { !$0.hasPrefix(".") }.sorted()
        var unclassified = Set<String>(), seen = 0
        for name in dirs {
            let result = try await ScanEngine(root: FixtureSupport.fixtureURL(name), config: Config()).run()
            for f in result.findings {
                for reason in f.reasons {
                    seen += 1
                    if ReasonCodes.classify(reason) == "other" { unclassified.insert(reason) }
                }
            }
        }
        XCTAssertGreaterThan(seen, 50)
        XCTAssertTrue(unclassified.isEmpty, "reasons without a code:\n" + unclassified.sorted().joined(separator: "\n"))
    }
}
