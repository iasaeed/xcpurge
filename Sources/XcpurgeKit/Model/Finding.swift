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
    /// Git history (`--git`); set after `ScanEngine.filter`, which dedups through a Set.
    public var history: FindingHistory?

    public init(kind: FindingKind, category: Category, path: String, line: Int? = nil, name: String? = nil,
                module: String, confidence: Confidence, reasons: [String] = [], sizeBytes: Int64? = nil,
                groupID: String? = nil, history: FindingHistory? = nil) {
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
        self.history = history
    }

    /// Identity across runs (no line number, locales collapsed); see `FindingIdentity.key`.
    public var key: String { FindingIdentity.key(self) }
    /// Short stable id, `<kind>-<10 hex>`; see `FindingIdentity.id`.
    public var id: String { FindingIdentity.id(self) }

    /// Canonical report order: category, kind, path, name, line.
    public static func reportOrder(_ a: Finding, _ b: Finding) -> Bool {
        if a.category != b.category { return a.category < b.category }
        if a.kind != b.kind { return a.kind < b.kind }
        if a.path != b.path { return a.path < b.path }
        if (a.name ?? "") != (b.name ?? "") { return (a.name ?? "") < (b.name ?? "") }
        if (a.line ?? 0) != (b.line ?? 0) { return (a.line ?? 0) < (b.line ?? 0) }
        return a.module < b.module
    }

    // MARK: Codable

    /// Stored properties only, so `init(from:)` stays synthesized; `id` is written by `encode(to:)` and ignored on read.
    enum CodingKeys: String, CodingKey {
        case kind, category, path, line, name, module, confidence, reasons, sizeBytes, groupID, history
    }

    private enum DerivedKeys: String, CodingKey { case id }

    /// The synthesized encoding (optionals omitted when nil) plus the derived `id`.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(category, forKey: .category)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(line, forKey: .line)
        try c.encodeIfPresent(name, forKey: .name)
        try c.encode(module, forKey: .module)
        try c.encode(confidence, forKey: .confidence)
        try c.encode(reasons, forKey: .reasons)
        try c.encodeIfPresent(sizeBytes, forKey: .sizeBytes)
        try c.encodeIfPresent(groupID, forKey: .groupID)
        try c.encodeIfPresent(history, forKey: .history)
        var derived = encoder.container(keyedBy: DerivedKeys.self)
        try derived.encode(id, forKey: .id)
    }
}
