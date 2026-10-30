import Foundation
import XCTest
@testable import XcpurgeKit

/// `--verify`: a fake build script that fails while a file is missing, attribution, bisection, timeout, blocking.
final class VerifyTests: XCTestCase {
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

    /// Writes a build script next to (not inside) the root; returns the `--verify` command.
    private func script(_ body: String, near root: URL) throws -> String {
        let file = root.deletingLastPathComponent().appendingPathComponent("verify-\(UUID().uuidString).sh")
        try Data(("#!/bin/sh\n" + body + "\n").utf8).write(to: file)
        return "/bin/sh '\(file.path)'"
    }

    /// Fails with `message` while `path` (root-relative) is missing.
    private func failsWithout(_ path: String, message: String, root: URL) throws -> String {
        try script("if [ ! -e '\(root.path)/\(path)' ]; then echo \"\(message)\"; exit 1; fi; echo ok", near: root)
    }

    private func pbxproj(_ root: URL) -> URL { root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj") }

    /// The project file of a fresh copy after removing exactly `paths`.
    private func pbxprojAfterRemoving(_ paths: [String]) async throws -> Data {
        let copy = try FixtureSupport.copyToTemp("ClassicApp")
        let context = try await ScanEngine(root: copy, config: Config()).discover()
        _ = try Trash(store: try TrashStore.begin(root: context.root)).remove(paths: paths, context: context)
        return try Data(contentsOf: pbxproj(copy))
    }

    private var sleepProcesses: String {
        (try? ProcessRunner.run("/usr/bin/pgrep", ["-f", "sleep 5.137"], timeout: 10))
            .map { String(decoding: $0.stdout, as: UTF8.self) } ?? ""
    }

    // MARK: - ShellRunner

    func testShellRunnerMergesStreamsAndReportsStatus() {
        let root = FileManager.default.temporaryDirectory
        let r = ShellRunner.run("echo out; echo err 1>&2; exit 3", cwd: root, timeout: 30)
        XCTAssertEqual(r.status, 3)
        XCTAssertFalse(r.timedOut)
        XCTAssertTrue(r.output.contains("out\n") && r.output.contains("err\n"), r.output)
        XCTAssertEqual(r.tail(1), ["err"])
        let big = ShellRunner.run("head -c 3000000 /dev/zero | tr '\\0' a; echo; echo END", cwd: root, timeout: 60)
        XCTAssertEqual(big.status, 0)
        XCTAssertLessThanOrEqual(big.output.utf8.count, ShellRunner.outputCap)
        XCTAssertTrue(big.output.hasSuffix("END\n"), "the ring keeps the end")
    }

    func testShellRunnerTimeoutKillsTheProcessGroup() throws {
        let root = FileManager.default.temporaryDirectory
        let started = Date()
        let r = ShellRunner.run("sleep 5.137; echo done", cwd: root, timeout: 1)
        XCTAssertTrue(r.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 4)
        XCTAssertFalse(r.output.contains("done"))
        // The group got SIGTERM; nothing of it is left (allow a moment for the kernel to reap).
        var left = sleepProcesses
        for _ in 0..<20 where !left.isEmpty { Thread.sleep(forTimeInterval: 0.1); left = sleepProcesses }
        XCTAssertEqual(left, "", "leftover processes: \(left)")
    }

    // MARK: - Attribution and units

    func testDiagnosticAttributorMapsNamesSymbolsAndPaths() {
        let dead = RemovalUnit(paths: ["App/Dead.swift"])
        let asset = RemovalUnit(paths: ["App/Assets.xcassets/old_hero.imageset"])
        let plist = RemovalUnit(paths: ["App/Unused.plist"])
        let sigs = [
            DiagnosticAttributor.Signature(unit: dead, declaredNames: ["DeadThing", "helper"], assetSymbols: []),
            DiagnosticAttributor.Signature(unit: asset, declaredNames: [], assetSymbols: DiagnosticAttributor.assetSymbols(for: asset.paths[0])),
            DiagnosticAttributor.Signature(unit: plist, declaredNames: [], assetSymbols: []),
        ]
        XCTAssertTrue(sigs[1].assetSymbols.contains("oldHero"))
        XCTAssertTrue(sigs[1].assetSymbols.contains("ACImageNameOldHero"))
        let output = """
        /r/App/View.swift:3:9: error: cannot find 'DeadThing' in scope
        /r/App/View.swift:9:20: error: type 'ImageResource' has no member 'oldHero'
        error: Build input file cannot be found: '/r/App/Unused.plist'. Did you forget to declare this file as an output?
        /r/App/Other.swift:1:1: error: no such module 'Gone'
        """
        let hits = DiagnosticAttributor.attribute(output: output, signatures: sigs)
        XCTAssertEqual(hits.keys.sorted(), [asset.id, dead.id, plist.id].sorted())
        XCTAssertTrue(hits[dead.id]!.contains("cannot find 'DeadThing'"))
        XCTAssertTrue(hits[asset.id]!.contains("has no member 'oldHero'"))
        XCTAssertTrue(hits[plist.id]!.contains("Build input file"))
        XCTAssertTrue(DiagnosticAttributor.attribute(output: "error: no such module 'Gone'", signatures: sigs).isEmpty)
        let byPath = DiagnosticAttributor.attribute(output: "/r/App/Dead.swift:1:1: error: boom", signatures: sigs)
        XCTAssertEqual(byPath.keys.sorted(), [dead.id])
    }

    /// Source files that mention each other's declarations form one unit; everything else stands alone.
    func testRemovalUnitsConnectReferencingSources() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        try Data("import Foundation\n\nstruct AThing {}\n".utf8).write(to: root.appendingPathComponent("ClassicApp/AThing.swift"))
        try Data("import Foundation\n\nlet b = AThing()\n".utf8).write(to: root.appendingPathComponent("ClassicApp/BThing.swift"))
        let context = try await ScanEngine(root: root, config: Config()).makeContext()
        let units = RemovalUnits.make(paths: ["ClassicApp/Unused.plist", "ClassicApp/BThing.swift", "ClassicApp/AThing.swift",
                                              "ClassicApp/Orphan.swift"], context: context)
        XCTAssertEqual(units.map(\.paths), [["ClassicApp/AThing.swift", "ClassicApp/BThing.swift"], ["ClassicApp/Orphan.swift"],
                                            ["ClassicApp/Unused.plist"]])
        XCTAssertEqual(RemovalUnits.declaredNames(of: "ClassicApp/Orphan.swift", context: context), ["OrphanThing"])
    }

    // MARK: - End to end through the CLI

    /// A red preflight exits 4 before anything is touched.
    func testPreflightRedExits4AndLeavesNoSession() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let cmd = try script("echo 'error: already broken'; exit 1", near: root)
        let run = try CLISupport.run(["remove", root.path, "ClassicApp/unused_loose.png", "--yes", "--quiet", "--verify", cmd])
        XCTAssertEqual(run.status, 4, run.stderr)
        XCTAssertTrue(run.stderr.contains("build fails before any change"), run.stderr)
        XCTAssertTrue(run.stderr.contains("error: already broken"), "last lines of the build are shown: \(run.stderr)")
        XCTAssertEqual(try snapshot(root), before)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
    }

    /// The compiler names the file: only that unit is restored; the project keeps the other edit, byte for byte.
    func testAttributionRestoresOnlyTheNamedUnit() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let cmd = try failsWithout("ClassicApp/Unused.plist",
                                   message: "error: Build input file cannot be found: '\(root.path)/ClassicApp/Unused.plist'", root: root)
        let run = try CLISupport.run(["remove", root.path, "ClassicApp/unused_loose.png", "ClassicApp/Unused.plist", "--yes", "--quiet",
                                      "--verify", cmd])
        XCTAssertEqual(run.status, 0, run.stderr)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/Unused.plist").path), "restored")
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/unused_loose.png").path), "verified removal stays")
        let expected = try await pbxprojAfterRemoving(["ClassicApp/unused_loose.png"])
        XCTAssertEqual(try Data(contentsOf: pbxproj(root)), expected,
                       "the project is edited for the verified file only")
        XCTAssertTrue(run.stderr.contains("1 removed and build-verified, 1 blocked (restored), 0 restored unverified; 2 build(s) used of 8"), run.stderr)
        XCTAssertTrue(run.stderr.contains("  blocked ClassicApp/Unused.plist: error: Build input file cannot be found"), run.stderr)
        XCTAssertTrue(run.stderr.contains("build-verified, not runtime-verified"), run.stderr)
        XCTAssertTrue(run.stderr.contains("  moved ClassicApp/unused_loose.png\n"), run.stderr)
        XCTAssertTrue(run.stderr.contains("  skipped ClassicApp/Unused.plist: blocked by --verify: error: Build input file"), run.stderr)
        XCTAssertFalse(run.stderr.contains("  moved ClassicApp/Unused.plist"), run.stderr)

        let session = try XCTUnwrap(try TrashStore.sessions(root: root).first)
        XCTAssertEqual(session.entries.map(\.path).sorted(), ["ClassicApp.xcodeproj/project.pbxproj", "ClassicApp/unused_loose.png"])
        let record = try XCTUnwrap(session.verify)
        XCTAssertEqual(record.outcome, .partial)
        XCTAssertEqual(record.builds, 3, "preflight, red, green")
        XCTAssertEqual(record.blocked.map(\.path), ["ClassicApp/Unused.plist"])
        XCTAssertEqual(record.command, cmd)
        let blocked = VerifyBlocklist.load(root: root)
        XCTAssertEqual(blocked.map(\.path), ["ClassicApp/Unused.plist"])
        XCTAssertEqual(blocked[0].session, session.id)

        // Restoring the session puts the verified file back too and keeps the block list.
        let restore = try CLISupport.run(["restore", root.path])
        XCTAssertEqual(restore.status, 0, restore.stderr)
        XCTAssertTrue(fm.fileExists(atPath: VerifyBlocklist.url(root: root).path))
        XCTAssertEqual(try Data(contentsOf: pbxproj(root)), try Data(contentsOf: FixtureSupport.fixtureURL("ClassicApp").appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")))
    }

    /// `files --delete`: `cannot find 'X' in scope` maps to the file declaring X; the next run skips the blocked path.
    func testDeleteAttributesDeclaredNameAndSkipsBlockedPathNextTime() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        try Data("import Foundation\n\nstruct DeadThing {\n    let x = 1\n}\n".utf8).write(to: root.appendingPathComponent("ClassicApp/DeadThing.swift"))
        let cmd = try failsWithout("ClassicApp/DeadThing.swift",
                                   message: "\(root.path)/ClassicApp/AppDelegate.swift:3:5: error: cannot find 'DeadThing' in scope", root: root)
        let run = try CLISupport.run(["files", root.path, "--delete", "--yes", "--quiet", "--no-swift", "--min-confidence", "medium",
                                      "--format", "json", "--verify", cmd])
        XCTAssertEqual(run.status, 0, run.stderr)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/DeadThing.swift").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/Orphan.swift").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/Unused.plist").path))
        XCTAssertTrue(run.stderr.contains("2 removed and build-verified, 1 blocked (restored)"), run.stderr)
        XCTAssertTrue(run.stderr.contains("blocked ClassicApp/DeadThing.swift: "), run.stderr)
        XCTAssertFalse(run.stdout.contains("Orphan.swift"), "the re-printed report drops what was trashed")
        XCTAssertTrue(run.stdout.contains("DeadThing.swift"), "the restored file is still a finding")

        let again = try CLISupport.run(["files", root.path, "--delete", "--yes", "--quiet", "--no-swift", "--min-confidence", "medium"])
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertTrue(again.stderr.contains("1 skipped: blocked by an earlier --verify (see .xcpurge-trash/verify-blocked.json)"), again.stderr)
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/DeadThing.swift").path))
        XCTAssertEqual(try TrashStore.sessions(root: root).count, 1, "no new session")

        // `remove` warns but proceeds.
        let forced = try CLISupport.run(["remove", root.path, "ClassicApp/DeadThing.swift", "--yes", "--quiet"])
        XCTAssertEqual(forced.status, 0, forced.stderr)
        XCTAssertTrue(forced.stderr.contains("warning: ClassicApp/DeadThing.swift was blocked by an earlier --verify"), forced.stderr)
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/DeadThing.swift").path))
    }

    /// Nothing in the output names a file: bisection finds the culprit within the cap.
    func testUnattributedFailureBisects() async throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let cmd = try failsWithout("ClassicApp/Unused.plist", message: "error: something opaque happened", root: root)
        let run = try CLISupport.run(["remove", root.path, "ClassicApp/unused_loose.png", "ClassicApp/Unused.plist", "--yes", "--quiet",
                                      "--verify", cmd])
        XCTAssertEqual(run.status, 0, run.stderr)
        let fm = FileManager.default
        XCTAssertTrue(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/Unused.plist").path))
        XCTAssertFalse(fm.fileExists(atPath: root.appendingPathComponent("ClassicApp/unused_loose.png").path))
        let expected = try await pbxprojAfterRemoving(["ClassicApp/unused_loose.png"])
        XCTAssertEqual(try Data(contentsOf: pbxproj(root)), expected)
        // All (red), then the two halves: one green, one red.
        XCTAssertTrue(run.stderr.contains("1 removed and build-verified, 1 blocked (restored), 0 restored unverified; 3 build(s) used of 8"), run.stderr)
        XCTAssertTrue(run.stderr.contains("  blocked ClassicApp/Unused.plist: error: something opaque happened"), run.stderr)
        let record = try XCTUnwrap(try TrashStore.sessions(root: root).first?.verify)
        XCTAssertEqual(record.outcome, .partial)
        XCTAssertEqual(record.builds, 4)
        XCTAssertEqual(VerifyBlocklist.paths(root: root), ["ClassicApp/Unused.plist"])
    }

    /// The cap stops the bisection: what was not proven is restored and reported as unverified.
    func testBuildCapRestoresUnverifiedUnits() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let cmd = try failsWithout("ClassicApp/Unused.plist", message: "error: something opaque happened", root: root)
        let run = try CLISupport.run(["remove", root.path, "ClassicApp/unused_loose.png", "ClassicApp/Unused.plist", "--yes", "--quiet",
                                      "--verify", cmd, "--verify-max-builds", "1"])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("0 removed and build-verified, 0 blocked (restored), 2 restored unverified; 1 build(s) used of 1"), run.stderr)
        XCTAssertEqual(try snapshot(root), before)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty, "everything restored: no session left")
        XCTAssertTrue(VerifyBlocklist.paths(root: root).isEmpty)
    }

    /// A timeout after the removal restores everything, exits 4 and leaves no build process behind.
    func testTimeoutRestoresEverythingAndExits4() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let before = try snapshot(root)
        let cmd = try script("[ -e '\(root.path)/ClassicApp/Unused.plist' ] && exit 0; sleep 5.137", near: root)
        let started = Date()
        let run = try CLISupport.run(["remove", root.path, "ClassicApp/unused_loose.png", "ClassicApp/Unused.plist", "--yes", "--quiet",
                                      "--verify", cmd, "--verify-timeout", "1"])
        XCTAssertEqual(run.status, 4, run.stderr)
        XCTAssertLessThan(Date().timeIntervalSince(started), 20)
        XCTAssertTrue(run.stderr.contains("build timed out after 1 s"), run.stderr)
        XCTAssertTrue(run.stderr.contains("everything was restored"), run.stderr)
        XCTAssertEqual(try snapshot(root), before)
        XCTAssertTrue(try TrashStore.sessions(root: root).isEmpty)
        var left = sleepProcesses
        for _ in 0..<20 where !left.isEmpty { Thread.sleep(forTimeInterval: 0.1); left = sleepProcesses }
        XCTAssertEqual(left, "", "leftover processes: \(left)")
    }

    /// Everything builds: the session records a passing verification.
    func testPassingVerificationRecordsOutcome() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let cmd = try script("exit 0", near: root)
        let run = try CLISupport.run(["remove", root.path, "ClassicApp/unused_loose.png", "--yes", "--quiet", "--verify", cmd])
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains("1 removed and build-verified, 0 blocked (restored), 0 restored unverified; 1 build(s) used of 8"), run.stderr)
        XCTAssertTrue(run.stderr.contains(VerifyRunner.limitationLine), run.stderr)
        let record = try XCTUnwrap(try TrashStore.sessions(root: root).first?.verify)
        XCTAssertEqual(record.outcome, .passed)
        XCTAssertEqual(record.builds, 2)
        XCTAssertTrue(record.blocked.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: VerifyBlocklist.url(root: root).path))
    }

    func testVerifyNeedsDelete() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let run = try CLISupport.run(["files", root.path, "--verify", "true", "--quiet"])
        XCTAssertEqual(run.status, 2, run.stderr)
        XCTAssertTrue(run.stderr.contains("--verify needs --delete"), run.stderr)
    }
}
