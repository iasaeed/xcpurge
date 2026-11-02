import Foundation

/// Restores a trash session: moves `moved` entries back and copies `rewritten` originals over the current
/// files, newest entry first. A fully restored session is removed so it cannot be applied twice. A partial
/// restore (`paths`) puts back only those entries and re-plans the `project.pbxproj` edits for what is still
/// in the trash; a session that still has entries is never deleted. A `rewritten` file whose contents differ
/// from what the cleanup left behind (its recorded hash) is skipped unless `force` is set.
public enum Restore {
    /// Skip reason for a rewritten file that changed after the cleanup.
    public static let changedReason = "changed since the cleanup; pass --force to overwrite it"

    /// - Parameters:
    ///   - sessionID: session to restore; nil means the newest session that holds entries (a session that only
    ///     records an aborted `--verify` is skipped; name it to remove it).
    ///   - force: overwrite rewritten files that changed after the cleanup.
    public static func run(root: URL, sessionID: String?, force: Bool = false) throws -> ActionReport {
        try run(root: root, sessionID: sessionID, paths: nil, context: nil, force: force)
    }

    /// - Parameters:
    ///   - paths: root-relative paths to put back; nil restores the whole session.
    ///   - context: used for the volume's case sensitivity when re-planning project edits; discovered from the
    ///     root when nil.
    ///   - force: overwrite rewritten files that changed after the cleanup.
    public static func run(root: URL, sessionID: String?, paths: Set<String>?, context: ScanContext?,
                           force: Bool = false) throws -> ActionReport {
        let sessions = try TrashStore.sessions(root: root)
        let match = sessionID.map { id in sessions.first { $0.id == id } } ?? defaultSession(sessions)
        guard let manifest = match else { throw XcpurgeError.notFound(sessionID ?? TrashStore.directoryName) }
        guard let paths else { return try restoreAll(manifest, root: root, force: force) }
        return try restore(paths, from: manifest, root: root, context: context, force: force)
    }

    /// The newest session with entries (sessions are newest first).
    public static func defaultSession(_ sessions: [TrashManifest]) -> TrashManifest? {
        sessions.first { !$0.entries.isEmpty }
    }

    private static func restoreAll(_ manifest: TrashManifest, root: URL, force: Bool) throws -> ActionReport {
        let fm = FileManager.default
        let sessionURL = TrashStore.sessionURL(root: root, id: manifest.id)
        var report = ActionReport()
        var restored = Set<String>()
        for entry in manifest.entries.reversed() {
            let before = report.skipped.count
            restore(entry, sessionURL: sessionURL, root: root, force: force, into: &report)
            if report.skipped.count == before { restored.insert(entry.path) }
        }
        if report.skipped.isEmpty {
            try fm.removeItem(at: sessionURL)
            removeTrashIfEmpty(root: root)
        } else if !restored.isEmpty {
            // The kept session lists only what is still to restore (a moved entry's stored copy is gone now).
            try TrashStore.open(root: root, id: manifest.id).dropEntries(paths: restored)
        }
        return report
    }

    /// Partial restore: `moved` and non-project `rewritten` entries for `paths` go back and leave the manifest;
    /// only the `project.pbxproj` entries whose edit removed a reference to a restored path (or to a file now back
    /// on disk) are reverted to their original and re-edited for the paths still in the trash. The others are left
    /// untouched and not reported.
    private static func restore(_ paths: Set<String>, from manifest: TrashManifest, root: URL,
                                context: ScanContext?, force: Bool) throws -> ActionReport {
        let store = try TrashStore.open(root: root, id: manifest.id)
        let sessionURL = store.sessionURL
        var report = ActionReport()
        var restored = Set<String>()
        for entry in manifest.entries.reversed() where paths.contains(entry.path) && !isProjectFile(entry) {
            let before = report.skipped.count
            restore(entry, sessionURL: sessionURL, root: root, force: force, into: &report)
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
            var wrote = false
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
                // A file back on disk keeps its reference, also one restored by an earlier run that left this
                // project file alone (changed since the cleanup).
                let keep = removedByEdit.filter {
                    !restoredFolded.contains(fold($0)) && !FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path)
                }
                // Nothing in this project needs its reference back: its edit stands, no rewrite, no report line.
                if keep.count == removedByEdit.count { continue }
                if !force, changedSinceCleanup(entry, target: target) {
                    report.skipped.append(.init(path: entry.path, reason: changedReason))
                    continue
                }
                try original.write(to: target, options: .atomic)
                wrote = true
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
                // The original is back but not re-edited: record its hash so the next restore accepts it.
                if wrote { try? store.sealRewrite(entry.path) }
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

    /// A rewritten file that exists and no longer matches the hash recorded right after the rewrite (entries from
    /// older versions carry no hash and never count as changed).
    private static func changedSinceCleanup(_ entry: TrashEntry, target: URL) -> Bool {
        guard let expected = entry.afterSHA256, FileManager.default.fileExists(atPath: target.path) else { return false }
        return (try? TrashStore.sha256(of: target)) != expected
    }

    private static func restore(_ entry: TrashEntry, sessionURL: URL, root: URL, force: Bool,
                                into report: inout ActionReport) {
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
                if !force, changedSinceCleanup(entry, target: target) {
                    report.skipped.append(.init(path: entry.path, reason: changedReason))
                    return
                }
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
