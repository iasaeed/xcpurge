import XCTest
@testable import XcpurgeKit
@testable import xcpurge

final class GitIgnoreOfferTests: XCTestCase {
    private let hint = "Hint: .xcpurge-trash/ is not in .gitignore. Add it, or run xcpurge with --gitignore to do it for you."

    /// A temp tree removed when the test ends.
    private func tree(_ files: [String: String]) throws -> URL {
        let url = try FixtureSupport.tempTree(files)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    /// A temp tree with one loose file; a git repository without any `.gitignore` when `git` is true.
    private func project(git: Bool) throws -> URL {
        let root = try tree(["App/loose.png": "x"])
        if git {
            let home = try tree(["keep": ""])
            let result = GitIgnoreOffer.git(["init", "-q"], in: root, environment: Self.isolatedGit(home: home))
            XCTAssertEqual(result?.status, 0, "git init failed")
        }
        return root
    }

    /// Environment that keeps git away from the real user and system configuration.
    private static func isolatedGit(home: URL) -> [String: String] {
        let config = home.appendingPathComponent("gitconfig")
        FileManager.default.createFile(atPath: config.path, contents: Data())
        return ["HOME": home.path, "XDG_CONFIG_HOME": home.appendingPathComponent("xdg").path,
                "GIT_CONFIG_GLOBAL": config.path, "GIT_CONFIG_NOSYSTEM": "1",
                "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
    }

    private func cliEnvironment() throws -> [String: String] {
        let home = try tree(["keep": ""])
        return Self.isolatedGit(home: home)
    }

    private func gitignore(_ root: URL) -> String? {
        FileManager.default.contents(atPath: root.appendingPathComponent(".gitignore").path).map { String(decoding: $0, as: UTF8.self) }
    }

    func testGitignoreFlagAddsBothFoldersOnceAndIsIdempotent() throws {
        let root = try project(git: true)
        let env = try cliEnvironment()
        let first = try CLISupport.run(["assets", root.path, "--gitignore", "--no-swift"], environment: env)
        XCTAssertEqual(first.status, 0, first.stderr)
        XCTAssertEqual(gitignore(root), "# xcpurge working folders\n.xcpurge/\n.xcpurge-trash/\n")
        XCTAssertTrue(first.stderr.contains("Added .xcpurge/ to "), first.stderr)
        XCTAssertTrue(first.stderr.contains("Added .xcpurge-trash/ to "), first.stderr)

        let again = try CLISupport.run(["assets", root.path, "--gitignore", "--no-swift"], environment: env)
        XCTAssertEqual(again.status, 0, again.stderr)
        XCTAssertFalse(again.stderr.contains("Added "), again.stderr)
        XCTAssertEqual(gitignore(root), "# xcpurge working folders\n.xcpurge/\n.xcpurge-trash/\n")
    }

    func testGitignoreFlagOnRemoveAppendsAfterAFileWithoutTrailingNewline() throws {
        let root = try project(git: true)
        try Data("build".utf8).write(to: root.appendingPathComponent(".gitignore"))
        let run = try CLISupport.run(["remove", root.path, "App/loose.png", "--gitignore", "--yes", "--quiet"],
                                     environment: try cliEnvironment())
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(gitignore(root), "build\n# xcpurge working folders\n.xcpurge/\n.xcpurge-trash/\n")
        XCTAssertFalse(run.stderr.contains("Hint:"), run.stderr)
    }

    func testNonInteractiveRunInAGitRepositoryPrintsTheHintOnce() throws {
        let root = try project(git: true)
        let env = try cliEnvironment()
        let run = try CLISupport.run(["remove", root.path, "App/loose.png", "--yes"], environment: env)
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertTrue(run.stderr.contains(hint), run.stderr)
        XCTAssertNil(gitignore(root), "the hint never writes")
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(".xcpurge-trash").path))

        // The folder exists now: the user has decided, no more hints.
        try FileManager.default.createDirectory(at: root.appendingPathComponent("App"), withIntermediateDirectories: true)
        try Data("x".utf8).write(to: root.appendingPathComponent("App/second.png"))
        let second = try CLISupport.run(["remove", root.path, "App/second.png", "--yes"], environment: env)
        XCTAssertEqual(second.status, 0, second.stderr)
        XCTAssertFalse(second.stderr.contains("Hint:"), second.stderr)
    }

    func testNoHintWhenQuietIgnoredOrNotAGitRepository() throws {
        let env = try cliEnvironment()
        let plain = try project(git: false)
        let outside = try CLISupport.run(["remove", plain.path, "App/loose.png", "--yes"], environment: env)
        XCTAssertEqual(outside.status, 0, outside.stderr)
        XCTAssertFalse(outside.stderr.contains("Hint:"), outside.stderr)

        let quiet = try project(git: true)
        let q = try CLISupport.run(["remove", quiet.path, "App/loose.png", "--yes", "--quiet"], environment: env)
        XCTAssertEqual(q.status, 0, q.stderr)
        XCTAssertFalse(q.stderr.contains("Hint:"), q.stderr)

        let ignored = try project(git: true)
        try Data(".xcpurge-trash\n".utf8).write(to: ignored.appendingPathComponent(".gitignore"))
        let i = try CLISupport.run(["remove", ignored.path, "App/loose.png", "--yes"], environment: env)
        XCTAssertEqual(i.status, 0, i.stderr)
        XCTAssertFalse(i.stderr.contains("Hint:"), i.stderr)
    }

    func testGlobalExcludesDefaultsToXDGThenHomeConfig() throws {
        let home = try tree(["keep": ""])
        var env = Self.isolatedGit(home: home)
        GitIgnoreOffer.addToGlobal(directory: ".xcpurge-trash", environment: env, quiet: true)
        let xdg = home.appendingPathComponent("xdg/git/ignore")
        XCTAssertEqual(try String(contentsOf: xdg, encoding: .utf8), "# xcpurge working folders\n.xcpurge-trash/\n")
        GitIgnoreOffer.addToGlobal(directory: ".xcpurge-trash", environment: env, quiet: true)
        XCTAssertEqual(try String(contentsOf: xdg, encoding: .utf8), "# xcpurge working folders\n.xcpurge-trash/\n", "no duplicate line")
        GitIgnoreOffer.addToGlobal(directory: ".xcpurge", environment: env, quiet: true)
        XCTAssertEqual(try String(contentsOf: xdg, encoding: .utf8), "# xcpurge working folders\n.xcpurge-trash/\n.xcpurge/\n")

        env["XDG_CONFIG_HOME"] = nil
        GitIgnoreOffer.addToGlobal(directory: ".xcpurge-trash", environment: env, quiet: true)
        let fallback = home.appendingPathComponent(".config/git/ignore")
        XCTAssertEqual(try String(contentsOf: fallback, encoding: .utf8), "# xcpurge working folders\n.xcpurge-trash/\n")
    }

    func testGlobalExcludesHonoursCoreExcludesFileWithTilde() throws {
        let home = try tree(["keep": ""])
        let env = Self.isolatedGit(home: home)
        try Data("[core]\n\texcludesFile = ~/custom/excludes\n".utf8).write(to: URL(fileURLWithPath: env["GIT_CONFIG_GLOBAL"]!))
        GitIgnoreOffer.addToGlobal(directory: ".xcpurge-trash", environment: env, quiet: true)
        let file = home.appendingPathComponent("custom/excludes")
        XCTAssertEqual(try String(contentsOf: file, encoding: .utf8), "# xcpurge working folders\n.xcpurge-trash/\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: home.appendingPathComponent("xdg/git/ignore").path))
    }
}
