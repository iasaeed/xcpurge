import XCTest
@testable import XcpurgeKit

final class SyncedFolderResolverTests: XCTestCase {
    private let files = ["App/main.swift", "App/Info.plist", "App/Old/a.swift", "App/Old/b.swift", "App/Shared/Helpers.swift",
                         "App/Bridge.h", "App/Public.h", "App/Assets.xcassets", "App/Scripts/run.sh"]

    func testOwnerExclusionsIncludingDirectories() {
        let g = SyncedGroup(id: "G", path: "App", owners: ["App"],
                            exceptions: [SyncedException(target: "App", sense: .byOwnership, paths: ["Info.plist", "Old"])])
        let m = SyncedFolderResolver.resolve(g, files: files)
        XCTAssertEqual(m["App"], ["App/main.swift", "App/Shared/Helpers.swift", "App/Assets.xcassets", "App/Scripts/run.sh"])
    }

    func testOtherTargetInclusionAndBuildPhaseException() {
        let g = SyncedGroup(id: "G", path: "App", owners: ["App"], exceptions: [
            SyncedException(target: "AppTests", sense: .byOwnership, paths: ["Shared/Helpers.swift"]),
            SyncedException(target: "App", sense: .inclusions, isBuildPhase: true, paths: ["Scripts/run.sh"]),
            SyncedException(target: "Tool", sense: .inclusions, isBuildPhase: true, paths: ["Scripts"]),
        ])
        let m = SyncedFolderResolver.resolve(g, files: files)
        XCTAssertEqual(m["AppTests"], ["App/Shared/Helpers.swift"])
        XCTAssertEqual(m["Tool"], ["App/Scripts/run.sh"])
        XCTAssertTrue(m["App"]!.contains("App/Shared/Helpers.swift"), "inclusion elsewhere does not remove from owner")
    }

    func testHeadersOnlyWithHeaderException() {
        let g = SyncedGroup(id: "G", path: "App", owners: ["App"], exceptions: [
            SyncedException(target: "App", sense: .byOwnership, paths: [], publicHeaders: ["Public.h"]),
        ])
        let m = SyncedFolderResolver.resolve(g, files: files)
        XCTAssertTrue(m["App"]!.contains("App/Public.h"))
        XCTAssertFalse(m["App"]!.contains("App/Bridge.h"))
    }

    func testExplicitFileTypeOverridesExtension() {
        let g = SyncedGroup(id: "G", path: "App", owners: ["App"], explicitFileTypes: ["Bridge.h": "text"])
        XCTAssertTrue(SyncedFolderResolver.resolve(g, files: files)["App"]!.contains("App/Bridge.h"))
    }

    func testXcprojExplicitSenses() {
        let g = SyncedGroup(id: "G", path: "App", owners: ["App", "Mac"], exceptions: [
            SyncedException(target: "Mac", sense: .exclusions, paths: ["main.swift"]),
            SyncedException(target: "App", sense: .inclusions, paths: ["Info.plist"]),
            SyncedException(target: "Widget", sense: .exclusions, paths: ["Old"]),
        ])
        let m = SyncedFolderResolver.resolve(g, files: files)
        XCTAssertFalse(m["Mac"]!.contains("App/main.swift"))
        XCTAssertTrue(m["App"]!.contains("App/main.swift"))
        XCTAssertTrue(m["App"]!.contains("App/Info.plist"), "inclusions for an owner do not exclude")
        XCTAssertNil(m["Widget"], "exclusions for a non-owner add nothing")
    }

    func testSyncedAppFixtureAttribution() async throws {
        let ctx = try await FixtureSupport.context("SyncedApp", config: { var c = Config(); c.noSwift = true; return c }())
        func modules(_ path: String) -> Set<String> { Set(ctx.inventory.file(at: path)?.modules.map(\.name) ?? []) }
        XCTAssertEqual(modules("SyncedApp/SyncedAppApp.swift"), ["SyncedApp"])
        XCTAssertEqual(modules("SyncedApp/Excluded/Legacy.swift"), [])
        XCTAssertEqual(ctx.inventory.file(at: "SyncedApp/Excluded/Legacy.swift")?.inSourceRoot, true)
        XCTAssertEqual(modules("SyncedApp/Shared/TestHelpers.swift"), ["SyncedApp", "SyncedAppTests"])
        XCTAssertEqual(modules("SyncedApp/Info.plist"), ["SyncedApp"], "INFOPLIST_FILE attributes the excluded plist")
        XCTAssertEqual(modules("SyncedApp/Launch.storyboard"), ["SyncedApp"])
        XCTAssertEqual(modules("SyncedApp/Web/index.html"), ["SyncedApp"], "opaque folder contents travel with the folder")
        XCTAssertEqual(modules("SyncedAppTests/SyncedAppTests.swift"), ["SyncedAppTests"])
        let app = try XCTUnwrap(ctx.graph.modules(named: "SyncedApp").first)
        XCTAssertEqual(app.infoPlist["UILaunchStoryboardName"], .string("Launch"))
        XCTAssertEqual(app.infoPlist["ITSAppUsesNonExemptEncryption"], .bool(false))
    }
}
