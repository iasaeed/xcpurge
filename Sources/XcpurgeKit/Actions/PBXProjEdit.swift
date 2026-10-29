import Foundation

/// A validated, not yet written `project.pbxproj` edit from `PBXProjEditor.plan`.
public struct PBXProjEdit: Sendable {
    /// Root-relative path of the `project.pbxproj`.
    public let projectFile: String
    /// Root-relative paths whose references the edit removes.
    public let paths: Set<String>
    /// Number of file references (PBXFileReference / XCVersionGroup) removed.
    public let referenceCount: Int
    /// The edited file contents.
    let output: Data
}
