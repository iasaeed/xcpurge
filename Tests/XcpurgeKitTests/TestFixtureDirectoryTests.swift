import XCTest
@testable import XcpurgeKit

/// Snapshot-test reference images (`__Snapshots__`, `ReferenceImages*`, `FailureDiffs`) are loaded by test name,
/// so they are never reported as unused or orphaned, but still count in `xcpurge size`.
final class TestFixtureDirectoryTests: XCTestCase {
    private func package() throws -> URL {
        try FixtureSupport.tempTree([
            "Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "Snap", targets: [.target(name: "App"), .testTarget(name: "AppTests", dependencies: ["App"])])
            """,
            "Sources/App/App.swift": "public struct App {}\n",
            "Sources/App/unused.png": "png",
            "Tests/AppTests/AppTests.swift": "import XCTest\n",
            "Tests/AppTests/__Snapshots__/AppTests/testA.1.png": "png",
            "Tests/AppTests/ReferenceImages_64/testB.png": "png",
            "Tests/AppTests/ReferenceImages/FailureDiffs/testC.png": "png",
        ])
    }

    private func paths(_ result: ScanResult, kind: FindingKind) -> [String] {
        result.findings.filter { $0.kind == kind }.map(\.path).sorted()
    }

    func testFixtureFolderFilesAreNotReportedByDefault() async throws {
        var config = Config()
        config.noSwift = true
        let result = try await ScanEngine(root: package(), config: config).run()
        XCTAssertEqual(paths(result, kind: .unusedAsset), ["Sources/App/unused.png"])
        XCTAssertEqual(paths(result, kind: .orphanFile), [])
    }

    func testEmptyListReportsThemAgain() async throws {
        var config = Config()
        config.noSwift = true
        config.testFixtureDirectories = []
        let result = try await ScanEngine(root: package(), config: config).run()
        XCTAssertEqual(paths(result, kind: .unusedAsset).filter { $0.contains("/__Snapshots__/") }.count, 1)
        XCTAssertTrue(paths(result, kind: .unusedAsset).contains("Tests/AppTests/ReferenceImages_64/testB.png"))
    }

    func testFixtureFilesStayInSizeTotals() async throws {
        var config = Config()
        config.noSwift = true
        let result = try await ScanEngine(root: package(), config: config).run()
        let total = SizeMeasurer.report(result).tree.files
        XCTAssertEqual(total, 7, "the three fixture images are still measured")
    }

    func testConfigKeyOverridesDefaults() throws {
        let dir = try FixtureSupport.tempTree([Config.fileName: #"{ "testFixtureDirectories": ["Goldens"] }"#])
        XCTAssertEqual(try Config.load(from: dir.appendingPathComponent(Config.fileName)).testFixtureDirectories, ["Goldens"])
        XCTAssertEqual(Config().testFixtureDirectories, ["__Snapshots__", "ReferenceImages", "ReferenceImages_64", "FailureDiffs"])
    }

    func testOnlyUnusedStyleKindsInsideFixtureFoldersAreDropped() {
        let dirs = Config.defaultTestFixtureDirectories
        func f(_ kind: FindingKind, _ path: String) -> Finding {
            Finding(kind: kind, category: .files, path: path, module: "M", confidence: .high)
        }
        XCTAssertTrue(ScanEngine.isTestFixture(f(.orphanFile, "T/__Snapshots__/a/b.png"), directories: dirs))
        XCTAssertTrue(ScanEngine.isTestFixture(f(.unusedAsset, "T/FailureDiffs/b.png"), directories: dirs))
        XCTAssertFalse(ScanEngine.isTestFixture(f(.ghostReference, "T/__Snapshots__/b.png"), directories: dirs))
        XCTAssertFalse(ScanEngine.isTestFixture(f(.orphanFile, "T/MySnapshots/b.png"), directories: dirs))
    }

    func testChangedListChangesBaselineHashButDefaultDoesNot() {
        let root = URL(fileURLWithPath: "/tmp/x")
        var config = Config()
        let base = BaselineFile.configHash(config, root: root)
        config.testFixtureDirectories = ["Other"]
        XCTAssertNotEqual(BaselineFile.configHash(config, root: root), base)
        config.testFixtureDirectories = Config.defaultTestFixtureDirectories
        XCTAssertEqual(BaselineFile.configHash(config, root: root), base)
    }

    /// Identical snapshot images are not duplicates, and do not make a real file a duplicate either.
    func testFixtureFolderFilesAreNotDuplicates() async throws {
        let tree = [
            "Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "Snap", targets: [.target(name: "App"), .testTarget(name: "AppTests", dependencies: ["App"])])
            """,
            "Sources/App/App.swift": "public struct App {}\n",
            "Sources/App/a.png": "same bytes", "Sources/App/b.png": "same bytes",
            "Tests/AppTests/AppTests.swift": "import XCTest\n",
            "Tests/AppTests/__Snapshots__/T1/x.png": "same bytes",
            "Tests/AppTests/__Snapshots__/T2/x.png": "same bytes",
            "Tests/AppTests/ReferenceImages/y.png": "other bytes", "Tests/AppTests/ReferenceImages_64/y.png": "other bytes",
        ]
        var config = Config()
        config.noSwift = true
        let root = try FixtureSupport.tempTree(tree)
        let dups = try await ScanEngine(root: root, config: config).run().findings.filter { $0.kind == .duplicate }.map(\.path).sorted()
        XCTAssertEqual(dups, ["Sources/App/a.png", "Sources/App/b.png"])
        config.testFixtureDirectories = []
        let all = try await ScanEngine(root: root, config: config).run().findings.filter { $0.kind == .duplicate }
        XCTAssertEqual(all.count, 6, "with the list emptied they are reported again")
    }
}
