import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge restore`: list trash sessions or undo one (the newest by default).
struct RestoreCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "restore", abstract: "Undo a delete or prune from .xcpurge-trash.")

    @Argument(help: "Project root.", completion: .directory) var path: String = "."
    @Option(help: "Session ID to restore (default: newest).") var session: String?
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
        let report = try Restore.run(root: root, sessionID: session)
        ScanRunner.printAction(report, verb: "restored", session: session ?? sessions[0].id)
    }
}
