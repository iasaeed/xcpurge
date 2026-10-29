// LANE: C
/// Orphan and ghost files, dead sources, unused interface files and resources (plan §4.1, §4.5).
/// Orphans are reported once: the later passes skip them, and an orphan's own references count for nothing.
public struct FilesDetector: Detector {
    public init() {}

    public var category: Category { .files }

    public func run(_ ctx: ScanContext) -> [Finding] {
        let orphans = OrphanFinder.find(ctx)
        let orphanPaths = Set(orphans.map(\.path))
        var findings = orphans + GhostFinder.find(ctx)
        findings += DeadSourceAnalyzer.find(ctx, skipping: orphanPaths)
        findings += InterfaceFileUsage.find(ctx, skipping: orphanPaths)
        findings += ResourceFileUsage.find(ctx, skipping: orphanPaths)
        return findings
    }

    /// Modules whose references can see `file`'s contents: the consumers of every module that builds it.
    static func visibility(of file: SourceFile, in ctx: ScanContext) -> Set<ModuleID> {
        file.effectiveModules.reduce(into: Set<ModuleID>()) { $0.formUnion(ctx.graph.consumers(of: $1)) }
    }

    /// Reference sources that can use something: every source except orphans, which no target builds.
    /// Unattributed files count (plan §3 step 6), like everywhere else in the scan.
    static func userFilter(_ ctx: ScanContext, orphans: Set<String>) -> @Sendable (Int32) -> Bool {
        let excluded = Set(orphans.compactMap { ctx.inventory.index(of: $0) }.map(Int32.init))
        return { file in !excluded.contains(file) }
    }

    /// Paths of the physical Info.plist / entitlements / xcconfig files the build settings point at.
    static func settingsFiles(_ ctx: ScanContext) -> Set<String> {
        Set(ctx.graph.sorted.flatMap(\.settingsFiles))
    }

    /// Folders whose insides belong to one resource (Core ML packages, compiled models, bundles).
    static let opaqueFolderExtensions: Set<String> = FileKind.bundleExtensions.union([
        "mlpackage", "mlmodelc", "momd", "xcdatamodel", "xcmappingmodel", "app", "appex", "xctest",
        "reality", "usdz", "xcarchive",
    ])

    /// True when some ancestor folder of `path` is an opaque folder (`Model.mlpackage/Data/x.json`).
    static func isInsideOpaqueFolder(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { component in
            guard let dot = component.lastIndex(of: ".") else { return false }
            return opaqueFolderExtensions.contains(component[component.index(after: dot)...].lowercased())
        }
    }
}
