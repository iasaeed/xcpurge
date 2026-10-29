/// Output of `FileWalker`: the raw inventory plus the project containers it found.
public struct WalkResult: Sendable {
    /// Files and bundle units, unattributed.
    public var files: [SourceFile]
    /// Root-relative `.xcodeproj` paths.
    public var xcodeprojs: [String]
    /// Root-relative `.xcworkspace` paths (never the one inside an `.xcodeproj`).
    public var workspaces: [String]
    /// Root-relative directories containing a `Package.swift` (`""` for the root).
    public var packages: [String]
}
