/// Which containers a scan will parse, all root-relative.
public struct LocatedProjects: Sendable, Equatable {
    public var xcodeprojs: [String]
    public var packages: [String]
    /// Workspaces that were expanded (empty when projects came from flags or the walker).
    public var workspaces: [String]

    public init(xcodeprojs: [String] = [], packages: [String] = [], workspaces: [String] = []) {
        self.xcodeprojs = xcodeprojs
        self.packages = packages
        self.workspaces = workspaces
    }
}
