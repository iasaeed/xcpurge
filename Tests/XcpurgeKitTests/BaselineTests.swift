import XCTest
@testable import XcpurgeKit

/// `xcpurge baseline` / `--baseline`: file format, multiset matching, scoping of fixed entries, warnings and exit codes.
final class BaselineTests: XCTestCase {
    private func asset(_ name: String, module: String = "App", catalog: String = "App/Assets.xcassets",
                       confidence: Confidence = .high) -> Finding {
        Finding(kind: .unusedAsset, category: .assets, path: "\(catalog)/\(name).imageset", name: name, module: module,
                confidence: confidence)
    }

    private func dead(_ path: String, module: String = "App") -> Finding {
        Finding(kind: .deadSource, category: .files, path: path, module: module, confidence: .high)
    }

    private func string(_ key: String, locale: String = "en", module: String = "App") -> Finding {
        Finding(kind: .unusedString, category: .strings, path: "App/\(locale).lproj/Localizable.strings", line: 3, name: key,
                module: module, confidence: .high)
    }

    private func file(_ findings: [Finding], categories: Set<XcpurgeKit.Category> = XcpurgeKit.Category.scannable,
                      config: Config = Config(), createdAt: Date = Date()) -> BaselineFile {
        BaselineFile.make(findings: findings, categories: categories, config: config,
                          root: URL(fileURLWithPath: "/tmp/root"), now: createdAt)
    }

    private func apply(_ findings: [Finding], _ file: BaselineFile, categories: Set<XcpurgeKit.Category> = XcpurgeKit.Category.scannable,
                       config: Config = Config(), now: Date = Date(), strict: Bool = false)
        -> (kept: [Finding], report: BaselineReport) {
        BaselineMatcher.apply(findings: findings, file: file, filePath: "b.json", categories: categories, config: config,
                              strict: strict, now: now)
    }

    // MARK: - File format

    func testRenderIsDeterministicWithOneEntryPerLine() throws {
        let findings = [dead("App/Z.swift"), asset("b"), asset("a"), string("k", locale: "fr"), string("k")]
        let date = Date(timeIntervalSince1970: 1_800_000_000)
        let a = file(findings, createdAt: date).render(), b = file(findings.reversed(), createdAt: date).render()
        XCTAssertEqual(a, b, "entry order must not depend on input order")
        let lines = a.split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("    {") }.count, 4, "one line per entry\n\(a)")
        XCTAssertTrue(a.hasPrefix("{\n  \"version\": 1,\n  \"tool\": {\"name\": \"xcpurge\", \"version\": \"\(XcpurgeVersion.current)\"},\n"))
        XCTAssertTrue(a.contains("\"createdAt\": \"2027-01-15\""), "day precision keeps same-day runs identical")
        XCTAssertTrue(a.contains("\"categories\": [\"assets\",\"duplicates\",\"files\",\"strings\"]"))
        XCTAssertTrue(a.contains("\"minConfidence\": \"low\""))
        XCTAssertTrue(a.hasSuffix("  ]\n}\n"))
        // Entries are sorted by key and the locale copies collapse into one entry with count 2.
        let keys = lines.filter { $0.hasPrefix("    {") }.map { line -> String in
            let start = line.range(of: "\"key\":\"")!.upperBound
            return String(line[start...].prefix { $0 != "\"" })
        }
        XCTAssertEqual(keys, keys.sorted())
        XCTAssertTrue(a.contains("\"count\":2,\"key\":\"unusedString|App|Localizable|k\""))
        // Entry keys inside a line are sorted too.
        XCTAssertTrue(a.contains("{\"category\":\"assets\",\"count\":1,\"key\":\"unusedAsset|App|a\",\"kind\":\"unusedAsset\",\"module\":\"App\",\"name\":\"a\",\"path\":\"App/Assets.xcassets/a.imageset\"}"))
        XCTAssertEqual(file([]).render().split(separator: "\n").last, "}")
        XCTAssertTrue(file([]).render().contains("\"entries\": []"))
    }

    func testRoundTrip() throws {
        var config = Config()
        config.failOn = ["any"]
        config.minConfidence = .medium
        let original = file([asset("a"), dead("App/Z.swift")], categories: [.assets, .files], config: config)
        let parsed = try BaselineFile.parse(Data(original.render().utf8))
        XCTAssertEqual(parsed, original)
        XCTAssertEqual(parsed.categories, [.assets, .files])
        XCTAssertEqual(parsed.failOn, ["any"])
        XCTAssertEqual(parsed.minConfidence, .medium)
        XCTAssertEqual(parsed.entries.count, 2)
        XCTAssertEqual(try BaselineFile.parse(Data(file([]).render().utf8)).entries, [])
    }

    func testParseErrors() {
        func error(_ text: String) -> BaselineError? {
            do { _ = try BaselineFile.parse(Data(text.utf8), path: "b.json"); return nil } catch { return error as? BaselineError }
        }
        XCTAssertEqual(error(""), .empty("b.json"))
        XCTAssertEqual(error("  \n"), .empty("b.json"))
        XCTAssertEqual(error("{\"version\": 2, \"entries\": []}"), .unsupportedVersion("b.json", 2))
        XCTAssertEqual(error("{\"version\": 7}"), .unsupportedVersion("b.json", 7), "version is checked before the shape")
        XCTAssertEqual(error("{\"entries\": []}"), .unsupportedVersion("b.json", nil))
        guard case .unparseable("b.json", _)? = error("not json") else { return XCTFail("expected unparseable") }
        guard case .unparseable("b.json", _)? = error("{\"version\": 1, \"entries\": [{\"key\": 1}]}") else {
            return XCTFail("expected unparseable")
        }
        XCTAssertEqual(try? BaselineFile.load(URL(fileURLWithPath: "/definitely/not/here.json")), nil)
        do { _ = try BaselineFile.load(URL(fileURLWithPath: "/definitely/not/here.json")) } catch {
            XCTAssertEqual(error as? BaselineError, .missing("/definitely/not/here.json"))
        }
    }

    func testConfigHashIsRootRelativeAndCoversScopeSettings() throws {
        var a = Config(), b = Config()
        a.project = "/tmp/root/App.xcodeproj"
        b.project = "/other/root/App.xcodeproj"
        XCTAssertEqual(BaselineFile.configHash(a, root: URL(fileURLWithPath: "/tmp/root")),
                       BaselineFile.configHash(b, root: URL(fileURLWithPath: "/other/root")), "same project, different checkout")
        var c = a
        c.exclude = ["Vendor/**"]
        XCTAssertNotEqual(BaselineFile.configHash(a, root: URL(fileURLWithPath: "/tmp/root")),
                          BaselineFile.configHash(c, root: URL(fileURLWithPath: "/tmp/root")))
        var d = a
        d.failOn = ["any"]
        d.minConfidence = .high
        d.verbose = true
        XCTAssertEqual(BaselineFile.configHash(a, root: URL(fileURLWithPath: "/tmp/root")),
                       BaselineFile.configHash(d, root: URL(fileURLWithPath: "/tmp/root")), "reporting flags are not scope")
        XCTAssertTrue(BaselineFile.configHash(a, root: URL(fileURLWithPath: "/tmp/root")).hasPrefix("fnv64:"))
        XCTAssertEqual(BaselineFile.configHash(a, root: URL(fileURLWithPath: "/tmp/root")).count, "fnv64:".count + 16)
    }

    // MARK: - Matching

    /// SwiftLint #6871: two findings sharing a key need two counts; one count hides one of them.
    func testMultisetMatching() {
        let two = [string("k"), string("k", locale: "fr")]
        let baseline = file(two)
        XCTAssertEqual(baseline.entries.map(\.count), [2])
        let all = apply(two, baseline)
        XCTAssertEqual(all.kept, [])
        XCTAssertEqual(all.report.baselinedCount, 2)
        XCTAssertEqual(all.report.fixed, [])

        let oneFixed = apply([string("k")], baseline)
        XCTAssertEqual(oneFixed.kept, [])
        XCTAssertEqual(oneFixed.report.baselinedCount, 1)
        XCTAssertEqual(oneFixed.report.fixed.map(\.count), [1])

        let oneNew = apply(two + [string("k", locale: "de")], baseline)
        XCTAssertEqual(oneNew.kept.count, 1)
        XCTAssertEqual(oneNew.report.newCount, 1)
        XCTAssertEqual(oneNew.report.baselinedCount, 2)
    }

    /// SwiftLint #6871, the known limitation of count-only matching: a fixed finding and a new one with the same
    /// identity (here the `en` copy of a key removed and a `de` copy added) cancel out and nothing is reported.
    func testFixedAndNewWithTheSameKeyCancelOut() {
        let baseline = file([string("k", locale: "en")])
        let out = apply([string("k", locale: "de")], baseline)
        XCTAssertEqual(out.kept, [])
        XCTAssertEqual(out.report.fixed, [])
        XCTAssertEqual(out.report.baselinedCount, 1)
        XCTAssertEqual(out.report.newCount, 0)
    }

    func testAssetRenamedIntoAnotherCatalogStaysBaselined() {
        let baseline = file([asset("old_icon", catalog: "App/Assets.xcassets")])
        let moved = asset("old_icon", catalog: "App/Resources/Media.xcassets")
        let out = apply([moved], baseline)
        XCTAssertEqual(out.kept, [], "asset identity is kind|module|name, not the path")
        XCTAssertEqual(out.report.fixed, [])
    }

    func testFileRenameIsNewPlusFixed() {
        let baseline = file([dead("App/Old.swift")])
        let out = apply([dead("App/New.swift")], baseline)
        XCTAssertEqual(out.kept.map(\.path), ["App/New.swift"])
        XCTAssertEqual(out.report.fixed.map(\.path), ["App/Old.swift"])
        XCTAssertEqual(out.report.fixed.first?.kind, .deadSource)
    }

    func testConfidenceIsNotPartOfTheKey() {
        let baseline = file([asset("a", confidence: .high)])
        XCTAssertEqual(apply([asset("a", confidence: .medium)], baseline).kept, [])
    }

    func testFixedIsScopedToCategoriesTargetsAndExcludes() {
        let baseline = file([asset("a"), string("k"), dead("Kit/Dead.swift", module: "Kit"), dead("Vendor/V.swift")])
        // `xcpurge assets --baseline`: strings and files are out of scope, never fixed.
        let assetsOnly = apply([], baseline, categories: [.assets, .duplicates])
        XCTAssertEqual(assetsOnly.report.fixed.map(\.key), ["unusedAsset|App|a"])
        // `--targets App`: the Kit file cannot have been scanned.
        var targeted = Config()
        targeted.targets = ["App"]
        let byTarget = apply([], baseline, config: targeted)
        XCTAssertEqual(Set(byTarget.report.fixed.map(\.kind)), [.unusedAsset, .unusedString, .deadSource])
        XCTAssertFalse(byTarget.report.fixed.contains { $0.module == "Kit" })
        // `--exclude Vendor/**`: excluded paths are not fixed either.
        var excluded = Config()
        excluded.exclude = ["Vendor/**"]
        XCTAssertFalse(apply([], baseline, config: excluded).report.fixed.contains { $0.path.hasPrefix("Vendor/") })
        XCTAssertEqual(apply([], baseline).report.fixed.count, 4, "a full scan reports every leftover")
    }

    func testStaleIgnoreEntriesAreFixedOnlyOnFullScansWithStaleIgnoresOn() {
        let stale = Finding(kind: .staleIgnore, category: .ignores, path: Ignore.fileName, line: 2, name: "Vendor/**",
                            module: "unknown", confidence: .medium)
        let baseline = file([stale])
        XCTAssertEqual(apply([], baseline).report.fixed.count, 1)
        XCTAssertEqual(apply([], baseline, categories: [.assets]).report.fixed.count, 0)
        var off = Config()
        off.staleIgnores = false
        XCTAssertEqual(apply([], baseline, config: off).report.fixed.count, 0)
        XCTAssertEqual(apply([stale], baseline).kept, [])
    }

    // MARK: - Warnings

    func testWarnings() {
        let created = Date(timeIntervalSince1970: 1_700_000_000)
        let baseline = file([asset("a")], createdAt: created)
        let fresh = apply([asset("a")], baseline, now: created.addingTimeInterval(86_400 * 3))
        XCTAssertEqual(fresh.report.ageDays, 3)
        XCTAssertEqual(fresh.report.warnings, [])
        XCTAssertEqual(fresh.report.toolVersion, XcpurgeVersion.current)

        let old = apply([asset("a")], baseline, now: created.addingTimeInterval(86_400 * 120))
        XCTAssertEqual(old.report.ageDays, 120)
        XCTAssertEqual(old.report.warnings, ["baseline is 120 days old; regenerate with xcpurge baseline"])
        var never = Config()
        never.baselineMaxAgeDays = 0
        XCTAssertEqual(apply([asset("a")], baseline, config: never, now: created.addingTimeInterval(86_400 * 1000)).report.warnings, [])
        var dated = baseline
        dated.createdAt = "2023-11-14T22:13:20Z"
        XCTAssertEqual(apply([asset("a")], dated, now: created.addingTimeInterval(86_400 * 3)).report.ageDays, 3, "full timestamps parse")
        dated.createdAt = "yesterday"
        XCTAssertTrue(apply([asset("a")], dated, now: created).report.warnings.contains { $0.contains("no readable createdAt") })

        var lower = Config()
        lower.minConfidence = .low
        var strictFile = baseline
        strictFile.minConfidence = .high
        XCTAssertTrue(apply([], strictFile, config: lower, now: created).report.warnings.contains { $0.contains("below the baseline's high") })
        var higher = Config()
        higher.minConfidence = .high
        XCTAssertTrue(apply([], baseline, config: higher, now: created).report.warnings.contains { $0.contains("above the baseline's low") })

        var gated = baseline
        gated.failOn = ["dead-source"]
        XCTAssertTrue(apply([], gated, now: created).report.warnings.contains { $0.contains("--fail-on dead-source") })
        var gating = Config()
        gating.failOn = ["any"]
        XCTAssertFalse(apply([], baseline, config: gating, now: created).report.warnings.contains { $0.contains("fail-on") },
                       "gating a baseline written without --fail-on is the normal workflow")

        var other = baseline
        other.toolVersion = "0.3.0"
        XCTAssertTrue(apply([], other, now: created).report.warnings.contains { $0.contains("written by xcpurge 0.3.0") })
        var partial = baseline
        partial.categories = [.assets]
        XCTAssertTrue(apply([], partial, now: created).report.warnings.contains { $0.contains("does not cover duplicates, files, strings") })
        XCTAssertEqual(apply([], partial, categories: [.assets], now: created).report.warnings, [])
        XCTAssertTrue(apply([], file([], createdAt: created), now: created).report.warnings.contains { $0.contains("no entries") })

        var hashed = baseline
        hashed.configHash = "fnv64:0000000000000000"
        let mismatch = BaselineMatcher.apply(findings: [], file: hashed, filePath: "b", categories: XcpurgeKit.Category.scannable,
                                             config: Config(), now: created, root: URL(fileURLWithPath: "/tmp/root"))
        XCTAssertTrue(mismatch.report.warnings.contains { $0.contains("different configuration") })
    }

    func testStrictFlagIsRecorded() {
        let baseline = file([asset("a")])
        XCTAssertTrue(apply([], baseline, strict: true).report.strict)
        XCTAssertFalse(apply([], baseline).report.strict)
    }

    // MARK: - CLI

    private func readBaseline(_ url: URL) throws -> BaselineFile { try BaselineFile.load(url) }

    func testBaselineCommandThenScanWithFailOnAnyExitsZero() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let written = try CLISupport.run(["baseline", root.path, "--quiet"])
        XCTAssertEqual(written.status, 0, written.stderr)
        let url = root.appendingPathComponent(BaselineFile.defaultName)
        XCTAssertTrue(written.stderr.contains("Wrote baseline \(url.path)"), written.stderr)
        let first = try Data(contentsOf: url)
        XCTAssertFalse(try readBaseline(url).entries.isEmpty)

        let again = try CLISupport.run(["baseline", root.path, "--quiet"])
        XCTAssertEqual(again.status, 0)
        XCTAssertEqual(try Data(contentsOf: url), first, "two runs are byte-identical")
        XCTAssertTrue(again.stderr.contains("(+0 added, -0 removed)"), again.stderr)

        let gated = try CLISupport.run(["scan", root.path, "--baseline", url.path, "--fail-on", "any"])
        XCTAssertEqual(gated.status, 0, gated.stderr)
        XCTAssertTrue(gated.stderr.contains("Baseline \(url.path) (0 days): "), gated.stderr)
        XCTAssertTrue(gated.stderr.contains(" baselined, 0 new, 0 fixed"), gated.stderr)
        XCTAssertFalse(gated.stderr.contains("warning: baseline"), gated.stderr)

        // Drop one entry: exactly one finding is new, --fail-on any fires, and the JSON carries the baseline object.
        var baseline = try readBaseline(url)
        let dropped = baseline.entries.first { $0.name == "legacy_unused" }!
        baseline.entries.removeAll { $0 == dropped }
        try baseline.write(to: url)
        let oneNew = try CLISupport.run(["scan", root.path, "--baseline", url.path, "--fail-on", "any", "--format", "json", "--quiet"])
        XCTAssertEqual(oneNew.status, 1)
        let doc = try JSONSerialization.jsonObject(with: Data(oneNew.stdout.utf8)) as! [String: Any]
        let findings = doc["findings"] as! [[String: Any]]
        XCTAssertEqual(findings.count, 1)
        XCTAssertEqual(findings.first?["name"] as? String, "legacy_unused")
        let report = doc["baseline"] as! [String: Any]
        XCTAssertEqual(report["newCount"] as? Int, 1)
        XCTAssertEqual(report["baselinedCount"] as? Int, 7)
        XCTAssertEqual(report["file"] as? String, url.path)
        XCTAssertEqual((report["fixed"] as? [Any])?.count, 0)
        XCTAssertEqual(report["strict"] as? Bool, false)

        // Regenerating prints the delta.
        let regenerated = try CLISupport.run(["baseline", root.path, "--quiet"])
        XCTAssertTrue(regenerated.stderr.contains("(+1 added, -0 removed)"), regenerated.stderr)
    }

    func testStrictBaselineExitsOneOnFixedEntries() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let out = root.appendingPathComponent("baselines/classic.json")
        let written = try CLISupport.run(["baseline", root.path, "--quiet", "--output", out.path])
        XCTAssertEqual(written.status, 0, written.stderr)
        XCTAssertTrue(try readBaseline(out).entries.contains { $0.kind == .unusedResource })
        // Ignoring the kind afterwards makes its entry fixed without adding a finding.
        try Data("kind:unused-resource\n".utf8).write(to: root.appendingPathComponent(Ignore.fileName))

        let lenient = try CLISupport.run(["scan", root.path, "--baseline", out.path, "--fail-on", "any"])
        XCTAssertEqual(lenient.status, 0, "fixed entries only warn by default\n\(lenient.stderr)")
        XCTAssertTrue(lenient.stderr.contains(", 1 fixed"), lenient.stderr)

        let strict = try CLISupport.run(["scan", root.path, "--baseline", out.path, "--strict-baseline"])
        XCTAssertEqual(strict.status, 1, strict.stderr)
        XCTAssertTrue(strict.stderr.contains("regenerate with xcpurge baseline"), strict.stderr)
        let json = try CLISupport.run(["scan", root.path, "--baseline", out.path, "--strict-baseline", "--format", "json", "--quiet"])
        let doc = try JSONSerialization.jsonObject(with: Data(json.stdout.utf8)) as! [String: Any]
        let report = doc["baseline"] as! [String: Any]
        XCTAssertEqual(report["strict"] as? Bool, true)
        XCTAssertEqual((report["fixed"] as? [[String: Any]])?.first?["kind"] as? String, "unusedResource")

        // `xcpurge files --baseline` still sees the fixed resource; `xcpurge assets --baseline` must not.
        let files = try CLISupport.run(["files", root.path, "--baseline", out.path, "--strict-baseline"])
        XCTAssertEqual(files.status, 1, files.stderr)
        let assets = try CLISupport.run(["assets", root.path, "--baseline", out.path, "--strict-baseline"])
        XCTAssertEqual(assets.status, 0, assets.stderr)
        XCTAssertTrue(assets.stderr.contains(", 0 fixed"), assets.stderr)
    }

    func testMissingEmptyAndCorruptBaselinesExitTwo() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let missing = try CLISupport.run(["scan", root.path, "--baseline", root.appendingPathComponent("nope.json").path])
        XCTAssertEqual(missing.status, 2)
        XCTAssertTrue(missing.stderr.contains("baseline file not found"), missing.stderr)

        let empty = root.appendingPathComponent("empty.json")
        try Data().write(to: empty)
        let emptyRun = try CLISupport.run(["scan", root.path, "--baseline", empty.path])
        XCTAssertEqual(emptyRun.status, 2)
        XCTAssertTrue(emptyRun.stderr.contains("is empty"), emptyRun.stderr)

        let corrupt = root.appendingPathComponent("corrupt.json")
        try Data("{\"version\": 1, \"entries\": \"no\"}".utf8).write(to: corrupt)
        let corruptRun = try CLISupport.run(["scan", root.path, "--baseline", corrupt.path])
        XCTAssertEqual(corruptRun.status, 2)
        XCTAssertTrue(corruptRun.stderr.contains("not valid"), corruptRun.stderr)

        let future = root.appendingPathComponent("v9.json")
        try Data("{\"version\": 9, \"entries\": []}".utf8).write(to: future)
        let futureRun = try CLISupport.run(["scan", root.path, "--baseline", future.path])
        XCTAssertEqual(futureRun.status, 2)
        XCTAssertTrue(futureRun.stderr.contains("version 9"), futureRun.stderr)

        // A valid file with no entries is allowed, with a warning.
        let blank = root.appendingPathComponent("blank.json")
        try BaselineFile.make(findings: [], categories: XcpurgeKit.Category.scannable, config: Config(), root: root).write(to: blank)
        let blankRun = try CLISupport.run(["scan", root.path, "--baseline", blank.path, "--quiet"])
        XCTAssertEqual(blankRun.status, 0, blankRun.stderr)
        XCTAssertTrue(blankRun.stderr.contains("warning: baseline: baseline has no entries"), blankRun.stderr)
    }

    func testAgeWarningAndConfigBaselinePathOnCommandLine() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let written = try CLISupport.run(["baseline", root.path, "--quiet"])
        XCTAssertEqual(written.status, 0, written.stderr)
        let url = root.appendingPathComponent(BaselineFile.defaultName)
        var baseline = try readBaseline(url)
        baseline.createdAt = "2020-01-01"
        try baseline.write(to: url)
        // Relative `baseline` in xcpurge.json resolves against the root.
        try Data("{\"baseline\": \"\(BaselineFile.defaultName)\"}".utf8).write(to: root.appendingPathComponent(Config.fileName))
        let aged = try CLISupport.run(["scan", root.path, "--quiet"])
        XCTAssertEqual(aged.status, 0, aged.stderr)
        XCTAssertTrue(aged.stderr.contains("days old; regenerate with xcpurge baseline"), aged.stderr)
        let silenced = try CLISupport.run(["scan", root.path, "--quiet", "--baseline-max-age", "0"])
        XCTAssertFalse(silenced.stderr.contains("days old"), silenced.stderr)
        XCTAssertFalse(silenced.stderr.contains("Baseline "), "--quiet hides the summary line")
    }

    func testBaselineCommandRejectsReportOnlyOptions() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        for flags in [["--format", "json"], ["--open"], ["--browser", "Safari"]] {
            let run = try CLISupport.run(["baseline", root.path, "--quiet"] + flags)
            XCTAssertEqual(run.status, 2, flags.joined(separator: " "))
            XCTAssertTrue(run.stderr.contains("do not apply to `xcpurge baseline`"), run.stderr)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(BaselineFile.defaultName).path))
        }
    }

    func testBaselineCommandDiff() {
        let old = file([asset("a"), string("k"), string("k", locale: "fr")])
        let new = file([asset("a"), asset("b"), string("k")])
        let (added, removed) = BaselineCommandDiff.diff(from: old, to: new)
        XCTAssertEqual(added, 1)
        XCTAssertEqual(removed, 1, "one of the two `k` counts went away")
    }
}

/// Mirror of `BaselineCommand.diff` (the CLI target is not importable from the tests).
private enum BaselineCommandDiff {
    static func diff(from old: BaselineFile, to new: BaselineFile) -> (added: Int, removed: Int) {
        var counts: [String: Int] = [:]
        for e in old.entries { counts[e.key, default: 0] -= e.count }
        for e in new.entries { counts[e.key, default: 0] += e.count }
        return (counts.values.filter { $0 > 0 }.reduce(0, +), -counts.values.filter { $0 < 0 }.reduce(0, +))
    }
}
