import Foundation

/// Restores a trash session: moves `moved` entries back and copies `rewritten` originals over the current
/// files, newest entry first. A fully restored session is removed so it cannot be applied twice. A partial
/// restore (`paths`) puts back only those entries and re-plans the `project.pbxproj` edits for what is still
/// in the trash; a session that still has entries is never deleted.
public enum Restore {
    /// - Parameter sessionID: session to restore; nil means the newest session.
    public static func run(root: URL, sessionID: String?) throws -> ActionReport {
        try run(root: root, sessionID: sessionID, paths: nil, context: nil)
    }

    /// - Parameters:
    ///   - paths: root-relative paths to put back; nil restores the whole session.
    ///   - context: used for the volume's case sensitivity when re-planning project edits; discovered from the
    ///     root when nil.
    public static func run(root: URL, sessionID: String?, paths: Set<String>?, context: ScanContext?) throws -> ActionReport {
        let sessions = try TrashStore.sessions(root: root)
        let match = sessionID.map { id in sessions.first { $0.id == id } } ?? sessions.first
        guard let manifest = match else { throw XcpurgeError.notFound(sessionID ?? TrashStore.directoryName) }
        guard let paths else { return try restoreAll(manifest, root: root) }
        return try restore(paths, from: manifest, root: root, context: context)
    }

    private static func restoreAll(_ manifest: TrashManifest, root: URL) throws -> ActionReport {
        let fm = FileManager.default
        let sessionURL = TrashStore.sessionURL(root: root, id: manifest.id)
        var report = ActionReport()
        for entry in manifest.entries.reversed() {
            restore(entry, sessionURL: sessionURL, root: root, into: &report)
        }
        if report.skipped.isEmpty {
            try fm.removeItem(at: sessionURL)
            removeTrashIfEmpty(root: root)
        }
        return report
    }

    /// Partial restore: `moved` and non-project `rewritten` entries for `paths` go back and leave the manifest;
    /// every `project.pbxproj` entry is reverted to its original and re-edited for the paths still in the trash.
    private static func restore(_ paths: Set<String>, from manifest: TrashManifest, root: URL,
                                context: ScanContext?) throws -> ActionReport {
        let store = try TrashStore.open(root: root, id: manifest.id)
        let sessionURL = store.sessionURL
        var report = ActionReport()
        var restored = Set<String>()
        for entry in manifest.entries.reversed() where paths.contains(entry.path) && !isProjectFile(entry) {
            let before = report.skipped.count
            restore(entry, sessionURL: sessionURL, root: root, into: &report)
            if report.skipped.count == before { restored.insert(entry.path) }
        }
        for path in paths where !manifest.entries.contains(where: { $0.path == path }) {
            report.skipped.append(.init(path: path, reason: "not in session \(manifest.id)"))
        }
        try store.dropEntries(paths: restored)

        // Project files: back to the original, then edited again for every reference the session's edit had
        // removed (trashed files and ghosts alike) except the ones just restored.
        let folding = context?.inventory.isCaseInsensitive ?? !FileInventory.isCaseSensitiveVolume(root)
        let fold = { (p: String) in folding ? p.lowercased() : p }
        let restoredFolded = Set(restored.map(fold))
        for entry in manifest.entries where isProjectFile(entry) {
            let stored = sessionURL.appendingPathComponent(entry.stored)
            let target = root.appendingPathComponent(entry.path)
            guard FileManager.default.fileExists(atPath: stored.path) else {
                report.skipped.append(.init(path: entry.path, reason: "stored copy is missing"))
                continue
            }
            do {
                let container = RelPath.parent(entry.path)
                let xcodeproj = root.appendingPathComponent(container)
                let original = try Data(contentsOf: stored)
                let edited = try Data(contentsOf: target)
                let refs = { (data: Data) throws -> Set<String> in
                    Set(try PBXProjParser.parse(data: data, xcodeproj: xcodeproj, root: root, diagnostics: Diagnostics())
                        .fileRefs.map(\.path))
                }
                let removedByEdit = try refs(original).subtracting(refs(edited))
                let keep = removedByEdit.filter { !restoredFolded.contains(fold($0)) }
                try original.write(to: target, options: .atomic)
                let project = ProjectModel(container: container, format: .pbxproj, name: RelPath.stem(container),
                                           directory: RelPath.parent(container))
                if !keep.isEmpty, let edit = try PBXProjEditor.plan(removing: keep, in: project, root: root, foldingCase: folding) {
                    try PBXProjEditor.apply(edit, root: root, store: store)
                    if paths.contains(entry.path) {
                        report.skipped.append(.init(path: entry.path, reason: "still edited for files in the trash; restored with them"))
                    } else {
                        report.rewritten.append(entry.path)
                    }
                } else {
                    try store.dropEntries(paths: [entry.path])
                    report.rewritten.append(entry.path)
                }
            } catch {
                report.skipped.append(.init(path: entry.path, reason: "cannot restore: \(error.localizedDescription)"))
            }
        }
        if store.entries.isEmpty, report.skipped.isEmpty {
            try FileManager.default.removeItem(at: sessionURL)
            removeTrashIfEmpty(root: root)
        }
        return report
    }

    static func isProjectFile(_ entry: TrashEntry) -> Bool {
        entry.action == .rewritten && RelPath.lastComponent(entry.path) == "project.pbxproj"
    }

    private static func restore(_ entry: TrashEntry, sessionURL: URL, root: URL, into report: inout ActionReport) {
        let fm = FileManager.default
        let stored = sessionURL.appendingPathComponent(entry.stored)
        let target = root.appendingPathComponent(entry.path)
        guard fm.fileExists(atPath: stored.path) else {
            report.skipped.append(.init(path: entry.path, reason: "stored copy is missing"))
            return
        }
        do {
            try fm.createDirectory(at: target.deletingLastPathComponent(), withIntermediateDirectories: true)
            switch entry.action {
            case .moved:
                guard !fm.fileExists(atPath: target.path) else {
                    report.skipped.append(.init(path: entry.path, reason: "a file already exists there"))
                    return
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

    /// Removes `.xcpurge-trash` when nothing is left in it (the verify block list keeps it).
    static func removeTrashIfEmpty(root: URL) {
        let trash = root.appendingPathComponent(TrashStore.directoryName)
        if (try? FileManager.default.contentsOfDirectory(atPath: trash.path))?.isEmpty == true {
            try? FileManager.default.removeItem(at: trash)
        }
    }
}
