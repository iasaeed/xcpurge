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
        perform(requested, context: context, droppingGhostReferences: false, into: &report)
        return report
    }

    /// Moves the given root-relative paths into the trash and drops their project references, whatever kind of
    /// finding (if any) reported them: `xcpurge remove`. Paths go through `targets(for:context:)` first (asset
    /// sets whole, on-disk spelling, deduped). A path missing on disk still loses its `project.pbxproj`
    /// references (a ghost reference); only a path that is missing and referenced nowhere is skipped. A plain
    /// folder is skipped: its files would leave dangling references (`isRemovableFolder`).
    /// Throws `XcpurgeError.notFound` for a path outside the root or inside the trash.
    public func remove(paths: [String], context: ScanContext) throws -> ActionReport {
        var report = ActionReport()
        var requested = Set<String>()
        for path in try Self.targets(for: paths, context: context) {
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: context.url(for: path).path, isDirectory: &isDir), isDir.boolValue,
               !Self.isRemovableFolder(path, context: context) {
                report.skipped.append(.init(path: path, reason: Self.folderReason))
                continue
            }
            requested.insert(path)
        }
        perform(requested, context: context, droppingGhostReferences: true, into: &report)
        return report
    }

    /// Skip reason for a plain folder (`isRemovableFolder` is false).
    public static let folderReason = "a folder; pass the files inside it (or its folder-reference path)"

    /// The root-relative paths `remove` acts on for the user's `paths`: each normalized, checked to lie inside
    /// the root (its parent's real path, so a symlinked folder cannot lead outside) and outside the trash,
    /// climbed to its asset set, spelled as on disk (case-insensitive volume), and deduped (folded). Sorted.
    /// Throws `XcpurgeError.notFound` for a path that is empty, absolute, outside the root or in the trash.
    public static func targets(for paths: [String], context: ScanContext) throws -> [String] {
        let folding = context.inventory.isCaseInsensitive
        let rootPath = RelPath.normalize(context.root.path)
        var out: [String] = [], seen = Set<String>()
        for raw in paths {
            let path = RelPath.normalize(raw)
            guard !path.isEmpty, !path.hasPrefix("/"), path != "..", !path.hasPrefix("../"),
                  !RelPath.isUnder(path, TrashStore.directoryName, foldingCase: folding)
            else { throw XcpurgeError.notFound(raw) }
            // A symlinked folder on the way (`App/Vendor -> /elsewhere`) escapes the root textually, not really.
            let parent = context.url(for: RelPath.parent(path)).resolvingSymlinksInPath().path
            guard RelPath.isUnder(RelPath.normalize(parent), rootPath, foldingCase: folding) else {
                throw XcpurgeError.notFound(raw)
            }
            let target = onDiskSpelling(assetSet(containing: path) ?? path, context: context)
            guard seen.insert(folding ? target.lowercased() : target).inserted else { continue }
            out.append(target)
        }
        return out.sorted()
    }

    /// The innermost asset-catalog set folder (`x.imageset`, `x.colorset`, …) that `path` lies inside, when
    /// `path` is a file or folder *within* such a set under an `.xcassets` catalog; nil when `path` is the set
    /// itself, a catalog group or not in a catalog at all. Sets are moved whole, as Xcode treats them; the
    /// innermost one, so an image set inside a sprite atlas or brand assets never takes its siblings along.
    public static func assetSet(containing path: String) -> String? {
        let parts = path.split(separator: "/").map(String.init)
        guard let catalog = parts.firstIndex(where: { $0.lowercased().hasSuffix(".xcassets") }),
              parts.count - 2 > catalog, let last = parts.last, !isSetFolder(last) else { return nil }
        for i in stride(from: parts.count - 2, to: catalog, by: -1) where isSetFolder(parts[i]) {
            return parts[...i].joined(separator: "/")
        }
        return nil
    }

    /// A catalog folder name Xcode treats as one entry (known set types, or any `*.…set`).
    static func isSetFolder(_ name: String) -> Bool {
        let ext = (name as NSString).pathExtension.lowercased()
        return !ext.isEmpty && (AssetType.byExtension[ext] != nil || ext.hasSuffix("set"))
    }

    /// Folders `remove` moves whole: asset sets and catalogs, bundle-like units (`.xcdatamodeld`, `.bundle`,
    /// `.scnassets`, …) and folders a project references (folder references). Any other folder is refused,
    /// because only exact references are edited and every file inside would be left dangling.
    public static func isRemovableFolder(_ path: String, context: ScanContext) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard let name = parts.last else { return false }
        let ext = (name as NSString).pathExtension.lowercased()
        if FileKind.bundleExtensions.contains(ext) { return true }
        if parts.dropLast().contains(where: { $0.lowercased().hasSuffix(".xcassets") }), isSetFolder(name) { return true }
        return isReferenced(path, context: context)
    }

    /// True when some project (not a package) has a file reference at `path` (case-folded on a
    /// case-insensitive volume). A missing path that is referenced nowhere has nothing left to remove.
    public static func isReferenced(_ path: String, context: ScanContext) -> Bool {
        let folding = context.inventory.isCaseInsensitive
        let fold = { (p: String) in folding ? p.lowercased() : p }
        return context.projects.contains { p in p.format != .package && p.fileRefs.contains { fold($0.path) == fold(path) } }
    }

    /// `path` as spelled on disk (a case-insensitive volume accepts `app/foo.png` for `App/Foo.png`): the
    /// inventory's file, the matching prefix of the first file beneath it for a folder, or, for a path the
    /// inventory does not list (inside a catalog or bundle, which the walker keeps as one unit), each
    /// component matched case-insensitively against the directory listing from the root down. Components
    /// that do not exist keep the user's spelling.
    static func onDiskSpelling(_ path: String, context: ScanContext) -> String {
        guard context.inventory.isCaseInsensitive else { return path }
        if let file = context.inventory.file(at: path) { return file.path }
        let parts = path.split(separator: "/").map(String.init)
        if let first = context.inventory.indices(under: path).first {
            return context.inventory.files[first].path.split(separator: "/").prefix(parts.count).joined(separator: "/")
        }
        var dir = context.root.path, out: [String] = []
        for part in parts {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
            let name = names.contains(part) ? part : names.first { $0.lowercased() == part.lowercased() } ?? part
            out.append(name)
            dir += "/" + name
        }
        return out.joined(separator: "/")
    }

    /// Shared core: dedupes nested paths, dry-runs the project edits, writes them, moves the files, and gives a
    /// file that failed to move its reference back. With `droppingGhostReferences`, a path missing on disk keeps
    /// going through the project edit (and is never moved); without it, it is skipped up front.
    private func perform(_ requested: Set<String>, context: ScanContext, droppingGhostReferences: Bool,
                         into report: inout ActionReport) {
        // Parents sort before their children, so nested paths are dropped.
        var chosen: [String] = []
        for path in requested.sorted() where !chosen.contains(where: { RelPath.isUnder(path, $0) }) { chosen.append(path) }
        var missing = Set<String>()
        chosen = chosen.filter { path in
            guard FileManager.default.fileExists(atPath: context.url(for: path).path) else {
                if droppingGhostReferences { missing.insert(path); return true }
                report.skipped.append(.init(path: path, reason: "no longer exists"))
                return false
            }
            return true
        }

        // Dry run: which loose files' project references can be removed (catalog entries have none; the catalog
        // itself is a loose file). On a case-insensitive volume the project may spell a path differently from
        // the disk.
        let folding = context.inventory.isCaseInsensitive
        let fold = { (p: String) in folding ? p.lowercased() : p }
        let loose = chosen.filter { !$0.split(separator: "/").dropLast().contains(where: { $0.lowercased().hasSuffix(".xcassets") }) }
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
        // A path one project cannot drop stays referenced everywhere: it touches no project.
        editable = editable.compactMap { project, paths in
            let rest = paths.filter { blocked[$0] == nil }
            return rest.isEmpty ? nil : (project, rest)
        }

        // A missing file that no project references has nothing left to remove.
        for path in missing.sorted() where blocked[path] == nil && !editable.contains(where: { $0.1.contains(path) }) {
            missing.remove(path)
            chosen.removeAll { $0 == path }
            report.skipped.append(.init(path: path, reason: "no longer exists"))
        }

        // Project edits first (backed up): if one cannot be written, its files stay where they are, and any
        // project already edited for them is reverted below (like a file that failed to move).
        var applied: [(project: ProjectModel, edit: PBXProjEdit)] = []
        var failed = Set<String>()
        for (project, paths) in editable {
            do {
                guard let edit = try PBXProjEditor.plan(removing: paths, in: project, root: context.root, foldingCase: folding)
                else { continue }
                try PBXProjEditor.apply(edit, root: context.root, store: store)
                applied.append((project, edit))
            } catch {
                for path in paths { blocked[path] = "\(project.container) not edited: \(error)" }
                failed.formUnion(paths)
            }
        }

        for path in chosen {
            if let why = blocked[path] {
                report.skipped.append(.init(path: path, reason: why))
                continue
            }
            // A ghost has nothing on disk to move; its references went with the project edit.
            if missing.contains(path) { continue }
            do {
                try store.move(path)
                report.moved.append(path)
            } catch {
                failed.insert(path)
                report.skipped.append(.init(path: path, reason: "cannot move: \(error.localizedDescription)"))
            }
        }

        // A file that did not move (or that another project could not drop) keeps its reference: re-plan from
        // the original without it.
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
                report.skipped.append(.init(path: edit.projectFile, reason: "references not restored after a failed edit or move: \(error)"))
            }
        }
    }
}
