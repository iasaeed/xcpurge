import Foundation
import XCTest
@testable import XcpurgeKit

/// `xcpurge remove` / `Trash.remove(paths:)`: explicit paths, asset sets taken whole, ghost references, restore.
final class RemoveTests: XCTestCase {
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

    private func remove(_ paths: [String], root: URL) async throws -> (ActionReport, ScanContext) {
        let context = try await ScanEngine(root: root, config: Config()).discover()
        let store = try TrashStore.begin(root: context.root)
        return (try Trash(store: store).remove(paths: paths, context: context), context)
    }

    private func text(_ url: URL) throws -> String { try String(contentsOf: url, encoding: .utf8) }

    /// Discovery alone finds the projects; the reference index stays empty.
    func testDiscoverSkipsReferenceIndex() async throws {
        let context = try await ScanEngine(root: FixtureSupport.fixtureURL("ClassicApp"), config: Config()).discover()
        XCTAssertEqual(context.projects.count, 1)
        XCTAssertTrue(context.refs.references.isEmpty)
        XCTAssertTrue(context.inventory.files.contains { $0.path == "ClassicApp/unused_loose.png" })
    }

    /// A loose file referenced by the pbxproj: moved, reference gone, restore byte-identical.
    func testLooseFileRoundTrip() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        XCTAssertTrue(try text(pbxproj).contains("unused_loose.png"))

        let (report, _) = try await remove(["ClassicApp/unused_loose.png"], root: root)
        XCTAssertEqual(report.moved, ["ClassicApp/unused_loose.png"])
        XCTAssertEqual(report.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        XCTAssertEqual(report.skipped, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/unused_loose.png").path))
        XCTAssertFalse(try text(pbxproj).contains("unused_loose.png"))

        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// Kinds `--delete` never touches (dead source) go when asked for by path.
    func testRemovesWhateverKindWhenAskedExplicitly() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let (report, _) = try await remove(["ClassicApp/DeadObjC.m"], root: root)
        XCTAssertEqual(report.moved, ["ClassicApp/DeadObjC.m"])
        XCTAssertEqual(report.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
    }

    /// A path inside an image set stands for the set: the whole folder moves, no project edit (catalog entry).
    func testPathInsideImageSetRemovesWholeSet() async throws {
        let root = try FixtureSupport.copyToTemp("AssetsEdgeCases")
        let before = try snapshot(root)
        let set = "Edge/Assets.xcassets/truly_unused.imageset"
        let (report, _) = try await remove([set + "/truly_unused.png"], root: root)
        XCTAssertEqual(report.moved, [set])
        XCTAssertEqual(report.rewritten, [])
        XCTAssertEqual(report.skipped, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(set).path))
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// The innermost set: an image set inside a sprite atlas, brand assets or an image stack goes alone.
    func testAssetSetContainingIsInnermost() {
        XCTAssertEqual(Trash.assetSet(containing: "A/V.xcassets/pubg.imageset/cardgift.pdf"), "A/V.xcassets/pubg.imageset")
        XCTAssertEqual(Trash.assetSet(containing: "A/V.xcassets/Group/c.colorset/Contents.json"), "A/V.xcassets/Group/c.colorset")
        XCTAssertEqual(Trash.assetSet(containing: "A.xcassets/Icons.spriteatlas/x.imageset/a.png"), "A.xcassets/Icons.spriteatlas/x.imageset")
        XCTAssertEqual(Trash.assetSet(containing: "A.xcassets/TV.brandassets/Top.imagestack/Front.imagestacklayer/Content.imageset/a.png"),
                       "A.xcassets/TV.brandassets/Top.imagestack/Front.imagestacklayer/Content.imageset")
        XCTAssertEqual(Trash.assetSet(containing: "A.xcassets/Icons.spriteatlas/Contents.json"), "A.xcassets/Icons.spriteatlas",
                       "the atlas's own file belongs to the atlas")
        XCTAssertNil(Trash.assetSet(containing: "A/V.xcassets/pubg.imageset"), "the set itself")
        XCTAssertNil(Trash.assetSet(containing: "A.xcassets/Icons.spriteatlas/x.imageset"), "a set inside an atlas, itself")
        XCTAssertNil(Trash.assetSet(containing: "A/V.xcassets/Group/Contents.json"), "a catalog group file")
        XCTAssertNil(Trash.assetSet(containing: "A/Images/pubg.imageset/x.png"), "not in a catalog")
    }

    /// A ghost reference: the file is already gone, the pbxproj still lists it. Only the reference is dropped.
    func testGhostReferenceDropsProjectReferenceOnly() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("ClassicApp/Ghost.swift").path))
        XCTAssertTrue(try text(pbxproj).contains("Ghost.swift"))

        let (report, _) = try await remove(["ClassicApp/Ghost.swift"], root: root)
        XCTAssertEqual(report.moved, [])
        XCTAssertEqual(report.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        XCTAssertEqual(report.skipped, [], "a referenced ghost is not 'no longer exists'")
        XCTAssertFalse(try text(pbxproj).contains("Ghost.swift"))

        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// Missing on disk and referenced nowhere: skipped, and the session stays empty.
    func testMissingUnreferencedPathIsSkipped() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let (report, _) = try await remove(["ClassicApp/never_was.png"], root: root)
        XCTAssertEqual(report.moved, [])
        XCTAssertEqual(report.rewritten, [])
        XCTAssertEqual(report.skipped, [.init(path: "ClassicApp/never_was.png", reason: "no longer exists")])
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
    }

    func testPathOutsideRootOrInTrashThrows() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let context = try await ScanEngine(root: root, config: Config()).discover()
        let trash = Trash(store: try TrashStore.begin(root: context.root))
        for bad in ["../Elsewhere.swift", "/etc/hosts", "ClassicApp/../../x", "", ".xcpurge-trash/20260101-000000/files/a.png"] {
            XCTAssertThrowsError(try trash.remove(paths: [bad], context: context), bad) { error in
                guard case XcpurgeError.notFound = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty, "nothing touched")
    }

    /// `App/Vendor -> /elsewhere`: the path reads as inside the root but its real parent is not.
    func testSymlinkedFolderCannotEscapeRoot() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let outside = try FixtureSupport.tempTree(["x.swift": "// outside\n"])
        let link = root.appendingPathComponent("ClassicApp/Vendor")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.appendingPathComponent("x.swift").path), "link works")

        let context = try await ScanEngine(root: root, config: Config()).discover()
        let trash = Trash(store: try TrashStore.begin(root: context.root))
        XCTAssertThrowsError(try trash.remove(paths: ["ClassicApp/Vendor/x.swift"], context: context)) { error in
            guard case XcpurgeError.notFound = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: outside.appendingPathComponent("x.swift").path), "target untouched")
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
    }

    /// The CLI resolves an absolute path's folder, not the file: a symlink moves itself, its target stays.
    func testCLIAbsoluteSymlinkMovesTheLinkNotItsTarget() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let outside = try FixtureSupport.tempTree(["real.png": "png"])
        let target = outside.appendingPathComponent("real.png")
        let link = root.appendingPathComponent("ClassicApp/link.png")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)

        let run = try CLISupport.run(["remove", root.path, link.path, "--yes", "--quiet"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("  moved ClassicApp/link.png\n"), run.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: target.path), "target untouched")
        XCTAssertNil(try? FileManager.default.destinationOfSymbolicLink(atPath: link.path), "link gone")
    }

    /// On a case-insensitive volume a path in any spelling maps to the on-disk one, and spellings dedupe.
    func testCaseInsensitiveSpellingMapsToDisk() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let context = try await ScanEngine(root: root, config: Config()).discover()
        try XCTSkipUnless(context.inventory.isCaseInsensitive, "needs a case-insensitive volume")
        XCTAssertEqual(try Trash.targets(for: ["classicapp/UNUSED_LOOSE.png", "ClassicApp/unused_loose.png"], context: context),
                       ["ClassicApp/unused_loose.png"])
        XCTAssertEqual(try Trash.targets(for: ["classicapp/model.XCDATAMODELD"], context: context), ["ClassicApp/Model.xcdatamodeld"],
                       "a folder's spelling comes from the files beneath it")

        let trash = Trash(store: try TrashStore.begin(root: context.root))
        let report = try trash.remove(paths: ["classicapp/UNUSED_LOOSE.png", "ClassicApp/unused_loose.png"], context: context)
        XCTAssertEqual(report.moved, ["ClassicApp/unused_loose.png"])
        XCTAssertEqual(report.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        XCTAssertEqual(report.skipped, [])
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before, "restored under the original spelling")
    }

    /// The catalog itself is a loose file: moving it drops its pbxproj reference.
    func testWholeCatalogLosesItsReference() async throws {
        let root = try FixtureSupport.copyToTemp("AssetsEdgeCases")
        let before = try snapshot(root)
        let pbxproj = root.appendingPathComponent("Edge.xcodeproj/project.pbxproj")
        let (report, _) = try await remove(["Edge/Assets.xcassets"], root: root)
        XCTAssertEqual(report.moved, ["Edge/Assets.xcassets"])
        XCTAssertEqual(report.rewritten, ["Edge.xcodeproj/project.pbxproj"])
        XCTAssertEqual(report.skipped, [])
        XCTAssertFalse(try text(pbxproj).contains("Assets.xcassets"))
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// A plain folder is refused (its files would dangle); a bundle-like folder moves with its version group.
    func testPlainFolderRefusedButBundlesMove() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        let (refused, context) = try await remove(["ClassicApp"], root: root)
        XCTAssertEqual(refused.moved, [])
        XCTAssertEqual(refused.rewritten, [])
        XCTAssertEqual(refused.skipped, [.init(path: "ClassicApp", reason: Trash.folderReason)])
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
        XCTAssertFalse(Trash.isRemovableFolder("ClassicApp", context: context))
        XCTAssertTrue(Trash.isRemovableFolder("ClassicApp/Model.xcdatamodeld", context: context))
        XCTAssertTrue(Trash.isRemovableFolder("Any/Assets.xcassets", context: context))
        XCTAssertTrue(Trash.isRemovableFolder("Any/Assets.xcassets/x.imageset", context: context))

        let (report, _) = try await remove(["ClassicApp/Model.xcdatamodeld"], root: root)
        XCTAssertEqual(report.moved, ["ClassicApp/Model.xcdatamodeld"])
        XCTAssertEqual(report.rewritten, ["ClassicApp.xcodeproj/project.pbxproj"])
        XCTAssertFalse(try text(pbxproj).contains("xcdatamodel"))
    }

    /// A file two projects reference, one of which cannot drop it: it is edited out of neither and not moved.
    func testPathBlockedByOneProjectTouchesNoProject() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let fm = FileManager.default
        let first = root.appendingPathComponent("ClassicApp.xcodeproj")
        let second = root.appendingPathComponent("Other.xcodeproj")
        try fm.copyItem(at: first, to: second)
        // Two list entries on one line: the editor refuses to touch the line (and so the reference).
        let secondFile = second.appendingPathComponent("project.pbxproj")
        let original = try text(secondFile)
        let lone = "\t\t\t\tCC0000000000000000000022 /* unused_loose.png */,\n"
        XCTAssertTrue(original.contains(lone))
        try original.replacingOccurrences(of: lone, with: "\t\t\t\tCC0000000000000000000022 /* unused_loose.png */, CC0000000000000000000023 /* Unused.plist */,\n")
            .write(to: secondFile, atomically: true, encoding: .utf8)
        let before = try snapshot(root)

        let context = try await ScanEngine(root: root, config: Config()).discover()
        XCTAssertEqual(context.projects.count, 2)
        let finding = Finding(kind: .unusedAsset, category: .assets, path: "ClassicApp/unused_loose.png", module: "ClassicApp", confidence: .high)
        let viaApply = try Trash(store: try TrashStore.begin(root: context.root)).apply([finding], context: context)
        let viaRemove = try Trash(store: try TrashStore.begin(root: context.root))
            .remove(paths: ["ClassicApp/unused_loose.png"], context: context)
        for r in [viaApply, viaRemove] {
            XCTAssertEqual(r.moved, [])
            XCTAssertEqual(r.rewritten, [], "the first project is not edited either")
            XCTAssertEqual(r.skipped.map(\.path), ["ClassicApp/unused_loose.png"])
            XCTAssertTrue(r.skipped[0].reason.contains("Other.xcodeproj/project.pbxproj reference cannot be removed"), r.skipped[0].reason)
        }
        XCTAssertEqual(try snapshot(root), before, "nothing on disk changed")
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
    }

    /// `apply` is unchanged: dead-source and ghost findings stay skipped there.
    func testApplyStillFiltersByKind() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let result = try await ScanEngine(root: root, config: Config()).run(categories: [.files])
        let report = try Trash(store: try TrashStore.begin(root: result.context.root)).apply(result.findings, context: result.context)
        XCTAssertEqual(Set(report.skipped.map(\.path)), ["ClassicApp/DeadObjC.m", "ClassicApp/Ghost.swift"])
    }

    /// The CLI: root first, then paths, flags anywhere; absolute paths; the restore hint; exit 2 outside the
    /// root or inside the trash.
    func testCLIRemoveAndRestore() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let run = try CLISupport.run(["remove", root.path, "ClassicApp/unused_loose.png", "--yes",
                                      root.appendingPathComponent("ClassicApp/Ghost.swift").path, "--quiet"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("  moved ClassicApp/unused_loose.png\n"), run.stderr)
        XCTAssertTrue(run.stderr.contains("  rewrote ClassicApp.xcodeproj/project.pbxproj\n"), run.stderr)
        XCTAssertTrue(run.stderr.contains("Removed 2 item(s). Undo with: xcpurge restore --session "), run.stderr)
        XCTAssertFalse(run.stderr.contains("no longer exists"), run.stderr)

        let outside = try CLISupport.run(["remove", root.path, "../other.swift", "--yes", "--quiet"])
        XCTAssertEqual(outside.status, 2, outside.stderr)
        XCTAssertTrue(outside.stderr.contains("is not inside"), outside.stderr)

        let inTrash = try CLISupport.run(["remove", root.path, ".xcpurge-trash/x/files/a.png", "--yes", "--quiet"])
        XCTAssertEqual(inTrash.status, 2, inTrash.stderr)
        XCTAssertTrue(inTrash.stderr.contains("is inside .xcpurge-trash; use `xcpurge restore` instead"), inTrash.stderr)
        XCTAssertEqual(try TrashStore.sessions(root: root).count, 1, "the failed runs made no session")

        let restore = try CLISupport.run(["restore", root.path])
        XCTAssertEqual(restore.status, 0, restore.stderr)
        XCTAssertTrue(restore.stderr.contains("Restored 2 item(s)"), restore.stderr)
    }

    /// The confirmation counts paths after climbing and dedupe, and labels ghosts separately. Without a
    /// terminal nobody can answer, so nothing moves and the exit code (2) says so instead of a silent 0.
    func testCLIConfirmationSummary() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let run = try CLISupport.run(["remove", root.path, "./ClassicApp/unused_loose.png", "ClassicApp/unused_loose.png",
                                      "ClassicApp/Ghost.swift", "--quiet"])
        XCTAssertEqual(run.status, 2, run.stderr)
        XCTAssertTrue(run.stderr.contains("Move 1 path(s) to .xcpurge-trash and drop 1 reference(s) to missing file(s)? Not a terminal"),
                      run.stderr)
        XCTAssertFalse(run.stderr.contains("moved"), run.stderr)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)

        let edge = try FixtureSupport.copyToTemp("AssetsEdgeCases")
        let set = "Edge/Assets.xcassets/truly_unused.imageset"
        let climbed = try CLISupport.run(["remove", edge.path, set + "/truly_unused.png", set + "/Contents.json", "--quiet"])
        XCTAssertEqual(climbed.status, 2, climbed.stderr)
        XCTAssertTrue(climbed.stderr.contains("removing asset set truly_unused.imageset (asset sets are removed whole)"), climbed.stderr)
        XCTAssertTrue(climbed.stderr.contains("Move 1 path(s) to .xcpurge-trash? Not a terminal"), climbed.stderr)
    }

    /// `assets --delete` without a terminal and without `--yes`: the report is still written (here to `--output`),
    /// nothing is trashed, and the exit code is 2 so CI cannot mistake the no-op for success.
    func testCLIDeleteWithoutTerminalWritesReportThenExitsTwo() throws {
        let root = try FixtureSupport.copyToTemp("AssetsEdgeCases")
        // The report goes outside the root: inside it, the next scan would read it as a reference to every asset.
        let out = try FixtureSupport.tempTree([:]).appendingPathComponent("report.json")
        let run = try CLISupport.run(["assets", root.path, "--delete", "--no-swift", "--format", "json", "--output", out.path, "--quiet"])
        XCTAssertEqual(run.status, 2, run.stderr)
        XCTAssertTrue(run.stderr.contains("to .xcpurge-trash? Not a terminal; pass --yes to confirm."), run.stderr)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: out)) as? [String: Any])
        XCTAssertGreaterThan((json["findings"] as? [Any])?.count ?? 0, 0, "the report lists the findings it would have acted on")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent("Edge/Images/loose_unused.png").path), "nothing moved")
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
        let stdout = try CLISupport.run(["assets", root.path, "--delete", "--no-swift", "--format", "json", "--quiet"])
        XCTAssertEqual(stdout.status, 2)
        XCTAssertTrue(stdout.stdout.hasPrefix("{"), "report on stdout as well")
    }

    /// A set inside a catalog has no inventory entry of its own: its spelling comes from the directory listing,
    /// so a mis-cased argument never renames the set through the manifest and restore.
    func testMiscasedCatalogSetKeepsOnDiskSpelling() async throws {
        let root = try FixtureSupport.copyToTemp("AssetsEdgeCases")
        let before = try snapshot(root)
        let context = try await ScanEngine(root: root, config: Config()).discover()
        try XCTSkipUnless(context.inventory.isCaseInsensitive, "needs a case-insensitive volume")
        let set = "Edge/Assets.xcassets/truly_unused.imageset"
        XCTAssertEqual(try Trash.targets(for: ["edge/ASSETS.xcassets/TRULY_UNUSED.imageset/Truly_Unused.png"], context: context), [set])
        XCTAssertEqual(try Trash.targets(for: ["Edge/Assets.xcassets/Truly_Unused.imageset"], context: context), [set])
        XCTAssertEqual(try Trash.targets(for: ["Edge/Assets.xcassets/Nope.imageset"], context: context), ["Edge/Assets.xcassets/Nope.imageset"],
                       "a component that does not exist keeps the given spelling")

        let trash = Trash(store: try TrashStore.begin(root: context.root))
        let report = try trash.remove(paths: ["Edge/Assets.xcassets/TRULY_UNUSED.imageset"], context: context)
        XCTAssertEqual(report.moved, [set])
        XCTAssertEqual(try TrashStore.sessions(root: root).first?.entries.map(\.path), [set], "manifest uses the on-disk name")
        _ = try Restore.run(root: root, sessionID: nil)
        XCTAssertEqual(try snapshot(root), before, "restored under the original spelling")
    }

    /// The confirmation counts only what `remove` will act on; folders and unreferenced missing paths are
    /// announced as skips. When everything would be skipped there is nothing to confirm.
    func testCLIConfirmationExcludesWhatWillBeSkipped() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let run = try CLISupport.run(["remove", root.path, "ClassicApp", "ClassicApp/never_was.png", "ClassicApp/unused_loose.png", "--quiet"])
        XCTAssertEqual(run.status, 2, run.stderr)
        XCTAssertTrue(run.stderr.contains("Move 1 path(s) to .xcpurge-trash? Not a terminal"), run.stderr)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)

        let allSkipped = try CLISupport.run(["remove", root.path, "ClassicApp", "ClassicApp/never_was.png", "--quiet"])
        XCTAssertEqual(allSkipped.status, 0, allSkipped.stderr)
        XCTAssertFalse(allSkipped.stderr.contains("Not a terminal"), "nothing to confirm: \(allSkipped.stderr)")
        XCTAssertTrue(allSkipped.stderr.contains("  skipped ClassicApp: \(Trash.folderReason)\n"), allSkipped.stderr)
        XCTAssertTrue(allSkipped.stderr.contains("  skipped ClassicApp/never_was.png: no longer exists\n"), allSkipped.stderr)
        XCTAssertTrue(allSkipped.stderr.contains("Nothing was removed.\n"), allSkipped.stderr)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
    }

    /// Two projects share a file; the second project's edit cannot be written. The first project's edit is
    /// reverted, the file stays on disk, and the skip says why.
    func testEditFailureInSecondProjectRevertsTheFirst() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let fm = FileManager.default
        let first = root.appendingPathComponent("ClassicApp.xcodeproj")
        let second = root.appendingPathComponent("Other.xcodeproj")
        try fm.copyItem(at: first, to: second)
        let firstFile = first.appendingPathComponent("project.pbxproj")
        let original = try text(firstFile)
        // Atomic writes need a writable directory; the second project's is not.
        try fm.setAttributes([.posixPermissions: 0o555], ofItemAtPath: second.path)
        defer { try? fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: second.path) }

        let context = try await ScanEngine(root: root, config: Config()).discover()
        XCTAssertEqual(context.projects.map(\.container), ["ClassicApp.xcodeproj", "Other.xcodeproj"], "first is edited first")
        let trash = Trash(store: try TrashStore.begin(root: context.root))
        let report = try trash.remove(paths: ["ClassicApp/unused_loose.png"], context: context)
        XCTAssertEqual(report.moved, [])
        XCTAssertEqual(report.rewritten, [], "the first project's edit was reverted")
        XCTAssertEqual(report.skipped.map(\.path), ["ClassicApp/unused_loose.png"])
        XCTAssertTrue(report.skipped[0].reason.hasPrefix("Other.xcodeproj not edited: "), report.skipped[0].reason)
        XCTAssertEqual(try text(firstFile), original)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/unused_loose.png").path))
    }
}
