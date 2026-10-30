import XCTest
@testable import XcpurgeKit

/// Stale `.xcpurgeignore` rules and inline `xcpurge:ignore` markers: every rule is conservative, so most of these
/// tests assert that something is NOT flagged.
final class StaleIgnoreTests: XCTestCase {
    private func stale(_ root: URL, config: Config = Config(),
                       categories: Set<XcpurgeKit.Category> = XcpurgeKit.Category.scannable) async throws -> [Finding] {
        let result = try await ScanEngine(root: root, config: config).run(categories: categories)
        XCTAssertTrue(result.findings.filter { $0.kind == .staleIgnore }.allSatisfy { $0.category == .ignores })
        return result.findings.filter { $0.kind == .staleIgnore }
    }

    private func rules(_ findings: [Finding]) -> [String] {
        findings.filter { $0.path == Ignore.fileName }.map { $0.name ?? "" }
    }

    private func markers(_ findings: [Finding]) -> [String] {
        findings.filter { $0.path != Ignore.fileName }.map { "\($0.path):\($0.line ?? 0)" }
    }

    private func write(_ text: String, to root: URL, _ path: String) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    // MARK: - .xcpurgeignore rules

    func testPathGlobsAreStaleOnlyWhenNothingOnDiskMatches() async throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        try write("x", to: root, "Pods/Lib/a.m")       // skipped by the walker, present on disk
        try write("x", to: root, ".github/ci.yml")     // hidden, skipped by the walker, present on disk
        try write("""
        # rules
        Vendor/**
        Pods/**
        Pods/Lib/*.m
        .github/**
        Legacy/
        Nope/
        !Legacy/Keep.swift
        !Legacy/Legacy.swift
        Modern/ModernAssets.xcassets/modern_unused.imageset/
        Modern/ModernAssets.xcassets/gone.imageset/
        /Content/*.json
        Content/*.swift
        """, to: root, Ignore.fileName)
        let found = try await stale(root)
        XCTAssertEqual(rules(found).sorted(), ["!Legacy/Keep.swift", "Content/*.swift", "Modern/ModernAssets.xcassets/gone.imageset/",
                                               "Nope/", "Vendor/**"].sorted())
        for f in found {
            XCTAssertEqual(f.confidence, .medium)
            XCTAssertEqual(f.reasons, ["matches no file on disk"])
            XCTAssertEqual(f.module, "unknown")
            XCTAssertEqual(f.category, .ignores)
        }
        XCTAssertEqual(found.first { $0.name == "Vendor/**" }?.line, 2, "line numbers count comments and blank lines")
        XCTAssertEqual(found.first { $0.name == "!Legacy/Keep.swift" }?.line, 8)
    }

    func testScopeFlagsDoNotMakeRulesStale() async throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        try write("Legacy/**\nStray/**\n", to: root, Ignore.fileName)
        var config = Config()
        config.exclude = ["Legacy/**"]
        config.targets = ["Nope"]
        let found1 = try await stale(root, config: config)
        XCTAssertEqual(rules(found1), [])
    }

    func testKindRulesFlagOnlyTypos() async throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        try write("kind:deadSource\nkind:dead-source\nkind:duplicate\nkind:deadSorce\nkind:staleIgnore\n", to: root, Ignore.fileName)
        let found = try await stale(root)
        XCTAssertEqual(rules(found), [], "`kind:staleIgnore` is a known kind and silences the rest")
        try write("kind:deadSource\nkind:dead-source\nkind:duplicate\nkind:deadSorce\n", to: root, Ignore.fileName)
        let typo = try await stale(root)
        XCTAssertEqual(rules(typo), ["kind:deadSorce"], "a known kind with no findings is policy, not stale")
        XCTAssertEqual(typo.first?.confidence, .high)
        XCTAssertEqual(typo.first?.line, 4)
        XCTAssertTrue(typo.first?.reasons.first?.contains("is not a finding kind") == true)
    }

    func testModuleRules() async throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        try write("module:Nope\nmodule:MixedApp\nmodule:Mixed*\n", to: root, Ignore.fileName)
        let found = try await stale(root)
        XCTAssertEqual(rules(found), ["module:Nope"])
        XCTAssertEqual(found.first?.confidence, .high)
        XCTAssertEqual(found.first?.reasons, ["no module named like this"])
        try write("module:unknown\n", to: root, Ignore.fileName)
        let unknown = try await stale(root)
        XCTAssertEqual(rules(unknown), [], "`unknown` is the module of unattributed files")
    }

    func testAssetAndStringRulesDependOnScannedCategories() async throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        try write("asset:legacy_unused\nasset:modern_used\nasset:never_there\nstring:farewell_unused\nstring:push.*\nstring:greeting\n",
                  to: root, Ignore.fileName)
        let full = try await stale(root)
        XCTAssertEqual(rules(full).sorted(), ["asset:modern_used", "asset:never_there", "string:greeting", "string:push.*"])
        XCTAssertEqual(full.first { $0.name == "asset:modern_used" }?.confidence, .low)
        XCTAssertEqual(full.first { $0.name == "asset:modern_used" }?.reasons, ["asset exists but is used; rule suppresses nothing"])
        XCTAssertEqual(full.first { $0.name == "asset:never_there" }?.confidence, .medium)
        XCTAssertEqual(full.first { $0.name == "asset:never_there" }?.reasons, ["no asset named like this"])
        XCTAssertEqual(full.first { $0.name == "string:push.*" }?.confidence, .low)

        let found2 = try await stale(root, categories: [.strings])
        XCTAssertEqual(rules(found2).sorted(), ["string:greeting", "string:push.*"],
                       "`xcpurge strings` cannot judge asset rules")
        let found3 = try await stale(root, categories: [.assets, .duplicates])
        XCTAssertEqual(rules(found3).sorted(), ["asset:modern_used", "asset:never_there"])
        let found4 = try await stale(root, categories: [.files])
        XCTAssertEqual(rules(found4), [])
    }

    func testStaleFindingsHonourThresholdAndRules() async throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        try write("asset:modern_used\nmodule:Nope\n", to: root, Ignore.fileName)
        var medium = Config()
        medium.minConfidence = .medium
        let found5 = try await stale(root, config: medium)
        XCTAssertEqual(rules(found5), ["module:Nope"], "low-confidence stale findings are cut")
        try write("asset:modern_used\nmodule:Nope\nkind:stale-ignore\n", to: root, Ignore.fileName)
        let found6 = try await stale(root)
        XCTAssertEqual(found6, [], "`kind:stale-ignore` silences the detector through the usual rules")
        var off = Config()
        off.staleIgnores = false
        try write("module:Nope\n", to: root, Ignore.fileName)
        let found7 = try await stale(root, config: off)
        XCTAssertEqual(found7, [])
    }

    func testScopedRunsKeepOnlyGlobAndKindChecks() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try write("module:AppWidget\nmodule:Nope\nasset:never_there\nstring:nope.*\nVendor/**\nkind:deadSorce\n", to: root, Ignore.fileName)
        let app = root.appendingPathComponent("App/App/ModularApp.swift")
        try Data((try String(contentsOf: app, encoding: .utf8) + "\nlet marked = 1 // xcpurge:ignore\n").utf8).write(to: app)

        let full = try await ScanEngine(root: root, config: Config()).run()
        let fullStale = full.findings.filter { $0.kind == .staleIgnore }
        XCTAssertEqual(rules(fullStale).sorted(), ["Vendor/**", "asset:never_there", "kind:deadSorce", "module:Nope", "string:nope.*"])
        XCTAssertEqual(markers(fullStale), ["App/App/ModularApp.swift:12"])
        XCTAssertFalse(full.context.diagnostics.entries.contains { $0.message.contains("stale-ignore checks limited") })

        var scoped = Config()
        scoped.package = root.appendingPathComponent("Packages/Core").path
        let partial = try await ScanEngine(root: root, config: scoped).run()
        let partialStale = partial.findings.filter { $0.kind == .staleIgnore }
        XCTAssertEqual(rules(partialStale).sorted(), ["Vendor/**", "kind:deadSorce"],
                       "AppWidget is outside the scoped graph; module/asset/string rules are not judged")
        XCTAssertEqual(markers(partialStale), [], "sources outside the scope are not judged")
        XCTAssertTrue(partial.context.diagnostics.entries.contains {
            $0.level == .info && $0.message.contains("stale-ignore checks limited") && $0.message.contains("scoped run")
        }, "\(partial.context.diagnostics.entries)")

        var project = Config()
        project.project = root.appendingPathComponent("App/App.xcodeproj").path
        let byProject = try await ScanEngine(root: root, config: project).run()
        XCTAssertEqual(markers(byProject.findings.filter { $0.kind == .staleIgnore }), [])
        let quiet = try await ScanEngine(root: try FixtureSupport.copyToTemp("ModularWorkspace"), config: scoped).run()
        XCTAssertFalse(quiet.context.diagnostics.entries.contains { $0.message.contains("stale-ignore checks limited") },
                       "no note when there is nothing to check")
    }

    func testLooseImageAssetRuleMatchesWithAndWithoutExtension() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        try write("asset:unused_loose\n", to: root, Ignore.fileName)
        let result = try await ScanEngine(root: root, config: Config()).run()
        XCTAssertFalse(result.findings.contains { $0.kind == .unusedAsset && $0.name == "unused_loose.png" }, "the rule suppresses")
        XCTAssertEqual(result.findings.filter { $0.kind == .staleIgnore }, [], "so it is not stale")
        try write("asset:unused_loose.png\nasset:unused_*\nasset:unused\n", to: root, Ignore.fileName)
        let found = try await stale(root)
        XCTAssertEqual(rules(found), ["asset:unused"])
        XCTAssertEqual(found.first?.confidence, .medium)
        XCTAssertEqual(found.first?.reasons, ["no asset named like this"])
    }

    // MARK: - Lazy disk walk

    private func pathRules(_ contents: String) -> [StaleIgnoreDetector.PathRule] {
        Ignore(contents: contents).rules.compactMap { rule in
            guard case let .path(glob, directoryOnly) = rule.matcher else { return nil }
            return StaleIgnoreDetector.PathRule(rule: rule, glob: glob, directoryOnly: directoryOnly)
        }
    }

    func testDiskWalkNeverEntersDirectoriesNoRuleCanMatchUnder() async throws {
        let root = try FixtureSupport.tempTree([
            "Src/A.swift": "struct A {}\n",
            "Other/deep/a/b/c.txt": "x", "Other/deep/a/d.txt": "x", "Other/e.txt": "x",
            "Vendorish/f.txt": "x",
            ".hidden/Vendor/g.txt": "x",
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        let rules = pathRules("Vendor/**\nSrc/Nope/*.swift\n/Other/deep/a/b/*.md\n")
        var visited: [String] = []
        let verdict = StaleIgnoreDetector.stalePathRules(rules, ctx) { visited.append($0) }
        XCTAssertEqual(verdict.stale.map(\.text), ["Vendor/**", "Src/Nope/*.swift", "/Other/deep/a/b/*.md"])
        XCTAssertEqual(verdict.undecided, [])
        // Directories are pruned, not files: a descended directory lists its files, but no directory off every
        // rule's chain is entered (`Vendorish/`, `.hidden/`, `Src/` is listed but its children are files).
        XCTAssertFalse(visited.contains { $0.hasPrefix("Vendorish/") || $0.hasPrefix(".hidden/") },
                       "only directories some rule can match under are entered: \(visited)")
        XCTAssertTrue(visited.contains("Other/deep/a/b/c.txt"), "the anchored rule's directory chain is walked: \(visited)")
        XCTAssertTrue(visited.contains("Vendorish") && visited.contains(".hidden"), "pruned directories are still tested themselves")

        let anchoredOnly = pathRules("Vendor/**\n")
        visited = []
        _ = StaleIgnoreDetector.stalePathRules(anchoredOnly, ctx) { visited.append($0) }
        XCTAssertEqual(visited.filter { $0.contains("/") }, [], "nothing below the top level is entered for Vendor/**: \(visited)")

        let unanchored = pathRules("*.md\n")
        visited = []
        let open = StaleIgnoreDetector.stalePathRules(unanchored, ctx) { visited.append($0) }
        XCTAssertEqual(open.stale.map(\.text), ["*.md"])
        XCTAssertTrue(visited.contains("Other/deep/a/b/c.txt"), "an unanchored rule can match anywhere, so everything is walked")
    }

    func testDiskWalkCapAndBuildOutputGiveUndecidedNotStale() async throws {
        let root = try FixtureSupport.tempTree([
            "Src/A.swift": "struct A {}\n",
            "node_modules/pkg/index.js": "x",
            "Big/a.txt": "x", "Big/b.txt": "x", "Big/c.txt": "x",
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        XCTAssertNil(ctx.inventory.index(of: "node_modules/pkg/index.js"), "the main walk skips node_modules")
        let verdict = StaleIgnoreDetector.stalePathRules(pathRules("node_modules/pkg/*.js\nnode_modules/**\nNope/**\n"), ctx)
        XCTAssertEqual(verdict.stale.map(\.text), ["Nope/**"])
        XCTAssertEqual(verdict.undecided.map(\.text), ["node_modules/pkg/*.js"], "could only match inside skipped build output")

        let capped = StaleIgnoreDetector.stalePathRules(pathRules("Big/*.md\nNope/**\n"), ctx, walkCap: 2)
        XCTAssertEqual(capped.stale, [])
        XCTAssertEqual(Set(capped.undecided.map(\.text)), ["Big/*.md", "Nope/**"])

        try write("node_modules/pkg/*.js\nNope/**\n", to: root, Ignore.fileName)
        let found = try await stale(root)
        XCTAssertEqual(found.map(\.name), ["Nope/**", "node_modules/pkg/*.js"])
        XCTAssertEqual(found.map(\.confidence), [.medium, .low])
        XCTAssertTrue(found[1].reasons[0].hasPrefix("could not evaluate"), found[1].reasons[0])
    }

    func testTwoStaleMarkersInOneFileHaveDistinctIdentities() async throws {
        let root = try FixtureSupport.tempTree([
            "A.swift": "struct A { func f() { B().g() } } // xcpurge:ignore\n\nlet x = 1 // xcpurge:ignore\n",
            "B.swift": "struct B { func g() { A().f() } }\n",
        ])
        let found = try await stale(root)
        XCTAssertEqual(found.map { "\($0.line ?? 0) \($0.name ?? "")" }, ["1 xcpurge:ignore", "3 xcpurge:ignore #2"])
        XCTAssertEqual(Set(found.map(\.key)).count, 2)
        XCTAssertEqual(Set(found.map(\.id)).count, 2)
        XCTAssertEqual(found.map(\.key), ["staleIgnore|A.swift|xcpurge:ignore", "staleIgnore|A.swift|xcpurge:ignore #2"])
    }

    // MARK: - Inline markers

    func testInlineMarkersAreStaleOnlyWhenTheySuppressNothing() async throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let app = root.appendingPathComponent("Modern/MixedAppApp.swift")
        var source = try String(contentsOf: app, encoding: .utf8)
        // Line 12 (`Text(banner.title())`) is a keyless localization lookup: a marker there suppresses a finding.
        source = source.replacingOccurrences(of: "            Text(banner.title())", with: "            Text(banner.title()) // xcpurge:ignore")
        source += """

        let plainMarked = 1 // xcpurge:ignore - a reason after a dash is fine
        // xcpurge:ignore
        let dynamic = UIImage(named: "flag_\\(plainMarked)")
        /* xcpurge:ignore */ let blockMarked = 2
        let literal = "xcpurge:ignore"

        """
        try Data(source.utf8).write(to: app)
        try write("// xcpurge:ignore\nstruct KeptOnPurpose {}\n", to: root, "Modern/Kept.swift")
        try write("// xcpurge:ignore\n", to: root, "Modern/Vendor/Empty.swift")
        try write("{\"icon\": \"x\"} // xcpurge:ignore\n", to: root, "Content/c.json")

        let found = try await stale(root)
        let lines = source.split(separator: "\n", omittingEmptySubsequences: false)
        let plainLine = lines.firstIndex { $0.hasPrefix("let plainMarked") }! + 1
        XCTAssertEqual(markers(found).sorted(), ["Modern/MixedAppApp.swift:\(plainLine)", "Modern/Vendor/Empty.swift:1"], """
        only the trailing marker on a plain line and the lone marker in an empty file are stale:
        \(found.map { "\($0.path):\($0.line ?? 0) \($0.reasons)" })
        """)
        let plain = found.first { $0.line == plainLine }!
        XCTAssertEqual(plain.name, "xcpurge:ignore #2", "second line-style marker of the file; the first (line 12) is used")
        XCTAssertEqual(plain.module, "MixedApp")
        XCTAssertEqual(plain.confidence, .medium)
        XCTAssertEqual(plain.category, .ignores)
        // The file the marker keeps alive is not a dead source and is not flagged.
        let result = try await ScanEngine(root: root, config: Config()).run()
        XCTAssertFalse(result.findings.contains { $0.kind == .deadSource && $0.path == "Modern/Kept.swift" })

        // Excluded files are never candidates; `--targets` applies to inline findings.
        var excluded = Config()
        excluded.exclude = ["Modern/Vendor/**"]
        let found8 = try await stale(root, config: excluded)
        XCTAssertEqual(markers(found8), ["Modern/MixedAppApp.swift:\(plainLine)"])
        var targeted = Config()
        targeted.targets = ["Nope"]
        let found9 = try await stale(root, config: targeted)
        XCTAssertEqual(markers(found9), [])
        // Partial scans cannot judge markers.
        let found10 = try await stale(root, categories: [.assets, .duplicates])
        XCTAssertEqual(markers(found10), [])
        let found11 = try await stale(root, categories: [.strings])
        XCTAssertEqual(markers(found11), [])
    }

    func testMarkerInBlockCommentIsHonouredButNeverFlagged() async throws {
        let root = try FixtureSupport.tempTree([
            "A.swift": "struct A { func f() { B().g() } }\n/* xcpurge:ignore */\nlet unusedButMarked = 1\n",
            "B.swift": "struct B { func g() { A().f() } }\n",
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        XCTAssertTrue(ctx.refs.isIgnored(file: 0, line: 2))
        XCTAssertTrue(ctx.refs.isIgnored(file: 0, line: 3))
        XCTAssertEqual(ctx.refs.ignoreMarkers[0]?.map(\.style), [.block])
        let found12 = try await stale(root)
        XCTAssertEqual(found12, [])
    }

    func testMarkerTextInsideStringLiteralIsNotAMarker() async throws {
        let root = try FixtureSupport.tempTree([
            "A.swift": "struct A { func f() { B().g(\"xcpurge:ignore\") } }\n",
            "B.swift": "struct B { func g(_ s: String) { A().f() } }\n",
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        XCTAssertTrue(ctx.refs.ignoredLines.isEmpty)
        XCTAssertTrue(ctx.refs.ignoreMarkers.isEmpty)
        let found13 = try await stale(root)
        XCTAssertEqual(found13, [])
    }

    func testGenericTextMarkersAreNeverCandidates() async throws {
        let root = try FixtureSupport.tempTree([
            "A.swift": "struct A { func f() { B().g() } }\n",
            "B.swift": "struct B { func g() { A().f() } }\n",
            "data.json": "{\"a\": 1} // xcpurge:ignore\n",
            "page.html": "<!-- xcpurge:ignore --><p>hi</p>\n",
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        XCTAssertFalse(ctx.refs.ignoredLines.isEmpty, "generic text markers still suppress")
        XCTAssertTrue(ctx.refs.ignoreMarkers.isEmpty)
        let found14 = try await stale(root)
        XCTAssertEqual(found14, [])
    }

    func testNoSecondDetectorPassWithoutLineMarkers() async throws {
        let root = try FixtureSupport.tempTree(["A.swift": "/* xcpurge:ignore */ let a = 1\n"])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        XCTAssertFalse(ctx.refs.hasLineStyleMarkers)
        let lined = try FixtureSupport.tempTree(["A.swift": "let a = 1 // xcpurge:ignore\n"])
        let linedRefs = try await ScanEngine(root: lined, config: Config()).makeContext().refs
        XCTAssertTrue(linedRefs.hasLineStyleMarkers)
    }

    func testWithoutIgnoresKeepsEverythingElse() async throws {
        let root = try FixtureSupport.tempTree(["A.swift": "let a = UIImage(named: \"x_\\(1)\") // xcpurge:ignore\n"])
        let refs = try await ScanEngine(root: root, config: Config()).makeContext().refs
        let off = refs.withoutIgnores()
        XCTAssertTrue(off.ignoredLines.isEmpty)
        XCTAssertFalse(refs.ignoredLines.isEmpty)
        XCTAssertEqual(off.references, refs.references)
        XCTAssertEqual(off.dynamicPatterns, refs.dynamicPatterns)
        XCTAssertEqual(off.ignoreMarkers, refs.ignoreMarkers)
        XCTAssertEqual(off.sourcePaths, refs.sourcePaths)
    }

    // MARK: - CLI

    func testFlagsAndExitCodes() throws {
        let root = try FixtureSupport.tempTree([
            Ignore.fileName: "module:Nope\n",
            "A.swift": "struct A { func f() { B().g() } }\n",
            "B.swift": "struct B { func g() { A().f() } }\n",
        ])
        let plain = try CLISupport.run(["scan", root.path, "--quiet", "--fail-on", "any"])
        XCTAssertEqual(plain.status, 0, "stale ignores are informational\n\(plain.stderr)")
        XCTAssertTrue(plain.stdout.contains("stale-ignore"), plain.stdout)
        XCTAssertTrue(plain.stdout.contains("module:Nope"), plain.stdout)

        let gated = try CLISupport.run(["scan", root.path, "--quiet", "--fail-on-stale-ignore"])
        XCTAssertEqual(gated.status, 1, gated.stderr)
        let gatedLong = try CLISupport.run(["scan", root.path, "--quiet", "--fail-on", "stale-ignore"])
        XCTAssertEqual(gatedLong.status, 1, gatedLong.stderr)

        let off = try CLISupport.run(["scan", root.path, "--quiet", "--no-stale-ignore", "--fail-on-stale-ignore", "--format", "json"])
        XCTAssertEqual(off.status, 0, off.stderr)
        XCTAssertFalse(off.stdout.contains("staleIgnore"), off.stdout)

        try Data("{\"staleIgnores\": false}".utf8).write(to: root.appendingPathComponent(Config.fileName))
        let configured = try CLISupport.run(["scan", root.path, "--quiet", "--fail-on-stale-ignore"])
        XCTAssertEqual(configured.status, 0, configured.stderr)
    }

    func testStaleIgnoresLandInBaselines() throws {
        let root = try FixtureSupport.tempTree([
            Ignore.fileName: "module:Nope\n",
            "A.swift": "struct A { func f() { B().g() } }\n",
            "B.swift": "struct B { func g() { A().f() } }\n",
        ])
        let written = try CLISupport.run(["baseline", root.path, "--quiet"])
        XCTAssertEqual(written.status, 0, written.stderr)
        let file = try BaselineFile.load(root.appendingPathComponent(BaselineFile.defaultName))
        XCTAssertEqual(file.entries.map(\.key), ["staleIgnore|.xcpurgeignore|module:Nope"])
        XCTAssertEqual(file.entries.first?.category, .ignores)
        let gated = try CLISupport.run(["scan", root.path, "--quiet", "--baseline", root.appendingPathComponent(BaselineFile.defaultName).path,
                                        "--fail-on-stale-ignore"])
        XCTAssertEqual(gated.status, 0, gated.stderr)
    }
}
