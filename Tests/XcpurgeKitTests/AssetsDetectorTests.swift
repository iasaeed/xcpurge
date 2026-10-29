import XCTest
@testable import XcpurgeKit

final class AssetsDetectorTests: XCTestCase {
    // MARK: - Goldens

    func testModularWorkspaceGolden() async throws {
        try await assertFindings(fixture: "ModularWorkspace", category: .assets)
    }

    func testSyncedAppGolden() async throws {
        try await assertFindings(fixture: "SyncedApp", category: .assets)
    }

    func testAssetsEdgeCasesGolden() async throws {
        try await assertFindings(fixture: "AssetsEdgeCases", category: .assets)
    }

    // MARK: - Behaviour

    private func findings(_ fixture: String, config: Config = Config()) async throws -> [String: Finding] {
        let ctx = try await FixtureSupport.context(fixture, config: config)
        var out: [String: Finding] = [:]
        for f in AssetsDetector().run(ctx) where f.kind != .dynamicLookup { out[f.name ?? f.path] = f }
        return out
    }

    func testModuleVisibility() async throws {
        let found = try await findings("ModularWorkspace")
        // `logo` lives in DesignSystem and is used only from App (which depends on it).
        XCTAssertNil(found["logo"])
        XCTAssertNil(found["ds_internal"])
        // `ds_isolated` is named only from Core, which cannot see DesignSystem's bundle.
        XCTAssertEqual(found["ds_isolated"]?.confidence, .high)
        XCTAssertEqual(found["ds_isolated"]?.module, "DesignSystem")
        // Kept by settings / Info.plist, the Icon Composer icon, the generated namespaced symbol.
        for kept in ["DarkIcon", "AccentColor", "WidgetBackground", "Glyph", "Brand/brand_mark", "hero", "widget_icon"] {
            XCTAssertNil(found[kept], kept)
        }
        XCTAssertEqual(found["LegacyIcon"]?.confidence, .medium)
        XCTAssertEqual(found["Unused-Bold.otf"]?.confidence, .medium)
        XCTAssertEqual(found["Unused-Bold.otf"]?.kind, .unusedFont)
        XCTAssertNil(found["Brand-Regular.ttf"])
    }

    func testUnattributedCatalogIsCheckedProjectWide() async throws {
        let root = try FixtureSupport.tempTree([
            "A/Assets.xcassets/orphan_asset.imageset/Contents.json": "{}",
            "A/Assets.xcassets/Contents.json": "{}",
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        // No project: the catalog is unattributed and visible project-wide.
        XCTAssertEqual(AssetsDetector().run(ctx).map(\.name), ["orphan_asset"])
    }

    func testGeneratedAssetSymbolsIndexWins() async throws {
        let dd = try FixtureSupport.tempTree([:])
        let sources = dd.appendingPathComponent("Build/Intermediates.noindex/Edge.build/Debug-iphonesimulator/Edge.build/DerivedSources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)
        // Built from another checkout: matched by catalog name + relative set path.
        let plist: [String: Any] = ["images": [[
            "catalogPath": "/elsewhere/Edge/Assets.xcassets", "relativePath": "./indexed-only.imageset",
            "swiftSymbol": "xcodeChoseThis", "objcSymbol": "ACImageNameIndexedOnly",
        ]], "colors": [], "symbols": []]
        try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
            .write(to: sources.appendingPathComponent(GeneratedAssetSymbolsIndex.fileName))

        var config = Config()
        config.derivedData = "/nonexistent-derived-data"
        let withoutIndex = try await findings("AssetsEdgeCases", config: config)
        XCTAssertEqual(withoutIndex["indexed-only"]?.confidence, .high)
        config.derivedData = dd.path
        let withIndex = try await findings("AssetsEdgeCases", config: config)
        XCTAssertNil(withIndex["indexed-only"])
    }

    func testEdgeCaseReasons() async throws {
        let found = try await findings("AssetsEdgeCases")
        XCTAssertEqual(found["tile_7"]?.confidence, .low)
        XCTAssertTrue(found["tile_7"]?.reasons.contains { $0.contains("EdgeApp.swift:") } == true)
        XCTAssertEqual(found["theme_dark"]?.confidence, .medium)
        XCTAssertEqual(found["badge_2"]?.confidence, .medium)
        XCTAssertEqual(found["odr_level"]?.confidence, .low)
        XCTAssertEqual(found["Icons/Settings/unused_gear"]?.path, "Edge/Assets.xcassets/Icons/Settings/unused_gear.imageset")
        for used in ["BrandColor", "noImage", "ABCLogo", "2fa", "default", "japan-street", "CaseHero", "Icons/Settings/gear",
                     "plain_used", "Characters", "config_data", "custom.symbol", "literal_image", "objc_icon", "ObjcTint",
                     "swiftgen_banner", "launch_logo", "LaunchBackground", "AppIcon", "Spare", "AccentColor",
                     "loose_used@2x.png", "loose_used@3x.png", "pad_only~ipad.png", "web_logo.svg", "Edge-Display.ttf"] {
            XCTAssertNil(found[used], used)
        }
        XCTAssertEqual(found["swiftgen_unused"]?.confidence, .high)
        XCTAssertEqual(found["Edge-Unused.otf"]?.confidence, .high)
    }

    func testIgnoredPatternLineAndIgnoreRules() async throws {
        let root = try FixtureSupport.tempTree([
            "Assets.xcassets/Contents.json": "{}",
            "Assets.xcassets/flag_de.imageset/Contents.json": "{}",
            "Assets.xcassets/flag_fr.imageset/Contents.json": "{}",
            "Flags.swift": """
            import UIKit
            func flag(_ code: String) -> UIImage? {
                UIImage(named: "flag_\\(code)") // xcpurge:ignore
            }
            func other(_ code: String) -> UIImage? { UIImage(named: "flag_f\\(code)") }
            """,
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        let found = AssetsDetector().run(ctx)
        XCTAssertEqual(found.filter { $0.kind == .dynamicLookup }.map(\.name), ["flag_f*"])
        let byName = Dictionary(uniqueKeysWithValues: found.filter { $0.kind == .unusedAsset }.map { ($0.name!, $0) })
        XCTAssertEqual(byName["flag_de"]?.confidence, .high)
        XCTAssertEqual(byName["flag_fr"]?.confidence, .low)
    }

    // MARK: - Building blocks

    func testCatalogReader() throws {
        let catalog = "Edge/Assets.xcassets"
        let assets = AssetCatalogReader.read(catalog: catalog, root: FixtureSupport.fixtureURL("AssetsEdgeCases"))
        let byName = Dictionary(uniqueKeysWithValues: assets.map { ($0.name, $0) })
        XCTAssertEqual(byName["Icons/Settings/gear"]?.namespace, ["Icons", "Settings"])
        XCTAssertEqual(byName["Icons/Settings/gear"]?.relativePath, "Icons/Settings/gear.imageset")
        XCTAssertEqual(byName["plain_used"]?.namespace, [])
        XCTAssertEqual(byName["odr_level"]?.odrTags, ["level1"])
        XCTAssertEqual(byName["Characters"]?.type, .spriteAtlas)
        XCTAssertEqual(byName["Characters"]?.aliases, ["hero_run"])
        XCTAssertNil(byName["hero_run"], "sprite atlas contents are part of the atlas")
        XCTAssertEqual(byName["custom.symbol"]?.type, .symbol)
        XCTAssertEqual(byName["Stickers"]?.type, .stickerPack)
        XCTAssertEqual(byName["Spare"]?.type, .appIcon)
        XCTAssertEqual(byName["dupe_one"]?.imageFiles, ["Edge/Assets.xcassets/dupe_one.imageset/dupe_one.png"])
        XCTAssertGreaterThan(byName["dupe_one"]?.sizeBytes ?? 0, 30)
    }

    func testLooseImageNormalizer() {
        XCTAssertEqual(LooseImageNormalizer.baseName("icon@2x~ipad.png"), "icon")
        XCTAssertEqual(LooseImageNormalizer.baseName("bg-dark@3x.png"), "bg")
        XCTAssertEqual(LooseImageNormalizer.candidates("icon@2x.png"), ["icon@2x.png", "icon@2x", "icon", "icon.png"])
        XCTAssertEqual(LooseImageNormalizer.candidates("plain.jpg"), ["plain.jpg", "plain"])
    }

    func testAppIconProtection() {
        let settings = BuildSettings(configurations: ["Release": [
            "ASSETCATALOG_COMPILER_APPICON_NAME": "AppIcon",
            "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES": "Dark \"Light Mode\"",
            "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS": "YES",
        ]])
        let id = ModuleID(container: "A.xcodeproj", name: "A")
        let plist: [String: JSONValue] = [
            "CFBundleIcons": .object(["CFBundleAlternateIcons": .object(["Retro": .object([:])])]),
            "UILaunchScreen": .object(["UIImageName": .string("splash")]),
        ]
        let graph = ModuleGraph(modules: [Module(id: id, kind: .app, productName: "A", moduleName: "A",
                                                 settings: settings, infoPlist: plist)])
        let protection = AppIconProtection(graph: graph)
        let consumers = graph.consumers(of: id)
        for name in ["AppIcon", "Dark", "Light Mode", "Retro", "splash"] {
            XCTAssertNotNil(protection.reason(for: [name], consumers: consumers), name)
        }
        XCTAssertNil(protection.reason(for: ["Other"], consumers: consumers))
        XCTAssertNotNil(protection.reason(for: ["Other"], consumers: consumers, includeAllApplies: true))
        XCTAssertNil(protection.reason(for: ["AppIcon"], consumers: [.unknown]))
    }
}
