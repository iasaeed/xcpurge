/// Parsed form of one Xcode project or Swift package: targets, file references and synced folders.
/// All paths are root-relative.
public struct ProjectModel: Sendable {
    public enum Format: String, Codable, Sendable {
        case pbxproj, xcproj, package
    }

    /// `App/App.xcodeproj`, or the package directory (`.` for a package at the scan root).
    public var container: String
    public var format: Format
    public var name: String
    /// Root-relative directory that `SRCROOT` (or the package root) points at.
    public var directory: String
    public var objectVersion: Int?
    public var targets: [TargetModel]
    public var fileRefs: [ProjectFileRef]
    public var syncedGroups: [SyncedGroup]
    /// Directories of groups with an explicit path; files under them count as "in a source root".
    public var groupPaths: [String]
    /// Local package directories this project references.
    public var localPackages: [String]
    /// Package products: product name -> target names (packages only).
    public var products: [String: [String]]
    /// Package dependency identity -> root-relative directory, for `.package(path:)` (packages only).
    public var packageDependencies: [String: String]
    /// True when file membership could not be trusted (unknown xcproj capability); files stay unattributed.
    public var membershipUnknown: Bool

    public init(container: String, format: Format, name: String, directory: String, objectVersion: Int? = nil,
                targets: [TargetModel] = [], fileRefs: [ProjectFileRef] = [], syncedGroups: [SyncedGroup] = [],
                groupPaths: [String] = [], localPackages: [String] = [], products: [String: [String]] = [:],
                packageDependencies: [String: String] = [:], membershipUnknown: Bool = false) {
        self.container = container
        self.format = format
        self.name = name
        self.directory = directory
        self.objectVersion = objectVersion
        self.targets = targets
        self.fileRefs = fileRefs
        self.syncedGroups = syncedGroups
        self.groupPaths = groupPaths
        self.localPackages = localPackages
        self.products = products
        self.packageDependencies = packageDependencies
        self.membershipUnknown = membershipUnknown
    }

    public func target(named name: String) -> TargetModel? { targets.first { $0.name == name } }
}
