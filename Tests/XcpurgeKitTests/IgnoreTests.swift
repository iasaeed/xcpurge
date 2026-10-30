import XCTest
@testable import XcpurgeKit

/// `.xcpurgeignore` parsing and matching: gitignore-style path globs, negation, name entries, inline markers.
final class IgnoreTests: XCTestCase {
    private func file(_ path: String, kind: FindingKind = .deadSource, module: String = "App", line: Int? = nil) -> Finding {
        Finding(kind: kind, category: .files, path: path, line: line, module: module, confidence: .high)
    }

    private func asset(_ name: String, kind: FindingKind = .unusedAsset) -> Finding {
        Finding(kind: kind, category: .assets, path: "App/Assets.xcassets", name: name, module: "App", confidence: .high)
    }

    private func string(_ key: String) -> Finding {
        Finding(kind: .unusedString, category: .strings, path: "App/Localizable.xcstrings", name: key, module: "App",
                confidence: .high)
    }

    func testPathGlobs() {
        let ignore = Ignore(contents: """
        # comment

        Vendor/**
        *.generated.swift
        /Top.swift
        Docs/
        App/**/Mocks/*.json
        """)
        XCTAssertTrue(ignore.suppresses(file("Vendor/Lib/a.swift")))
        XCTAssertTrue(ignore.suppresses(file("App/Sub/Model.generated.swift")), "unanchored glob matches any depth")
        XCTAssertTrue(ignore.suppresses(file("Top.swift")))
        XCTAssertFalse(ignore.suppresses(file("App/Top.swift")), "leading / anchors at the root")
        XCTAssertTrue(ignore.suppresses(file("App/Docs/x.swift")), "trailing / matches a directory at any depth")
        XCTAssertFalse(ignore.suppresses(file("App/Docs")), "trailing / never matches a plain file")
        XCTAssertTrue(ignore.suppresses(file("App/A/B/Mocks/user.json")))
        XCTAssertFalse(ignore.suppresses(file("App/A/B/Mocks/user.swift")))
        XCTAssertFalse(ignore.suppresses(file("Sources/App.swift")))
    }

    func testDirectoryRuleMatchesFolderUnits() {
        let ignore = Ignore(contents: "Legacy.xcassets/\n")
        XCTAssertTrue(ignore.suppresses(Finding(kind: .unusedAsset, category: .assets, path: "App/Legacy.xcassets",
                                                name: "x", module: "App", confidence: .high)))
    }

    func testNegationLastMatchWins() {
        let ignore = Ignore(contents: """
        Vendor/**
        !Vendor/Keep.swift
        Vendor/Keep.swift
        !Vendor/Really/**
        """)
        XCTAssertTrue(ignore.suppresses(file("Vendor/a.swift")))
        XCTAssertTrue(ignore.suppresses(file("Vendor/Keep.swift")), "re-ignored by a later rule")
        XCTAssertFalse(ignore.suppresses(file("Vendor/Really/b.swift")), "re-included by the last rule")
        XCTAssertFalse(Ignore(contents: "!Nothing/**").suppresses(file("Nothing/a.swift")), "negation alone ignores nothing")
    }

    func testNameEntries() {
        let ignore = Ignore(contents: """
        asset:server_*
        string:push.*
        module:Legacy*
        kind:dead-source
        kind:ghostReference
        """)
        XCTAssertTrue(ignore.suppresses(asset("server_banner")))
        XCTAssertFalse(ignore.suppresses(asset("local_banner")))
        XCTAssertFalse(ignore.suppresses(asset("server_banner", kind: .duplicate)), "duplicates are not by name")
        XCTAssertFalse(ignore.suppresses(string("server_banner")), "asset: entries only match assets")
        XCTAssertTrue(ignore.suppresses(string("push.welcome")))
        XCTAssertFalse(ignore.suppresses(string("pushwelcome")))
        XCTAssertTrue(ignore.suppresses(file("Kit/a.swift", kind: .orphanFile, module: "LegacyKit")))
        XCTAssertTrue(ignore.suppresses(file("App/a.swift", kind: .deadSource)), "kebab-case kind")
        XCTAssertTrue(ignore.suppresses(file("App/a.swift", kind: .ghostReference)), "camelCase kind")
        XCTAssertFalse(ignore.suppresses(file("App/a.swift", kind: .orphanFile)))
    }

    /// Loose images and fonts are named with their extension; `asset:` rules match with or without it.
    func testAssetRulesMatchLooseFileNamesWithoutExtension() {
        let loose = Finding(kind: .unusedAsset, category: .assets, path: "App/unused_loose.png", name: "unused_loose.png",
                            module: "App", confidence: .high)
        XCTAssertTrue(Ignore(contents: "asset:unused_loose").suppresses(loose))
        XCTAssertTrue(Ignore(contents: "asset:unused_loose.png").suppresses(loose))
        XCTAssertTrue(Ignore(contents: "asset:unused_*").suppresses(loose))
        XCTAssertFalse(Ignore(contents: "asset:unused").suppresses(loose))
        XCTAssertFalse(Ignore(contents: "asset:unused_loose").suppresses(string("unused_loose.png")), "still assets only")
        XCTAssertTrue(Ignore(contents: "asset:icon").suppresses(asset("icon")), "catalog names unchanged")
        XCTAssertFalse(Ignore(contents: "asset:icon").suppresses(asset("icon.v2")) == false, "a dotted catalog name also matches its stem")
    }

    func testEscapesAndBlankLines() {
        let ignore = Ignore(contents: "  \n\\#hash.swift\n\\!bang.swift\n   # indented comment\n")
        XCTAssertTrue(ignore.suppresses(file("#hash.swift")))
        XCTAssertTrue(ignore.suppresses(file("!bang.swift")))
        XCTAssertEqual(ignore.rules.count, 2)
    }

    func testRulesKeepLineNumbersAndText() {
        let ignore = Ignore(contents: """
        # header

        Vendor/**
          !Vendor/Keep.swift  
        \\#hash.swift
        asset:server_*  
        """)
        XCTAssertEqual(ignore.ruleSummaries.map(\.line), [3, 4, 5, 6], "blank lines and comments count")
        XCTAssertEqual(ignore.ruleSummaries.map(\.text), ["Vendor/**", "!Vendor/Keep.swift", "\\#hash.swift", "asset:server_*"],
                       "text is the trimmed rule as written")
        XCTAssertEqual(ignore.ruleSummaries.map(\.negated), [false, true, false, false])
        XCTAssertEqual(ignore.rules.map(\.line), [3, 4, 5, 6])
        XCTAssertEqual(Ignore(contents: "a\r\nb\r\n\r\nc").ruleSummaries.map(\.line), [1, 2, 4])
        XCTAssertTrue(Ignore().ruleSummaries.isEmpty)
    }

    func testTemplateHasNoActiveRules() {
        XCTAssertTrue(Ignore(contents: Ignore.template).isEmpty)
        XCTAssertTrue(Ignore.template.contains("asset:"))
        XCTAssertTrue(Ignore.template.contains("xcpurge:ignore"))
    }

    func testLoadFromRoot() throws {
        let root = try FixtureSupport.tempTree([Ignore.fileName: "Generated/**\n"])
        XCTAssertTrue(try Ignore.load(root: root).suppresses(file("Generated/x.swift")))
        let empty = try FixtureSupport.tempTree(["a.swift": ""])
        XCTAssertTrue(try Ignore.load(root: empty).isEmpty)
    }

    func testInlineMarkerSuppressesFindingOnThatLine() async throws {
        let root = try FixtureSupport.tempTree([
            "A.swift": "let a = 1\n// xcpurge:ignore\nlet b = 2\n",
            Ignore.fileName: "kind:unusedResource\n",
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        XCTAssertTrue(ctx.ignore.suppresses(file("A.swift", line: 3), refs: ctx.refs, inventory: ctx.inventory))
        XCTAssertFalse(ctx.ignore.suppresses(file("A.swift", line: 1), refs: ctx.refs, inventory: ctx.inventory))
        XCTAssertFalse(ctx.ignore.suppresses(file("A.swift"), refs: ctx.refs, inventory: ctx.inventory), "no line, no marker")
        XCTAssertTrue(ctx.ignore.suppresses(file("A.swift", kind: .unusedResource), refs: ctx.refs, inventory: ctx.inventory),
                      "file rules still apply")
    }
}
