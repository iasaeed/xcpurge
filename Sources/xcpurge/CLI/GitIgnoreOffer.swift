import Foundation
import XcpurgeKit

/// xcpurge writes `.xcpurge-trash/` and `.xcpurge/` into the project root; in a git work tree they would show up in
/// the commit dialog. Right before the first creation of each folder this offers to add it to a `.gitignore`.
/// Never fails the command: any problem with git or the file system ends the step silently (or with a warning).
enum GitIgnoreOffer {
    /// The folders xcpurge creates under the root.
    static let directories = [ToolOutput.reportDirectoryName, TrashStore.directoryName]
    static let comment = "# xcpurge working folders"
    static let gitTimeout: TimeInterval = 2

    /// Offers to ignore `directory` (a folder name under `root`, without a slash). Does nothing when the folder
    /// already exists (the user decided on an earlier run), `root` is not in a git work tree, or git already ignores it.
    /// On a terminal it asks; with `assumeYes`, `quiet` or no terminal it only prints a hint (not under `quiet`).
    static func offer(root: URL, directory: String, assumeYes: Bool, quiet: Bool) {
        guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(directory).path),
              needsEntry(root: root, directory: directory) else { return }
        let interactive = !assumeYes && !quiet && isatty(STDIN_FILENO) != 0 && StderrTerminal.isTTY
        guard interactive else {
            if !quiet {
                ScanRunner.stderr("Hint: \(directory)/ is not in .gitignore. "
                    + "Add it, or run xcpurge with --gitignore to do it for you.\n")
            }
            return
        }
        ScanRunner.stderr("xcpurge is about to create \(directory)/ and it is not ignored by git.\n"
            + "Add it to .gitignore? [Y]es, project .gitignore / [g]lobal git excludes / [n]o: ")
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased() ?? "n"
        switch answer {
        case "", "y", "yes": addToProject(root: root, directory: directory, quiet: false)
        case "g", "global": addToGlobal(directory: directory, environment: ProcessInfo.processInfo.environment, quiet: false)
        default: break
        }
    }

    /// Convenience for the commands that trash or rewrite files.
    static func offerTrash(root: URL, assumeYes: Bool, quiet: Bool) {
        offer(root: root, directory: TrashStore.directoryName, assumeYes: assumeYes, quiet: quiet)
    }

    /// `--gitignore`: adds both folders to the project `.gitignore` without asking (those git does not ignore yet).
    static func addAll(root: URL, quiet: Bool) {
        guard isInsideWorkTree(root) else { return }
        for directory in directories where isIgnored(root: root, directory: directory) == false {
            addToProject(root: root, directory: directory, quiet: quiet)
        }
    }

    // MARK: - Writing

    static func addToProject(root: URL, directory: String, quiet: Bool) {
        write(directory: directory, to: root.appendingPathComponent(".gitignore"), quiet: quiet)
    }

    /// Appends to the global excludes file (`core.excludesFile`, else `$XDG_CONFIG_HOME/git/ignore`, else
    /// `~/.config/git/ignore`); `environment` is what git and the path lookup see.
    static func addToGlobal(directory: String, environment: [String: String], quiet: Bool) {
        write(directory: directory, to: globalExcludesFile(environment: environment), quiet: quiet)
    }

    private static func write(directory: String, to file: URL, quiet: Bool) {
        do {
            if try appendEntry(directory: directory, to: file), !quiet {
                ScanRunner.stderr("Added \(directory)/ to \(file.path)\n")
            }
        } catch {
            if !quiet { ScanRunner.stderr("warning: could not update \(file.path): \(error.localizedDescription)\n") }
        }
    }

    /// Appends `<directory>/` to `file` (created with its folder when missing): after a newline when the file does not
    /// end with one, and under the `# xcpurge working folders` comment the first time. False when the line is there.
    @discardableResult
    static func appendEntry(directory: String, to file: URL) throws -> Bool {
        let entry = directory + "/"
        let fm = FileManager.default
        let existing = fm.contents(atPath: file.path).map { String(decoding: $0, as: UTF8.self) } ?? ""
        let lines = existing.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }
        if lines.contains(entry) { return false }
        var addition = ""
        if !existing.isEmpty, !existing.hasSuffix("\n") { addition += "\n" }
        if !lines.contains(comment) { addition += comment + "\n" }
        addition += entry + "\n"
        if existing.isEmpty, !fm.fileExists(atPath: file.path) {
            try fm.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(addition.utf8).write(to: file)
        } else {
            let handle = try FileHandle(forWritingTo: file)
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(addition.utf8))
        }
        return true
    }

    /// `core.excludesFile` (with `~` expanded), else `$XDG_CONFIG_HOME/git/ignore`, else `~/.config/git/ignore`.
    static func globalExcludesFile(environment: [String: String]) -> URL {
        let home = environment["HOME"] ?? NSHomeDirectory()
        func expand(_ path: String) -> String {
            if path == "~" { return home }
            if path.hasPrefix("~/") { return home + String(path.dropFirst(1)) }
            return path
        }
        let cwd = URL(fileURLWithPath: home)
        if let result = git(["config", "--global", "--get", "core.excludesFile"], in: cwd, environment: environment),
           result.status == 0 {
            let configured = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !configured.isEmpty { return URL(fileURLWithPath: expand(configured), relativeTo: cwd).standardizedFileURL }
        }
        if let xdg = environment["XDG_CONFIG_HOME"], !xdg.isEmpty {
            return URL(fileURLWithPath: expand(xdg)).appendingPathComponent("git/ignore")
        }
        return URL(fileURLWithPath: home).appendingPathComponent(".config/git/ignore")
    }

    // MARK: - git

    /// Inside a git work tree and `directory/` is not ignored there.
    static func needsEntry(root: URL, directory: String) -> Bool {
        isInsideWorkTree(root) && isIgnored(root: root, directory: directory) == false
    }

    static func isInsideWorkTree(_ root: URL) -> Bool {
        guard let inside = git(["rev-parse", "--is-inside-work-tree"], in: root) else { return false }
        return inside.status == 0 && inside.output.trimmingCharacters(in: .whitespacesAndNewlines) == "true"
    }

    /// Whether git ignores `directory/` under `root`; nil when git cannot tell. The trailing slash matters: a
    /// `dir/` rule only matches a path git knows to be a directory.
    static func isIgnored(root: URL, directory: String) -> Bool? {
        guard let result = git(["check-ignore", "-q", directory + "/"], in: root) else { return nil }
        return result.status == 0 ? true : result.status == 1 ? false : nil
    }

    /// Runs `git` in `cwd` with a time limit; nil when it cannot start or times out.
    static func git(_ arguments: [String], in cwd: URL, environment: [String: String]? = nil)
        -> (status: Int32, output: String)? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git"] + arguments
        process.currentDirectoryURL = cwd
        if let environment { process.environment = environment }
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let finished = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in finished.signal() }
        do { try process.run() } catch { return nil }
        if finished.wait(timeout: .now() + gitTimeout) == .timedOut {
            process.terminate()
            return nil
        }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }
}
