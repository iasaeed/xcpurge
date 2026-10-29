import XCTest
@testable import XcpurgeKit

final class TrashStoreTests: XCTestCase {
    func testMoveBackupAndManifest() throws {
        let root = try FixtureSupport.tempTree([
            "App/a.png": "png-bytes",
            "App/Assets.xcassets/x.imageset/Contents.json": "{}",
            "App/Localizable.xcstrings": "{\"strings\":{}}",
        ])
        let store = try TrashStore.begin(root: root, now: Date(timeIntervalSince1970: 1_800_000_000))
        try store.move("App/a.png")
        try store.move("App/Assets.xcassets/x.imageset")
        try store.backup("App/Localizable.xcstrings")
        try store.backup("App/Localizable.xcstrings")
        let fm = FileManager.default
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("App/a.png").path))
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("App/Localizable.xcstrings").path))
        XCTAssertEqual(store.entries.map(\.action), [.moved, .moved, .rewritten])
        XCTAssertEqual(store.entries.map(\.sizeBytes), [9, 2, 14])
        XCTAssertTrue(fm.fileExists(atPath: store.storedURL(store.entries[0]).path))
        XCTAssertTrue(store.sessionURL.path.contains(".xcpurge-trash/"))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("App/Localizable.xcstrings.bak").path))

        let sessions = try TrashStore.sessions(root: root)
        XCTAssertEqual(sessions.count, 1)
        XCTAssertEqual(sessions[0].id, store.sessionID)
        XCTAssertEqual(sessions[0].entries, store.entries)
        XCTAssertEqual(sessions[0].schemaVersion, 1)
    }

    func testSessionIDsAreUniqueAndSortedNewestFirst() throws {
        let root = try FixtureSupport.tempTree(["a": "", "b": "", "c": ""])
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try TrashStore.begin(root: root, now: t)
        let second = try TrashStore.begin(root: root, now: t)
        let third = try TrashStore.begin(root: root, now: t.addingTimeInterval(60))
        XCTAssertNotEqual(first.sessionID, second.sessionID, "unique even before either session is on disk")
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty, "sessions materialize on first move")
        try first.move("a")
        try second.move("b")
        try third.move("c")
        XCTAssertEqual(try TrashStore.sessions(root: root).first?.id, third.sessionID)
        XCTAssertEqual(TrashStore.sessionURL(root: root, id: first.sessionID).standardizedFileURL, first.sessionURL.standardizedFileURL)
    }

    func testMissingFileThrows() throws {
        let store = try TrashStore.begin(root: try FixtureSupport.tempTree(["a": ""]))
        XCTAssertThrowsError(try store.move("nope.png"))
        XCTAssertTrue(store.entries.isEmpty)
    }
}
