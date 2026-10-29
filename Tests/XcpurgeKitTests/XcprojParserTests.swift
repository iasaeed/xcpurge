import XCTest
@testable import XcpurgeKit

final class XcprojParserTests: XCTestCase {
    private let root = URL(fileURLWithPath: "/tmp/xcproj-root")

    private let sample = """
    // JSON5: comments, trailing commas, unquoted keys
    {
      "default-configuration": "Release",
      configurations: ["Debug", "Release",],
      "build-settings": { "SWIFT_VERSION": "6.0", "SWIFT_ACTIVE_COMPILATION_CONDITIONS[config=Debug]": "DEBUG" },
      localizations: { development: "en" },
      packages: [ { kind: "local", path: "../Packages/Core" } ],
      files: [
        { kind: "folder", path: "App", "target-membership": ["App"],
          "file-types": { "Resources/data.bin": "file" },
          "opaque-folders": ["Web"],
          "membership-exceptions": [
            { target: "App", exclusions: ["Info.plist", "Old"] },
            { target: "AppTests", inclusions: ["Shared/Helpers.swift"] },
            { "build-phase": "App/copy/Embed", inclusions: ["Plugins/x.bundle"] },
          ],
        },
        { kind: "group", path: "Classic", children: [
            { path: "Legacy.m", "target-membership": ["App/compile-sources"] },
            { path: "Both.swift", "target-membership": [ { "build-phase": "App/compile-sources" }, "AppTests/compile-sources" ] },
            { path: "Orphan.swift" },
            { kind: "variant-group", path: "", name: "Main.storyboard", children: [
                { path: "Base.lproj/Main.storyboard", "target-membership": ["App/resources"] },
            ] },
          ],
        },
        { kind: "group", name: "Products", children: [
            { path: "<PRODUCTS>/App.app" },
            { path: "<PRODUCTS>/Widget.appex", "target-membership": ["App/copy/Embed Foundation Extensions"] },
          ],
        },
        { path: "<PROJECT>/Config/Base.xcconfig" },
        { path: "<USER:SRCROOT>/README.md" },
        { path: "<SDK>/System/Library/Frameworks/UIKit.framework" },
      ],
      targets: [
        { name: "App", id: "T1", "product-type": "application", product: "Products/App.app",
          dependencies: ["Widget", { kind: "package", package: "../Packages/Core", "product-name": "Core" }],
          "build-settings": { "INFOPLIST_FILE": "App/Info.plist", "PRODUCT_NAME[config=Release]": "Shipping" },
        },
        { name: "AppTests", id: "T2", "product-type": "bundle.unit-test", dependencies: ["App"] },
        { name: "Widget", id: "T3", "full-product-type": "com.apple.product-type.app-extension", product: "Products/Widget.appex" },
      ],
      "future-key": true,
    }
    """

    private func parse(_ text: String, diagnostics: Diagnostics = Diagnostics()) throws -> ProjectModel {
        try XcprojParser.parse(data: Data(text.utf8), xcodeproj: root.appendingPathComponent("App.xcodeproj"),
                               root: root, diagnostics: diagnostics)
    }

    func testTargetsDependenciesAndSettings() throws {
        let diagnostics = Diagnostics()
        let p = try parse(sample, diagnostics: diagnostics)
        XCTAssertEqual(p.format, .xcproj)
        XCTAssertEqual(p.targets.map(\.name), ["App", "AppTests", "Widget"])
        XCTAssertEqual(p.targets.map(\.kind), [.app, .unitTest, .appExtension])
        let app = try XCTUnwrap(p.target(named: "App"))
        XCTAssertEqual(app.dependencies, ["Widget"])
        XCTAssertEqual(app.productDependencies, [ProductDependency(packageDir: "../Packages/Core", package: "Core", product: "Core")])
        XCTAssertEqual(app.embeddedProducts, ["Widget.appex"])
        XCTAssertEqual(app.settings.value("SWIFT_VERSION"), "6.0")
        XCTAssertEqual(app.settings.value("SWIFT_ACTIVE_COMPILATION_CONDITIONS", configuration: "Debug"), "DEBUG")
        XCTAssertNil(app.settings.value("SWIFT_ACTIVE_COMPILATION_CONDITIONS", configuration: "Release"))
        XCTAssertEqual(app.productName, "Shipping")
        XCTAssertEqual(p.localPackages, ["../Packages/Core"])
        XCTAssertTrue(diagnostics.entries.contains { $0.message.contains("future-key") })
    }

    func testFileMembershipAndPaths() throws {
        let p = try parse(sample)
        let refs = Dictionary(uniqueKeysWithValues: p.fileRefs.map { ($0.path, $0.targets) })
        XCTAssertEqual(refs["Classic/Legacy.m"], ["App"])
        XCTAssertEqual(refs["Classic/Both.swift"], ["App", "AppTests"])
        XCTAssertEqual(refs["Classic/Orphan.swift"], [])
        XCTAssertEqual(refs["Classic/Base.lproj/Main.storyboard"], ["App"])
        XCTAssertNotNil(refs["Config/Base.xcconfig"])
        XCTAssertNotNil(refs["README.md"])
        XCTAssertFalse(refs.keys.contains { $0.contains("UIKit") || $0.hasSuffix(".app") || $0.hasSuffix(".appex") })
        XCTAssertEqual(p.groupPaths, ["Classic"])
        XCTAssertEqual(p.target(named: "App")?.members.contains("Classic/Legacy.m"), true)
    }

    func testFolderExceptions() throws {
        let p = try parse(sample)
        let folder = try XCTUnwrap(p.syncedGroups.first)
        XCTAssertEqual(folder.path, "App")
        XCTAssertEqual(folder.owners, ["App"])
        XCTAssertEqual(folder.explicitFolders, ["Web"])
        XCTAssertEqual(folder.explicitFileTypes, ["Resources/data.bin": "file"])
        XCTAssertEqual(folder.exceptions, [
            SyncedException(target: "App", sense: .exclusions, paths: ["Info.plist", "Old"]),
            SyncedException(target: "AppTests", sense: .inclusions, paths: ["Shared/Helpers.swift"]),
            SyncedException(target: "App", sense: .inclusions, isBuildPhase: true, paths: ["Plugins/x.bundle"]),
        ])
        XCTAssertEqual(p.target(named: "App")?.syncedGroupIDs, [folder.id])
    }

    func testUnknownCapabilityFallsBackToUnknownAttribution() throws {
        let diagnostics = Diagnostics()
        let p = try parse("""
        { "required-capabilities": ["glow in the dark files"], "default-configuration": "Release",
          files: [ { path: "a.swift", "target-membership": ["App/compile-sources"] } ],
          targets: [ { name: "App", id: "T", "product-type": "application" } ] }
        """, diagnostics: diagnostics)
        XCTAssertTrue(p.membershipUnknown)
        XCTAssertEqual(p.targets.map(\.name), ["App"])
        XCTAssertEqual(p.fileRefs.first?.targets, [])
        XCTAssertTrue(p.target(named: "App")!.members.isEmpty)
        XCTAssertTrue(diagnostics.entries.contains { $0.level == .warning && $0.message.contains("glow in the dark") })
    }

    func testInvalidJSONThrows() {
        XCTAssertThrowsError(try parse("{ files: [ }"))
    }

    func testPreferredFormatUsesNewerFile() throws {
        let dir = try FixtureSupport.tempTree(["A.xcodeproj/project.pbxproj": "{}", "A.xcodeproj/project.xcproj": "{}"])
        let proj = dir.appendingPathComponent("A.xcodeproj")
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: proj.appendingPathComponent("project.pbxproj").path)
        XCTAssertEqual(ProjectLocator.preferredFormat(xcodeproj: proj), .xcproj)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: proj.appendingPathComponent("project.pbxproj").path)
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_000)], ofItemAtPath: proj.appendingPathComponent("project.xcproj").path)
        XCTAssertEqual(ProjectLocator.preferredFormat(xcodeproj: proj), .pbxproj)
        try fm.removeItem(at: proj.appendingPathComponent("project.pbxproj"))
        XCTAssertEqual(ProjectLocator.preferredFormat(xcodeproj: proj), .xcproj)
    }
}
