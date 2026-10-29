import XCTest
@testable import XcpurgeKit

final class ModuleGraphTests: XCTestCase {
    private func id(_ container: String, _ name: String) -> ModuleID { ModuleID(container: container, name: name) }
    private var app: ModuleID { id("App/App.xcodeproj", "App") }
    private var widget: ModuleID { id("App/App.xcodeproj", "AppWidget") }
    private var tests: ModuleID { id("App/App.xcodeproj", "AppTests") }
    private var core: ModuleID { id("Packages/Core", "Core") }
    private var ds: ModuleID { id("Packages/DesignSystem", "DesignSystem") }

    private func config(ignoreTests: Bool = false) -> Config {
        var c = Config()
        c.noSwift = true
        c.ignoreTestReferences = ignoreTests
        return c
    }

    func testModularWorkspaceEdges() async throws {
        let g = try await FixtureSupport.context("ModularWorkspace", config: config()).graph
        XCTAssertEqual(Set(g.modules.keys), [app, widget, tests, core, ds])
        XCTAssertEqual(g.module(app)?.dependsOn, [widget, core, ds])
        XCTAssertEqual(g.module(app)?.embeds, [widget])
        XCTAssertEqual(g.module(ds)?.dependsOn, [core])
        XCTAssertEqual(g.module(tests)?.dependsOn, [app])
        XCTAssertEqual(g.module(core)?.dependsOn, [])
    }

    func testConsumersClosure() async throws {
        let g = try await FixtureSupport.context("ModularWorkspace", config: config()).graph
        XCTAssertEqual(g.consumers(of: ds), [ds, app, tests, .unknown])
        XCTAssertEqual(g.consumers(of: core), [core, ds, app, tests, .unknown])
        XCTAssertEqual(g.consumers(of: widget), [widget, app, tests, .unknown])
        XCTAssertEqual(g.consumers(of: tests), [tests, .unknown])
        XCTAssertEqual(g.consumers(of: .unknown), [app, widget, tests, core, ds, .unknown])
        XCTAssertTrue(g.isVisible(from: [app], to: ds))
        XCTAssertFalse(g.isVisible(from: [core], to: ds), "Core does not depend on DesignSystem")
        XCTAssertTrue(g.isVisible(from: [], to: ds), "unattributed sites are visible everywhere")
    }

    func testIgnoreTestReferences() async throws {
        let g = try await FixtureSupport.context("ModularWorkspace", config: config(ignoreTests: true)).graph
        XCTAssertEqual(g.consumers(of: app), [app, .unknown])
        XCTAssertEqual(g.consumers(of: tests), [tests, .unknown], "a test module still sees itself")
    }

    func testModuleDetails() async throws {
        let g = try await FixtureSupport.context("ModularWorkspace", config: config()).graph
        let a = try XCTUnwrap(g.module(app))
        XCTAssertEqual(a.kind, .app)
        XCTAssertEqual(a.moduleName, "App")
        XCTAssertEqual(a.resourceBundleAccess, .main)
        XCTAssertEqual(a.rootPaths, ["App/App"])
        XCTAssertEqual(a.infoPlist["UIMainStoryboardFile"], .string("Main"))
        XCTAssertEqual(a.infoPlist["UIAppFonts"], .array([.string("Brand-Regular.ttf"), .string("Unused-Bold.otf")]))
        XCTAssertTrue(a.settingsFiles.contains("App/App/Info.plist"))
        XCTAssertEqual(g.module(ds)?.resourceBundleAccess, .module)
        XCTAssertEqual(g.module(ds)?.rootPaths, ["Packages/DesignSystem/Sources/DesignSystem"])
        XCTAssertEqual(g.module(widget)?.infoPlist["CFBundleDisplayName"], .string("Status"))
    }

    func testDirectGraphConstruction() {
        let a = Module(id: id("p", "A"), kind: .app, productName: "A", moduleName: "A", dependsOn: [id("p", "B")])
        let b = Module(id: id("p", "B"), kind: .framework, productName: "B", moduleName: "B", dependsOn: [id("p", "C")])
        let c = Module(id: id("p", "C"), kind: .framework, productName: "C", moduleName: "C")
        let t = Module(id: id("p", "T"), kind: .unitTest, productName: "T", moduleName: "T", dependsOn: [id("p", "C")])
        let g = ModuleGraph(modules: [a, b, c, t])
        XCTAssertEqual(g.consumers(of: id("p", "C")), [id("p", "A"), id("p", "B"), id("p", "C"), id("p", "T"), .unknown])
        XCTAssertEqual(g.consumers(of: id("x", "missing")), [id("x", "missing"), .unknown])
        XCTAssertEqual(ModuleGraph(modules: [a, b, c, t], ignoreTestReferences: true).consumers(of: id("p", "C")),
                       [id("p", "A"), id("p", "B"), id("p", "C"), .unknown])
    }
}
