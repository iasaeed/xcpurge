import Foundation

/// Enumerates the named entries of an `.xcassets` folder: every set type Xcode knows (image, color, symbol,
/// data, texture, sprite atlas, app icon, …), honouring provides-namespace folders and reading
/// on-demand-resource tags and sizes from disk.
public enum AssetCatalogReader {
    /// Extensions counted as image files (for duplicates and loose-image detection).
    public static let imageExtensions: Set<String> = [
        "png", "jpg", "jpeg", "gif", "pdf", "svg", "heic", "heif", "webp", "tif", "tiff", "bmp",
    ]

    /// - Parameters:
    ///   - catalog: root-relative path of the `.xcassets` folder.
    ///   - root: scan root.
    /// - Returns: entries sorted by path; empty when the folder cannot be read.
    public static func read(catalog: String, root: URL) -> [CatalogAsset] {
        var out: [CatalogAsset] = []
        walk(dir: root.appendingPathComponent(catalog).path, rel: "", namespace: [], catalog: catalog, into: &out)
        return out.sorted { $0.path < $1.path }
    }

    private static func walk(dir: String, rel: String, namespace: [String], catalog: String, into out: inout [CatalogAsset]) {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: dir) else { return }
        for name in names.sorted() where !name.hasPrefix(".") {
            let full = dir + "/" + name
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: full, isDirectory: &isDir), isDir.boolValue else { continue }
            let childRel = rel.isEmpty ? name : rel + "/" + name
            let ext = (name as NSString).pathExtension.lowercased()
            guard let type = AssetType.byExtension[ext] else {
                let provides = (contents(of: full)?["properties"]?["provides-namespace"]?.boolValue) ?? false
                walk(dir: full, rel: childRel, namespace: provides ? namespace + [name] : namespace,
                     catalog: catalog, into: &out)
                continue
            }
            let leaf = (name as NSString).deletingPathExtension
            let tags = contents(of: full)?["properties"]?["on-demand-resource-tags"]?.arrayValue?
                .compactMap(\.stringValue) ?? []
            let (images, aliases) = scanSet(full, rel: catalog + "/" + childRel, collectImages: type == .image || type == .spriteAtlas)
            out.append(CatalogAsset(
                name: (namespace + [leaf]).joined(separator: "/"), leaf: leaf, namespace: namespace, type: type,
                path: catalog + "/" + childRel, catalog: catalog, relativePath: childRel,
                sizeBytes: FileWalker.treeSize(full), odrTags: tags,
                aliases: type == .spriteAtlas ? aliases : [], imageFiles: images))
        }
    }

    /// Image files (root-relative) and nested image-set leaf names inside a set folder.
    private static func scanSet(_ dir: String, rel: String, collectImages: Bool) -> (images: [String], imageSets: [String]) {
        guard let e = FileManager.default.enumerator(atPath: dir) else { return ([], []) }
        var images: [String] = [], sets: [String] = []
        while let item = e.nextObject() as? String {
            let ext = (item as NSString).pathExtension.lowercased()
            if ext == "imageset" { sets.append(((item as NSString).lastPathComponent as NSString).deletingPathExtension) }
            if collectImages, imageExtensions.contains(ext), e.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                images.append(rel + "/" + item)
            }
        }
        return (images.sorted(), sets.sorted())
    }

    /// Parsed `Contents.json` of a catalog folder, or nil.
    static func contents(of dir: String) -> JSONValue? {
        guard let data = FileManager.default.contents(atPath: dir + "/Contents.json"),
              let object = try? JSONSerialization.jsonObject(with: data) else { return nil }
        return JSONValue(any: object)
    }
}
