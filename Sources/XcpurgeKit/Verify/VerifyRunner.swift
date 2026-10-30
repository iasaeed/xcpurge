import Foundation

/// `--verify "<cmd>"`: runs the build before any change (preflight), again after the trash action, and when it
/// fails puts back the removal units the compiler names (`DiagnosticAttributor`), bisecting whatever it cannot
/// attribute, under a build cap and a per-build timeout. The tree always ends in a state that built (or fully
/// restored on timeout). Build-verified, not runtime-verified.
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

    public enum Failure: Error, CustomStringConvertible, Sendable {
        /// The command was red (or timed out) before anything changed; `tail` is the end of its output.
        case preflightFailed(tail: [String], timedOut: Bool)
        /// A build timed out after the removal; everything was restored.
        case timedOut(builds: Int)

        public var description: String {
            switch self {
            case .preflightFailed(_, let timedOut):
                "--verify: build fails before any change\(timedOut ? " (timed out)" : ""); nothing was removed"
            case .timedOut(let builds):
                "--verify: build timed out (after \(builds) build(s)); everything was restored"
            }
        }
    }

    public static let limitationLine =
        "build-verified, not runtime-verified (dynamic lookups, other schemes/configurations and tests are not covered)"

    public struct Report: Sendable {
        public var verified: [String] = []
        public var blocked: [VerifyRecord.Blocked] = []
        public var restoredUnverified: [String] = []
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
            out.append(limitationLine)
            return out
        }

        /// The action report as it stands after verification: only what is still in the trash counts as moved
        /// or rewritten; blocked and unverified paths are listed as skipped with the reason.
        public func adjust(_ action: ActionReport, store: TrashStore) -> ActionReport {
            let still = store.entries
            var out = ActionReport()
            out.moved = action.moved.filter { p in still.contains { $0.action == .moved && $0.path == p } }
            out.rewritten = action.rewritten.filter { p in still.contains { $0.action == .rewritten && $0.path == p } }
            out.skipped = action.skipped
            for b in blocked { out.skipped.append(.init(path: b.path, reason: "blocked by --verify: " + (b.diagnostic ?? b.reason))) }
            for p in restoredUnverified { out.skipped.append(.init(path: p, reason: "restored by --verify, not verified: build cap reached")) }
            return out
        }
    }

    /// Runs the command before any change. Throws `Failure.preflightFailed` when it is red or times out.
    public static func preflight(_ options: Options, root: URL, log: (String) -> Void = { _ in }) throws {
        log("--verify: preflight build (\(options.command))")
        let result = ShellRunner.run(options.command, cwd: root, timeout: options.timeout)
        if result.timedOut || result.status != 0 {
            throw Failure.preflightFailed(tail: result.tail(40), timedOut: result.timedOut)
        }
    }

    /// Verifies the trash session `store` holds after `action` (moved paths are the removal candidates). On
    /// return the tree builds; the session manifest carries the `VerifyRecord` and blocked paths are in
    /// `VerifyBlocklist`. Throws `Failure.timedOut` after restoring everything.
    public static func verify(store: TrashStore, context: ScanContext, action: ActionReport, options: Options,
                              log: (String) -> Void = { _ in }) throws -> Report {
        let root = context.root
        let started = Date()
        var report = Report(maxBuilds: options.maxBuilds)
        let units = RemovalUnits.make(paths: action.moved, context: context)
        let storedURL = { (path: String) -> URL? in
            store.entries.first { $0.action == .moved && $0.path == path }.map(store.storedURL)
        }
        let signatures = DiagnosticAttributor.signatures(for: units, context: context, storedURL: storedURL)
        var active = units                       // removed, not yet verified
        var verified: [RemovalUnit] = []
        var blocked: [(RemovalUnit, String?)] = []
        var unverified: [RemovalUnit] = []

        struct Timeout: Error {}
        func build(_ what: String) throws -> ShellRunner.Result {
            report.builds += 1
            log("--verify: build \(report.builds)/\(options.maxBuilds): \(what)")
            let r = ShellRunner.run(options.command, cwd: root, timeout: options.timeout)
            if r.timedOut { throw Timeout() }
            return r
        }
        func restore(_ set: [RemovalUnit]) throws {
            let paths = Set(set.flatMap(\.paths))
            guard !paths.isEmpty else { return }
            _ = try Restore.run(root: root, sessionID: store.sessionID, paths: paths, context: context)
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

        do {
            if units.isEmpty, action.rewritten.isEmpty {
                report.outcome = .passed
            } else {
                var result = try build("after removing \(units.count) unit(s)")
                // 1. Attribute from diagnostics while that makes progress.
                while result.status != 0 {
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
                } else if report.builds >= options.maxBuilds {
                    try restore(active)
                    unverified = active
                } else {
                    // 2. Bisect what the compiler did not name. Each round trashes a candidate set into the same
                    // session and builds; the tree is always left in the last passing state.
                    try restore(active)
                    var queue: [[RemovalUnit]] = active.count == 1 ? [] : [Array(active.prefix(active.count / 2)), Array(active.suffix(from: active.count / 2))]
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
                                queue.insert(contentsOf: [Array(candidate.prefix(candidate.count / 2)),
                                                          Array(candidate.suffix(from: candidate.count / 2))], at: 0)
                            }
                        }
                    }
                }
                report.outcome = verified.count == units.count ? .passed : (verified.isEmpty ? .restoredAll : .partial)
            }
        } catch is Timeout {
            if FileManager.default.fileExists(atPath: store.sessionURL.path) {
                _ = try? Restore.run(root: root, sessionID: store.sessionID)
                try? store.reload()
            }
            throw Failure.timedOut(builds: report.builds)
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
