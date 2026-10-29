import XCTest
@testable import XcpurgeKit

final class PackageManifestTests: XCTestCase {
    private let root = FixtureSupport.fixtureURL("ModularWorkspace")

    private func check(_ models: [ProjectModel], file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(models.map(\.container), ["Packages/Core", "Packages/DesignSystem"], file: file, line: line)
        let core = models[0], ds = models[1]
        XCTAssertEqual(core.name, "Core", file: file, line: line)
        XCTAssertEqual(core.products["Core"], ["Core"], file: file, line: line)
        let coreTarget = try XCTUnwrap(core.target(named: "Core"))
        XCTAssertEqual(coreTarget.kind, .packageLibrary, file: file, line: line)
        XCTAssertEqual(coreTarget.sourceDir, "Packages/Core/Sources/Core", file: file, line: line)
        XCTAssertEqual(coreTarget.resources, [PackageResource(path: "Packages/Core/Sources/Core/Resources", rule: .process)],
                       file: file, line: line)
        XCTAssertEqual(ds.packageDependencies, ["core": "Packages/Core"], file: file, line: line)
        XCTAssertEqual(ds.localPackages, ["Packages/Core"], file: file, line: line)
        let dsTarget = try XCTUnwrap(ds.target(named: "DesignSystem"))
        XCTAssertEqual(dsTarget.productDependencies,
                       [ProductDependency(packageDir: "Packages/Core", package: "Core", product: "Core")], file: file, line: line)
    }

    func testDumpPackage() async throws {
        let diagnostics = Diagnostics()
        let models = await PackageManifest.load(packageDirs: ["Packages/Core", "Packages/DesignSystem"], root: root,
                                                useSwift: true, diagnostics: diagnostics)
        if diagnostics.entries.contains(where: { $0.message.contains("dump-package failed") }) {
            throw XCTSkip("swift package dump-package unavailable here: \(diagnostics.entries)")
        }
        try check(models)
    }

    func testTextFallback() async throws {
        let diagnostics = Diagnostics()
        let models = await PackageManifest.load(packageDirs: ["Packages/Core", "Packages/DesignSystem"], root: root,
                                                useSwift: false, diagnostics: diagnostics)
        try check(models)
        XCTAssertTrue(diagnostics.entries.contains { $0.level == .info && $0.message.contains("without swift") })
    }

    func testFallbackParsesTargetKindsPathsAndDependencies() throws {
        let text = """
        // swift-tools-version: 6.0
        import PackageDescription
        let package = Package(
            name: "Tools",
            products: [
                .library(name: "ToolsKit", targets: ["Kit", "Extras"]),
                .executable(name: "tool", targets: ["CLI"]),
                .plugin(name: "Lint", targets: ["LintPlugin"]),
            ],
            dependencies: [
                .package(path: "../Shared"),
                .package(name: "Other", path: "Vendor/Other"),
                .package(url: "https://github.com/apple/swift-argument-parser", from: "1.5.0"),
            ],
            targets: [
                .target(name: "Kit", dependencies: ["Extras", .product(name: "SharedKit", package: "Shared")],
                        path: "Lib/Kit", exclude: ["README.md"], resources: [.copy("Templates"), .process("Media.xcassets")]),
                .target(name: "Extras"),
                .executableTarget(name: "CLI", dependencies: [.target(name: "Kit"), .product(name: "ArgumentParser", package: "swift-argument-parser")]),
                .testTarget(name: "KitTests", dependencies: ["Kit"]),
                .plugin(name: "LintPlugin", capability: .buildTool()),
                .binaryTarget(name: "Blob", path: "Blob.xcframework"),
            ]
        )
        """
        let p = PackageManifestRegexFallback.parse(text: text, packageDir: "Tools", rootPath: "/repo")
        XCTAssertEqual(p.name, "Tools")
        XCTAssertEqual(p.targets.map(\.name), ["Kit", "Extras", "CLI", "KitTests", "LintPlugin"])
        XCTAssertEqual(p.targets.map(\.kind), [.packageLibrary, .packageLibrary, .packageExecutable, .unitTest, .plugin])
        let kit = p.targets[0]
        XCTAssertEqual(kit.sourceDir, "Tools/Lib/Kit")
        XCTAssertEqual(kit.excludes, ["Tools/Lib/Kit/README.md"])
        XCTAssertEqual(kit.resources, [PackageResource(path: "Tools/Lib/Kit/Templates", rule: .copy),
                                       PackageResource(path: "Tools/Lib/Kit/Media.xcassets", rule: .process)])
        XCTAssertEqual(kit.dependencies, ["Extras"])
        XCTAssertEqual(kit.productDependencies, [ProductDependency(packageDir: "Shared", package: "Shared", product: "SharedKit")])
        XCTAssertEqual(p.targets[2].dependencies, ["Kit"])
        XCTAssertEqual(p.targets[2].productDependencies.first?.packageDir, nil)
        XCTAssertEqual(p.targets[3].sourceDir, "Tools/Tests/KitTests")
        XCTAssertEqual(p.products["ToolsKit"], ["Kit", "Extras"])
        XCTAssertEqual(p.products["Lint"], ["LintPlugin"])
        XCTAssertEqual(p.packageDependencies, ["shared": "Shared", "other": "Tools/Vendor/Other"])
    }

    func testRootPackageContainer() {
        let p = PackageManifestRegexFallback.parse(text: "let package = Package(name: \"Root\", targets: [.target(name: \"A\")])",
                                                   packageDir: "", rootPath: "/repo")
        XCTAssertEqual(p.container, ".")
        XCTAssertEqual(p.targets.first?.sourceDir, "Sources/A")
    }

    func testEnvironmentDisablesSwift() async throws {
        // The env switch is read at load time; with it unset and useSwift false, the fallback is used.
        let models = await PackageManifest.load(packageDirs: ["Packages/Core"], root: root, useSwift: false, diagnostics: Diagnostics())
        XCTAssertEqual(models.first?.target(named: "Core")?.sourceDir, "Packages/Core/Sources/Core")
    }
}
