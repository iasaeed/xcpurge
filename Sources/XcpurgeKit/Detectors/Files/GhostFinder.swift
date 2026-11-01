import Foundation

/// Project file references (and synchronized folders) whose resolved path no longer exists on disk: Xcode shows
/// them red and the build fails or silently drops them. Paths under an uninitialised submodule or missing CocoaPods
/// output are left out: the scan notes those folders once.
enum GhostFinder {
    static func find(_ ctx: ScanContext) -> [Finding] {
        let fm = FileManager.default
        let rootPath = ctx.root.path
        var out: [Finding] = []
        for project in ctx.projects where project.format != .package {
            let entries = project.fileRefs.map { (path: $0.path, targets: $0.targets.sorted(), what: "file reference") }
                + project.syncedGroups.map { (path: $0.path, targets: $0.owners.sorted(), what: "synchronized folder") }
            for entry in entries where !entry.path.isEmpty && !fm.fileExists(atPath: RelPath.join(rootPath, entry.path))
                && !MissingCheckouts.contains(ctx.missingCheckouts, path: entry.path) {
                var reasons = ["\(entry.what) in \(project.container) points at a missing path"]
                if !entry.targets.isEmpty { reasons.append("member of \(entry.targets.joined(separator: ", "))") }
                out.append(Finding(kind: .ghostReference, category: .files, path: entry.path,
                                   module: entry.targets.first ?? ModuleID.unknown.name, confidence: .high,
                                   reasons: reasons))
            }
        }
        return out
    }
}
