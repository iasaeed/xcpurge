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

    /// After `--delete`, the re-printed report no longer lists what was moved (nor duplicates inside it).
    func testReportAfterDeleteDropsTrashedFindings() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let result = try await ScanEngine(root: root, config: Config()).run(categories: [.files])
        let store = try TrashStore.begin(root: result.context.root)
        let report = try Trash(store: store).apply(result.findings, context: result.context)
        let after = result.afterAction(report, acted: result.findings)
        XCTAssertFalse(after.findings.contains { report.moved.contains($0.path) })
        XCTAssertEqual(Set(after.findings.map(\.path)), Set(report.skipped.map(\.path)), "only skipped findings remain")
        let pruned = ActionReport(rewritten: ["T.strings"])
        let kept = Finding(kind: .unusedString, category: .strings, path: "T.strings", name: "k", module: "M", confidence: .medium)
        let gone = Finding(kind: .unusedString, category: .strings, path: "T.strings", name: "g", module: "M", confidence: .high)
        let strings = ScanResult(context: result.context, findings: [gone, kept]).afterAction(pruned, acted: [gone])
        XCTAssertEqual(strings.findings, [kept], "unacted keys in a rewritten table stay")
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

    // MARK: - Review #8: project edits are dry-run before anything moves

    private func finding(_ path: String, _ kind: FindingKind = .unusedResource) -> Finding {
        Finding(kind: kind, category: .files, path: path, module: "ClassicApp", confidence: .high)
    }

    private func trash(_ paths: [String], in root: URL, config: Config = Config()) async throws -> ActionReport {
        let context = try await ScanEngine(root: root, config: config).makeContext()
        let store = try TrashStore.begin(root: context.root)
        return try Trash(store: store).apply(paths.map { finding($0) }, context: context)
    }

    /// A CRLF pbxproj is edited line by line with its CRLF endings kept, and restores byte for byte.
    func testCRLFProjectIsEditedAndRestored() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        let lf = try String(contentsOf: pbxproj, encoding: .utf8)
        try Data(lf.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: pbxproj)
        let before = try snapshot(root)
        let report = try await trash(["ClassicApp/Unused.plist"], in: root)
        XCTAssertEqual(report.moved, ["ClassicApp/Unused.plist"])
        XCTAssertEqual(report.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        let edited = try String(contentsOf: pbxproj, encoding: .utf8)
        XCTAssertFalse(edited.contains("Unused.plist"))
        XCTAssertFalse(edited.replacingOccurrences(of: "\r\n", with: "").contains("\n"), "every line still ends in CRLF")
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// When the reference cannot be removed (unusual formatting), the file stays where it is.
    func testFileStaysWhenItsReferenceCannotBeRemoved() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        var text = try String(contentsOf: pbxproj, encoding: .utf8)
        // Two list entries on one line: the line editor cannot drop just one of them.
        text = text.replacingOccurrences(of: "CC0000000000000000000023 /* Unused.plist */,\n\t\t\t\t",
                                         with: "CC0000000000000000000023 /* Unused.plist */, ")
        try Data(text.utf8).write(to: pbxproj)
        let before = try snapshot(root)
        let report = try await trash(["ClassicApp/Unused.plist", "ClassicApp/Orphan.swift"], in: root)
        XCTAssertEqual(report.moved, ["ClassicApp/Orphan.swift"], "an unreferenced file still moves")
        XCTAssertTrue(report.rewritten.isEmpty)
        let skipped = try XCTUnwrap(report.skipped.first { $0.path == "ClassicApp/Unused.plist" })
        XCTAssertTrue(skipped.reason.contains("cannot be removed"), skipped.reason)
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/Unused.plist").path))
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// `.xcdatamodeld` version groups are removed with their `.xcdatamodel` children.
    func testDataModelVersionGroupIsRemoved() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let report = try await trash(["ClassicApp/Model.xcdatamodeld"], in: root)
        XCTAssertEqual(report.moved, ["ClassicApp/Model.xcdatamodeld"])
        XCTAssertEqual(report.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        let edited = try String(contentsOf: root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        for gone in ["Model.xcdatamodel", "CC000000000000000000001C", "CC000000000000000000001B", "CC0000000000000000000035"] {
            XCTAssertFalse(edited.contains(gone), gone)
        }
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// Files referenced by a `project.xcproj` (never edited) are not moved.
    func testXcprojReferencedFilesAreNotMoved() async throws {
        let root = try FixtureSupport.copyToTemp("XcprojApp")
        let xcodeproj = root.appendingPathComponent("XcprojApp.xcodeproj")
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSince1970: 1_577_836_800)],
                                              ofItemAtPath: xcodeproj.appendingPathComponent("project.pbxproj").path)
        try FileManager.default.setAttributes([.modificationDate: Date()],
                                              ofItemAtPath: xcodeproj.appendingPathComponent("project.xcproj").path)
        var config = Config()
        config.noSwift = true
        let context = try await ScanEngine(root: root, config: config).makeContext()
        XCTAssertEqual(context.projects.first?.format, .xcproj)
        let referenced = try XCTUnwrap(context.projects.first?.fileRefs.map(\.path).first {
            !$0.hasSuffix(".swift") && FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
        })
        let report = try Trash(store: try TrashStore.begin(root: context.root)).apply([finding(referenced)], context: context)
        XCTAssertTrue(report.moved.isEmpty)
        XCTAssertTrue(report.skipped.contains { $0.path == referenced && $0.reason.contains("not edited") }, "\(report.skipped)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(referenced).path))
    }

    func testLineSplitterKeepsEveryEnding() {
        let text = "a\r\nb\nc\rd"
        XCTAssertEqual(PBXProjEditor.lines(text).map(\.ending), ["\r\n", "\n", "\r", ""])
        XCTAssertEqual(PBXProjEditor.removeObjects([], from: text), text)
        XCTAssertEqual(PBXProjEditor.removeObjects(["X"], from: "a\r\n\t\tX /* x */,\r\nb\r\n"), "a\r\nb\r\n")
    }

    // MARK: - Review 2

    /// #1: on a case-insensitive volume a file whose disk spelling differs from the project's is trashed
    /// together with its reference.
    func testCaseMismatchedReferenceIsRemovedWithTheFile() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        guard !FileInventory.isCaseSensitiveVolume(root) else { throw XCTSkip("temporary volume is case-sensitive") }
        let fm = FileManager.default
        let dir = root.appendingPathComponent("ClassicApp")
        try fm.moveItem(at: dir.appendingPathComponent("unused_loose.png"), to: dir.appendingPathComponent("tmp.png"))
        try fm.moveItem(at: dir.appendingPathComponent("tmp.png"), to: dir.appendingPathComponent("Unused_Loose.png"))
        let result = try await ScanEngine(root: root, config: Config()).run(categories: [.assets])
        let high = result.findings.filter { $0.confidence == .high && $0.path.hasSuffix("Unused_Loose.png") }
        XCTAssertEqual(high.map(\.path), ["ClassicApp/Unused_Loose.png"])
        let report = try Trash(store: try TrashStore.begin(root: result.context.root)).apply(high, context: result.context)
        XCTAssertEqual(report.moved, ["ClassicApp/Unused_Loose.png"])
        XCTAssertEqual(report.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        let pbx = try String(contentsOf: root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj"), encoding: .utf8)
        XCTAssertFalse(pbx.contains("unused_loose.png"))
        XCTAssertTrue(RelPath.isUnder("App/Web/a.html", "app/web", foldingCase: true))
        XCTAssertFalse(RelPath.isUnder("App/Web/a.html", "app/web", foldingCase: false))
    }

    /// #6: the project edit is written first; a file that then fails to move gets its reference back.
    func testFailedMoveRestoresItsReference() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        let original = try Data(contentsOf: pbxproj)
        let context = try await ScanEngine(root: root, config: Config()).makeContext()
        let dir = root.appendingPathComponent("ClassicApp").path
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: dir)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dir) }
        let report = try Trash(store: try TrashStore.begin(root: context.root)).apply([finding("ClassicApp/Unused.plist")],
                                                                                   context: context)
        XCTAssertTrue(report.moved.isEmpty)
        XCTAssertTrue(report.rewritten.isEmpty)
        XCTAssertTrue(report.skipped.contains { $0.path == "ClassicApp/Unused.plist" && $0.reason.hasPrefix("cannot move") })
        XCTAssertEqual(try Data(contentsOf: pbxproj), original, "reference restored")
    }

    /// Review 2 #7: an action that moves and rewrites nothing leaves no empty trash session behind.
    func testNothingTrashedLeavesNoSession() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let result = try await ScanEngine(root: root, config: Config()).run(categories: [.files])
        let onlySkipped = result.findings.filter { $0.kind == .deadSource || $0.kind == .ghostReference }
        XCTAssertFalse(onlySkipped.isEmpty)
        let store = try TrashStore.begin(root: result.context.root)
        let report = try Trash(store: store).apply(onlySkipped, context: result.context)
        XCTAssertTrue(report.moved.isEmpty && report.rewritten.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(TrashStore.directoryName).path))
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
    }

    /// `assets --delete` stores size-before.json / size-after.json in the session; the tree shrank by exactly the
    /// bytes moved to the trash, and restore prints the reverse table.
    func testDeleteRecordsSizeBeforeAndAfter() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let run = try CLISupport.run(["assets", root.path, "--delete", "--yes", "--no-swift", "--format", "json"])
        XCTAssertEqual(run.status, 0, run.stderr)
        let manifest = try XCTUnwrap(try TrashStore.sessions(root: root).first)
        let session = TrashStore.sessionURL(root: root, id: manifest.id)
        let before = try SizeSnapshot.load(from: session.appendingPathComponent(SizeSnapshot.beforeFileName))
        let after = try SizeSnapshot.load(from: session.appendingPathComponent(SizeSnapshot.afterFileName))
        let moved = manifest.entries.filter { $0.action == .moved }.map(\.sizeBytes).reduce(0, +)
        XCTAssertGreaterThan(moved, 0)
        XCTAssertLessThan(after.tree.total, before.tree.total)
        XCTAssertEqual(before.tree.total - after.tree.total, moved)
        XCTAssertEqual(before.reclaimable.categories, ["assets", "duplicates"])
        XCTAssertTrue(run.stderr.contains("Size before → after:\n"), run.stderr)
        XCTAssertTrue(run.stderr.contains("  Total "), run.stderr)

        let restore = try CLISupport.run(["restore", root.path])
        XCTAssertEqual(restore.status, 0, restore.stderr)
        XCTAssertTrue(restore.stderr.contains(SizeText.compact(after, before)), restore.stderr)
    }

    // MARK: - Partial restore (`restore --path`)

    /// The project file of a fresh copy after removing exactly `paths`.
    private func pbxprojAfterRemoving(_ paths: [String], fixture: String = "ClassicApp", project: String = "ClassicApp.xcodeproj") async throws -> Data {
        let copy = try FixtureSupport.copyToTemp(fixture)
        let context = try await ScanEngine(root: copy, config: Config()).discover()
        _ = try Trash(store: try TrashStore.begin(root: context.root)).remove(paths: paths, context: context)
        return try Data(contentsOf: copy.appendingPathComponent(project).appendingPathComponent("project.pbxproj"))
    }

    /// ClassicApp: one of two referenced files comes back; the project is re-edited for the other only, then the
    /// rest restores byte for byte.
    func testPartialRestoreReplansProjectEdit() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        let context = try await ScanEngine(root: root, config: Config()).discover()
        let store = try TrashStore.begin(root: context.root)
        let report = try Trash(store: store).remove(paths: ["ClassicApp/unused_loose.png", "ClassicApp/Unused.plist"], context: context)
        XCTAssertEqual(Set(report.moved), ["ClassicApp/unused_loose.png", "ClassicApp/Unused.plist"])

        let partial = try Restore.run(root: root, sessionID: store.sessionID, paths: ["ClassicApp/Unused.plist"], context: context)
        XCTAssertEqual(partial.moved, ["ClassicApp/Unused.plist"])
        XCTAssertEqual(partial.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        XCTAssertEqual(partial.skipped, [])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/Unused.plist").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/unused_loose.png").path))
        let expected = try await pbxprojAfterRemoving(["ClassicApp/unused_loose.png"])
        XCTAssertEqual(try Data(contentsOf: pbxproj), expected)
        let session = try XCTUnwrap(try TrashStore.sessions(root: root).first, "a session with entries is never deleted")
        XCTAssertEqual(session.entries.map(\.path).sorted(), ["ClassicApp.xcodeproj/project.pbxproj", "ClassicApp/unused_loose.png"])

        let unknown = try Restore.run(root: root, sessionID: store.sessionID, paths: ["ClassicApp/never.png"], context: nil)
        XCTAssertEqual(unknown.skipped.map(\.path), ["ClassicApp/never.png"])
        XCTAssertEqual(unknown.moved, [])

        let rest = try Restore.run(root: root, sessionID: store.sessionID, paths: ["ClassicApp/unused_loose.png"], context: nil)
        XCTAssertEqual(rest.moved, ["ClassicApp/unused_loose.png"])
        XCTAssertEqual(rest.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        XCTAssertEqual(try snapshot(root), before)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(TrashStore.directoryName).path))
    }

    /// A ghost-reference edit in the same session survives a partial restore of another file.
    func testPartialRestoreKeepsGhostReferenceEdit() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        let context = try await ScanEngine(root: root, config: Config()).discover()
        let store = try TrashStore.begin(root: context.root)
        _ = try Trash(store: store).remove(paths: ["ClassicApp/Ghost.swift", "ClassicApp/unused_loose.png"], context: context)
        _ = try Restore.run(root: root, sessionID: store.sessionID, paths: ["ClassicApp/unused_loose.png"], context: context)
        let expected = try await pbxprojAfterRemoving(["ClassicApp/Ghost.swift"])
        XCTAssertEqual(try Data(contentsOf: pbxproj), expected)
        XCTAssertEqual(try TrashStore.sessions(root: root).first?.entries.map(\.path), ["ClassicApp.xcodeproj/project.pbxproj"])
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// SyncedApp (synchronized folders, no project edit): files come back one at a time, the rest whole.
    func testPartialRestoreOnSyncedApp() async throws {
        let root = try FixtureSupport.copyToTemp("SyncedApp")
        let before = try snapshot(root)
        let result = try await ScanEngine(root: root, config: Config()).run(categories: [.files])
        let store = try TrashStore.begin(root: result.context.root)
        let report = try Trash(store: store).apply(result.findings, context: result.context)
        XCTAssertEqual(Set(report.moved), ["SyncedApp/Excluded/Legacy.swift", "SyncedApp/Web/index.html"])
        XCTAssertTrue(report.rewritten.isEmpty)

        let partial = try Restore.run(root: root, sessionID: nil, paths: ["SyncedApp/Web/index.html"], context: result.context)
        XCTAssertEqual(partial.moved, ["SyncedApp/Web/index.html"])
        XCTAssertEqual(partial.rewritten, [])
        XCTAssertEqual(partial.skipped, [])
        XCTAssertEqual(try TrashStore.sessions(root: root).first?.entries.map(\.path), ["SyncedApp/Excluded/Legacy.swift"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("SyncedApp/Excluded/Legacy.swift").path))
        _ = try Restore.run(root: root, sessionID: nil, paths: ["SyncedApp/Excluded/Legacy.swift"], context: nil)
        XCTAssertEqual(try snapshot(root), before)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
    }

    /// `xcpurge restore --path` (repeatable, relative or absolute) and the trash folder that stays for the block list.
    func testCLIRestorePath() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let removed = try CLISupport.run(["remove", root.path, "ClassicApp/unused_loose.png", "ClassicApp/Unused.plist", "ClassicApp/Orphan.swift",
                                          "--yes", "--quiet"])
        XCTAssertEqual(removed.status, 0, removed.stderr)
        let one = try CLISupport.run(["restore", root.path, "--path", "ClassicApp/Unused.plist", "--path",
                                      root.appendingPathComponent("ClassicApp/Orphan.swift").path])
        XCTAssertEqual(one.status, 0, one.stderr)
        XCTAssertTrue(one.stderr.contains("  restored ClassicApp/Unused.plist\n"), one.stderr)
        XCTAssertTrue(one.stderr.contains("  restored ClassicApp/Orphan.swift\n"), one.stderr)
        XCTAssertTrue(one.stderr.contains("  restored ClassicApp.xcodeproj/project.pbxproj\n"), one.stderr)
        XCTAssertFalse(one.stderr.contains("Size before"), "no size table for a partial restore: \(one.stderr)")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/unused_loose.png").path))
        XCTAssertEqual(try TrashStore.sessions(root: root).count, 1)

        try VerifyBlocklist.add([.init(path: "ClassicApp/x.png", reason: "r", session: "s", date: Date())], root: root)
        let rest = try CLISupport.run(["restore", root.path])
        XCTAssertEqual(rest.status, 0, rest.stderr)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
        XCTAssertTrue(FileManager.default.fileExists(atPath: VerifyBlocklist.url(root: root).path), "the block list keeps the folder")
        try FileManager.default.removeItem(at: root.appendingPathComponent(TrashStore.directoryName))
        XCTAssertEqual(try snapshot(root), before)
    }
}
