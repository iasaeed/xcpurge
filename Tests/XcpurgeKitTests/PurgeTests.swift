import Foundation
import XCTest
@testable import XcpurgeKit

/// `xcpurge purge`: every category in one run and one trash session, `--only`, `--ids`, `--dry-run`.
/// MixedApp has two high-confidence unused assets, a high-confidence unused string (in two `.lproj` variants)
/// and a medium-confidence orphan file.
final class PurgeTests: XCTestCase {
    private let assetA = "Legacy/LegacyAssets.xcassets/legacy_unused.imageset"
    private let assetB = "Modern/ModernAssets.xcassets/modern_unused.imageset"
    private let orphan = "Modern/Excluded.swift"
    private let stringsEN = "Legacy/en.lproj/Localizable.strings"
    private let stringsFR = "Legacy/fr.lproj/Localizable.strings"

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

    private func purge(_ root: URL, _ extra: [String]) throws -> (status: Int32, stdout: String, stderr: String) {
        try CLISupport.run(["purge", root.path, "--no-swift", "--format", "json"] + extra)
    }

    private func exists(_ root: URL, _ path: String) -> Bool {
        FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path)
    }

    private func entries(_ root: URL) throws -> [TrashEntry] {
        let sessions = try TrashStore.sessions(root: root)
        XCTAssertEqual(sessions.count, 1, "one purge, one trash session")
        return sessions.first?.entries ?? []
    }

    /// Finding ids by path, from a read-only JSON scan.
    private func ids(_ root: URL) throws -> [String: String] {
        let run = try CLISupport.run(["scan", root.path, "--no-swift", "--format", "json", "--quiet"])
        XCTAssertEqual(run.status, 0, run.stderr)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(run.stdout.utf8)) as? [String: Any])
        let findings = try XCTUnwrap(json["findings"] as? [[String: Any]])
        var out: [String: String] = [:]
        for f in findings {
            if let path = f["path"] as? String, let id = f["id"] as? String, out[path] == nil { out[path] = id }
        }
        return out
    }

    /// Assets and the orphan file go to the trash and the string is pruned, all in one session; one restore
    /// brings the tree back byte for byte.
    func testPurgesEveryCategoryInOneSession() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let before = try snapshot(root)

        let run = try purge(root, ["--min-confidence", "medium", "--yes"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertFalse(exists(root, assetA))
        XCTAssertFalse(exists(root, assetB))
        XCTAssertFalse(exists(root, orphan))
        XCTAssertFalse(try String(contentsOf: root.appendingPathComponent(stringsEN), encoding: .utf8).contains("farewell_unused"))

        let all = try entries(root)
        XCTAssertEqual(Set(all.filter { $0.action == .moved }.map(\.path)), [assetA, assetB, orphan])
        XCTAssertEqual(Set(all.filter { $0.action == .rewritten }.map(\.path)), [stringsEN, stringsFR])
        XCTAssertTrue(run.stderr.contains("Trashed 3 item(s)."), run.stderr)
        XCTAssertTrue(run.stderr.contains("Pruned 2 item(s)."), run.stderr)

        let restore = try CLISupport.run(["restore", root.path])
        XCTAssertEqual(restore.status, 0, restore.stderr)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// `--only strings` prunes the string and leaves assets and files alone.
    func testOnlyStringsTouchesOnlyStrings() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let run = try purge(root, ["--only", "strings", "--min-confidence", "medium", "--yes"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(exists(root, assetA))
        XCTAssertTrue(exists(root, assetB))
        XCTAssertTrue(exists(root, orphan))
        let all = try entries(root)
        XCTAssertEqual(all.filter { $0.action == .moved }.map(\.path), [])
        XCTAssertEqual(Set(all.filter { $0.action == .rewritten }.map(\.path)), [stringsEN, stringsFR])
    }

    /// `--only orphan-file` (a finding kind) moves the orphan file only.
    func testOnlyKindFilter() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let run = try purge(root, ["--only", "orphan-file", "--min-confidence", "medium", "--yes"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertFalse(exists(root, orphan))
        XCTAssertTrue(exists(root, assetA))
        XCTAssertTrue(exists(root, assetB))
        XCTAssertEqual(try entries(root).map(\.path), [orphan])
    }

    /// `--ids` acts on exactly the listed findings, the medium-confidence one included without
    /// `--min-confidence`, and warns about an id the scan did not produce.
    func testIdsActOnListedFindingsAndWarnOnUnknown() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let byPath = try ids(root)
        let assetID = try XCTUnwrap(byPath[assetB]), orphanID = try XCTUnwrap(byPath[orphan])

        let run = try purge(root, ["--ids", "\(assetID),unused-asset-0000000000", "--ids", orphanID, "--yes"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("warning: 1 id(s) not found in this scan: unused-asset-0000000000"), run.stderr)
        XCTAssertFalse(exists(root, assetB))
        XCTAssertFalse(exists(root, orphan))
        XCTAssertTrue(exists(root, assetA))
        XCTAssertTrue(try String(contentsOf: root.appendingPathComponent(stringsEN), encoding: .utf8).contains("farewell_unused"))
        XCTAssertEqual(Set(try entries(root).map(\.path)), [assetB, orphan])
    }

    /// `--ids` that match nothing: a warning, no prompt (no terminal here, yet exit 0), nothing changed.
    func testIdsMatchingNothingExitsZero() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let before = try snapshot(root)
        let run = try purge(root, ["--ids", "orphan-file-0000000000"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("warning: 1 id(s) not found in this scan: orphan-file-0000000000"), run.stderr)
        XCTAssertEqual(try snapshot(root), before)
    }

    /// `--dry-run` lists the pending actions and prints the report, and changes nothing.
    func testDryRunChangesNothing() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let before = try snapshot(root)
        let run = try purge(root, ["--min-confidence", "medium", "--dry-run"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("Dry run: would move 3 asset/file item(s)"), run.stderr)
        XCTAssertTrue(run.stderr.contains("strings (prune 1):"), run.stderr)
        XCTAssertTrue(run.stdout.contains("\"findings\""), "the report still goes to stdout")
        XCTAssertEqual(try snapshot(root), before)
        XCTAssertFalse(exists(root, TrashStore.directoryName))
    }

    /// `--only any` is the default and rejected as a usage error.
    func testOnlyAnyIsRejected() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let run = try purge(root, ["--only", "any", "--yes"])
        XCTAssertEqual(run.status, 2)
        XCTAssertTrue(run.stderr.contains("--only any is the default; omit it"), run.stderr)
        XCTAssertFalse(exists(root, TrashStore.directoryName))
    }

    /// `--ids` bypasses a confidence floor: a medium finding picked by id goes even with `--min-confidence high`.
    func testIdsBypassMinConfidence() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let orphanID = try XCTUnwrap(try ids(root)[orphan])
        let run = try purge(root, ["--ids", orphanID, "--min-confidence", "high", "--yes"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertFalse(run.stderr.contains("not found"), run.stderr)
        XCTAssertFalse(exists(root, orphan))
        XCTAssertEqual(try entries(root).map(\.path), [orphan])
    }

    /// `--ids` naming findings purge never acts on (a duplicate, a dead-source file, an informational finding):
    /// warned about and left alone, exit 0, nothing changed.
    func testIdsNamingUnpurgeableFindingsAreLeftAlone() throws {
        let classic = try FixtureSupport.copyToTemp("ClassicApp")
        let classicIDs = try ids(classic)
        let duplicateID = try XCTUnwrap(classicIDs["ClassicApp/icon@2x.png"])
        let deadID = try XCTUnwrap(classicIDs["ClassicApp/DeadObjC.m"])
        let before = try snapshot(classic)
        let run = try purge(classic, ["--ids", "\(duplicateID),\(deadID)", "--yes"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("warning: 2 id(s) left alone"), run.stderr)
        XCTAssertTrue(run.stderr.contains("None of the given ids can be purged"), run.stderr)
        XCTAssertEqual(try snapshot(classic), before)

        let mixed = try FixtureSupport.copyToTemp("MixedApp")
        let dynamicID = try XCTUnwrap(try ids(mixed)["Modern/MixedAppApp.swift"])
        let informational = try purge(mixed, ["--ids", dynamicID, "--yes"])
        XCTAssertEqual(informational.status, 0, informational.stderr)
        XCTAssertTrue(informational.stderr.contains("warning: 1 id(s) left alone"), informational.stderr)
        XCTAssertFalse(exists(mixed, TrashStore.directoryName))
    }

    /// Kinds purge never acts on are rejected in `--only`, like `any`.
    func testOnlyUnpurgeableKindIsRejected() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        for rule in ["dead-source", "ghost-reference", "duplicates", "dynamic-lookup"] {
            let run = try purge(root, ["--only", rule, "--yes"])
            XCTAssertEqual(run.status, 2, rule)
            XCTAssertTrue(run.stderr.contains("--only \(rule): purge never acts on"), run.stderr)
        }
        XCTAssertFalse(exists(root, TrashStore.directoryName))
    }

    /// A prune that fails after the trash step: the trash result and the restore hint are printed, the report is
    /// still written, the run fails (exit 3), and `restore` brings the tree back byte for byte.
    func testPruneFailureAfterTrashKeepsRestoreHintAndReport() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let before = try snapshot(root)
        let locked = root.appendingPathComponent("Legacy/fr.lproj")
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path) }
        let reportURL = root.deletingLastPathComponent().appendingPathComponent("report.json")

        let run = try purge(root, ["--min-confidence", "medium", "--yes", "--output", reportURL.path])
        XCTAssertEqual(run.status, 3, run.stderr)
        XCTAssertTrue(run.stderr.contains("Trashed 3 item(s)."), run.stderr)
        XCTAssertTrue(run.stderr.contains("error: pruning strings failed"), run.stderr)
        XCTAssertTrue(run.stderr.contains("Undo with: xcpurge restore --session "), run.stderr)
        XCTAssertTrue(FileManager.default.fileExists(atPath: reportURL.path), "the report is written")
        XCTAssertFalse(exists(root, assetA))

        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: locked.path)
        let restore = try CLISupport.run(["restore", root.path])
        XCTAssertEqual(restore.status, 0, restore.stderr)
        XCTAssertTrue(exists(root, assetA))
        XCTAssertEqual(try snapshot(root), before)
    }

    /// `--fail-on` applies on the dry-run path, as for `scan`.
    func testDryRunHonoursFailOn() throws {
        let root = try FixtureSupport.copyToTemp("MixedApp")
        let run = try purge(root, ["--dry-run", "--fail-on", "any", "--quiet"])
        XCTAssertEqual(run.status, 1, run.stderr)
        XCTAssertFalse(exists(root, TrashStore.directoryName))
    }
}
