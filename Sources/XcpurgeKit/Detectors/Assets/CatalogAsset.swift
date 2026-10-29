/// One named entry of an asset catalog (an `.imageset`, `.colorset`, `.spriteatlas`, …).
public struct CatalogAsset: Sendable, Hashable {
    /// Lookup name: provides-namespace folders joined with `/` plus the leaf (`Brand/brand_mark`).
    public var name: String
    /// Folder name without its extension (`brand_mark`).
    public var leaf: String
    /// Provides-namespace folder chain, outermost first (`["Brand"]`).
    public var namespace: [String]
    public var type: AssetType
    /// Root-relative path of the set folder.
    public var path: String
    /// Root-relative path of the `.xcassets` it belongs to.
    public var catalog: String
    /// Set path relative to the catalog (`Brand/brand_mark.imageset`), as `GeneratedAssetSymbols-Index.plist` spells it.
    public var relativePath: String
    /// Total bytes of every file inside the set.
    public var sizeBytes: Int64
    /// `properties.on-demand-resource-tags` from the set's `Contents.json`.
    public var odrTags: [String]
    /// Extra names that also load this unit (image sets inside a sprite atlas).
    public var aliases: [String]
    /// Root-relative image files inside the set (image-like sets only), for duplicate detection.
    public var imageFiles: [String]

    public init(name: String, leaf: String, namespace: [String], type: AssetType, path: String, catalog: String,
                relativePath: String, sizeBytes: Int64, odrTags: [String] = [], aliases: [String] = [],
                imageFiles: [String] = []) {
        self.name = name
        self.leaf = leaf
        self.namespace = namespace
        self.type = type
        self.path = path
        self.catalog = catalog
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.odrTags = odrTags
        self.aliases = aliases
        self.imageFiles = imageFiles
    }
}
