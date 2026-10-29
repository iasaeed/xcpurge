/// An explicit file reference in a project (classic group tree or xcproj file node).
public struct ProjectFileRef: Sendable, Hashable {
    /// Root-relative resolved path.
    public var path: String
    /// Target names whose build phases include the file.
    public var targets: Set<String>
    /// Folder reference ("blue folder"): everything under it travels with the reference.
    public var isFolder: Bool

    public init(path: String, targets: Set<String> = [], isFolder: Bool = false) {
        self.path = path
        self.targets = targets
        self.isFolder = isFolder
    }
}
