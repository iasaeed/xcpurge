import Foundation

/// Bytes and file count of one category, catalog, asset type or module.
public struct SizeEntry: Codable, Equatable, Sendable {
    public var name: String
    public var files: Int
    public var bytes: Int64

    public init(name: String, files: Int, bytes: Int64) {
        self.name = name
        self.files = files
        self.bytes = bytes
    }
}

/// Bytes and file count of one module (`id` is `container:name`, or `(unattributed)`).
public struct ModuleSize: Codable, Equatable, Sendable {
    public var id: String
    public var files: Int
    public var bytes: Int64

    public init(id: String, files: Int, bytes: Int64) {
        self.id = id
        self.files = files
        self.bytes = bytes
    }
}

/// Size of the scanned tree (the files a scan inventories; bundle folders such as `.xcassets` count as one file).
public struct TreeSize: Codable, Equatable, Sendable {
    public var total: Int64
    public var files: Int
    /// Fixed order (`SizeMeasurer.categoryNames`); every category is present.
    public var categories: [SizeEntry]
    /// Largest first. A file built by several modules counts in each, so these may add up to more than `total`.
    public var modules: [ModuleSize]
    /// Per `.xcassets` (only from `xcpurge size`).
    public var assetCatalogs: [SizeEntry]?
    /// Per asset set type inside catalogs (`imageset`, `colorset`, ..., `other`; only from `xcpurge size`).
    public var assetTypes: [SizeEntry]?

    public init(total: Int64, files: Int, categories: [SizeEntry], modules: [ModuleSize],
                assetCatalogs: [SizeEntry]? = nil, assetTypes: [SizeEntry]? = nil) {
        self.total = total
        self.files = files
        self.categories = categories
        self.modules = modules
        self.assetCatalogs = assetCatalogs
        self.assetTypes = assetTypes
    }
}

/// Bytes the reported unused findings occupy, at high and at high-or-medium confidence.
public struct Reclaimable: Codable, Equatable, Sendable {
    public var high: Int64
    public var highMedium: Int64
    /// Detector categories the estimate covers (sorted), when known: `assets --delete` measures only its own.
    public var categories: [String]?

    public init(high: Int64, highMedium: Int64, categories: [String]? = nil) {
        self.high = high
        self.highMedium = highMedium
        self.categories = categories
    }
}

/// One part of a built app bundle (`Executable`, `Assets.car`, `en.lproj`, `Frameworks/X.framework`, ...).
public struct AppSection: Codable, Equatable, Sendable {
    public var name: String
    public var bytes: Int64

    public init(name: String, bytes: Int64) {
        self.name = name
        self.bytes = bytes
    }
}

/// Size of a built `.app` (or the `.app` inside an `.ipa`).
public struct AppSize: Codable, Equatable, Sendable {
    public var path: String
    /// Uncompressed bytes of the bundle (install size, unthinned).
    public var total: Int64
    public var sections: [AppSection]
    /// The `.ipa` file's own size when the input was an `.ipa`: compressed, unthinned, not the App Store download.
    public var compressedBytes: Int64?

    public init(path: String, total: Int64, sections: [AppSection], compressedBytes: Int64? = nil) {
        self.path = path
        self.total = total
        self.sections = sections
        self.compressedBytes = compressedBytes
    }
}

/// The `size` object of the JSON/HTML report: tree sizes and the reclaimable estimate (no dates, deterministic).
public struct SizeReport: Codable, Equatable, Sendable {
    public var tree: TreeSize
    public var reclaimable: Reclaimable

    public init(tree: TreeSize, reclaimable: Reclaimable) {
        self.tree = tree
        self.reclaimable = reclaimable
    }
}

/// What `xcpurge size --save` writes and `--compare` reads; also `size-before.json` / `size-after.json` in a
/// trash session.
public struct SizeSnapshot: Codable, Equatable, Sendable {
    public static let schemaVersion = 1
    public static let beforeFileName = "size-before.json"
    public static let afterFileName = "size-after.json"

    /// Writer of the snapshot (`{"name": "xcpurge", "version": …}`); nil in snapshots from 0.4.0 and earlier. Lets
    /// a scan recognise a snapshot saved inside the project and never read it as a reference source.
    public struct Tool: Codable, Equatable, Sendable {
        public var name: String
        public var version: String
    }

    public var schemaVersion: Int
    public var tool: Tool?
    public var root: String
    /// ISO 8601.
    public var measuredAt: String
    public var tree: TreeSize
    public var reclaimable: Reclaimable
    public var app: AppSize?
    /// Bytes per root-relative path, sorted by path: every inventory file, with asset catalogs split into their
    /// asset sets (plus one entry for the catalog's own files). Only `xcpurge size` writes it (0.4+); they add up
    /// to `tree.total`.
    public var paths: [SizeEntry]?

    public init(root: String, measuredAt: Date, tree: TreeSize, reclaimable: Reclaimable, app: AppSize? = nil,
                paths: [SizeEntry]? = nil) {
        self.schemaVersion = Self.schemaVersion
        self.tool = Tool(name: XcpurgeVersion.name, version: XcpurgeVersion.current)
        self.root = root
        self.measuredAt = ISO8601DateFormatter().string(from: measuredAt)
        self.tree = tree
        self.reclaimable = reclaimable
        self.app = app
        self.paths = paths
    }

    public func json() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(self)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }

    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(json().utf8).write(to: url, options: .atomic)
    }

    public static func load(from url: URL) throws -> SizeSnapshot {
        guard let data = FileManager.default.contents(atPath: url.path) else { throw XcpurgeError.notFound(url.path) }
        do { return try JSONDecoder().decode(SizeSnapshot.self, from: data) } catch {
            throw XcpurgeError.invalidConfig("\(url.path) is not an xcpurge size snapshot: \(error)")
        }
    }
}
