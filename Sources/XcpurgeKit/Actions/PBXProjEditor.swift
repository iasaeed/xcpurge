// LANE: A
import Foundation

/// Removes file references (PBXFileReference, PBXBuildFile, group children, synced-folder exception entries)
/// for deleted paths from a `project.pbxproj`, backing the file up into the `TrashStore` first.
/// Handover stub: Lane A implements `removeReferences`.
public enum PBXProjEditor {
    /// - Parameters:
    ///   - paths: root-relative paths that were deleted.
    ///   - project: the parsed project that may reference them.
    /// - Returns: number of references removed.
    public static func removeReferences(to paths: Set<String>, in project: ProjectModel, root: URL,
                                        store: TrashStore) throws -> Int { 0 }
}
