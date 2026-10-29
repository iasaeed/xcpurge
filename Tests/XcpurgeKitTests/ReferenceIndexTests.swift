import XCTest
@testable import XcpurgeKit

final class ReferenceIndexTests: XCTestCase {
    private static func config() -> Config {
        var c = Config()
        c.noSwift = true
        return c
    }

    private func context() async throws -> ScanContext {
        try await FixtureSupport.context("ModularWorkspace", config: Self.config())
    }

    private let ds = ModuleID(container: "Packages/DesignSystem", name: "DesignSystem")
    private let core = ModuleID(container: "Packages/Core", name: "Core")
    private let app = ModuleID(container: "App/App.xcodeproj", name: "App")

    func testLiteralSitesWithContext() async throws {
        let refs = try await context().refs
        let hero = refs.sites("hero", kinds: .stringLiteral)
        XCTAssertEqual(hero.count, 1)
        XCTAssertEqual(refs.path(of: hero[0].file), "App/App/ContentView.swift")
        XCTAssertEqual(hero[0].line, 9)
        XCTAssertEqual(hero[0].context?.callee, "Image")
        XCTAssertEqual(refs.modules(of: hero[0].file), [app])
    }

    func testVisibilityRespectsModuleGraph() async throws {
        let ctx = try await context()
        let refs = ctx.refs
        XCTAssertEqual(refs.referenced("ds_isolated", kinds: .stringLiteral, from: ctx.graph.consumers(of: ds)), nil,
                       "only Core mentions ds_isolated and Core cannot see DesignSystem")
        XCTAssertEqual(refs.referenced("ds_isolated", kinds: .stringLiteral, from: ctx.graph.consumers(of: core)), .high)
        XCTAssertEqual(refs.referenced("logo", kinds: .memberSymbol, from: ctx.graph.consumers(of: ds)), .high)
        XCTAssertEqual(refs.referenced("HERO", kinds: .stringLiteral, from: ctx.graph.consumers(of: app)), .medium,
                       "case-insensitive-only match")
        XCTAssertNil(refs.referenced("unused_app_image", kinds: .all, from: ctx.graph.consumers(of: app)))
    }

    func testIBPlistAndBuildSettingReferences() async throws {
        let ctx = try await context()
        let refs = ctx.refs
        XCTAssertEqual(refs.sites("storyboard_bg", kinds: .ibAttribute).map { refs.path(of: $0.file) }.first,
                       "App/App/Main.storyboard")
        XCTAssertTrue(refs.sites("Unused-Bold.otf", kinds: .plistValue).contains { refs.path(of: $0.file) == "App/App/Info.plist" })
        let glyph = refs.sites("Glyph", kinds: .buildSetting)
        XCTAssertEqual(glyph.count, 1)
        XCTAssertEqual(glyph.first?.kind, .buildSetting("ASSETCATALOG_COMPILER_APPICON_NAME"))
        XCTAssertEqual(refs.modules(of: glyph[0].file), [app])
        XCTAssertTrue(refs.path(of: glyph[0].file).hasSuffix("(build settings)"))
        XCTAssertEqual(refs.sites("Main", kinds: .buildSetting).first?.kind, .buildSetting("INFOPLIST_KEY_UIMainStoryboardFile"))
        XCTAssertEqual(refs.sites("WidgetBackground", kinds: .buildSetting).count, 1)
    }

    func testDynamicPatternsAndIdentifiers() async throws {
        let ctx = try await context()
        let patterns = ctx.refs.dynamicPatterns
        XCTAssertTrue(patterns.contains { $0.prefix == "icon_" && $0.domain == .asset })
        XCTAssertTrue(patterns.contains { $0.prefix == "error_" && $0.domain == .string })
        let contentView = Int32(ctx.inventory.index(of: "App/App/ContentView.swift")!)
        XCTAssertTrue(ctx.refs.identifiersByFile[contentView]!.isSuperset(of: ["DSButton", "ResourceLoader", "onboardingStepTitle"]))
        XCTAssertNil(ctx.refs.identifiersByFile[Int32(ctx.inventory.index(of: "App/App/Data/unused.json")!)])
    }

    func testNonSourcesAreNotScanned() async throws {
        let ctx = try await context()
        // Contents.json and xcstrings name every asset / key; they must never count as references.
        XCTAssertTrue(ctx.refs.sites("core_unused").isEmpty)
        XCTAssertTrue(ctx.refs.sites("manual_unused").isEmpty)
    }

    func testDeterministicAcrossBuilds() async throws {
        let a = try await context().refs, b = try await context().refs
        XCTAssertEqual(a.references, b.references)
        XCTAssertEqual(a.dynamicPatterns, b.dynamicPatterns)
        XCTAssertEqual(a.sourcePaths, b.sourcePaths)
    }

    func testIgnoreMarkersAndSizeCap() async throws {
        let big = String(repeating: "x", count: Int(ReferenceIndex.maxFileSize) + 1)
        let root = try FixtureSupport.tempTree([
            "A.swift": "let a = 1\n// xcpurge:ignore\nlet b = UIImage(named: \"server_icon\")\n",
            "Big.json": big,
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        let file = Int32(ctx.inventory.index(of: "A.swift")!)
        XCTAssertTrue(ctx.refs.isIgnored(file: file, line: 2))
        XCTAssertTrue(ctx.refs.isIgnored(file: file, line: 3))
        XCTAssertFalse(ctx.refs.isIgnored(file: file, line: 1))
        XCTAssertTrue(ctx.diagnostics.entries.contains { $0.path == "Big.json" && $0.message.contains("5 MB") })
        XCTAssertEqual(ctx.graph.modules.count, 0)
        XCTAssertEqual(ctx.refs.modules(of: file), [.unknown])
    }
}
