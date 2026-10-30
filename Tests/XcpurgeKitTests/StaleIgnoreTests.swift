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
        XCTAssertEqual(plain.name, "xcpurge:ignore")
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
