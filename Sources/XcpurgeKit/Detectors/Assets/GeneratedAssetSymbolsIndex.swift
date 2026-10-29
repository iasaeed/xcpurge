import Foundation

/// Exact asset -> generated-symbol map from Xcode's `GeneratedAssetSymbols-Index.plist` files in DerivedData
/// (`Build/Intermediates.noindex/<P>.build/<Config>/<T>.build/DerivedSources/`). Absent DerivedData or files
/// simply yield an empty index, and the mangler rules apply instead.
public struct GeneratedAssetSymbolsIndex: Sendable {
    public struct Symbols: Sendable, Hashable {
        public var swift: Set<String> = []
        public var objc: Set<String> = []
    }

    public static let fileName = "GeneratedAssetSymbols-Index.plist"

    /// Root-relative set path -> symbols.
    private var byPath: [String: Symbols] = [:]
    /// `<catalog folder name>/<relative set path>` -> symbols; used when DerivedData was built from another
    /// checkout of the same project (worktrees, moved folders).
    private var bySuffix: [String: Symbols] = [:]

    public init() {}

    public var isEmpty: Bool { byPath.isEmpty && bySuffix.isEmpty }

    /// Loads every index plist under `derivedData`; tolerant of missing folders and unreadable files.
    public static func load(derivedData: URL?, root: URL) -> GeneratedAssetSymbolsIndex {
        var index = GeneratedAssetSymbolsIndex()
        guard let derivedData else { return index }
        let base = derivedData.appendingPathComponent("Build/Intermediates.noindex").path
        for file in indexFiles(under: base) {
            guard let data = FileManager.default.contents(atPath: file) else { continue }
            index.add(plist: data, root: root)
        }
        return index
    }

    /// `<base>/*.build/*/*.build/DerivedSources/GeneratedAssetSymbols-Index.plist`, sorted.
    static func indexFiles(under base: String) -> [String] {
        let fm = FileManager.default
        func dirs(_ path: String, suffix: String? = nil) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: path)) ?? []).sorted()
                .filter { suffix == nil || $0.hasSuffix(suffix!) }.map { path + "/" + $0 }
        }
        var out: [String] = []
        for project in dirs(base, suffix: ".build") {
            for config in dirs(project) {
                for target in dirs(config, suffix: ".build") {
                    let file = target + "/DerivedSources/" + fileName
                    if fm.fileExists(atPath: file) { out.append(file) }
                }
            }
        }
        return out
    }

    /// Adds the entries of one index plist (`{images: [...], colors: [...], symbols: [...]}`).
    public mutating func add(plist data: Data, root: URL) {
        guard let object = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return }
        let rootPath = root.standardizedFileURL.path
        guard case .object(let groups) = JSONValue(any: object) else { return }
        for key in groups.keys.sorted() {
            for entry in groups[key]?.arrayValue ?? [] {
                guard let catalog = entry["catalogPath"]?.stringValue,
                      let relative = entry["relativePath"]?.stringValue else { continue }
                var symbols = Symbols()
                if let s = entry["swiftSymbol"]?.stringValue, !s.isEmpty { symbols.swift.insert(s) }
                if let s = entry["objcSymbol"]?.stringValue, !s.isEmpty { symbols.objc.insert(s) }
                let rel = RelPath.normalize(relative)
                let absolute = RelPath.join(catalog, rel)
                if RelPath.isUnder(absolute, rootPath) {
                    byPath[RelPath.relative(absolute, to: rootPath), default: Symbols()].merge(symbols)
                }
                bySuffix[RelPath.lastComponent(catalog) + "/" + rel, default: Symbols()].merge(symbols)
            }
        }
    }

    /// Symbols Xcode generated for `asset`, or nil when the index does not know it.
    public func symbols(for asset: CatalogAsset) -> Symbols? {
        byPath[asset.path] ?? bySuffix[RelPath.lastComponent(asset.catalog) + "/" + asset.relativePath]
    }
}

private extension GeneratedAssetSymbolsIndex.Symbols {
    mutating func merge(_ other: Self) {
        swift.formUnion(other.swift)
        objc.formUnion(other.objc)
    }
}
