import XCTest
@testable import XcpurgeKit

final class FileWalkerTests: XCTestCase {
    private func tree() throws -> URL {
        try FixtureSupport.tempTree([
            "App/main.swift": "",
            "App/Assets.xcassets/Contents.json": "{}",
            "App/Assets.xcassets/a.imageset/Contents.json": "{}",
            "App/en.lproj/Localizable.strings": "\"a\" = \"b\";",
            "App/Model.xcdatamodeld/Model.xcdatamodel/contents": "<model/>",
            "App/Glyph.icon/icon.json": "{}",
            "App/Settings.bundle/Root.plist": "",
            "App.xcodeproj/project.pbxproj": "{}",
            "App.xcodeproj/project.xcworkspace/contents.xcworkspacedata": "",
            "Root.xcworkspace/contents.xcworkspacedata": "",
            "Package.swift": "",
            "Packages/Kit/Package.swift": "",
            "Packages/Kit/Sources/Kit/Kit.swift": "",
            "Packages/Kit/.build/debug/x.swift": "",
            ".git/HEAD": "",
            ".hidden.swift": "",
            "build/Intermediates/x.swift": "",
            "DerivedData/App-abc/x.swift": "",
            "Pods/Alamofire/a.swift": "",
            "node_modules/x/index.js": "",
            "Carthage/Build/x.swift": "",
            "Carthage/Checkouts/y.swift": "",
            "CustomDD/Build/Intermediates.noindex/x.swift": "",
            "CustomDD/SourcePackages/workspace-state.json": "{}",
            "Scratch/workspace-state.json": "{}",
            "Scratch/x.swift": "",
            "Output/Old.app/Info.plist": "",
            "Vendor/Lib/lib.swift": "",
            ".xcpurge-trash/s/files/a.png": "",
        ])
    }

    func testSkipRulesUnitsAndContainers() throws {
        let result = FileWalker().walk(root: try tree())
        let paths = Set(result.files.map(\.path))
        XCTAssertEqual(paths, ["App/main.swift", "App/Assets.xcassets", "App/en.lproj/Localizable.strings",
                               "App/Model.xcdatamodeld", "App/Glyph.icon", "App/Settings.bundle", "Package.swift",
                               "Packages/Kit/Package.swift", "Packages/Kit/Sources/Kit/Kit.swift", "Vendor/Lib/lib.swift"])
        XCTAssertEqual(result.xcodeprojs, ["App.xcodeproj"])
        XCTAssertEqual(result.workspaces, ["Root.xcworkspace"])
        XCTAssertEqual(result.packages, ["", "Packages/Kit"])
        let catalog = try XCTUnwrap(result.files.first { $0.path == "App/Assets.xcassets" })
        XCTAssertTrue(catalog.isUnit)
        XCTAssertEqual(catalog.kind, .assetCatalog)
        XCTAssertEqual(catalog.size, 4)
        XCTAssertEqual(result.files.first { $0.path == "App/en.lproj/Localizable.strings" }?.kind, .strings)
    }

    func testIncludePodsAndExcludes() throws {
        let root = try tree()
        let withPods = FileWalker(includePods: true, excludes: [Glob("Vendor/**"), Glob("*.strings"), Glob("Packages/**")])
            .walk(root: root)
        let paths = Set(withPods.files.map(\.path))
        XCTAssertTrue(paths.contains("Pods/Alamofire/a.swift"))
        // Review #7: excluded files stay in the inventory as reference sources; only containers are not discovered.
        XCTAssertTrue(paths.contains("Vendor/Lib/lib.swift"))
        XCTAssertTrue(paths.contains("App/en.lproj/Localizable.strings"))
        XCTAssertFalse(withPods.packages.contains("Packages/Kit"))
        XCTAssertTrue(withPods.packages.contains(""))
    }

    func testGlob() {
        XCTAssertTrue(Glob("Vendor/**").matches("Vendor/a/b.swift"))
        XCTAssertTrue(Glob("Vendor").matches("Vendor/a/b.swift"))
        XCTAssertTrue(Glob("Generated").matches("App/Generated/x.swift"))
        XCTAssertTrue(Glob("**/Generated/*.swift").matches("App/Generated/x.swift"))
        XCTAssertFalse(Glob("**/Generated/*.swift").matches("App/Generated/sub/x.png"))
        XCTAssertTrue(Glob("*.png").matches("a/b/c.png"))
        XCTAssertTrue(Glob("icon_[0-9]?.png").matches("icon_12.png"))
        XCTAssertFalse(Glob("icon_[!0-9].png").matches("icon_1.png"))
        XCTAssertTrue(Glob("/App/*.swift").matches("App/main.swift"))
        XCTAssertFalse(Glob("App/*.swift").matches("Other/App/main.swift"))
        XCTAssertFalse(Glob("").matches("anything"))
    }

    func testRelPath() {
        XCTAssertEqual(RelPath.normalize("a/./b/../c//d"), "a/c/d")
        XCTAssertEqual(RelPath.normalize("../x"), "../x")
        XCTAssertEqual(RelPath.join("App", "../Packages/Core"), "Packages/Core")
        XCTAssertEqual(RelPath.relative("/r/a/b", to: "/r"), "a/b")
        XCTAssertEqual(RelPath.relative("/r", to: "/r"), "")
        XCTAssertEqual(RelPath.relative("/other/x", to: "/r/s"), "../../other/x")
        XCTAssertTrue(RelPath.isUnder("a/b", "a"))
        XCTAssertFalse(RelPath.isUnder("ab/c", "a"))
        XCTAssertEqual(RelPath.stem("Fonts/Brand-Regular.ttf"), "Brand-Regular")
        // `swift package` reports /private/tmp, Foundation /tmp: both forms must meet.
        XCTAssertEqual(RelPath.relative("/private/tmp/r/Packages/Core", to: "/tmp/r"), "Packages/Core")
        XCTAssertEqual(RelPath.relative("/var/folders/x/a", to: "/private/var/folders/x"), "a")
        XCTAssertEqual(RelPath.normalize("/private/var"), "/var")
        XCTAssertEqual(RelPath.normalize("/private/varnish/x"), "/private/varnish/x")
    }
}
