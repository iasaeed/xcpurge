import Foundation
import XCTest
@testable import XcpurgeKit

/// `--git`: temp repositories built with the system git, fixed author/committer dates.
final class GitHistoryTests: XCTestCase {
    static let git = "/usr/bin/git"
    static let day1 = "2024-01-02T03:04:05+00:00"
    static let day2 = "2024-03-02T03:04:05+00:00"
    /// Ten days after `day2`.
    static let now = ISO8601DateFormatter().date(from: "2024-03-12T03:04:05+00:00")!

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard FileManager.default.isExecutableFile(atPath: Self.git) else { throw XCTSkip("git is not installed") }
    }

    /// A temporary git work tree.
    final class Repo {
        let url: URL
        init(_ url: URL) { self.url = url }

        static func make(_ files: [String: String] = [:]) throws -> Repo {
            let repo = Repo(try FixtureSupport.tempTree(files))
            try repo.git(["init", "-q", "-b", "main", "."])
            return repo
        }

        /// Runs git in the repo with a clean config (no global hooks, signing or mailmap).
        @discardableResult
        func git(_ args: [String], env: [String: String] = [:], date: String? = nil) throws -> String {
            var environment = ProcessInfo.processInfo.environment
            environment["GIT_CONFIG_GLOBAL"] = "/dev/null"
            environment["GIT_CONFIG_NOSYSTEM"] = "1"
            if let date { environment["GIT_AUTHOR_DATE"] = date; environment["GIT_COMMITTER_DATE"] = date }
            for (k, v) in env { environment[k] = v }
            let result = try ProcessRunner.run(GitHistoryTests.git, ["-C", url.path] + args, timeout: 60, environment: environment)
            guard result.status == 0 else { throw XCTSkip("git \(args) failed (\(result.status))") }
            return String(decoding: result.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        }

        func write(_ path: String, _ text: String) throws {
            let file = url.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file)
        }

        /// Commits everything with a fixed author and date; returns the sha.
        func commit(_ message: String, author: String = "Jane Doe", email: String = "jane@example.com", date: String) throws -> String {
            try git(["add", "-A"])
            try git(["-c", "user.name=\(author)", "-c", "user.email=\(email)", "commit", "-q", "--allow-empty", "-m", message], date: date)
            return try git(["rev-parse", "HEAD"])
        }
    }

    private func finding(_ path: String, name: String? = nil, size: Int64? = nil) -> Finding {
        Finding(kind: .unusedAsset, category: .assets, path: path, name: name, module: "App", confidence: .high, sizeBytes: size)
    }

    private func annotate(_ findings: [Finding], root: URL, settings: GitHistory.Settings = .init(now: GitHistoryTests.now)) async
        -> ([Finding], [Diagnostics.Entry], GitHistory.Stats) {
        await GitHistory.annotateDetailed(findings, root: root, settings: settings)
    }

    func testLastCommitAgeAuthorAndNoEmailByDefault() async throws {
        let repo = try Repo.make(["App/a.swift": "1\n", "App/b.swift": "1\n"])
        let first = try repo.commit("add both", date: Self.day1)
        try repo.write("App/a.swift", "2\n")
        let second = try repo.commit("touch a", author: "John Roe", email: "john@example.com", date: Self.day2)

        let (out, diags, stats) = await annotate([finding("App/a.swift"), finding("App/b.swift")], root: repo.url)
        XCTAssertTrue(diags.isEmpty, "\(diags)")
        let a = try XCTUnwrap(out[0].history), b = try XCTUnwrap(out[1].history)
        XCTAssertEqual(a.status, .ok)
        XCTAssertEqual(a.lastCommit?.sha, second)
        XCTAssertEqual(a.lastCommit?.authorName, "John Roe")
        XCTAssertNil(a.lastCommit?.authorEmail, "emails only with --git-emails")
        XCTAssertEqual(a.lastCommit?.subject, "touch a")
        XCTAssertEqual(a.lastCommit?.date, "2024-03-02T03:04:05Z", "git's %aI spelling of UTC")
        XCTAssertEqual(a.ageDays, 10)
        XCTAssertEqual(a.bucket, .leftover)
        XCTAssertEqual(b.lastCommit?.sha, first)
        XCTAssertEqual(b.lastCommit?.authorName, "Jane Doe")
        XCTAssertEqual(b.ageDays, 70)
        XCTAssertEqual(stats.annotated, 2)
        XCTAssertEqual(stats.repositories, 1)
        // Confidence and reasons are untouched.
        XCTAssertEqual(out.map(\.confidence), [.high, .high])
        XCTAssertEqual(out.map(\.reasons), [[], []])
    }

    func testEmailsWithTheFlag() async throws {
        let repo = try Repo.make(["a.swift": "1\n"])
        _ = try repo.commit("a", date: Self.day1)
        let (out, _, _) = await annotate([finding("a.swift")], root: repo.url,
                                         settings: .init(emails: true, now: Self.now))
        XCTAssertEqual(out[0].history?.lastCommit?.authorEmail, "jane@example.com")
    }

    /// A folder unit (image set) takes the newest commit of any file inside it.
    func testFolderUnitTakesNewestCommitInside() async throws {
        let repo = try Repo.make(["App/A.xcassets/x.imageset/Contents.json": "{}\n", "App/A.xcassets/x.imageset/x.png": "p\n"])
        _ = try repo.commit("add set", date: Self.day1)
        try repo.write("App/A.xcassets/x.imageset/x.png", "q\n")
        let newer = try repo.commit("replace png", date: Self.day2)
        let (out, _, _) = await annotate([finding("App/A.xcassets/x.imageset", name: "x")], root: repo.url)
        XCTAssertEqual(out[0].history?.lastCommit?.sha, newer)
        XCTAssertEqual(out[0].history?.ageDays, 10)
    }

    func testUntrackedFile() async throws {
        let repo = try Repo.make(["a.swift": "1\n"])
        _ = try repo.commit("a", date: Self.day1)
        try repo.write("new.png", "p")
        let (out, _, stats) = await annotate([finding("new.png"), finding("a.swift")], root: repo.url)
        XCTAssertEqual(out[0].history?.status, .untracked)
        XCTAssertNil(out[0].history?.lastCommit)
        XCTAssertNil(out[0].history?.ageDays)
        XCTAssertEqual(out[0].history?.note, "n/a (not tracked: never committed, ignored or deleted)")
        XCTAssertEqual(out[1].history?.status, .ok)
        XCTAssertEqual(stats.untracked, 1)
    }

    func testNonGitRoot() async throws {
        let root = try FixtureSupport.tempTree(["a.swift": "1\n"])
        let (out, diags, _) = await annotate([finding("a.swift")], root: root)
        XCTAssertEqual(out[0].history?.status, .notGit)
        XCTAssertNil(out[0].history?.lastCommit)
        XCTAssertEqual(diags.count, 1)
        XCTAssertEqual(diags[0].level, .info)
        XCTAssertTrue(diags[0].message.contains("not inside a git work tree"), diags[0].message)
    }

    /// The root is a subfolder of the work tree: paths are mapped through the prefix.
    func testRootInsideRepositorySubfolder() async throws {
        let repo = try Repo.make(["ios/App/a.swift": "1\n", "android/x.kt": "1\n"])
        let sha = try repo.commit("mono", date: Self.day1)
        let (out, _, _) = await annotate([finding("App/a.swift")], root: repo.url.appendingPathComponent("ios"))
        XCTAssertEqual(out[0].history?.status, .ok)
        XCTAssertEqual(out[0].history?.lastCommit?.sha, sha)
    }

    /// Glob characters in the root's folder name are not patterns.
    func testRootPrefixWithGlobCharactersIsLiteral() async throws {
        let repo = try Repo.make(["ios[1]/App/a.swift": "1\n", "ios1/App/a.swift": "1\n"])
        let sha = try repo.commit("mono", date: Self.day1)
        try repo.write("ios1/App/a.swift", "2\n")
        _ = try repo.commit("touch the other", date: Self.day2)
        let (out, _, _) = await annotate([finding("App/a.swift")], root: repo.url.appendingPathComponent("ios[1]"))
        XCTAssertEqual(out[0].history?.status, .ok)
        XCTAssertEqual(out[0].history?.lastCommit?.sha, sha, "not the commit that touched ios1/")
    }

    /// A ghost reference (the project names a file that is gone) shows the commit that deleted the file.
    func testGhostReferenceShowsDeletionCommit() async throws {
        let repo = try Repo.make(["App/Gone.swift": "1\n", "App/keep.swift": "1\n"])
        _ = try repo.commit("add", date: Self.day1)
        try FileManager.default.removeItem(at: repo.url.appendingPathComponent("App/Gone.swift"))
        let deletion = try repo.commit("delete Gone", author: "Deleter", date: Self.day2)
        let ghost = Finding(kind: .ghostReference, category: .files, path: "App/Gone.swift", module: "App", confidence: .high)
        let never = Finding(kind: .ghostReference, category: .files, path: "App/NeverWas.swift", module: "App", confidence: .high)
        let (out, _, stats) = await annotate([ghost, never, finding("App/keep.swift")], root: repo.url)
        XCTAssertEqual(out[0].history?.status, .ok)
        XCTAssertEqual(out[0].history?.lastCommit?.sha, deletion)
        XCTAssertEqual(out[0].history?.lastCommit?.authorName, "Deleter")
        XCTAssertEqual(out[0].history?.ageDays, 10)
        XCTAssertEqual(out[0].history?.note, "deleted in \(deletion.prefix(7))")
        XCTAssertNil(out[0].history?.bucket)
        XCTAssertEqual(out[1].history?.status, .untracked, "a ghost that was never committed")
        XCTAssertEqual(out[2].history?.status, .ok)
        XCTAssertEqual(stats.annotated, 2)
        XCTAssertEqual(stats.untracked, 1)
    }

    func testShallowCloneGivesNoteAndNoDates() async throws {
        let origin = try Repo.make(["a.swift": "1\n"])
        _ = try origin.commit("one", date: Self.day1)
        try origin.write("a.swift", "2\n")
        _ = try origin.commit("two", date: Self.day2)
        let dir = try FixtureSupport.tempTree([:])
        let clone = Repo(dir.appendingPathComponent("clone"))
        try origin.git(["clone", "-q", "--depth", "1", "file://" + origin.url.path, clone.url.path])
        XCTAssertEqual(try clone.git(["rev-parse", "--is-shallow-repository"]), "true")

        let (out, diags, _) = await annotate([finding("a.swift")], root: clone.url)
        XCTAssertEqual(out[0].history?.status, .shallow)
        XCTAssertEqual(out[0].history?.note, GitHistory.shallowNote)
        XCTAssertNil(out[0].history?.lastCommit)
        XCTAssertNil(out[0].history?.ageDays)
        XCTAssertTrue(diags.contains { $0.message.contains("shallow clone") }, "\(diags)")
    }

    func testSubmoduleFindingsUseTheSubmodulesHistory() async throws {
        let lib = try Repo.make(["lib.swift": "1\n", "Res/old.png": "p\n"])
        let libSha = try lib.commit("lib", author: "Lib Author", date: Self.day1)
        let app = try Repo.make(["App/a.swift": "1\n"])
        let appSha = try app.commit("app", date: Self.day2)
        try app.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", "file://" + lib.url.path, "Vendor/Lib"])
        _ = try app.commit("add submodule", date: Self.day2)

        let (out, diags, stats) = await annotate([finding("Vendor/Lib/Res/old.png"), finding("App/a.swift")], root: app.url)
        XCTAssertTrue(diags.isEmpty, "\(diags)")
        XCTAssertEqual(stats.repositories, 2)
        XCTAssertEqual(out[0].history?.status, .ok)
        XCTAssertEqual(out[0].history?.lastCommit?.sha, libSha)
        XCTAssertEqual(out[0].history?.lastCommit?.authorName, "Lib Author")
        XCTAssertEqual(out[1].history?.lastCommit?.sha, appSha)
    }

    func testMailmapRenamesAuthor() async throws {
        let repo = try Repo.make(["a.swift": "1\n", ".mailmap": "Proper Name <proper@example.com> <jane@example.com>\n"])
        _ = try repo.commit("a", date: Self.day1)
        let (out, _, _) = await annotate([finding("a.swift")], root: repo.url, settings: .init(emails: true, now: Self.now))
        XCTAssertEqual(out[0].history?.lastCommit?.authorName, "Proper Name")
        XCTAssertEqual(out[0].history?.lastCommit?.authorEmail, "proper@example.com")
    }

    func testRecentlyAddedVersusLeftover() async throws {
        let repo = try Repo.make(["old.swift": "1\n"])
        _ = try repo.commit("old", date: Self.day1)
        try repo.write("fresh.swift", "1\n")
        let today = ISO8601DateFormatter().string(from: Date())
        _ = try repo.commit("fresh", date: today)
        let (out, _, _) = await annotate([finding("old.swift"), finding("fresh.swift")], root: repo.url,
                                         settings: .init(recentDays: 30, now: Date()))
        XCTAssertEqual(out[0].history?.bucket, .leftover)
        XCTAssertEqual(out[1].history?.bucket, .recentlyAdded)
        XCTAssertEqual(out[1].history?.ageDays, 0)
        // A window of 0 days turns the bucket pass off: everything is a leftover.
        let (none, _, _) = await annotate([finding("fresh.swift")], root: repo.url, settings: .init(recentDays: 0, now: Date()))
        XCTAssertEqual(none[0].history?.bucket, .leftover)
    }

    /// The walk stops once every path has a commit: with the finding touched by the newest commit, the older
    /// history is never parsed, however long it is.
    func testWalkStopsEarly() async throws {
        let repo = try Repo.make(["other.txt": "0\n"])
        _ = try repo.commit("base", date: Self.day1)
        // Enough history to overflow the pipe buffer several times (long subjects).
        let subject = String(repeating: "x", count: 600)
        let script = "cd \"\(repo.url.path)\" && for i in $(seq 1 200); do echo $i > other.txt; git add -A; "
            + "git -c user.name=A -c user.email=a@example.com commit -q -m \"\(subject) $i\"; done"
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_AUTHOR_DATE"] = Self.day1
        env["GIT_COMMITTER_DATE"] = Self.day1
        let made = try ProcessRunner.run("/bin/sh", ["-c", script], timeout: 120, environment: env)
        XCTAssertEqual(made.status, 0)
        try repo.write("a.swift", "1\n")
        let newest = try repo.commit("newest", date: Self.day2)
        XCTAssertEqual(Int(try repo.git(["rev-list", "--count", "HEAD"])), 202)

        // An uncommitted path (and a ghost: a file that never existed) must not hold the walk up.
        try repo.write("loose.png", "p")
        let (out, _, stats) = await annotate([finding("a.swift"), finding("loose.png"), finding("Ghost.swift")], root: repo.url)
        XCTAssertEqual(out[0].history?.lastCommit?.sha, newest)
        XCTAssertEqual(out[1].history?.status, .untracked)
        XCTAssertEqual(out[2].history?.status, .untracked)
        XCTAssertLessThan(stats.commitsWalked, 202, "the walk stopped before the end of history")
    }

    /// Dead-since: the newest commit changing how often the name occurs in source-like files.
    func testDeadSinceHeuristic() async throws {
        let repo = try Repo.make(["App/A.xcassets/hero_image.imageset/Contents.json": "{}\n", "App/V.swift": "Image(\"hero_image\")\n"])
        _ = try repo.commit("use hero", date: Self.day1)
        try repo.write("App/V.swift", "Image(\"other\")\n")
        let removal = try repo.commit("stop using hero", date: Self.day2)
        let f = finding("App/A.xcassets/hero_image.imageset", name: "hero_image", size: 10)
        let short = finding("App/A.xcassets/hero_image.imageset", name: "abc", size: 10)
        let (out, _, _) = await annotate([f, short], root: repo.url, settings: .init(deadSince: true, now: Self.now))
        XCTAssertEqual(out[0].history?.deadSince?.sha, removal)
        XCTAssertEqual(out[0].history?.deadSince?.subject, "stop using hero")
        XCTAssertNil(out[1].history?.deadSince, "names under 4 characters are skipped")
        let (off, _, _) = await annotate([f], root: repo.url)
        XCTAssertNil(off[0].history?.deadSince, "only with --git-dead-since")
    }

    /// The CLI: findings are identical with and without `--git` except for `history`.
    func testCLIConfidenceIdenticalWithAndWithoutGit() throws {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let repo = Repo(root)
        try repo.git(["init", "-q", "."])
        _ = try repo.commit("fixture", date: Self.day1)
        let plain = try CLISupport.run(["scan", root.path, "--format", "json", "--quiet", "--no-swift"])
        let git = try CLISupport.run(["scan", root.path, "--format", "json", "--quiet", "--no-swift", "--git"])
        XCTAssertEqual(plain.status, 0, plain.stderr)
        XCTAssertEqual(git.status, 0, git.stderr)
        struct Doc: Decodable { var findings: [Finding] }
        let a = try JSONDecoder().decode(Doc.self, from: Data(plain.stdout.utf8)).findings
        let b = try JSONDecoder().decode(Doc.self, from: Data(git.stdout.utf8)).findings
        XCTAssertFalse(a.isEmpty)
        XCTAssertTrue(a.allSatisfy { $0.history == nil })
        for f in b {
            // The ghost reference points at a file that never existed, so it has no history.
            let expected: FindingHistory.Status = f.kind == .ghostReference ? .untracked : .ok
            XCTAssertEqual(f.history?.status, expected, f.path)
            if expected == .ok { XCTAssertEqual(f.history?.lastCommit?.authorName, "Jane Doe", f.path) }
        }
        let strip = { (f: Finding) -> Finding in var g = f; g.history = nil; return g }
        XCTAssertEqual(a, b.map(strip))
        XCTAssertTrue(git.stdout.contains("\"history\""))
    }

    func testParserHandlesSplitChunksAndEmptyCommits() {
        let text = "\u{1e}aaa\u{1f}2024-01-02T03:04:05+00:00\u{1f}Jane\u{1f}j@x\u{1f}subject one\0\nApp/a.swift\0App/b.swift\0"
            + "\u{1e}bbb\u{1f}2024-01-01T00:00:00+00:00\u{1f}John\u{1f}\u{1f}empty\0"
            + "\u{1e}ccc\u{1f}2023-12-31T00:00:00+00:00\u{1f}Jo\u{1f}jo@x\u{1f}last\0\nz.png\0"
        let data = Data(text.utf8)
        var parser = GitLogParser()
        var commits: [GitLogParser.Commit] = []
        for i in stride(from: 0, to: data.count, by: 7) {
            commits += parser.feed(data[i..<min(i + 7, data.count)])
        }
        commits += parser.finish()
        XCTAssertEqual(commits.map(\.sha), ["aaa", "bbb", "ccc"])
        XCTAssertEqual(commits[0].paths, ["App/a.swift", "App/b.swift"])
        XCTAssertEqual(commits[0].authorName, "Jane")
        XCTAssertEqual(commits[0].subject, "subject one")
        XCTAssertEqual(commits[1].paths, [])
        XCTAssertEqual(commits[1].authorEmail, "")
        XCTAssertEqual(commits[2].paths, ["z.png"])
        XCTAssertEqual(GitLogParser.paths(fromNulSeparated: Data("\nA/b\0\0C\0".utf8)), ["A/b", "C"])
        XCTAssertEqual(GitHistory.ageDays("2024-03-02T03:04:05+00:00", now: Self.now), 10)
        XCTAssertNil(GitHistory.ageDays("yesterday", now: Self.now))
    }
}
