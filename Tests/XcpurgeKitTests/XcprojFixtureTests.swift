import XCTest
@testable import XcpurgeKit

/// Discovery on the hand-written XcprojApp fixture (Xcode 27.2 JSON5 `project.xcproj` beside a stale
/// `project.pbxproj`), using Lane 0's `XcprojParser` and `ProjectLocator` as they are.
final class XcprojFixtureTests: XCTestCase {
    static let xcodeproj = FixtureSupport.fixtureURL("XcprojApp").appendingPathComponent("XcprojApp.xcodeproj")

    /// Git does not keep mtimes, so the stale pbxproj is made older than project.xcproj before every use.
    static func prepare() throws {
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)],
                             ofItemAtPath: xcodeproj.appendingPathComponent("project.pbxproj").path)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: xcodeproj.appendingPathComponent("project.xcproj").path)
    }

    private func context() async throws -> ScanContext {
        try Self.prepare()
        return try await FixtureSupport.context("XcprojApp", config: { var c = Config(); c.noSwift = true; return c }())
    }

    func testNewerXcprojWinsOverStalePbxproj() throws {
        try Self.prepare()
        XCTAssertEqual(ProjectLocator.preferredFormat(xcodeproj: Self.xcodeproj), .xcproj)
        // A pbxproj touched after the xcproj wins instead (conversion rolled back).
        let fm = FileManager.default
        let pbxproj = Self.xcodeproj.appendingPathComponent("project.pbxproj").path
        try fm.setAttributes([.modificationDate: Date().addingTimeInterval(60)], ofItemAtPath: pbxproj)
        defer { try? Self.prepare() }
        XCTAssertEqual(ProjectLocator.preferredFormat(xcodeproj: Self.xcodeproj), .pbxproj)
    }

    func testTargetsComeFromXcproj() async throws {
        let ctx = try await context()
        XCTAssertEqual(ctx.projects.map(\.format), [.xcproj])
        XCTAssertEqual(ctx.projects.first?.targets.map(\.name), ["App", "AppTests"], "StaleTarget only exists in the pbxproj")
        XCTAssertEqual(ctx.graph.module(ModuleID(container: "XcprojApp.xcodeproj", name: "App"))?.kind, .app)
        XCTAssertEqual(ctx.graph.module(ModuleID(container: "XcprojApp.xcodeproj", name: "AppTests"))?.dependsOn,
                       [ModuleID(container: "XcprojApp.xcodeproj", name: "App")])
        XCTAssertTrue(ctx.diagnostics.entries.contains { $0.level == .warning && $0.message.contains("future-key") },
                      "unknown top-level key warns")
    }

    func testFolderAndExplicitMembership() async throws {
        let ctx = try await context()
        func modules(_ path: String) -> Set<String>? { ctx.inventory.file(at: path).map { Set($0.modules.map(\.name)) } }
        XCTAssertEqual(modules("App/ContentView.swift"), ["App"])
        XCTAssertEqual(modules("App/XcprojAppApp.swift"), ["App"])
        XCTAssertEqual(modules("App/Shared/Helpers.swift"), ["App", "AppTests"], "inclusion for a non-owner target")
        XCTAssertEqual(modules("App/Old/Legacy.swift"), [], "exclusion for the owning target")
        XCTAssertEqual(ctx.inventory.file(at: "App/Old/Legacy.swift")?.inSourceRoot, true)
        XCTAssertEqual(modules("App/Info.plist"), ["App"], "excluded from the folder, but it is App's INFOPLIST_FILE")
        XCTAssertEqual(modules("Explicit/Tool.swift"), ["App"], "\"App/compile-sources\" file membership")
        XCTAssertEqual(modules("AppTests/AppTests.swift"), ["AppTests"])
        XCTAssertEqual(ctx.projects.first?.groupPaths, ["AppTests", "Explicit"])
    }
}
