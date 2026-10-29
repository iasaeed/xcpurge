import Foundation

/// Everything a detector needs: inventory, module graph, reference index, projects and settings.
public struct ScanContext: Sendable {
    /// Absolute, symlink-resolved scan root.
    public let root: URL
    public let config: Config
    public let inventory: FileInventory
    public let graph: ModuleGraph
    public let refs: ReferenceIndex
    public let projects: [ProjectModel]
    /// DerivedData folder for the scanned workspace/project, if found (for `GeneratedAssetSymbols-Index.plist`).
    public let derivedData: URL?
    public let diagnostics: Diagnostics
    public let ignore: Ignore

    public init(root: URL, config: Config, inventory: FileInventory, graph: ModuleGraph, refs: ReferenceIndex,
                projects: [ProjectModel], derivedData: URL?, diagnostics: Diagnostics, ignore: Ignore) {
        self.root = root
        self.config = config
        self.inventory = inventory
        self.graph = graph
        self.refs = refs
        self.projects = projects
        self.derivedData = derivedData
        self.diagnostics = diagnostics
        self.ignore = ignore
    }

    /// Absolute URL of a root-relative path.
    public func url(for path: String) -> URL { root.appendingPathComponent(path) }

    /// Display name of the module owning `path` (first by sort order), or `unknown`.
    public func moduleName(for path: String) -> String {
        inventory.file(at: path)?.modules.sorted().first?.name ?? ModuleID.unknown.name
    }
}
