import XCTest
@testable import XcpurgeKit

/// Orphans, ghosts, unused interface files and resources: fixture goldens plus focused temp-tree cases.
final class FilesDetectorTests: XCTestCase {
    // MARK: - Goldens (`expected-files.json`)

    func testModularWorkspaceGolden() async throws {
        try await assertFindings(fixture: "ModularWorkspace", category: .files)
    }

    func testSyncedAppGolden() async throws {
        try await assertFindings(fixture: "SyncedApp", category: .files)
    }

    func testClassicAppGolden() async throws {
        try await assertFindings(fixture: "ClassicApp", category: .files)
    }

    func testXcprojAppGolden() async throws {
        try XcprojFixtureTests.prepare()
        try await assertFindings(fixture: "XcprojApp", category: .files)
    }

    // MARK: - Helpers

    private func findings(_ root: URL, config: Config = Config()) async throws -> [Finding] {
        try await ScanEngine(root: root, config: config).run(categories: [.files]).findings
    }

    private func byPath(_ findings: [Finding], _ kind: FindingKind) -> [String: Finding] {
        Dictionary(uniqueKeysWithValues: findings.filter { $0.kind == kind }.map { ($0.path, $0) })
    }

    /// A one-target package (`Kit`) with the given manifest arguments; parsed with the regex fallback.
    private func package(_ files: [String: String], targetArgs: String = "") async throws -> [Finding] {
        var tree = files
        tree["Package.swift"] = """
        // swift-tools-version: 5.9
        import PackageDescription

        let package = Package(
            name: "Kit",
            targets: [
                .target(name: "Kit"\(targetArgs)),
            ]
        )
        """
        var config = Config()
        config.noSwift = true
        return try await findings(try FixtureSupport.tempTree(tree), config: config)
    }

    // MARK: - Orphans and ghosts

    func testClassicAppOrphansAndGhosts() async throws {
        let f = try await findings(FixtureSupport.fixtureURL("ClassicApp"))
        XCTAssertEqual(byPath(f, .orphanFile).keys.sorted(), ["ClassicApp/Orphan.swift"],
                       "headers, Info.plist and the bridging header are never orphans")
        XCTAssertEqual(byPath(f, .orphanFile)["ClassicApp/Orphan.swift"]?.confidence, .medium)
        XCTAssertEqual(byPath(f, .ghostReference)["ClassicApp/Ghost.swift"]?.confidence, .high)
        XCTAssertEqual(byPath(f, .ghostReference)["ClassicApp/Ghost.swift"]?.module, "ClassicApp")
    }

    func testSyncedFolderExclusionsAndInclusions() async throws {
        let f = try await findings(FixtureSupport.fixtureURL("SyncedApp"))
        let orphans = byPath(f, .orphanFile)
        XCTAssertEqual(orphans["SyncedApp/Excluded/Legacy.swift"]?.confidence, .medium)
        XCTAssertEqual(orphans["SyncedApp/Excluded/Legacy.swift"]?.module, "SyncedApp")
        XCTAssertNil(orphans["SyncedApp/Shared/TestHelpers.swift"], "added to the tests by an inclusion")
        XCTAssertNil(orphans["SyncedApp/Info.plist"], "excluded, but it is the INFOPLIST_FILE")
        XCTAssertNil(byPath(f, .deadSource)["SyncedApp/Excluded/Legacy.swift"], "orphans are reported once")
        XCTAssertNil(byPath(f, .unusedInterfaceFile)["SyncedApp/Launch.storyboard"], "INFOPLIST_KEY_UILaunchStoryboardName")
    }

    func testDevelopmentAssetPathsAreNotOrphans() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        let text = try String(contentsOf: pbxproj, encoding: .utf8).replacingOccurrences(
            of: "INFOPLIST_FILE = ClassicApp/Info.plist;",
            with: "DEVELOPMENT_ASSET_PATHS = \"\\\"ClassicApp/Preview Content\\\"\";\n\t\t\t\tINFOPLIST_FILE = ClassicApp/Info.plist;")
        try text.write(to: pbxproj, atomically: true, encoding: .utf8)
        let preview = root.appendingPathComponent("ClassicApp/Preview Content/sample.json")
        try FileManager.default.createDirectory(at: preview.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("{}".utf8).write(to: preview)
        let orphans = byPath(try await findings(root), .orphanFile)
        XCTAssertNil(orphans["ClassicApp/Preview Content/sample.json"])
        XCTAssertNotNil(orphans["ClassicApp/Orphan.swift"])
    }

    func testPackageExcludesAreLowOrphans() async throws {
        let f = try await package([
            "Sources/Kit/Kit.swift": "public enum Kit {}\n",
            "Sources/Kit/Disabled/Old.swift": "struct Old {}\n",
            "Sources/Kit/Notes.md": "notes\n",
        ], targetArgs: ", exclude: [\"Disabled\", \"Notes.md\"]")
        let orphans = byPath(f, .orphanFile)
        XCTAssertEqual(orphans.keys.sorted(), ["Sources/Kit/Disabled/Old.swift"], "docs are never orphans")
        XCTAssertEqual(orphans["Sources/Kit/Disabled/Old.swift"]?.confidence, .low)
        XCTAssertEqual(orphans["Sources/Kit/Disabled/Old.swift"]?.module, "Kit")
    }

    func testNoProjectMeansNoOrphansOrResources() async throws {
        let root = try FixtureSupport.tempTree(["Loose/a.swift": "struct Loose {}\n", "Loose/data.json": "{}"])
        let f = try await findings(root)
        XCTAssertTrue(f.allSatisfy { $0.kind == .deadSource }, "\(f)")
    }

    // MARK: - Interface files

    func testInterfaceFileLoaders() async throws {
        let xib = "<document><objects><view id=\"1\"/></objects></document>\n"
        let f = try await package([
            "Sources/Kit/Loaders.swift": """
            import UIKit
            let a = UINib(nibName: "ByNib", bundle: .module)
            let b = UIStoryboard(name: "ByStoryboard", bundle: .module)
            let c = String(describing: ByClass.self)
            let d = "Spelled"
            final class ByClass: UIView {}
            """,
            "Sources/Kit/ByNib.xib": xib,
            "Sources/Kit/ByStoryboard.storyboard": xib,
            "Sources/Kit/ByClass.xib": xib,
            "Sources/Kit/Spelled.xib": xib,
            "Sources/Kit/Referenced.storyboard": xib,
            "Sources/Kit/Host.storyboard": "<document><objects><viewControllerPlaceholder storyboardName=\"Referenced\" id=\"2\"/></objects></document>\n",
            "Sources/Kit/Nobody~ipad.xib": xib,
        ])
        let unused = byPath(f, .unusedInterfaceFile)
        for used in ["ByNib.xib", "ByStoryboard.storyboard", "ByClass.xib", "Referenced.storyboard"] {
            XCTAssertNil(unused["Sources/Kit/\(used)"], used)
        }
        XCTAssertEqual(unused["Sources/Kit/Spelled.xib"]?.confidence, .medium, "a bare literal is weak evidence")
        XCTAssertEqual(unused["Sources/Kit/Nobody~ipad.xib"]?.confidence, .high)
        XCTAssertEqual(unused["Sources/Kit/Host.storyboard"]?.confidence, .high)
    }

    // MARK: - Resources

    func testResourceUsageAndDowngrades() async throws {
        let f = try await package([
            "Sources/Kit/Use.swift": """
            import Foundation
            let config = Bundle.module.url(forResource: "settings", withExtension: "json")
            let data = Bundle.module.url(forResource: "Tables/rates.csv", withExtension: nil)
            let levels = Bundle.module.urls(forResourcesWithExtension: "gpx", subdirectory: nil)
            func intro(_ n: Int) -> URL? { Bundle.module.url(forResource: "intro_\\(n)", withExtension: "mp3") }
            let model = Classifier()
            """,
            "Sources/Kit/settings.json": "{}",
            "Sources/Kit/orphaned.json": "{}",
            "Sources/Kit/rates.csv": "a,b\n",
            "Sources/Kit/route1.gpx": "<gpx/>",
            "Sources/Kit/intro_1.mp3": "x",
            "Sources/Kit/Classifier.mlmodel": "x",
            "Sources/Kit/Feature.plist": "<plist><dict/></plist>",
            "Sources/Kit/Info.plist": "<plist><dict/></plist>",
            "Sources/Kit/Model.mlpackage/Data/weights.json": "{}",
        ], targetArgs: ", resources: [.process(\"settings.json\")]")
        let unused = byPath(f, .unusedResource)
        XCTAssertNil(unused["Sources/Kit/settings.json"])
        XCTAssertEqual(unused["Sources/Kit/orphaned.json"]?.confidence, .high)
        XCTAssertNil(unused["Sources/Kit/rates.csv"], "path-like literal names the file")
        XCTAssertEqual(unused["Sources/Kit/route1.gpx"]?.confidence, .low, "loaded by extension")
        XCTAssertEqual(unused["Sources/Kit/intro_1.mp3"]?.confidence, .low, "dynamic name")
        XCTAssertNil(unused["Sources/Kit/Classifier.mlmodel"], "generated model class")
        XCTAssertEqual(unused["Sources/Kit/Feature.plist"]?.confidence, .medium)
        XCTAssertNil(unused["Sources/Kit/Info.plist"])
        XCTAssertNil(unused["Sources/Kit/Model.mlpackage/Data/weights.json"], "inside an opaque model package")
    }

    func testFolderReferenceAndCopiedResourcesAreLow() async throws {
        let f = try await package([
            "Sources/Kit/Kit.swift": "enum Kit {}\n",
            "Sources/Kit/Web/page.html": "<html></html>",
        ], targetArgs: ", resources: [.copy(\"Web\")]")
        XCTAssertEqual(byPath(f, .unusedResource)["Sources/Kit/Web/page.html"]?.confidence, .low)
    }
}
