/// One inventory entry: a file or a bundle unit (e.g. `Assets.xcassets`) with its module attribution.
public struct SourceFile: Sendable, Hashable {
    /// Root-relative path, `/`-separated.
    public let path: String
    public let kind: FileKind
    public let size: Int64
    /// True for bundle-like folders treated as a single unit.
    public let isUnit: Bool
    /// Modules that build this file. Empty means no project claims it (treated as `.unknown`).
    public var modules: Set<ModuleID>
    /// True when the file sits under a project group path, synced folder or package target dir.
    public var inSourceRoot: Bool
    /// Containers (xcodeproj paths) that reference this file explicitly by a file reference.
    public var projectRefs: Set<String>

    public init(path: String, kind: FileKind, size: Int64, isUnit: Bool = false, modules: Set<ModuleID> = [],
                inSourceRoot: Bool = false, projectRefs: Set<String> = []) {
        self.path = path
        self.kind = kind
        self.size = size
        self.isUnit = isUnit
        self.modules = modules
        self.inSourceRoot = inSourceRoot
        self.projectRefs = projectRefs
    }

    /// Modules used for visibility checks: `.unknown` when nothing claims the file.
    public var effectiveModules: Set<ModuleID> { modules.isEmpty ? [.unknown] : modules }

    public var fileName: String { path.split(separator: "/").last.map(String.init) ?? path }
}
