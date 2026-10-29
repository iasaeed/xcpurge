/// One target inside a `ProjectModel`, before it is linked into the module graph.
public struct TargetModel: Sendable {
    public var name: String
    public var kind: ModuleKind
    public var productName: String
    /// Product file name (`AppWidget.appex`), used to match link and embed phases.
    public var productFile: String?
    /// Same-container target names this target depends on.
    public var dependencies: [String]
    public var productDependencies: [ProductDependency]
    /// Product file names linked in a frameworks phase.
    public var linkedProducts: [String]
    /// Product file names copied by a copy-files (embed) phase.
    public var embeddedProducts: [String]
    public var settings: BuildSettings
    /// Files explicitly listed in build phases (classic groups) or with xcproj target membership.
    public var members: Set<String>
    /// IDs of synchronized folders this target owns.
    public var syncedGroupIDs: [String]
    /// Package target source directory.
    public var sourceDir: String?
    /// Package `exclude:` paths (root-relative).
    public var excludes: [String]
    public var resources: [PackageResource]
    /// xcconfig files feeding this target's settings.
    public var settingsFiles: [String]

    public init(name: String, kind: ModuleKind, productName: String? = nil, productFile: String? = nil,
                dependencies: [String] = [], productDependencies: [ProductDependency] = [],
                linkedProducts: [String] = [], embeddedProducts: [String] = [], settings: BuildSettings = BuildSettings(),
                members: Set<String> = [], syncedGroupIDs: [String] = [], sourceDir: String? = nil,
                excludes: [String] = [], resources: [PackageResource] = [], settingsFiles: [String] = []) {
        self.name = name
        self.kind = kind
        self.productName = productName ?? name
        self.productFile = productFile
        self.dependencies = dependencies
        self.productDependencies = productDependencies
        self.linkedProducts = linkedProducts
        self.embeddedProducts = embeddedProducts
        self.settings = settings
        self.members = members
        self.syncedGroupIDs = syncedGroupIDs
        self.sourceDir = sourceDir
        self.excludes = excludes
        self.resources = resources
        self.settingsFiles = settingsFiles
    }
}
