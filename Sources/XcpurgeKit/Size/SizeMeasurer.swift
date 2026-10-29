import Foundation

/// Measures a scanned tree by category and module (from the scan's inventory and attribution) and estimates
/// what the reported findings would reclaim.
public enum SizeMeasurer {
    public static let categoryNames = ["Asset catalogs", "Loose images", "Fonts", "Strings", "Interface Builder",
                                       "Other resources", "Source", "Other files"]
    public static let unattributed = "(unattributed)"

    /// Category of one inventory entry. Data-like files count as resources only when a module builds them.
    public static func category(of file: SourceFile) -> String {
        switch file.kind {
        case .assetCatalog: "Asset catalogs"
        case .image: "Loose images"
        case .font: "Fonts"
        case .stringCatalog, .strings, .stringsdict: "Strings"
        case .storyboard, .xib: "Interface Builder"
        case .swift, .objc, .header, .c, .cpp, .metal: "Source"
        case .packageManifest, .xcconfig, .entitlements, .docc, .playground: "Other files"
        default: file.modules.isEmpty ? "Other files" : "Other resources"
        }
    }

    /// The JSON/HTML report's `size` object (inventory only, no disk access).
    public static func report(_ result: ScanResult) -> SizeReport {
        SizeReport(tree: tree(result.context, targets: Set(result.context.config.targets), assetBreakdown: false),
                   reclaimable: reclaimable(result.findings))
    }

    /// A full snapshot: tree (with the per-catalog and per-asset-type breakdown read from disk), reclaimable
    /// estimate over the detector `categories` that produced `result`, and, when given, a built app.
    public static func snapshot(_ result: ScanResult, categories: Set<Category>, app: AppSize? = nil,
                                date: Date = Date()) -> SizeSnapshot {
        var r = reclaimable(result.findings)
        r.categories = categories.map(\.rawValue).sorted()
        return SizeSnapshot(root: result.context.root.path, measuredAt: date,
                            tree: tree(result.context, targets: Set(result.context.config.targets), assetBreakdown: true),
                            reclaimable: r, app: app)
    }

    /// Sizes of the inventory, limited to files of `targets` (module names) when not empty.
    public static func tree(_ context: ScanContext, targets: Set<String> = [], assetBreakdown: Bool) -> TreeSize {
        let files = context.inventory.files.filter { f in
            targets.isEmpty || f.modules.contains { targets.contains($0.name) }
        }
        var byCategory: [String: SizeEntry] = [:]
        var byModule: [String: ModuleSize] = [:]
        for f in files {
            let c = category(of: f)
            byCategory[c, default: SizeEntry(name: c, files: 0, bytes: 0)].files += 1
            byCategory[c]!.bytes += f.size
            let modules = targets.isEmpty ? f.modules : f.modules.filter { targets.contains($0.name) }
            for id in f.modules.isEmpty ? [unattributed] : modules.map(\.description) {
                byModule[id, default: ModuleSize(id: id, files: 0, bytes: 0)].files += 1
                byModule[id]!.bytes += f.size
            }
        }
        var tree = TreeSize(
            total: files.reduce(0) { $0 + $1.size }, files: files.count,
            categories: categoryNames.map { byCategory[$0] ?? SizeEntry(name: $0, files: 0, bytes: 0) },
            modules: byModule.values.sorted { ($1.bytes, $0.id) < ($0.bytes, $1.id) })
        if assetBreakdown {
            let catalogs = files.filter { $0.kind == .assetCatalog }
            var types: [String: SizeEntry] = [:]
            tree.assetCatalogs = catalogs.map { catalog in
                let parts = assetTypes(in: context.root.appendingPathComponent(catalog.path).path)
                var count = 0
                for part in parts {
                    types[part.name, default: SizeEntry(name: part.name, files: 0, bytes: 0)].files += part.files
                    types[part.name]!.bytes += part.bytes
                    count += part.files
                }
                return SizeEntry(name: catalog.path, files: count, bytes: catalog.size)
            }
            tree.assetTypes = types.values.sorted { ($1.bytes, $0.name) < ($0.bytes, $1.name) }
        }
        return tree
    }

    /// Bytes of every asset set in a catalog folder, by set type (`imageset`, `colorset`, ...); everything
    /// outside a set (group `Contents.json` files) is `other`. Files counts are regular files.
    static func assetTypes(in catalog: String) -> [SizeEntry] {
        guard let e = FileManager.default.enumerator(atPath: catalog) else { return [] }
        var out: [String: SizeEntry] = [:]
        func add(_ name: String, files: Int, bytes: Int64) {
            out[name, default: SizeEntry(name: name, files: 0, bytes: 0)].files += files
            out[name]!.bytes += bytes
        }
        while let rel = e.nextObject() as? String {
            let type = e.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                let ext = (rel as NSString).pathExtension.lowercased()
                guard ext.hasSuffix("set") else { continue }
                e.skipDescendants()
                let stats = treeStats(catalog + "/" + rel)
                add(ext, files: stats.files, bytes: stats.bytes)
            } else if type == .typeRegular {
                add("other", files: 1, bytes: (e.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0)
            }
        }
        return Array(out.values)
    }

    /// Regular files and their total bytes under a folder (hidden files included, like `FileWalker.treeSize`).
    static func treeStats(_ path: String) -> (files: Int, bytes: Int64) {
        guard let e = FileManager.default.enumerator(atPath: path) else { return (0, 0) }
        var files = 0, bytes: Int64 = 0
        while e.nextObject() != nil {
            if e.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                files += 1
                bytes += (e.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return (files, bytes)
    }

    /// Bytes of non-informational findings (each path once), at high and at high-or-medium confidence.
    public static func reclaimable(_ findings: [Finding]) -> Reclaimable {
        var seen = Set<String>(), high: Int64 = 0, highMedium: Int64 = 0
        for f in findings.sorted(by: Finding.reportOrder) where !f.kind.isInformational && f.confidence >= .medium {
            guard let size = f.sizeBytes, seen.insert(f.path).inserted else { continue }
            highMedium += size
            if f.confidence == .high { high += size }
        }
        return Reclaimable(high: high, highMedium: highMedium)
    }
}
