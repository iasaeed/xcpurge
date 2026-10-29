// LANE: A
import Foundation

/// Restores a trash session: moves `moved` entries back and copies `rewritten` originals over the current
/// files, newest entry first. A fully restored session is removed so it cannot be applied twice.
public enum Restore {
    /// - Parameter sessionID: session to restore; nil means the newest session.
    public static func run(root: URL, sessionID: String?) throws -> ActionReport {
        let sessions = try TrashStore.sessions(root: root)
        let match = sessionID.map { id in sessions.first { $0.id == id } } ?? sessions.first
        guard let manifest = match else { throw XcpurgeError.notFound(sessionID ?? TrashStore.directoryName) }
        let fm = FileManager.default
        let sessionURL = TrashStore.sessionURL(root: root, id: manifest.id)
        var report = ActionReport()
        for entry in manifest.entries.reversed() {
            let stored = sessionURL.appendingPathComponent(entry.stored)
            let target = root.appendingPathComponent(entry.path)
            guard fm.fileExists(atPath: stored.path) else {
                report.skipped.append(.init(path: entry.path, reason: "stored copy is missing"))
                continue
            }
            do {
                try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
                switch entry.action {
                case .moved:
                    guard !fm.fileExists(atPath: target.path) else {
                        report.skipped.append(.init(path: entry.path, reason: "a file already exists there"))
                        continue
                    }
                    try fm.moveItem(at: stored, to: target)
                    report.moved.append(entry.path)
                case .rewritten:
                    if fm.fileExists(atPath: target.path) { try fm.removeItem(at: target) }
                    try fm.copyItem(at: stored, to: target)
                    report.rewritten.append(entry.path)
                }
            } catch {
                report.skipped.append(.init(path: entry.path, reason: "cannot restore: \(error.localizedDescription)"))
            }
        }
        if report.skipped.isEmpty {
            try fm.removeItem(at: sessionURL)
            let trash = root.appendingPathComponent(TrashStore.directoryName)
            if (try? fm.contentsOfDirectory(atPath: trash.path))?.isEmpty == true { try fm.removeItem(at: trash) }
        }
        return report
    }
}
