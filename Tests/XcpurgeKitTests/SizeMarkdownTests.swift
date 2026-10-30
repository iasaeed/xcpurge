import Foundation
import XCTest
@testable import XcpurgeKit

/// `xcpurge size --compare --format markdown|github`: the PR comment body, the comment threshold and the growth gate.
final class SizeMarkdownTests: XCTestCase {
    private static func snapshot(total: Int64, catalogs: Int64, source: Int64, paths: [(String, Int64)]?, app: AppSize? = nil,
                                 modules: [(String, Int64)] = [("P:App", 0)]) -> SizeSnapshot {
        let cats = SizeMeasurer.categoryNames.map { n in
            SizeEntry(name: n, files: 1, bytes: n == "Asset catalogs" ? catalogs : n == "Source" ? source : 0)
        }
        return SizeSnapshot(
            root: "/r", measuredAt: Date(timeIntervalSince1970: 0),
            tree: TreeSize(total: total, files: cats.count, categories: cats,
                           modules: modules.map { ModuleSize(id: $0.0, files: 1, bytes: $0.1) }),
            reclaimable: Reclaimable(high: 100, highMedium: 200, categories: ["assets"]),
            app: app, paths: paths?.map { SizeEntry(name: $0.0, files: 1, bytes: $0.1) })
    }

    private var before: SizeSnapshot {
        Self.snapshot(total: 204_800 + 10_240, catalogs: 204_800, source: 10_240,
                      paths: [("App/Assets.xcassets/hero.imageset", 200_000), ("App/Assets.xcassets/old.imageset", 4_800),
                              ("App/Main.swift", 10_240)])
    }

    private var grown: SizeSnapshot {
        Self.snapshot(total: 204_800 + 10_240 + 150_000, catalogs: 204_800 + 150_000, source: 10_240,
                 paths: [("App/Assets.xcassets/hero.imageset", 350_000), ("App/Assets.xcassets/old.imageset", 4_800),
                         ("App/Main.swift", 10_240), ("App/Tiny.swift", 100)],
                 modules: [("P:App", 150_000)])
    }

    func testMarkdownGolden() {
        let md = SizeMarkdown.render(before: before, after: grown, options: .init(version: "0.4.0"))
        XCTAssertEqual(md, """
        <!-- xcpurge-size -->
        ### xcpurge size: +146.5 KB (+69.8%)

        Source-tree bytes (files in the repository), not shipped bytes.

        |  | Base | PR | Change |
        |---|---:|---:|---:|
        | Whole tree | 210.0 KB | 356.5 KB | +146.5 KB (+69.8%) |
        | Asset catalogs | 200.0 KB | 346.5 KB | +146.5 KB (+73.2%) |
        | Loose images | 0 B | 0 B | no change |
        | Fonts | 0 B | 0 B | no change |
        | Strings | 0 B | 0 B | no change |
        | Interface Builder | 0 B | 0 B | no change |
        | Other resources | 0 B | 0 B | no change |
        | Source | 10.0 KB | 10.0 KB | no change |
        | Other files | 0 B | 0 B | no change |

        <details><summary>Modules (1)</summary>

        | Module | Base | PR | Change |
        |---|---:|---:|---:|
        | P:App | 0 B | 146.5 KB | +146.5 KB (new) |

        </details>

        **Top changes** (|change| ≥ 500 B; grown and shrunk)

        | Path | Base | PR | Change |
        |---|---:|---:|---:|
        | `App/Assets.xcassets/hero.imageset` | 195.3 KB | 341.8 KB | +146.5 KB (+75.0%) |

        Reclaimable (high+medium): 200 B → 200 B

        <sub>xcpurge 0.4.0 · this comment is edited in place on each push.</sub>

        """)
        XCTAssertTrue(md.hasPrefix(SizeMarkdown.marker + "\n"), "marker is the first line")
        XCTAssertFalse(md.contains("App/Tiny.swift"), "a 100 B change is below --min-path-delta")
    }

    func testTopAndRestAndShrunkPaths() {
        var after = grown
        after.paths = [SizeEntry(name: "App/Assets.xcassets/hero.imageset", files: 1, bytes: 350_000),
                       SizeEntry(name: "App/Main.swift", files: 1, bytes: 1_000),
                       SizeEntry(name: "New/Big.bin", files: 1, bytes: 9_000)]
        let md = SizeMarkdown.render(before: before, after: after, options: .init(top: 2, minPathDelta: 500))
        let top = md.components(separatedBy: "**Top changes**")[1]
        XCTAssertTrue(top.contains("| `App/Assets.xcassets/hero.imageset` |"), "largest change first")
        XCTAssertTrue(top.contains("| `App/Main.swift` | 10.0 KB | 1000 B | -9.0 KB (-90.2%) |"), "shrunk paths count too")
        XCTAssertTrue(md.contains("<details><summary>2 more changed paths</summary>"), md)
        XCTAssertTrue(md.contains("| `New/Big.bin` _(new)_ | 0 B | 8.8 KB | +8.8 KB (new) |"))
        XCTAssertTrue(md.contains("| `App/Assets.xcassets/old.imageset` _(removed)_ | 4.7 KB | 0 B | -4.7 KB (-100.0%) |"))
        XCTAssertEqual(md.components(separatedBy: "<details>").count, md.components(separatedBy: "</details>").count)
    }

    func testOldBaseWithoutPaths() {
        var old = before
        old.paths = nil
        let md = SizeMarkdown.render(before: old, after: grown)
        XCTAssertTrue(md.contains("_Path breakdown unavailable (base snapshot from xcpurge < 0.4)._"), md)
        XCTAssertFalse(md.contains("Top changes"))
        let same = SizeMarkdown.render(before: before, after: before)
        XCTAssertTrue(same.contains("### xcpurge size: no change"))
        XCTAssertTrue(same.contains("**Top changes**: no path changed by |change| ≥ 500 B."), same)
    }

    func testAppAndIPALabelsAreHonest() {
        let app = { (total: Int64, zip: Int64?) in
            AppSize(path: "/a", total: total, sections: [AppSection(name: "Executable", bytes: total)], compressedBytes: zip)
        }
        var b = before, a = grown
        b.app = app(100 * 1_048_576, nil)
        a.app = app(101 * 1_048_576, nil)
        let install = SizeMarkdown.render(before: b, after: a)
        XCTAssertTrue(install.contains("### xcpurge size: +1.0 MB (+1.0%)"), "headline is the app, not the tree")
        XCTAssertTrue(install.contains("**Install size** (uncompressed .app, unthinned): 100.0 MB → 101.0 MB"))
        XCTAssertFalse(install.contains("Download size"), "no .ipa, no download claim")
        XCTAssertTrue(install.contains("<details><summary>App bundle sections</summary>"))
        XCTAssertFalse(install.hasPrefix("<!-- xcpurge-size -->\n### xcpurge size: +146.5"))

        b.app = app(100 * 1_048_576, 40 * 1_048_576)
        a.app = app(101 * 1_048_576, 41 * 1_048_576)
        let ipa = SizeMarkdown.render(before: b, after: a)
        XCTAssertTrue(ipa.contains("**Download size** (≈ .ipa bytes, compressed, unthinned; not the App Store download): 40.0 MB → 41.0 MB, +1.0 MB (+2.5%)"), ipa)
        XCTAssertFalse(ipa.contains("Source-tree bytes (files in the repository), not shipped bytes."), "the caveat is for tree-only comparisons")
        XCTAssertTrue(SizeMarkdown.render(before: before, after: grown).contains("Source-tree bytes (files in the repository), not shipped bytes."))
    }

    func testTruncationKeepsMarkerAndClosesDetails() {
        var a = grown, b = before
        let many = (0..<4_000).map { ("App/Assets.xcassets/set_\($0).imageset", Int64(1_000 + $0)) }
        b.paths = many.map { SizeEntry(name: $0.0, files: 1, bytes: 10) }
        a.paths = many.map { SizeEntry(name: $0.0, files: 1, bytes: $0.1) }
        let full = SizeMarkdown.render(before: b, after: a, options: .init(maxLength: Int.max))
        XCTAssertGreaterThan(full.count, 65_536, "enough to overflow a GitHub comment")
        let md = SizeMarkdown.render(before: b, after: a)
        XCTAssertLessThanOrEqual(md.count, SizeMarkdown.maxLength)
        XCTAssertTrue(md.hasPrefix(SizeMarkdown.marker + "\n"))
        XCTAssertTrue(md.hasSuffix("_Truncated to fit the GitHub comment limit; run `xcpurge size --compare` locally for the full table._\n"))
        XCTAssertEqual(md.components(separatedBy: "<details>").count, md.components(separatedBy: "</details>").count, "no open <details>")
    }

    func testTableCellsEscapePipes() {
        var a = grown
        a.paths = [SizeEntry(name: "Odd|name/x.png", files: 1, bytes: 9_000)]
        a.tree.modules = [ModuleSize(id: "P|Q:App", files: 1, bytes: 1)]
        let md = SizeMarkdown.render(before: before, after: a)
        XCTAssertTrue(md.contains("`Odd\\|name/x.png`"))
        XCTAssertTrue(md.contains("| P\\|Q:App |"))
    }

    // MARK: - Threshold and gate

    func testCommentThreshold() {
        XCTAssertTrue(SizeGate.belowThreshold(before, grown, threshold: 200 * 1024), "146.5 KB < 200 KB")
        XCTAssertFalse(SizeGate.belowThreshold(before, grown, threshold: 100 * 1024))
        var shrunk = grown
        shrunk.tree.total = before.tree.total - 150_000
        XCTAssertFalse(SizeGate.belowThreshold(before, shrunk, threshold: 100 * 1024), "|delta| counts shrinking too")
        XCTAssertEqual(ByteSize.parse("100KB"), 102_400)
        XCTAssertEqual(ByteSize.parse("1.5 MB"), 1_572_864)
        XCTAssertEqual(ByteSize.parse("500"), 500)
        XCTAssertEqual(ByteSize.parse("500b"), 500)
        XCTAssertEqual(ByteSize.parse("2GB"), 2 << 30)
        XCTAssertNil(ByteSize.parse("-1KB"))
        XCTAssertNil(ByteSize.parse("2%"))
        XCTAssertNil(ByteSize.parse("abc"))
    }

    func testGateAbsoluteAndPercent() throws {
        XCTAssertEqual(SizeLimit("100KB"), .bytes(102_400))
        XCTAssertEqual(SizeLimit("2%"), .percent(2))
        XCTAssertEqual(SizeLimit("0.5 %"), .percent(0.5))
        XCTAssertNil(SizeLimit("2%%"))
        XCTAssertNil(SizeLimit("-2%"))
        XCTAssertEqual(SizeLimit("100KB")?.description, "100.0 KB")
        XCTAssertEqual(SizeLimit("2%")?.description, "2%")

        // grown is +150,000 B on a 215,040 B base (+69.8%).
        XCTAssertNil(SizeGate.check(before, grown, limit: .bytes(150_000)), "equal to the limit is not a breach")
        let breach = try XCTUnwrap(SizeGate.check(before, grown, limit: .bytes(100 * 1024)))
        XCTAssertEqual(breach.line, "size gate: grew +146.5 KB (limit 100.0 KB)")
        XCTAssertEqual(breach.metric.kind, .tree)
        XCTAssertNotNil(SizeGate.check(before, grown, limit: .percent(50)))
        XCTAssertNil(SizeGate.check(before, grown, limit: .percent(70)))
        XCTAssertEqual(SizeGate.check(before, grown, limit: .percent(2))?.line, "size gate: grew +146.5 KB (limit 2%)")
        XCTAssertNil(SizeGate.check(grown, before, limit: .bytes(0)), "shrinking never breaches")

        // With an app on both sides the gate measures the app, not the tree.
        var b = before, a = grown
        b.app = AppSize(path: "/a", total: 1_000, sections: [])
        a.app = AppSize(path: "/a", total: 1_000, sections: [])
        XCTAssertNil(SizeGate.check(b, a, limit: .bytes(0)), "tree grew, app did not")
        XCTAssertEqual(SizeGate.metric(b, a).kind, .app)
    }

    // MARK: - CLI

    /// `CLISupport.run` with extra environment variables (`$GITHUB_STEP_SUMMARY`).
    private static func run(_ args: [String], environment: [String: String]) throws -> (status: Int32, stdout: String, stderr: String) {
        guard FileManager.default.isExecutableFile(atPath: CLISupport.binary.path) else {
            throw XCTSkip("\(CLISupport.binary.path) not built; run `swift build` first")
        }
        let process = Process()
        process.executableURL = CLISupport.binary
        process.arguments = args
        process.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err
        try process.run()
        let errData = out.fileHandleForReading.readDataToEndOfFile()
        let stderrData = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: errData, as: UTF8.self), String(decoding: stderrData, as: UTF8.self))
    }

    /// markdown and github need --compare; under the threshold nothing is printed and no --output is written;
    /// a missing base with --allow-missing-compare is a note and exit 0; the gate exits 1 after the comment is written.
    func testCLIThresholdGateAndMissingBase() throws {
        let fixture = FixtureSupport.fixtureURL("ModularWorkspace").path
        let dir = try FixtureSupport.tempTree([:])
        let saved = dir.appendingPathComponent("base.json")
        let noCompare = try CLISupport.run(["size", fixture, "--no-swift", "--format", "markdown"])
        XCTAssertEqual(noCompare.status, 2, "markdown needs --compare")
        XCTAssertTrue(noCompare.stderr.contains("--compare"), noCompare.stderr)
        XCTAssertEqual(try CLISupport.run(["size", fixture, "--no-swift", "--fail-if-grows", "1KB"]).status, 2)
        XCTAssertEqual(try CLISupport.run(["size", fixture, "--no-swift", "--compare", saved.path, "--fail-if-grows", "lots"]).status, 2)

        let missing = try CLISupport.run(["size", fixture, "--no-swift", "--compare", saved.path, "--format", "markdown",
                                          "--allow-missing-compare", "--output", dir.appendingPathComponent("size.md").path])
        XCTAssertEqual(missing.status, 0, missing.stderr)
        XCTAssertTrue(missing.stderr.contains("no base snapshot"), missing.stderr)
        XCTAssertEqual(missing.stdout, "")
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("size.md").path), "no file under --allow-missing-compare")
        XCTAssertNotEqual(try CLISupport.run(["size", fixture, "--no-swift", "--compare", saved.path]).status, 0, "without the flag a missing base is an error")

        let save = try CLISupport.run(["size", fixture, "--no-swift", "--save", saved.path, "--quiet"])
        XCTAssertEqual(save.status, 0, save.stderr)
        var base = try SizeSnapshot.load(from: saved)
        XCTAssertNotNil(base.paths)

        // Unchanged tree: markdown prints (no threshold), github appends to the step summary.
        let summary = dir.appendingPathComponent("summary.md")
        let md = try CLISupport.run(["size", fixture, "--no-swift", "--compare", saved.path, "--format", "markdown"])
        XCTAssertEqual(md.status, 0, md.stderr)
        XCTAssertTrue(md.stdout.hasPrefix("<!-- xcpurge-size -->\n### xcpurge size: no change\n"), md.stdout)
        let gh = try Self.run(["size", fixture, "--no-swift", "--compare", saved.path, "--format", "github",
                                                    "--comment-threshold", "1KB"], environment: ["GITHUB_STEP_SUMMARY": summary.path])
        XCTAssertEqual(gh.status, 0, gh.stderr)
        XCTAssertEqual(gh.stdout, "", "no change is under the threshold")
        XCTAssertFalse(FileManager.default.fileExists(atPath: summary.path), "nothing appended when suppressed")

        // Shrink the saved base so the live tree looks 10 KB bigger: the comment is written, then the gate fails.
        base.tree.total -= 10_240
        if let i = base.tree.categories.firstIndex(where: { $0.name == "Source" }) { base.tree.categories[i].bytes -= 10_240 }
        try base.write(to: saved)
        let out = dir.appendingPathComponent("comment.md")
        let gate = try Self.run(["size", fixture, "--no-swift", "--compare", saved.path, "--format", "github",
                                                      "--comment-threshold", "1KB", "--fail-if-grows", "2%", "--output", out.path],
                                                     environment: ["GITHUB_STEP_SUMMARY": summary.path])
        XCTAssertEqual(gate.status, 1, gate.stderr)
        XCTAssertTrue(gate.stderr.contains("size gate: grew +10.0 KB (limit 2%)"), gate.stderr)
        let comment = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(comment.hasPrefix("<!-- xcpurge-size -->\n### xcpurge size: +10.0 KB"), comment)
        XCTAssertTrue(try String(contentsOf: summary, encoding: .utf8).hasPrefix("<!-- xcpurge-size -->"), "appended to $GITHUB_STEP_SUMMARY")
        XCTAssertEqual(try CLISupport.run(["size", fixture, "--no-swift", "--compare", saved.path, "--fail-if-grows", "20KB"]).status, 0,
                       "text output with a generous limit passes")
    }
}
