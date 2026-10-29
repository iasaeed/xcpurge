// LANE: A
import Foundation

/// Deletes findings safely: moves files / asset sets into the `TrashStore` (whole set folders for catalog
/// entries) and removes the file references of loose files from classic `project.pbxproj` files. Project edits
/// are dry-run first and written (backed up) before anything moves: a file is moved only when every project
/// referencing it dropped that reference, and a file that then fails to move gets its reference back.
public struct Trash: Sendable {
    public let store: TrashStore

    /// Finding kinds whose path can be moved to the trash.
    public static let deletableKinds: Set<FindingKind> = [
        .unusedAsset, .unusedFont, .orphanFile, .unusedResource, .unusedInterfaceFile,
    ]

    public init(store: TrashStore) {
        self.store = store
    }

    /// Moves every deletable finding's path into the trash and updates project files.
    public func apply(_ findings: [Finding], context: ScanContext) throws -> ActionReport {
        var report = ActionReport()
        var requested = Set<String>()
        for f in findings {
            if Self.deletableKinds.contains(f.kind) { requested.insert(f.path) }
            else { report.skipped.append(.init(path: f.path, reason: "\(f.kind.rawValue) findings are not deleted")) }
        }
        // Parents sort before their children, so nested paths are dropped.
        var chosen: [String] = []
        for path in requested.sorted() where !chosen.contains(where: { RelPath.isUnder(path, $0) }) { chosen.append(path) }
        chosen = chosen.filter { path in
            guard FileManager.default.fileExists(atPath: context.url(for: path).path) else {
                report.skipped.append(.init(path: path, reason: "no longer exists"))
                return false
            }
            return true
        }

        // Dry run: which loose files' project references can be removed (catalog entries have none). On a
        // case-insensitive volume the project may spell a path differently from the disk.
        let folding = context.inventory.isCaseInsensitive
        let fold = { (p: String) in folding ? p.lowercased() : p }
        let loose = chosen.filter { !$0.split(separator: "/").contains(where: { $0.hasSuffix(".xcassets") }) }
        var blocked: [String: String] = [:]
        var editable: [(ProjectModel, Set<String>)] = []
        for project in context.projects where project.format != .package {
            let refs = Set(project.fileRefs.map { fold($0.path) })
            let referenced = Set(loose.filter { refs.contains(fold($0)) })
            guard !referenced.isEmpty else { continue }
            let projectFile = RelPath.join(project.container, "project.\(project.format.rawValue)")
            guard project.format == .pbxproj else {
                for path in referenced {
                    blocked[path] = "referenced by \(projectFile), which is not edited; remove it in Xcode"
                }
                continue
            }
            let check = PBXProjEditor.removable(referenced, in: project, root: context.root, foldingCase: folding)
            for (path, why) in check.failures { blocked[path] = "\(projectFile) reference cannot be removed: \(why)" }
            if !check.paths.isEmpty { editable.append((project, check.paths)) }
        }

        // Project edits first (backed up): if one cannot be written, its files stay where they are.
        var applied: [(project: ProjectModel, edit: PBXProjEdit)] = []
        for (project, paths) in editable {
            do {
                guard let edit = try PBXProjEditor.plan(removing: paths, in: project, root: context.root, foldingCase: folding)
                else { continue }
                try PBXProjEditor.apply(edit, root: context.root, store: store)
                applied.append((project, edit))
            } catch {
                for path in paths { blocked[path] = "\(project.container) not edited: \(error)" }
            }
        }

        var failed = Set<String>()
        for path in chosen {
            if let why = blocked[path] {
                report.skipped.append(.init(path: path, reason: why))
                continue
            }
            do {
                try store.move(path)
                report.moved.append(path)
            } catch {
                failed.insert(path)
                report.skipped.append(.init(path: path, reason: "cannot move: \(error.localizedDescription)"))
            }
        }

        // A file that did not move keeps its reference: re-plan from the original without it.
        for (project, edit) in applied {
            guard !edit.paths.isDisjoint(with: failed) else {
                report.rewritten.append(edit.projectFile)
                continue
            }
            do {
                try PBXProjEditor.revert(edit, root: context.root)
                let rest = edit.paths.subtracting(failed)
                if !rest.isEmpty, let redo = try PBXProjEditor.plan(removing: rest, in: project, root: context.root,
                                                                     foldingCase: folding) {
                    try PBXProjEditor.apply(redo, root: context.root, store: store)
                    report.rewritten.append(redo.projectFile)
                }
            } catch {
                report.skipped.append(.init(path: edit.projectFile, reason: "references not restored after a failed move: \(error)"))
            }
        }
        return report
    }
}
