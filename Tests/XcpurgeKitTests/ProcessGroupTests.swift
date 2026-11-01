import XCTest
@testable import XcpurgeKit

/// `dump-package` children lead their own process group, are killed with it on a timeout or an interrupt, and a
/// manifest that never finishes falls back to the text parser with a warning.
final class ProcessGroupTests: XCTestCase {
    /// A command line only these tests produce (the digit varies, so this source never contains it).
    private func sleeper(_ tag: Int) -> String { "sleep 4\(tag).5" }

    private func pgrep(_ marker: String) -> String {
        (try? ProcessRunner.run("/usr/bin/pgrep", ["-f", marker], timeout: 10))
            .map { String(decoding: $0.stdout, as: UTF8.self) } ?? ""
    }

    /// Polls until nothing matches `marker` (the kernel needs a moment to reap).
    private func waitUntilGone(_ marker: String) -> String {
        var left = pgrep(marker)
        for _ in 0..<50 where !left.isEmpty {
            usleep(100_000)
            left = pgrep(marker)
        }
        return left
    }

    func testTimeoutKillsTheWholeGroup() throws {
        let started = Date()
        let result = try ProcessRunner.run("/bin/sh", ["-c", "\(sleeper(1)) & \(sleeper(1)); wait"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertLessThan(Date().timeIntervalSince(started), 8, "the run ends at the timeout, not when sleep does")
        XCTAssertEqual(waitUntilGone(sleeper(1)), "", "children of the child die too")
    }

    /// `swift package` runs the compiled manifest in a process group of its own; `set -m` makes `sh` do the same.
    func testTimeoutAlsoKillsDescendantsInOtherGroups() throws {
        let result = try ProcessRunner.run("/bin/sh", ["-c", "set -m; \(sleeper(3)) & wait"], timeout: 1)
        XCTAssertTrue(result.timedOut)
        XCTAssertEqual(waitUntilGone(sleeper(3)), "")
    }

    func testOutputStatusAndEnvironmentStillWork() throws {
        let ok = try ProcessRunner.run("/bin/sh", ["-c", "printf %s \"$XCPURGE_T\"; echo err >&2; exit 3"], timeout: 10,
                                       environment: ["XCPURGE_T": "value"])
        XCTAssertEqual(String(decoding: ok.stdout, as: UTF8.self), "value", "stderr is discarded")
        XCTAssertEqual(ok.status, 3)
        XCTAssertFalse(ok.timedOut)
    }

    func testChildLeadsItsOwnProcessGroup() throws {
        let result = try ProcessRunner.run("/bin/sh", ["-c", "ps -o pgid= -p $$; echo $$"], timeout: 10)
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
        XCTAssertEqual(lines.first, lines.last, "pgid equals the child's pid")
        XCTAssertNotEqual(lines.first, String(getpgrp()))
    }

    private final class Box: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: ProcessRunner.Result?
        var result: ProcessRunner.Result? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    func testKillAllStopsRunningChildren() throws {
        let box = Box()
        let done = DispatchSemaphore(value: 0)
        let command = "\(sleeper(2)) & \(sleeper(2)); wait"
        DispatchQueue.global().async {
            box.result = try? ProcessRunner.run("/bin/sh", ["-c", command], timeout: 60)
            done.signal()
        }
        for _ in 0..<100 where pgrep(sleeper(2)).isEmpty { usleep(100_000) }
        XCTAssertFalse(pgrep(sleeper(2)).isEmpty, "started")
        ProcessRunner.killAll()
        XCTAssertEqual(done.wait(timeout: .now() + 10), .success, "the run ends when its group is killed")
        let result = try XCTUnwrap(box.result)
        XCTAssertFalse(result.timedOut)
        XCTAssertNotEqual(result.status, 0)
        XCTAssertEqual(waitUntilGone(sleeper(2)), "")
    }

    func testInterruptGuardRestoresSignalHandlers() {
        let before = signal(SIGINT, SIG_IGN)
        defer { signal(SIGINT, before) }
        let guardian = ProcessRunner.InterruptGuard()
        let during = signal(SIGINT, SIG_IGN)
        XCTAssertEqual(unsafeBitCast(during, to: Int.self), unsafeBitCast(SIG_IGN, to: Int.self), "ignored while the guard is up")
        guardian.dispose()
        let after = signal(SIGINT, SIG_DFL)
        XCTAssertEqual(unsafeBitCast(after, to: Int.self), unsafeBitCast(SIG_IGN, to: Int.self), "back to what it was")
    }

    func testManifestThatHangsFallsBackToTheTextParser() async throws {
        try XCTSkipIf(ProcessInfo.processInfo.environment["XCPURGE_NO_SWIFT"] != nil,
                      "XCPURGE_NO_SWIFT disables manifest execution, so nothing can time out")
        let root = FixtureSupport.fixtureURL("ModularWorkspace")
        let diagnostics = Diagnostics()
        let started = Date()
        let models = await PackageManifest.load(packageDirs: ["Packages/Core", "Packages/DesignSystem"], root: root,
                                                useSwift: true, diagnostics: diagnostics, timeout: 1,
                                                swift: ["/bin/sh", "-c", sleeper(4)])
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
        XCTAssertEqual(models.map(\.container), ["Packages/Core", "Packages/DesignSystem"], "text fallback still builds both")
        let warnings = diagnostics.entries.filter { $0.level == .warning && $0.message.contains("timed out after 1 s") }
        XCTAssertEqual(warnings.compactMap(\.path), ["Packages/Core/Package.swift", "Packages/DesignSystem/Package.swift"])
        XCTAssertTrue(warnings.allSatisfy { $0.message.contains("using manifest text fallback") })
        XCTAssertEqual(waitUntilGone(sleeper(4)), "")
    }

    func testDefaultTimeoutIsSixtySeconds() {
        XCTAssertEqual(PackageManifest.dumpTimeout, 60)
    }

    /// Review: with dozens of manifests every `dump-package` blocked a global-pool thread, so the signal sources (also
    /// on the global queue) never ran and Ctrl-C waited for the manifests. Signals now have their own queue and runs
    /// are capped at the core count: SIGTERM stops a scan of 72 hanging manifests at once.
    func testSigtermStopsAScanOfManyHangingManifests() throws {
        guard FileManager.default.isExecutableFile(atPath: CLISupport.binary.path) else { throw XCTSkip("xcpurge not built") }
        let marker = sleeper(6)
        var files: [String: String] = ["bin/swift": "#!/bin/sh\nexec \(marker)\n"]
        for i in 0..<72 {
            let name = String(format: "P%02d", i)
            files["\(name)/Package.swift"] = "// swift-tools-version: 5.9\nimport PackageDescription\nlet package = Package(name: \"\(name)\")\n"
        }
        let root = try FixtureSupport.tempTree(files)
        let stub = root.appendingPathComponent("bin/swift")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: stub.path)

        let process = Process()
        process.executableURL = CLISupport.binary
        process.arguments = ["scan", root.path, "--quiet", "--format", "json", "--output", root.appendingPathComponent("out.json").path]
        var environment = ProcessInfo.processInfo.environment
        environment["PATH"] = root.appendingPathComponent("bin").path + ":/usr/bin:/bin"
        environment["XCPURGE_NO_SWIFT"] = nil
        process.environment = environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        defer {
            if process.isRunning { kill(process.processIdentifier, SIGKILL) }
            _ = try? ProcessRunner.run("/usr/bin/pkill", ["-9", "-f", marker], timeout: 10)
        }
        for _ in 0..<100 where pgrep(marker).isEmpty { usleep(100_000) }
        XCTAssertFalse(pgrep(marker).isEmpty, "manifests started")
        let running = pgrep(marker).split(separator: "\n").count
        XCTAssertLessThanOrEqual(running, ProcessInfo.processInfo.activeProcessorCount, "dump-package runs are capped")

        let sent = Date()
        kill(process.processIdentifier, SIGTERM)
        let exited = DispatchSemaphore(value: 0)
        DispatchQueue.global().async { process.waitUntilExit(); exited.signal() }
        XCTAssertEqual(exited.wait(timeout: .now() + 5), .success, "SIGTERM stops the scan")
        XCTAssertLessThan(Date().timeIntervalSince(sent), 2)
        XCTAssertEqual(process.terminationReason, .uncaughtSignal)
        XCTAssertEqual(waitUntilGone(marker), "", "no manifest run is left behind")
    }
}
