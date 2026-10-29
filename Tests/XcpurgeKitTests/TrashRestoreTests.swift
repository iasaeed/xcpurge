import XCTest
@testable import XcpurgeKit

final class TrashRestoreTests: XCTestCase {
    /// Every file (with bytes) and directory under `root`, keyed by relative path.
    private func snapshot(_ root: URL) throws -> [String: Data] {
        var out: [String: Data] = [:]
        let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isDirectoryKey])!
        for case let url as URL in e {
            let rel = RelPath.relative(url.standardizedFileURL.path, to: root.standardizedFileURL.path)
            let isDir = try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory ?? false
            out[rel] = isDir ? Data("<dir>".utf8) : try Data(contentsOf: url)
        }
        return out
    }

    private func trashAll(_ root: URL) async throws -> (ActionReport, TrashStore) {
        let result = try await ScanEngine(root: root, config: Config()).run(categories: [.assets, .duplicates])
        let store = try TrashStore.begin(root: result.context.root)
        let report = try Trash(store: store).apply(result.findings, context: result.context)
        return (report, store)
    }

    /// `files --delete`: orphans and unused resources move to the trash, project references go, restore is exact.
    func testFilesRoundTripIsByteIdentical() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let result = try await ScanEngine(root: root, config: Config()).run(categories: [.files])
        let store = try TrashStore.begin(root: result.context.root)
        let report = try Trash(store: store).apply(result.findings, context: result.context)
        XCTAssertEqual(Set(report.moved), ["ClassicApp/Orphan.swift", "ClassicApp/Unused.plist"])
        XCTAssertEqual(report.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        XCTAssertEqual(Set(report.skipped.map(\.path)), ["ClassicApp/DeadObjC.m", "ClassicApp/Ghost.swift"],
                       "dead-source and ghost findings are never deleted")
        let edited = try String(contentsOf: root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertFalse(edited.contains("Unused.plist"))
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    func testClassicProjectRoundTripIsByteIdentical() async throws {
        let root = try FixtureSupport.copyToTemp("AssetsEdgeCases")
        let before = try snapshot(root)
        let pbxproj = root.appendingPathComponent("Edge.xcodeproj/project.pbxproj")
        let originalProject = try String(contentsOf: pbxproj, encoding: .utf8)

        let (report, store) = try await trashAll(root)
        for path in ["Edge/Assets.xcassets/truly_unused.imageset", "Edge/Assets.xcassets/Icons/Settings/unused_gear.imageset",
                     "Edge/Images/loose_unused.png", "Edge/Fonts/Edge-Unused.otf"] {
            XCTAssertTrue(report.moved.contains(path), path)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), path)
            XCTAssertTrue(FileManager.default.fileExists(atPath: store.sessionURL.appendingPathComponent("files/" + path).path))
        }
        XCTAssertEqual(report.rewritten, ["Edge.xcodeproj/project.pbxproj"])
        XCTAssertTrue(report.skipped.allSatisfy { $0.reason.contains("not deleted") }, "\(report.skipped)")

        let edited = try String(contentsOf: pbxproj, encoding: .utf8)
        XCTAssertFalse(edited.contains("loose_unused.png"))
        XCTAssertFalse(edited.contains("Edge-Unused.otf"))
        XCTAssertTrue(edited.contains("loose_used@2x.png"))
        // Only whole lines were removed: every remaining line is an original line, in order.
        let originalLines = originalProject.split(separator: "\n", omittingEmptySubsequences: false)
        var cursor = originalLines.startIndex
        for line in edited.split(separator: "\n", omittingEmptySubsequences: false) {
            guard let next = originalLines[cursor...].firstIndex(of: line) else { return XCTFail("new line: \(line)") }
            cursor = originalLines.index(after: next)
        }
        let model = try PBXProjParser.parse(xcodeproj: root.appendingPathComponent("Edge.xcodeproj"), root: root,
                                            diagnostics: Diagnostics())
        XCTAssertFalse(model.fileRefs.contains { $0.path == "Edge/Images/loose_unused.png" })
        XCTAssertTrue(model.target(named: "Edge")!.members.contains("Edge/Images/loose_used@2x.png"))

        let restored = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(Set(restored.moved), Set(report.moved))
        XCTAssertEqual(restored.rewritten, ["Edge.xcodeproj/project.pbxproj"])
        XCTAssertTrue(restored.skipped.isEmpty)
        XCTAssertEqual(try snapshot(root), before)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
    }

    func testSyncedFolderProjectNeedsNoProjectEdit() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        let before = try snapshot(root)
        let (report, _) = try await trashAll(root)
        XCTAssertTrue(report.moved.contains("App/App/Fonts/Unused-Bold.otf"))
        XCTAssertTrue(report.moved.contains("App/App/Assets.xcassets/LegacyIcon.appiconset"))
        XCTAssertTrue(report.rewritten.isEmpty)
        // Duplicates and dynamic lookups are never deleted.
        XCTAssertTrue(report.skipped.contains { $0.reason.hasPrefix("duplicate") })
        XCTAssertTrue(report.skipped.contains { $0.reason.hasPrefix("dynamicLookup") })
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    func testRestoreChoosesSessionAndRefusesToOverwrite() throws {
        let root = try FixtureSupport.tempTree(["a.png": "a", "b.png": "b"])
        let first = try TrashStore.begin(root: root, now: Date(timeIntervalSince1970: 1_800_000_000))
        try first.move("a.png")
        let second = try TrashStore.begin(root: root, now: Date(timeIntervalSince1970: 1_800_000_060))
        try second.move("b.png")
        XCTAssertThrowsError(try Restore.run(root: root, sessionID: "nope"))

        try Data("new a".utf8).write(to: root.appendingPathComponent("a.png"))
        let blocked = try Restore.run(root: root, sessionID: first.sessionID)
        XCTAssertEqual(blocked.skipped.map(\.path), ["a.png"])
        XCTAssertEqual(try String(contentsOf: root.appendingPathComponent("a.png"), encoding: .utf8), "new a")

        let newest = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(newest.moved, ["b.png"])
        XCTAssertEqual(try TrashStore.sessions(root: root).map(\.id), [first.sessionID])
    }

    func testEditorRemovesOneLineAndMultiLineObjects() {
        let text = """
        \t\tB1 /* a.png in Resources */ = {isa = PBXBuildFile; fileRef = F1 /* a.png */; };
        \t\tB2 /* b.png in Resources */ = {isa = PBXBuildFile; fileRef = F2 /* b.png */; };
        \t\tF1 /* a.png */ = {
        \t\t\tisa = PBXFileReference;
        \t\t\tpath = a.png;
        \t\t};
        \t\tF2 /* b.png */ = {isa = PBXFileReference; path = b.png; sourceTree = "<group>"; };
        \t\t\tchildren = (
        \t\t\t\tF1 /* a.png */,
        \t\t\t\tF2 /* b.png */,
        \t\t\t);
        \t\t\tfiles = (
        \t\t\t\tB1 /* a.png in Resources */,
        \t\t\t);
        """
        let expected = """
        \t\tB2 /* b.png in Resources */ = {isa = PBXBuildFile; fileRef = F2 /* b.png */; };
        \t\tF2 /* b.png */ = {isa = PBXFileReference; path = b.png; sourceTree = "<group>"; };
        \t\t\tchildren = (
        \t\t\t\tF2 /* b.png */,
        \t\t\t);
        \t\t\tfiles = (
        \t\t\t);
        """
        XCTAssertEqual(PBXProjEditor.removeObjects(["F1", "B1"], from: text), expected)
    }
}
