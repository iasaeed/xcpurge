/// One reported problem: what, where, which module, and how sure we are.
public struct Finding: Codable, Hashable, Sendable {
    public var kind: FindingKind
    public var category: Category
    /// Root-relative path of the file or bundle unit the finding is about.
    public var path: String
    public var line: Int?
    /// Asset name, string key, declaration or table name, when the finding is about a named thing.
    public var name: String?
    /// Display name of the owning module (`ModuleID.name`), or `unknown`.
    public var module: String
    public var confidence: Confidence
    public var reasons: [String]
    public var sizeBytes: Int64?
    /// Findings of kind `duplicate` that belong together share a group ID.
    public var groupID: String?

    public init(kind: FindingKind, category: Category, path: String, line: Int? = nil, name: String? = nil,
                module: String, confidence: Confidence, reasons: [String] = [], sizeBytes: Int64? = nil,
                groupID: String? = nil) {
        self.kind = kind
        self.category = category
        self.path = path
        self.line = line
        self.name = name
        self.module = module
        self.confidence = confidence
        self.reasons = reasons
        self.sizeBytes = sizeBytes
        self.groupID = groupID
    }

    /// Canonical report order: category, kind, path, name, line.
    public static func reportOrder(_ a: Finding, _ b: Finding) -> Bool {
        if a.category != b.category { return a.category < b.category }
        if a.kind != b.kind { return a.kind < b.kind }
        if a.path != b.path { return a.path < b.path }
        if (a.name ?? "") != (b.name ?? "") { return (a.name ?? "") < (b.name ?? "") }
        if (a.line ?? 0) != (b.line ?? 0) { return (a.line ?? 0) < (b.line ?? 0) }
        return a.module < b.module
    }
}
