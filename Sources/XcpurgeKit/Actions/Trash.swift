// LANE: A
import Foundation

/// Deletes findings safely: moves files / asset sets into the `TrashStore` (whole set folders for catalog
/// entries) and removes the file references of loose files from classic `project.pbxproj` files.
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

        var looseMoved = Set<String>()
        for path in chosen {
            guard FileManager.default.fileExists(atPath: context.url(for: path).path) else {
                report.skipped.append(.init(path: path, reason: "no longer exists"))
                continue
            }
            do {
                try store.move(path)
                report.moved.append(path)
                if !path.split(separator: "/").contains(where: { $0.hasSuffix(".xcassets") }) { looseMoved.insert(path) }
            } catch {
                report.skipped.append(.init(path: path, reason: "cannot move: \(error.localizedDescription)"))
            }
        }

        for project in context.projects where project.format != .package {
            let referenced = looseMoved.intersection(project.fileRefs.map(\.path))
            guard !referenced.isEmpty else { continue }
            let projectFile = RelPath.join(project.container, "project.\(project.format.rawValue)")
            guard project.format == .pbxproj else {
                report.skipped.append(.init(path: projectFile, reason: "project.xcproj references are not edited; remove them in Xcode"))
                continue
            }
            do {
                if try PBXProjEditor.removeReferences(to: referenced, in: project, root: context.root, store: store) > 0 {
                    report.rewritten.append(projectFile)
                }
            } catch {
                report.skipped.append(.init(path: projectFile, reason: "references not removed: \(error)"))
            }
        }
        return report
    }
}
