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

    /// `open` reads a session back; `dropEntries` and `setVerify` rewrite its manifest; `reload` follows changes
    /// made through another store.
    func testOpenDropEntriesReloadAndVerifyRecord() throws {
        let root = try FixtureSupport.tempTree(["a.png": "a", "b.png": "bb", "T.strings": "t"])
        let store = try TrashStore.begin(root: root, now: Date(timeIntervalSince1970: 1_800_000_000))
        try store.move("a.png")
        try store.move("b.png")
        try store.backup("T.strings")
        XCTAssertThrowsError(try TrashStore.open(root: root, id: "nope"))

        let reopened = try TrashStore.open(root: root, id: store.sessionID)
        XCTAssertEqual(reopened.entries, store.entries)
        XCTAssertEqual(reopened.sessionURL.standardizedFileURL, store.sessionURL.standardizedFileURL)
        XCTAssertNil(reopened.verify)
        try reopened.dropEntries(paths: ["a.png"])
        XCTAssertEqual(reopened.entries.map(\.path), ["b.png", "T.strings"])
        XCTAssertEqual(store.entries.count, 3, "the other instance is stale until reloaded")
        try store.reload()
        XCTAssertEqual(store.entries.map(\.path), ["b.png", "T.strings"])

        let record = VerifyRecord(command: "true", startedAt: Date(timeIntervalSince1970: 1_800_000_001), builds: 2, outcome: .partial,
                                  blocked: [.init(path: "b.png", reason: "build failed without it", diagnostic: "error: x")])
        try store.setVerify(record)
        let onDisk = try XCTUnwrap(try TrashStore.sessions(root: root).first)
        XCTAssertEqual(onDisk.verify, record)
        XCTAssertEqual(onDisk.entries.map(\.path), ["b.png", "T.strings"])

        // A second backup after the entry was dropped replaces the stale stored copy.
        try reopened.dropEntries(paths: ["T.strings"])
        try Data("changed".utf8).write(to: root.appendingPathComponent("T.strings"))
        try reopened.backup("T.strings")
        XCTAssertEqual(try String(contentsOf: reopened.storedURL(reopened.entries[1]), encoding: .utf8), "changed")

        try reopened.reload()
        try FileManager.default.removeItem(at: reopened.sessionURL)
        try reopened.reload()
        XCTAssertTrue(reopened.entries.isEmpty, "a removed session reads as empty")
    }

    func testBlocklistRoundTrip() throws {
        let root = try FixtureSupport.tempTree(["a": ""])
        XCTAssertEqual(VerifyBlocklist.load(root: root), [])
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try VerifyBlocklist.add([.init(path: "b.png", reason: "r1", session: "s1", date: t),
                                 .init(path: "a.png", reason: "r2", session: "s1", date: t)], root: root)
        try VerifyBlocklist.add([.init(path: "b.png", reason: "newer", session: "s2", date: t.addingTimeInterval(60))], root: root)
        let entries = VerifyBlocklist.load(root: root)
        XCTAssertEqual(entries.map(\.path), ["a.png", "b.png"], "sorted, one per path")
        XCTAssertEqual(entries[1].reason, "newer")
        XCTAssertEqual(VerifyBlocklist.paths(root: root), ["a.png", "b.png"])
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty, "the list is not a session")
        try VerifyBlocklist.remove(["a.png"], root: root)
        XCTAssertEqual(VerifyBlocklist.paths(root: root), ["b.png"])
        try VerifyBlocklist.remove(["b.png"], root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: VerifyBlocklist.url(root: root).path))
    }
}
