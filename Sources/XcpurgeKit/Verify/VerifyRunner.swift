import Darwin
import Foundation

/// `--verify "<cmd>"`: runs the build before any change (preflight), again after the trash action, and when it
/// fails puts back the removal units the compiler names (`DiagnosticAttributor`), bisecting whatever it cannot
/// attribute, under a build cap and a per-build timeout. The tree always ends in a state that built, or fully
/// restored (timeout, Ctrl-C / SIGTERM, or a red build nothing can be blamed for). Build-verified, not
/// runtime-verified.
public enum VerifyRunner {
    public struct Options: Sendable {
        public var command: String
        /// Seconds per build.
        public var timeout: TimeInterval
        /// Builds after the removal (the preflight is extra).
        public var maxBuilds: Int

        public init(command: String, timeout: TimeInterval = 1800, maxBuilds: Int = 8) {
            self.command = command
            self.timeout = timeout
            self.maxBuilds = max(1, maxBuilds)
        }
    }

    /// Why a verification gave up and restored everything.
    public enum AbortReason: String, Sendable {
        case timedOut = "timed out"
        case interrupted
        /// The build was red and no removal unit could be blamed (nothing left to bisect).
        case unresolved
    }

    public enum Failure: Error, CustomStringConvertible, Sendable {
        /// The command was red (or timed out, or was interrupted) before anything changed; `tail` is the end of
        /// its output.
        case preflightFailed(tail: [String], timedOut: Bool, interrupted: Bool)
        /// The verification stopped and everything was put back (`restoreFailures` lists what could not be).
        case aborted(reason: AbortReason, builds: Int, restoreFailures: [ActionReport.Skip])

        public var description: String {
            switch self {
            case .preflightFailed(_, let timedOut, let interrupted):
                "--verify: build fails before any change\(timedOut ? " (timed out)" : interrupted ? " (interrupted)" : ""); nothing was removed"
            case .aborted(let reason, let builds, let failures):
                "--verify: \(reason.rawValue) after \(builds) build(s); "
                    + (failures.isEmpty ? "everything was restored" : "restored all but \(failures.count) path(s)")
            }
        }
    }

    public static let limitationLine =
        "build-verified, not runtime-verified (dynamic lookups, other schemes/configurations and tests are not covered)"

    public struct Report: Sendable {
        public var verified: [String] = []
        public var blocked: [VerifyRecord.Blocked] = []
        public var restoredUnverified: [String] = []
        /// Entries a restore could not put back (the file could not move back, …).
        public var restoreFailures: [ActionReport.Skip] = []
        /// Builds after the removal.
        public var builds = 0
        public var maxBuilds: Int
        public var outcome: VerifyRecord.Outcome = .passed
        /// The session still exists (has entries) after verification.
        public var sessionKept = true

        /// The stderr summary.
        public var lines: [String] {
            var out = ["--verify: \(verified.count) removed and build-verified, \(blocked.count) blocked (restored), "
                + "\(restoredUnverified.count) restored unverified; \(builds) build(s) used of \(maxBuilds) (plus the preflight)"]
            for b in blocked {
                out.append("  blocked \(b.path): \(b.diagnostic ?? b.reason)")
            }
            for p in restoredUnverified { out.append("  restored unverified \(p): build cap reached") }
            for f in restoreFailures { out.append("  could not restore \(f.path): \(f.reason)") }
            out.append(limitationLine)
            return out
        }

        /// The action report as it stands after verification: only what is still in the trash counts as moved
        /// or rewritten; blocked, unverified and unrestorable paths are listed as skipped with the reason.
        public func adjust(_ action: ActionReport, store: TrashStore) -> ActionReport {
            let still = store.entries
            var out = ActionReport()
            out.moved = action.moved.filter { p in still.contains { $0.action == .moved && $0.path == p } }
            out.rewritten = action.rewritten.filter { p in still.contains { $0.action == .rewritten && $0.path == p } }
            out.skipped = action.skipped
            let failed = Set(restoreFailures.map(\.path))
            for b in blocked where !failed.contains(b.path) {
                out.skipped.append(.init(path: b.path, reason: "blocked by --verify: " + (b.diagnostic ?? b.reason)))
            }
            for p in restoredUnverified where !failed.contains(p) {
                out.skipped.append(.init(path: p, reason: "restored by --verify, not verified: build cap reached"))
            }
            for f in restoreFailures { out.skipped.append(.init(path: f.path, reason: "--verify could not restore it: \(f.reason)")) }
            return out
        }
    }

    /// While a build runs, SIGINT and SIGTERM must not kill xcpurge and orphan the build with the removals
    /// applied: they terminate the build's process group instead, and the caller restores everything.
    final class InterruptGuard {
        private var sources: [any DispatchSourceSignal] = []

        init() {
            ShellRunner.clearInterrupt()
            for sig in [SIGINT, SIGTERM] {
                signal(sig, SIG_IGN)
                let source = DispatchSource.makeSignalSource(signal: sig, queue: .global())
                source.setEventHandler { ShellRunner.interruptAll() }
                source.resume()
                sources.append(source)
            }
        }

        var interrupted: Bool { ShellRunner.wasInterrupted }

        func dispose() {
            for s in sources { s.cancel() }
            sources = []
            signal(SIGINT, SIG_DFL)
            signal(SIGTERM, SIG_DFL)
        }
    }

    /// Runs the command before any change. Throws `Failure.preflightFailed` when it is red, times out or is
    /// interrupted.
    public static func preflight(_ options: Options, root: URL, log: (String) -> Void = { _ in }) throws {
        log("--verify: preflight build (\(options.command))")
        let guardian = InterruptGuard()
        defer { guardian.dispose() }
        let result = ShellRunner.run(options.command, cwd: root, timeout: options.timeout)
        if result.timedOut || result.interrupted || result.status != 0 {
            throw Failure.preflightFailed(tail: result.tail(40), timedOut: result.timedOut, interrupted: result.interrupted)
        }
    }

    /// Verifies the trash session `store` holds after `action` (moved paths are the removal candidates). On
    /// return the tree builds; the session manifest carries the `VerifyRecord` and blocked paths are in
    /// `VerifyBlocklist`. Throws `Failure.aborted` after restoring everything (timeout, interrupt, or a red
    /// build nothing could be blamed for); the record is still written.
    public static func verify(store: TrashStore, context: ScanContext, action: ActionReport, options: Options,
                              log: (String) -> Void = { _ in }) throws -> Report {
        let root = context.root
        let started = Date()
        var report = Report(maxBuilds: options.maxBuilds)
        // The files are already in the trash: read them from their stored copies.
        let storedURL = { (path: String) -> URL? in
            store.entries.first { $0.action == .moved && $0.path == path }.map(store.storedURL)
        }
        let units = RemovalUnits.make(paths: action.moved, context: context, fileURL: storedURL)
        let signatures = DiagnosticAttributor.signatures(for: units, context: context, storedURL: storedURL)
        var active = units                       // removed, not yet verified
        var verified: [RemovalUnit] = []
        var blocked: [(RemovalUnit, String?)] = []
        var unverified: [RemovalUnit] = []
        let guardian = InterruptGuard()
        defer { guardian.dispose() }

        struct Abort: Error { var reason: AbortReason }
        func build(_ what: String) throws -> ShellRunner.Result {
            if guardian.interrupted { throw Abort(reason: .interrupted) }
            report.builds += 1
            log("--verify: build \(report.builds)/\(options.maxBuilds): \(what)")
            let r = ShellRunner.run(options.command, cwd: root, timeout: options.timeout)
            if r.interrupted || guardian.interrupted { throw Abort(reason: .interrupted) }
            if r.timedOut { throw Abort(reason: .timedOut) }
            return r
        }
        func restore(_ set: [RemovalUnit]) throws {
            let paths = Set(set.flatMap(\.paths))
            guard !paths.isEmpty else { return }
            let result = try Restore.run(root: root, sessionID: store.sessionID, paths: paths, context: context)
            report.restoreFailures += result.skipped
            try store.reload()
        }
        /// Trashes the units again; false when some path could not be moved (then nothing of the set stays).
        func retrash(_ set: [RemovalUnit]) throws -> Bool {
            let paths = set.flatMap(\.paths)
            let result = try Trash(store: store).remove(paths: paths, context: context)
            if Set(result.moved) == Set(paths) { return true }
            try restore(set)
            return false
        }
        func halves(_ set: [RemovalUnit]) -> [[RemovalUnit]] {
            set.count < 2 ? [] : [Array(set.prefix(set.count / 2)), Array(set.suffix(from: set.count / 2))]
        }

        do {
            if units.isEmpty, action.rewritten.isEmpty {
                report.outcome = .passed
            } else {
                var result = try build("after removing \(units.count) unit(s)")
                // 1. Attribute from diagnostics while that makes progress.
                while result.status != 0, !active.isEmpty {
                    let hits = DiagnosticAttributor.attribute(output: result.output,
                                                              signatures: signatures.filter { active.contains($0.unit) })
                    guard !hits.isEmpty else { break }
                    let culprits = active.filter { hits[$0.id] != nil }
                    try restore(culprits)
                    for u in culprits { blocked.append((u, hits[u.id])) }
                    active.removeAll { hits[$0.id] != nil }
                    log("--verify: restored \(culprits.count) unit(s) named by the compiler")
                    if active.isEmpty { result.status = 0; break }   // back to the preflight state
                    guard report.builds < options.maxBuilds else { break }
                    result = try build("after restoring \(culprits.count) unit(s)")
                }
                if result.status == 0 {
                    verified = active
                } else if active.isEmpty {
                    // Only project edits (ghost references) are left and the build is red: nothing to bisect.
                    throw Abort(reason: .unresolved)
                } else if report.builds >= options.maxBuilds {
                    try restore(active)
                    unverified = active
                } else {
                    // 2. Bisect what the compiler did not name. Each round trashes a candidate set into the same
                    // session and builds; the tree is always left in the last passing state.
                    try restore(active)
                    var queue = halves(active)
                    if active.count == 1 { blocked.append((active[0], DiagnosticAttributor.firstErrorLine(in: result.output))) }
                    while !queue.isEmpty {
                        guard report.builds < options.maxBuilds else {
                            unverified += queue.flatMap { $0 }
                            break
                        }
                        let candidate = queue.removeFirst()
                        guard try retrash(candidate) else { unverified += candidate; continue }
                        let r = try build("bisect \(candidate.count) unit(s)")
                        if r.status == 0 {
                            verified += candidate
                        } else {
                            try restore(candidate)
                            if candidate.count == 1 {
                                blocked.append((candidate[0], DiagnosticAttributor.firstErrorLine(in: r.output)))
                            } else {
                                queue.insert(contentsOf: halves(candidate), at: 0)
                            }
                        }
                    }
                }
                report.outcome = verified.count == units.count ? .passed : (verified.isEmpty ? .restoredAll : .partial)
            }
        } catch let abort as Abort {
            // Put everything back (what is left in the session), record what happened, and give up.
            var failures = report.restoreFailures
            if FileManager.default.fileExists(atPath: store.sessionURL.path) {
                if let result = try? Restore.run(root: root, sessionID: store.sessionID) { failures += result.skipped }
                try? store.reload()
            }
            let record = VerifyRecord(command: options.command, startedAt: started, builds: report.builds + 1, outcome: .restoredAll,
                                      reason: abort.reason.rawValue)
            // A fully restored session is gone; the record is written into a manifest of its own.
            try? store.setVerify(record)
            throw Failure.aborted(reason: abort.reason, builds: report.builds, restoreFailures: failures)
        }

        report.verified = verified.flatMap(\.paths).sorted()
        report.blocked = blocked.flatMap { unit, diag in
            unit.paths.map { VerifyRecord.Blocked(path: $0, reason: "build failed without it", diagnostic: diag) }
        }.sorted { $0.path < $1.path }
        report.restoredUnverified = unverified.flatMap(\.paths).sorted()
        report.sessionKept = FileManager.default.fileExists(atPath: store.sessionURL.path) && !store.entries.isEmpty
        let record = VerifyRecord(command: options.command, startedAt: started, builds: report.builds + 1,
                                  outcome: report.outcome, blocked: report.blocked)
        if report.sessionKept { try store.setVerify(record) }
        try VerifyBlocklist.add(report.blocked.map {
            VerifyBlocklist.Entry(path: $0.path, reason: $0.diagnostic ?? $0.reason, session: store.sessionID, date: started)
        }, root: root)
        return report
    }
}
