import XCTest
@testable import XcpurgeKit

final class PBXProjParserTests: XCTestCase {
    private let root = FixtureSupport.fixtureURL("ModularWorkspace")

    private func modularApp() throws -> ProjectModel {
        try PBXProjParser.parse(xcodeproj: root.appendingPathComponent("App/App.xcodeproj"), root: root,
                                diagnostics: Diagnostics())
    }

    func testTargetsKindsAndProducts() throws {
        let p = try modularApp()
        XCTAssertEqual(p.container, "App/App.xcodeproj")
        XCTAssertEqual(p.directory, "App")
        XCTAssertEqual(p.objectVersion, 77)
        XCTAssertEqual(p.targets.map(\.name), ["App", "AppWidget", "AppTests"])
        XCTAssertEqual(p.targets.map(\.kind), [.app, .appExtension, .unitTest])
        XCTAssertEqual(p.target(named: "AppWidget")?.productFile, "AppWidget.appex")
    }

    func testDependenciesEmbedsAndPackageProducts() throws {
        let p = try modularApp()
        let app = try XCTUnwrap(p.target(named: "App"))
        XCTAssertEqual(app.dependencies, ["AppWidget"])
        XCTAssertEqual(app.embeddedProducts, ["AppWidget.appex"])
        XCTAssertEqual(Set(app.productDependencies.map(\.product)), ["Core", "DesignSystem"])
        XCTAssertEqual(Set(app.productDependencies.compactMap(\.packageDir)), ["Packages/Core", "Packages/DesignSystem"])
        XCTAssertEqual(p.target(named: "AppTests")?.dependencies, ["App"])
        XCTAssertEqual(p.localPackages, ["Packages/Core", "Packages/DesignSystem"])
    }

    func testSynchronizedGroupsAndExceptions() throws {
        let p = try modularApp()
        XCTAssertEqual(p.syncedGroups.map(\.path), ["App/App", "App/AppTests", "App/AppWidget"])
        let app = try XCTUnwrap(p.syncedGroups.first { $0.path == "App/App" })
        XCTAssertEqual(app.owners, ["App"])
        XCTAssertEqual(app.exceptions, [SyncedException(target: "App", sense: .byOwnership, paths: ["Info.plist"])])
        XCTAssertEqual(p.target(named: "App")?.syncedGroupIDs, [app.id])
    }

    func testBuildSettingsWithXCConfigIncludeAndInherited() throws {
        let app = try XCTUnwrap(try modularApp().target(named: "App"))
        let s = app.settings
        XCTAssertEqual(s.configurationNames, ["Debug", "Release"])
        XCTAssertEqual(s.value("ASSETCATALOG_COMPILER_APPICON_NAME"), "Glyph")
        XCTAssertEqual(s.value("INFOPLIST_FILE"), "App/Info.plist")
        XCTAssertEqual(s.value("PRODUCT_NAME"), "App")
        XCTAssertEqual(s.value("PRODUCT_MODULE_NAME"), "App")
        XCTAssertEqual(s.value("SWIFT_VERSION"), "6.0", "from Shared.xcconfig via #include")
        XCTAssertEqual(s.value("OTHER_SWIFT_FLAGS"), "-DMODULAR", "$(inherited) with nothing below")
        XCTAssertEqual(s.value("SWIFT_ACTIVE_COMPILATION_CONDITIONS", configuration: "Debug"), "DEBUG")
        XCTAssertTrue(s.value("SRCROOT")?.hasSuffix("ModularWorkspace/App") == true)
        XCTAssertEqual(Set(app.settingsFiles), ["App/Configs/Base.xcconfig", "App/Configs/Shared.xcconfig"])
        XCTAssertTrue(s.isEnabled("STRING_CATALOG_GENERATE_SYMBOLS"))
    }

    /// Classic (non-synced) project: groups, build phases, variant groups, folder references, version groups.
    func testClassicGroupsAndBuildPhases() throws {
        let text = """
        // !$*UTF8*$!
        { archiveVersion = 1; objectVersion = 54; rootObject = P0;
          objects = {
            P0 = { isa = PBXProject; mainGroup = G0; targets = (T0); buildConfigurationList = L0; };
            G0 = { isa = PBXGroup; children = (G1, F9, PR); sourceTree = "<group>"; };
            G1 = { isa = PBXGroup; children = (F1, F2, V1, D1, BF); path = Classic; sourceTree = "<group>"; };
            F1 = { isa = PBXFileReference; path = AppDelegate.swift; sourceTree = "<group>"; };
            F2 = { isa = PBXFileReference; path = Ghost.swift; sourceTree = "<group>"; };
            V1 = { isa = PBXVariantGroup; children = (V2, V3); name = Main.storyboard; sourceTree = "<group>"; };
            V2 = { isa = PBXFileReference; name = Base; path = Base.lproj/Main.storyboard; sourceTree = "<group>"; };
            V3 = { isa = PBXFileReference; name = fr; path = fr.lproj/Main.strings; sourceTree = "<group>"; };
            D1 = { isa = XCVersionGroup; children = (D2); currentVersion = D2; path = Model.xcdatamodeld; sourceTree = "<group>"; };
            D2 = { isa = PBXFileReference; path = Model.xcdatamodel; sourceTree = "<group>"; };
            BF = { isa = PBXFileReference; lastKnownFileType = folder; path = Web; sourceTree = "<group>"; };
            F9 = { isa = PBXFileReference; path = README.md; sourceTree = SOURCE_ROOT; };
            PR = { isa = PBXFileReference; path = Classic.app; sourceTree = BUILT_PRODUCTS_DIR; };
            T0 = { isa = PBXNativeTarget; name = Classic; productType = "com.apple.product-type.application";
                   productReference = PR; buildPhases = (S0, R0); buildConfigurationList = L1; };
            S0 = { isa = PBXSourcesBuildPhase; files = (B1); };
            R0 = { isa = PBXResourcesBuildPhase; files = (B2, B3, B4); };
            B1 = { isa = PBXBuildFile; fileRef = F1; };
            B2 = { isa = PBXBuildFile; fileRef = V1; };
            B3 = { isa = PBXBuildFile; fileRef = BF; };
            B4 = { isa = PBXBuildFile; fileRef = D1; };
            L0 = { isa = XCConfigurationList; buildConfigurations = (C0); };
            C0 = { isa = XCBuildConfiguration; name = Release; buildSettings = { SDKROOT = iphoneos; }; };
            L1 = { isa = XCConfigurationList; buildConfigurations = (C1); };
            C1 = { isa = XCBuildConfiguration; name = Release; buildSettings = { PRODUCT_NAME = "My App"; OTHER_LDFLAGS = ("-ObjC", "-lz"); }; };
            X1 = { isa = PBXMysteryObject; };
          };
        }
        """
        let root = URL(fileURLWithPath: "/tmp/fixture-root")
        let diagnostics = Diagnostics()
        let p = try PBXProjParser.parse(data: Data(text.utf8), xcodeproj: root.appendingPathComponent("Classic.xcodeproj"),
                                        root: root, diagnostics: diagnostics)
        XCTAssertEqual(p.objectVersion, 54)
        let t = try XCTUnwrap(p.target(named: "Classic"))
        XCTAssertEqual(t.members, ["Classic/AppDelegate.swift", "Classic/Base.lproj/Main.storyboard",
                                   "Classic/fr.lproj/Main.strings", "Classic/Web", "Classic/Model.xcdatamodeld"])
        XCTAssertEqual(t.productName, "My App")
        XCTAssertEqual(t.settings.value("PRODUCT_MODULE_NAME"), "My_App")
        XCTAssertEqual(t.settings.values("OTHER_LDFLAGS"), ["-ObjC", "-lz"])
        let refs = Dictionary(uniqueKeysWithValues: p.fileRefs.map { ($0.path, $0) })
        XCTAssertEqual(refs["Classic/Ghost.swift"]?.targets, [])
        XCTAssertEqual(refs["Classic/AppDelegate.swift"]?.targets, ["Classic"])
        XCTAssertEqual(refs["Classic/Web"]?.isFolder, true)
        XCTAssertEqual(refs["README.md"]?.targets, [])
        XCTAssertNil(refs["Classic/Model.xcdatamodeld/Model.xcdatamodel"], "version-group children are inside the unit")
        XCTAssertNil(refs["Classic.app"], "products are not file references")
        XCTAssertEqual(p.groupPaths, ["Classic"])
        XCTAssertTrue(diagnostics.entries.contains { $0.message.contains("PBXMysteryObject") })
    }

    func testRejectsNonPlist() {
        XCTAssertThrowsError(try PBXProjParser.parse(data: Data("nope".utf8), xcodeproj: URL(fileURLWithPath: "/x/A.xcodeproj"),
                                                     root: URL(fileURLWithPath: "/x"), diagnostics: Diagnostics()))
    }

    /// MixedApp mixes the four kinds of membership in one pbxproj: a classic group file (explicit PBXBuildFile),
    /// a synchronized-folder file, a file excluded by the folder's exception set, and the children of a blue
    /// folder reference (copied as a whole). A file in no group at all stays unattributed.
    func testMixedProjectAttributesEveryMembershipKind() async throws {
        let ctx = try await FixtureSupport.context("MixedApp")
        let project = try XCTUnwrap(ctx.projects.first)
        XCTAssertEqual(project.objectVersion, 77)
        XCTAssertEqual(project.targets.map(\.name), ["MixedApp", "MixedAppTests"])
        XCTAssertEqual(project.syncedGroups.map(\.path).sorted(), ["MixedAppTests", "Modern"])
        XCTAssertTrue(project.fileRefs.contains { $0.path == "Content" && $0.isFolder })

        func modules(_ path: String) -> Set<String>? { ctx.inventory.file(at: path).map { Set($0.modules.map(\.name)) } }
        XCTAssertEqual(modules("Legacy/Legacy.swift"), ["MixedApp"], "group file via PBXBuildFile")
        XCTAssertEqual(modules("Legacy/LegacyAssets.xcassets"), ["MixedApp"])
        XCTAssertEqual(modules("Legacy/en.lproj/Localizable.strings"), ["MixedApp"], "PBXVariantGroup child")
        XCTAssertEqual(modules("Legacy/fr.lproj/Localizable.strings"), ["MixedApp"])
        XCTAssertEqual(modules("Modern/MixedAppApp.swift"), ["MixedApp"], "synchronized folder file")
        XCTAssertEqual(modules("Modern/ModernAssets.xcassets"), ["MixedApp"])
        XCTAssertEqual(modules("Modern/Excluded.swift"), [], "excluded by the exception set")
        XCTAssertEqual(ctx.inventory.file(at: "Modern/Excluded.swift")?.inSourceRoot, true)
        XCTAssertEqual(modules("Content/a.json"), ["MixedApp"], "blue folder reference child")
        XCTAssertEqual(modules("Content/b.json"), ["MixedApp"])
        XCTAssertEqual(modules("MixedAppTests/MixedAppTests.swift"), ["MixedAppTests"])
        XCTAssertEqual(modules("Stray/Stray.swift"), [], "in no group and no synchronized folder")
        XCTAssertEqual(ctx.inventory.file(at: "Stray/Stray.swift")?.inSourceRoot, false)
    }

    /// Review #5: another project's product (`sourceTree = BUILT_PRODUCTS_DIR`) in link / embed phases and a
    /// foreign container proxy are recorded, not dropped.
    func testCrossProjectProductsAndProxies() throws {
        let text = """
        { archiveVersion = 1; objectVersion = 54; rootObject = P0;
          objects = {
            P0 = { isa = PBXProject; mainGroup = G0; targets = (T0); };
            G0 = { isa = PBXGroup; children = (FW, PR, KP); sourceTree = "<group>"; };
            KP = { isa = PBXFileReference; path = ../Kit/Kit.xcodeproj; sourceTree = "<group>"; };
            FW = { isa = PBXFileReference; explicitFileType = wrapper.framework; path = Kit.framework; sourceTree = BUILT_PRODUCTS_DIR; };
            PR = { isa = PBXFileReference; path = App.app; sourceTree = BUILT_PRODUCTS_DIR; };
            T0 = { isa = PBXNativeTarget; name = App; productType = "com.apple.product-type.application"; productReference = PR; buildPhases = (F0, E0); dependencies = (D0); };
            D0 = { isa = PBXTargetDependency; targetProxy = X0; };
            X0 = { isa = PBXContainerItemProxy; containerPortal = KP; proxyType = 1; remoteGlobalIDString = K0; remoteInfo = Kit; };
            F0 = { isa = PBXFrameworksBuildPhase; files = (B1); };
            E0 = { isa = PBXCopyFilesBuildPhase; dstSubfolderSpec = 10; files = (B2); };
            B1 = { isa = PBXBuildFile; fileRef = FW; };
            B2 = { isa = PBXBuildFile; fileRef = FW; };
          };
        }
        """
        let root = URL(fileURLWithPath: "/tmp/fixture-root")
        let model = try PBXProjParser.parse(data: Data(text.utf8), xcodeproj: root.appendingPathComponent("App/App.xcodeproj"),
                                            root: root, diagnostics: Diagnostics())
        let app = try XCTUnwrap(model.target(named: "App"))
        XCTAssertEqual(app.linkedProducts, ["Kit.framework"])
        XCTAssertEqual(app.embeddedProducts, ["Kit.framework"])
        XCTAssertEqual(app.externalDependencies, [ExternalTargetDependency(container: "Kit/Kit.xcodeproj", target: "Kit")])
        XCTAssertFalse(model.fileRefs.contains { $0.path.hasSuffix("Kit.framework") }, "built products are not files")
    }
}
