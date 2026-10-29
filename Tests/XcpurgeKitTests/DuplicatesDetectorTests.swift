import XCTest
@testable import XcpurgeKit

final class DuplicatesDetectorTests: XCTestCase {
    func testModularWorkspaceGolden() async throws {
        try await assertFindings(fixture: "ModularWorkspace", category: .duplicates)
    }

    func testSyncedAppGolden() async throws {
        try await assertFindings(fixture: "SyncedApp", category: .duplicates)
    }

    func testAssetsEdgeCasesGolden() async throws {
        try await assertFindings(fixture: "AssetsEdgeCases", category: .duplicates)
    }

    func testGroupAcrossModulesSharesID() async throws {
        let ctx = try await FixtureSupport.context("ModularWorkspace")
        let found = DuplicatesDetector().run(ctx)
        XCTAssertEqual(Set(found.map(\.module)), ["App", "Core"])
        XCTAssertEqual(Set(found.compactMap(\.groupID)).count, 1)
        // Only the redundant copy counts as reclaimable.
        XCTAssertEqual(found.filter { $0.sizeBytes != nil }.count, 1)
        XCTAssertTrue(found.allSatisfy { $0.confidence == .high && $0.category == .duplicates })
    }

    func testCopiesInsideOneSetAreNotDuplicates() async throws {
        let root = try FixtureSupport.tempTree([
            "A.xcassets/x.imageset/x@2x.png": "same",
            "A.xcassets/x.imageset/x@3x.png": "same",
            "A.xcassets/y.imageset/y.png": "other",
            "A.xcassets/z.imageset/z.png": "other",
        ])
        let found = DuplicatesDetector().run(try await ScanEngine(root: root, config: Config()).makeContext())
        XCTAssertEqual(found.compactMap(\.name).sorted(), ["y", "z"])
    }
}
