/// A target dependency on a target of another project (`PBXTargetDependency` whose `PBXContainerItemProxy`
/// points at a different `.xcodeproj` through `containerPortal`). Resolved across the workspace by `ModuleGraph`.
public struct ExternalTargetDependency: Sendable, Hashable {
    /// Root-relative path of the other `.xcodeproj`, when its file reference resolves.
    public var container: String?
    /// The other project's target name (`remoteInfo`).
    public var target: String

    public init(container: String?, target: String) {
        self.container = container
        self.target = target
    }
}
