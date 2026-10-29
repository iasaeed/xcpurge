/// A synchronized folder (`PBXFileSystemSynchronizedRootGroup`, or an xcproj `folder` node).
public struct SyncedGroup: Sendable, Hashable {
    public var id: String
    /// Root-relative folder path.
    public var path: String
    /// Targets that own the folder (`fileSystemSynchronizedGroups` / `target-membership`).
    public var owners: [String]
    public var exceptions: [SyncedException]
    /// Folder-relative paths treated as opaque folders.
    public var explicitFolders: [String]
    /// Folder-relative path -> explicit file type.
    public var explicitFileTypes: [String: String]

    public init(id: String, path: String, owners: [String] = [], exceptions: [SyncedException] = [],
                explicitFolders: [String] = [], explicitFileTypes: [String: String] = [:]) {
        self.id = id
        self.path = path
        self.owners = owners
        self.exceptions = exceptions
        self.explicitFolders = explicitFolders
        self.explicitFileTypes = explicitFileTypes
    }
}
