// LANE: C
import ArgumentParser
import Foundation
import XcpurgeKit

/// `--verify` flags shared by `assets --delete`, `files --delete` and `remove`.
struct VerifyOptions: ParsableArguments {
    @Option(help: ArgumentHelp(
        "Build command run before the removal and after it; removals the build cannot do without are put back and blocked.",
        discussion: "Runs through /bin/sh in the root. Example: --verify \"xcodebuild -scheme App -destination 'generic/platform=iOS' "
            + "-derivedDataPath .build/verify -quiet build\". Build-verified only: runtime lookups, other schemes and tests are not covered."))
    var verify: String?
    @Option(help: "Seconds per --verify build; a timeout restores everything and exits 4.") var verifyTimeout: Int = 1800
    @Option(help: "Most builds --verify may run after the removal (attribution and bisection); the preflight is extra.")
    var verifyMaxBuilds: Int = 8

    var enabled: Bool { verify != nil }

    var runnerOptions: VerifyRunner.Options? {
        verify.map { VerifyRunner.Options(command: $0, timeout: TimeInterval(verifyTimeout), maxBuilds: verifyMaxBuilds) }
    }

    func validate() throws {
        if let verify, verify.trimmingCharacters(in: .whitespaces).isEmpty { throw ValidationError("--verify needs a command") }
        if verifyTimeout <= 0 { throw ValidationError("--verify-timeout must be positive") }
        if verifyMaxBuilds <= 0 { throw ValidationError("--verify-max-builds must be positive") }
    }
}

/// The verify steps around a trash action, with their stderr output and exit codes.
enum VerifyStep {
    /// Runs the preflight build; a red build prints its last 40 lines and exits 4.
    static func preflight(_ options: VerifyOptions, root: URL, quiet: Bool) throws {
        guard let runner = options.runnerOptions else { return }
        do {
            try VerifyRunner.preflight(runner, root: root) { if !quiet { ScanRunner.stderr($0 + "\n") } }
        } catch VerifyRunner.Failure.preflightFailed(let tail, let timedOut) {
            var text = tail.joined(separator: "\n")
            if !text.isEmpty { text += "\n" }
            text += "error: --verify: build fails before any change\(timedOut ? " (timed out after \(options.verifyTimeout) s)" : ""); nothing was removed\n"
            ScanRunner.stderr(text)
            throw XcpurgeExit.verifyFailed.exitCode
        }
    }

    /// Verifies the session after the action; returns the action report as it stands afterwards. A timeout
    /// (everything restored) exits 4.
    static func verify(_ options: VerifyOptions, store: TrashStore, context: ScanContext, action: ActionReport,
                       quiet: Bool) throws -> ActionReport {
        guard let runner = options.runnerOptions else { return action }
        guard FileManager.default.fileExists(atPath: store.sessionURL.path) else { return action }
        do {
            let report = try VerifyRunner.verify(store: store, context: context, action: action, options: runner) {
                if !quiet { ScanRunner.stderr($0 + "\n") }
            }
            ScanRunner.stderr(report.lines.joined(separator: "\n") + "\n")
            return report.adjust(action, store: store)
        } catch VerifyRunner.Failure.timedOut(let builds) {
            ScanRunner.stderr("error: --verify: build timed out after \(options.verifyTimeout) s (\(builds) build(s) after the removal); "
                + "everything was restored\n")
            throw XcpurgeExit.verifyFailed.exitCode
        }
    }

    /// Splits `--delete` candidates into those to act on and those an earlier `--verify` blocked; says so.
    static func dropBlocked(_ findings: [Finding], root: URL) -> [Finding] {
        let blocked = VerifyBlocklist.paths(root: root)
        guard !blocked.isEmpty else { return findings }
        let kept = findings.filter { !blocked.contains($0.path) }
        let skipped = findings.count - kept.count
        if skipped > 0 {
            ScanRunner.stderr("\(skipped) skipped: blocked by an earlier --verify (see \(TrashStore.directoryName)/\(VerifyBlocklist.fileName))\n")
        }
        return kept
    }

    /// `remove` proceeds for blocked paths, with a warning.
    static func warnBlocked(_ paths: [String], root: URL) {
        let blocked = VerifyBlocklist.load(root: root)
        for path in paths {
            if let entry = blocked.first(where: { $0.path == path }) {
                ScanRunner.stderr("warning: \(path) was blocked by an earlier --verify (\(entry.reason)); removing anyway\n")
            }
        }
    }
}
