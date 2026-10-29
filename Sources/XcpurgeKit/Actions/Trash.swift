// LANE: A
import Foundation

/// Deletes findings safely: moves files / asset sets into the `TrashStore` (whole set folders for catalog
/// entries) and removes the file references of loose files from classic `project.pbxproj` files. Project edits
/// are dry-run first: a file is moved only when every project referencing it can drop that reference, so the
/// build never points at a missing file.
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

        // Dry run: which loose files' project references can be removed (catalog entries have none).
        let loose = Set(chosen.filter { !$0.split(separator: "/").contains(where: { $0.hasSuffix(".xcassets") }) })
        var blocked: [String: String] = [:]
        var editable: [(ProjectModel, Set<String>)] = []
        for project in context.projects where project.format != .package {
            let referenced = loose.intersection(project.fileRefs.map(\.path))
            guard !referenced.isEmpty else { continue }
            let projectFile = RelPath.join(project.container, "project.\(project.format.rawValue)")
            guard project.format == .pbxproj else {
                for path in referenced {
                    blocked[path] = "referenced by \(projectFile), which is not edited; remove it in Xcode"
                }
                continue
            }
            let check = PBXProjEditor.removable(referenced, in: project, root: context.root)
            for (path, why) in check.failures { blocked[path] = "\(projectFile) reference cannot be removed: \(why)" }
            editable.append((project, check.paths))
        }

        var moved = Set<String>()
        for path in chosen {
            if let why = blocked[path] {
                report.skipped.append(.init(path: path, reason: why))
                continue
            }
            do {
                try store.move(path)
                report.moved.append(path)
                moved.insert(path)
            } catch {
                report.skipped.append(.init(path: path, reason: "cannot move: \(error.localizedDescription)"))
            }
        }

        for (project, paths) in editable {
            let gone = paths.intersection(moved)
            guard !gone.isEmpty else { continue }
            do {
                if let edit = try PBXProjEditor.plan(removing: gone, in: project, root: context.root) {
                    try PBXProjEditor.apply(edit, root: context.root, store: store)
                    report.rewritten.append(edit.projectFile)
                }
            } catch {
                let projectFile = RelPath.join(project.container, "project.pbxproj")
                report.skipped.append(.init(path: projectFile, reason: "references not removed: \(error)"))
            }
        }
        return report
    }
}
