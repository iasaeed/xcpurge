import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge restore`: list trash sessions or undo one (the newest by default).
struct RestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "Undo a delete or prune from .xcpurge-trash.")

    @Argument(help: "Project root.", completion: .directory) var path: String = "."
    @Option(help: "Session ID to restore (default: newest).") var session: String?
    @Option(name: .customLong("path"), parsing: .singleValue,
            help: "Restore only this file or asset set (root-relative or absolute; repeatable), leaving the rest of the session in the trash; project.pbxproj edits are redone for what stays trashed.")
    var paths: [String] = []
    @Flag(help: "List sessions instead of restoring.") var list = false

    func run() async throws {
        let root = CommonOptions.absolute(path)
        let sessions = try TrashStore.sessions(root: root)
        if list {
            if sessions.isEmpty { print("No trash sessions.") }
            for s in sessions {
                let bytes = s.entries.map(\.sizeBytes).reduce(0, +)
                print("\(s.id)  \(s.entries.count) entr\(s.entries.count == 1 ? "y" : "ies")  \(bytes) bytes")
            }
            return
        }
        guard !sessions.isEmpty else { throw XcpurgeError.notFound(TrashStore.directoryName) }
        if let session, !sessions.contains(where: { $0.id == session }) { throw XcpurgeError.notFound(session) }
        let id = session ?? sessions[0].id
        // Read before restoring: a fully restored session folder is removed.
        let sessionURL = TrashStore.sessionURL(root: root, id: id)
        let before = try? SizeSnapshot.load(from: sessionURL.appendingPathComponent(SizeSnapshot.beforeFileName))
        let after = try? SizeSnapshot.load(from: sessionURL.appendingPathComponent(SizeSnapshot.afterFileName))
        let report: ActionReport
        if paths.isEmpty {
            report = try Restore.run(root: root, sessionID: session)
        } else {
            report = try Restore.run(root: root, sessionID: session, paths: Set(paths.map { relative($0, root: root) }), context: nil)
        }
        ScanRunner.printAction(report, verb: "restored", session: id)
        // The reverse of the action's table: what the tree measured after it, back to before (whole sessions only).
        if paths.isEmpty, let before, let after, !report.moved.isEmpty || !report.rewritten.isEmpty {
            ScanRunner.stderr(SizeText.compact(after, before, colors: StderrTerminal.isTTY && StderrTerminal.colors))
        }
    }

    /// A `--path` as given (absolute under the root, or root-relative), root-relative and normalized.
    private func relative(_ raw: String, root: URL) -> String {
        if raw.hasPrefix("/") || raw.hasPrefix("~") {
            return RelPath.relative(CommonOptions.absolute(raw).path, to: root.path)
        }
        return RelPath.normalize(raw)
    }
}
