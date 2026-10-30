import Foundation

/// `--git`: fills `Finding.history` (last commit, age, author, recently-added bucket) from one streaming
/// `git log --name-only -z` walk per repository, stopped as soon as every finding path has resolved. Never
/// changes confidence or reasons. Shallow clones and non-git roots get a status and a note, never fake dates.
public enum GitHistory {
    public struct Settings: Sendable {
        /// Fill `authorEmail` (names only by default).
        public var emails = false
        /// Run the per-finding `git log -S<name>` heuristic (capped at `deadSinceLimit` findings).
        public var deadSince = false
        /// A path added within this many days is `recentlyAdded`, otherwise `leftover`.
        public var recentDays = 30
        public var gitPath = "/usr/bin/git"
        /// "Now" for `ageDays` (injectable for tests).
        public var now = Date()
        public var deadSinceLimit = 20
        public var deadSinceTimeout: TimeInterval = 15

        public init(emails: Bool = false, deadSince: Bool = false, recentDays: Int = 30, gitPath: String = "/usr/bin/git",
                    now: Date = Date(), deadSinceLimit: Int = 20, deadSinceTimeout: TimeInterval = 15) {
            self.emails = emails
            self.deadSince = deadSince
            self.recentDays = recentDays
            self.gitPath = gitPath
            self.now = now
            self.deadSinceLimit = deadSinceLimit
            self.deadSinceTimeout = deadSinceTimeout
        }
    }

    /// What the walks did (for tests and the stderr note).
    public struct Stats: Sendable, Equatable {
        /// Commits the main walks parsed before stopping.
        public var commitsWalked = 0
        /// Repositories walked (the root's plus initialized submodules holding findings).
        public var repositories = 0
        public var annotated = 0
        public var untracked = 0
        public init() {}
    }

    public static let shallowNote = "n/a (shallow clone; use fetch-depth: 0)"
    static let logFormat = "--format=%x1e%H%x1f%aI%x1f%aN%x1f%aE%x1f%s"
    static let deadSincePathspecs = ["*.swift", "*.m", "*.h", "*.storyboard", "*.xib", "*.plist"]

    /// Annotates every finding; the diagnostics explain anything that could not be annotated.
    public static func annotate(_ findings: [Finding], root: URL, settings: Settings = Settings()) async
        -> ([Finding], [Diagnostics.Entry]) {
        let (out, diags, _) = await annotateDetailed(findings, root: root, settings: settings)
        return (out, diags)
    }

    public static func annotateDetailed(_ findings: [Finding], root: URL, settings: Settings = Settings()) async
        -> ([Finding], [Diagnostics.Entry], Stats) {
        await blocking { annotateSync(findings, root: root, settings: settings) }
    }

    // MARK: - Implementation

    /// One git work tree holding some of the findings.
    private struct Repo {
        var dir: URL
        /// Toplevel-relative display of where it sits (for diagnostics).
        var label: String
        /// Pathspec limiting the walk (root prefix inside this repo), empty for the whole tree.
        var prefix: String
        /// Repo-relative unit path -> finding indices.
        var paths: [String: [Int]] = [:]
    }

    private static func annotateSync(_ findings: [Finding], root: URL, settings: Settings) -> ([Finding], [Diagnostics.Entry], Stats) {
        var out = findings
        var diags: [Diagnostics.Entry] = []
        var stats = Stats()
        guard !findings.isEmpty else { return (out, diags, stats) }
        let git = settings.gitPath

        // 1. The repository the root lives in.
        guard FileManager.default.isExecutableFile(atPath: git),
              let topRaw = capture(git, ["-C", root.path, "rev-parse", "--show-toplevel"]) else {
            for i in out.indices { out[i].history = FindingHistory(status: .notGit, note: "n/a (not a git repository)") }
            diags.append(.init(level: .info, message: "--git: \(root.path) is not inside a git work tree (or git is not installed); history skipped"))
            return (out, diags, stats)
        }
        let top = RelPath.normalize(URL(fileURLWithPath: topRaw).resolvingSymlinksInPath().path)
        let rootPath = RelPath.normalize(root.resolvingSymlinksInPath().path)
        let prefix = RelPath.relative(rootPath, to: top)
        guard !prefix.hasPrefix("..") else {
            for i in out.indices { out[i].history = FindingHistory(status: .notGit, note: "n/a (not a git repository)") }
            diags.append(.init(level: .info, message: "--git: cannot map \(root.path) into \(top); history skipped"))
            return (out, diags, stats)
        }
        if isShallow(git, dir: URL(fileURLWithPath: top)) {
            for i in out.indices { out[i].history = FindingHistory(status: .shallow, note: shallowNote) }
            diags.append(.init(level: .info, message: "--git: shallow clone; history unavailable (use fetch-depth: 0 in CI)"))
            return (out, diags, stats)
        }

        // 2. Route findings to the root repository or an initialized submodule.
        var main = Repo(dir: URL(fileURLWithPath: top), label: ".", prefix: prefix)
        var submodules: [Repo] = submodulePaths(git, top: top).compactMap { sub in
            let dir = RelPath.join(top, sub)
            guard FileManager.default.fileExists(atPath: dir + "/.git") else { return nil }
            return Repo(dir: URL(fileURLWithPath: dir), label: sub, prefix: "")
        }.sorted { $0.label.count > $1.label.count }   // innermost first
        for (i, f) in findings.enumerated() {
            let topPath = RelPath.join(prefix, f.path)
            if let s = submodules.indices.first(where: { RelPath.isUnder(topPath, submodules[$0].label) }) {
                submodules[s].paths[RelPath.relative(topPath, to: submodules[s].label), default: []].append(i)
            } else {
                main.paths[topPath, default: []].append(i)
            }
        }

        // 3. Walk each repository.
        for repo in [main] + submodules where !repo.paths.isEmpty {
            stats.repositories += 1
            if repo.label != ".", isShallow(git, dir: repo.dir) {
                for i in repo.paths.values.joined() { out[i].history = FindingHistory(status: .shallow, note: shallowNote) }
                diags.append(.init(level: .info, message: "--git: submodule \(repo.label) is a shallow clone; history unavailable"))
                continue
            }
            let walk = walk(git, repo: repo)
            stats.commitsWalked += walk.commits
            if let failure = walk.failure {
                diags.append(.init(level: .warning, message: "--git: git log failed in \(repo.label): \(failure)"))
            }
            let added = walk.failure == nil ? recentlyAdded(git, repo: repo, days: settings.recentDays) : []
            for (path, indices) in repo.paths {
                let history: FindingHistory
                if let c = walk.resolved[path] {
                    let commit = FindingHistory.Commit(sha: c.sha, date: c.date, authorName: c.authorName,
                                                       authorEmail: settings.emails ? c.authorEmail : nil, subject: c.subject)
                    let bucket: FindingHistory.Bucket = added.contains(where: { $0 == path || RelPath.isUnder($0, path) })
                        ? .recentlyAdded : .leftover
                    history = FindingHistory(status: .ok, lastCommit: commit, ageDays: ageDays(c.date, now: settings.now), bucket: bucket)
                    stats.annotated += indices.count
                } else if walk.failure != nil {
                    history = FindingHistory(status: .unavailable, note: "n/a (git log failed)")
                } else {
                    history = FindingHistory(status: .untracked, note: "n/a (not committed)")
                    stats.untracked += indices.count
                }
                for i in indices { out[i].history = history }
            }
            if settings.deadSince {
                deadSince(git, repo: repo, findings: &out, settings: settings)
            }
        }
        return (out, diags, stats)
    }

    private struct Walk {
        var resolved: [String: GitLogParser.Commit] = [:]
        var commits = 0
        var failure: String?
    }

    /// One streaming `git log` over the repo (limited to `prefix`), stopped once every path has a commit.
    private static func walk(_ git: String, repo: Repo) -> Walk {
        var walk = Walk()
        var pending = Set(repo.paths.keys)
        var parser = GitLogParser()
        func attribute(_ commit: GitLogParser.Commit) {
            for logged in commit.paths {
                var p = logged
                while !p.isEmpty {
                    if pending.remove(p) != nil { walk.resolved[p] = commit }
                    p = RelPath.parent(p)
                }
            }
        }
        var args = ["-C", repo.dir.path, "log", "--no-renames", logFormat, "--name-only", "-z"]
        if !repo.prefix.isEmpty { args += ["--", repo.prefix] }
        do {
            let outcome = try StreamingProcess.run(git, args) { chunk in
                for commit in parser.feed(chunk) where !pending.isEmpty {
                    walk.commits += 1
                    attribute(commit)
                }
                return !pending.isEmpty
            }
            if !outcome.stoppedEarly {
                for commit in parser.finish() where !pending.isEmpty {
                    walk.commits += 1
                    attribute(commit)
                }
                if outcome.status != 0 {
                    walk.failure = outcome.stderr.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "\n").last.map(String.init)
                        ?? "exit \(outcome.status)"
                }
            }
        } catch {
            walk.failure = "\(error)"
        }
        return walk
    }

    /// Paths added within the window (`--diff-filter=A`), repo-relative.
    private static func recentlyAdded(_ git: String, repo: Repo, days: Int) -> Set<String> {
        guard days > 0 else { return [] }
        var args = ["-C", repo.dir.path, "log", "--since=\(days).days", "--diff-filter=A", "--name-only", "-z", "--format="]
        if !repo.prefix.isEmpty { args += ["--", repo.prefix] }
        guard let (outcome, data) = try? StreamingProcess.capture(git, args), outcome.status == 0 else { return [] }
        return Set(GitLogParser.paths(fromNulSeparated: data))
    }

    /// `git log -S<name> -1` over source-like files for the largest named findings: the commit that last changed
    /// how often the name occurs, which for an unused name is usually the one that removed its last use.
    private static func deadSince(_ git: String, repo: Repo, findings: inout [Finding], settings: Settings) {
        let indices = repo.paths.values.joined().filter { i in
            findings[i].history?.status == .ok && (findings[i].name?.count ?? 0) >= 4
        }
        let chosen = indices.sorted { a, b in
            let sa = findings[a].sizeBytes ?? 0, sb = findings[b].sizeBytes ?? 0
            if sa != sb { return sa > sb }
            return Finding.reportOrder(findings[a], findings[b])
        }.prefix(settings.deadSinceLimit)
        var cache: [String: FindingHistory.Commit?] = [:]
        for i in chosen {
            guard let name = findings[i].name else { continue }
            let commit: FindingHistory.Commit?
            if let cached = cache[name] { commit = cached } else {
                let args = ["-C", repo.dir.path, "log", "-S" + name, "-1", "--format=%H%x1f%aI%x1f%aN%x1f%aE%x1f%s", "--"]
                    + deadSincePathspecs
                if let (outcome, data) = try? StreamingProcess.capture(git, args, timeout: settings.deadSinceTimeout),
                   outcome.status == 0, !outcome.timedOut {
                    let line = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                    let f = line.split(separator: "\u{1f}", maxSplits: 4, omittingEmptySubsequences: false).map(String.init)
                    commit = f.count >= 2 && !f[0].isEmpty
                        ? FindingHistory.Commit(sha: f[0], date: f[1], authorName: f.count > 2 ? f[2] : "",
                                                authorEmail: settings.emails && f.count > 3 && !f[3].isEmpty ? f[3] : nil,
                                                subject: f.count > 4 ? f[4] : "")
                        : nil
                } else {
                    commit = nil
                }
                cache[name] = commit
            }
            findings[i].history?.deadSince = commit
        }
    }

    // MARK: - git helpers

    /// Trimmed stdout of a short git command, nil on failure.
    private static func capture(_ git: String, _ args: [String]) -> String? {
        guard let (outcome, data) = try? StreamingProcess.capture(git, args, timeout: 60), outcome.status == 0 else { return nil }
        let text = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    private static func isShallow(_ git: String, dir: URL) -> Bool {
        capture(git, ["-C", dir.path, "rev-parse", "--is-shallow-repository"]) == "true"
    }

    /// Submodule paths declared in `.gitmodules` (toplevel-relative).
    private static func submodulePaths(_ git: String, top: String) -> [String] {
        guard FileManager.default.fileExists(atPath: top + "/.gitmodules"),
              let text = capture(git, ["-C", top, "config", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.path$"])
        else { return [] }
        return text.split(separator: "\n").compactMap { line in
            guard let space = line.firstIndex(of: " ") else { return nil }
            let path = RelPath.normalize(String(line[line.index(after: space)...]))
            return path.isEmpty ? nil : path
        }
    }

    /// Whole days between an ISO 8601 author date and `now` (never negative; nil when unparseable).
    static func ageDays(_ iso: String, now: Date) -> Int? {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return nil }
        return max(0, Int(now.timeIntervalSince(date) / 86_400))
    }

    private static func blocking<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async { continuation.resume(returning: body()) }
        }
    }
}
