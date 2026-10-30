// Optional-field additions only; the fields below are a frozen contract.
/// One entry of a baseline file: a finding identity (`FindingIdentity.key`) with the display fields needed to
/// report it as fixed without re-reading sources, and how many findings share the key.
public struct BaselineEntry: Codable, Hashable, Sendable, Comparable {
    public var key: String
    public var kind: FindingKind
    public var category: Category
    public var module: String
    /// Root-relative.
    public var path: String
    public var name: String?
    public var count: Int

    public init(key: String, kind: FindingKind, category: Category, module: String, path: String, name: String? = nil,
                count: Int = 1) {
        self.key = key
        self.kind = kind
        self.category = category
        self.module = module
        self.path = path
        self.name = name
        self.count = count
    }

    public static func < (lhs: BaselineEntry, rhs: BaselineEntry) -> Bool { lhs.key < rhs.key }
}

/// What `--baseline` did to a scan: how many findings it hid, how many are new, which entries are fixed.
public struct BaselineReport: Codable, Hashable, Sendable {
    /// The baseline file as given.
    public var file: String
    /// ISO 8601 creation date read from the file.
    public var createdAt: String
    public var ageDays: Int
    public var toolVersion: String
    public var baselinedCount: Int
    public var newCount: Int
    public var fixed: [BaselineEntry]
    public var warnings: [String]
    public var strict: Bool

    public init(file: String, createdAt: String, ageDays: Int, toolVersion: String, baselinedCount: Int, newCount: Int,
                fixed: [BaselineEntry] = [], warnings: [String] = [], strict: Bool = false) {
        self.file = file
        self.createdAt = createdAt
        self.ageDays = ageDays
        self.toolVersion = toolVersion
        self.baselinedCount = baselinedCount
        self.newCount = newCount
        self.fixed = fixed
        self.warnings = warnings
        self.strict = strict
    }
}
