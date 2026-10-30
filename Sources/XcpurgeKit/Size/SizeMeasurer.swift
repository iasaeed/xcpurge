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

    /// A full snapshot: tree (with the per-catalog and per-asset-type breakdown read from disk), per-path bytes,
    /// reclaimable estimate over the detector `categories` that produced `result`, and, when given, a built app.
    public static func snapshot(_ result: ScanResult, categories: Set<Category>, app: AppSize? = nil,
                                date: Date = Date()) -> SizeSnapshot {
        var r = reclaimable(result.findings)
        r.categories = categories.map(\.rawValue).sorted()
        let targets = Set(result.context.config.targets)
        return SizeSnapshot(root: result.context.root.path, measuredAt: date,
                            tree: tree(result.context, targets: targets, assetBreakdown: true),
                            reclaimable: r, app: app, paths: paths(result.context, targets: targets))
    }

    /// Bytes per root-relative path (`SizeSnapshot.paths`): one entry per inventory file, except that an asset
    /// catalog becomes one entry per asset set plus one for its loose files, so a comparison names the set that grew.
    public static func paths(_ context: ScanContext, targets: Set<String> = []) -> [SizeEntry] {
        var out: [SizeEntry] = []
        for f in context.inventory.files where targets.isEmpty || f.modules.contains(where: { targets.contains($0.name) }) {
            guard f.kind == .assetCatalog else {
                out.append(SizeEntry(name: f.path, files: 1, bytes: f.size))
                continue
            }
            let parts = assetSets(in: context.root.appendingPathComponent(f.path).path)
            var loose = SizeEntry(name: f.path, files: 0, bytes: 0)
            for part in parts {
                if let rel = part.set {
                    out.append(SizeEntry(name: f.path + "/" + rel, files: part.files, bytes: part.bytes))
                } else {
                    loose.files += part.files
                    loose.bytes += part.bytes
                }
            }
            if loose.files > 0 { out.append(loose) }
        }
        return out.sorted { $0.name < $1.name }
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
        var out: [String: SizeEntry] = [:]
        for part in assetSets(in: catalog) {
            let name = part.set.map { ($0 as NSString).pathExtension.lowercased() } ?? "other"
            out[name, default: SizeEntry(name: name, files: 0, bytes: 0)].files += part.files
            out[name]!.bytes += part.bytes
        }
        return Array(out.values)
    }

    /// One part of a catalog: a `*set` folder (`set` is its catalog-relative path) or a loose regular file (`set` nil).
    struct CatalogPart { var set: String?; var files: Int; var bytes: Int64 }

    /// Walks a catalog folder once: asset sets are measured whole and not entered; other regular files count singly.
    static func assetSets(in catalog: String) -> [CatalogPart] {
        guard let e = FileManager.default.enumerator(atPath: catalog) else { return [] }
        var out: [CatalogPart] = []
        while let rel = e.nextObject() as? String {
            let type = e.fileAttributes?[.type] as? FileAttributeType
            if type == .typeDirectory {
                guard (rel as NSString).pathExtension.lowercased().hasSuffix("set") else { continue }
                e.skipDescendants()
                let stats = treeStats(catalog + "/" + rel)
                out.append(CatalogPart(set: rel, files: stats.files, bytes: stats.bytes))
            } else if type == .typeRegular {
                out.append(CatalogPart(set: nil, files: 1, bytes: (e.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0))
            }
        }
        return out
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
