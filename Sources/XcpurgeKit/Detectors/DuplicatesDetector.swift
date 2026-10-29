// LANE: A
import CryptoKit
import Foundation

/// Byte-identical images across image sets (all catalogs) and loose image files. Every file of a group gets
/// a `duplicate` finding with the same `groupID`; all but the first (by path) carry the reclaimable size.
public struct DuplicatesDetector: Detector {
    public init() {}

    public var category: Category { .duplicates }

    private struct Item {
        var path: String
        var name: String
        var module: String
        /// Set folder (catalog images) or the file itself: copies inside one set are not duplicates.
        var unit: String
        var size: Int64
    }

    public func run(_ ctx: ScanContext) -> [Finding] {
        var items: [Item] = []
        for catalog in ctx.inventory.files where catalog.kind == .assetCatalog {
            let module = ctx.moduleName(for: catalog.path)
            for asset in AssetCatalogReader.read(catalog: catalog.path, root: ctx.root) {
                for file in asset.imageFiles {
                    let set = RelPath.parent(file)
                    let name = asset.type == .image ? asset.name : RelPath.stem(set)
                    items.append(Item(path: file, name: name, module: module, unit: set, size: Self.size(ctx.url(for: file))))
                }
            }
        }
        for file in ctx.inventory.files where file.kind == .image && !file.modules.isEmpty {
            items.append(Item(path: file.path, name: file.fileName, module: ctx.moduleName(for: file.path),
                              unit: file.path, size: file.size))
        }

        var findings: [Finding] = []
        let bySize = Dictionary(grouping: items.filter { $0.size > 0 }, by: \.size)
        for size in bySize.keys.sorted() {
            guard let sameSize = bySize[size], sameSize.count > 1 else { continue }
            var byHash: [String: [Item]] = [:]
            for item in sameSize {
                guard let data = try? Data(contentsOf: ctx.url(for: item.path), options: .alwaysMapped) else { continue }
                let hex = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
                byHash[hex, default: []].append(item)
            }
            for hash in byHash.keys.sorted() {
                let group = byHash[hash]!.sorted { $0.path < $1.path }
                guard group.count > 1, Set(group.map(\.unit)).count > 1 else { continue }
                let id = String(hash.prefix(12))
                for (i, item) in group.enumerated() {
                    let others = group.filter { $0.path != item.path }.map(\.path)
                    let shown = others.prefix(5).joined(separator: ", ") + (others.count > 5 ? ", …" : "")
                    findings.append(Finding(kind: .duplicate, category: .duplicates, path: item.path, name: item.name,
                                            module: item.module, confidence: .high,
                                            reasons: ["identical bytes (SHA-256 \(id)) to \(shown)"],
                                            sizeBytes: i == 0 ? nil : item.size, groupID: id))
                }
            }
        }
        return findings
    }

    static func size(_ url: URL) -> Int64 {
        ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}
