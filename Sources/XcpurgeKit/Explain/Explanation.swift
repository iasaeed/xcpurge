import Foundation

/// What `xcpurge explain` says about one match of a subject: whether it is reported, who could see it, where it
/// is referenced, how its confidence was derived and what would make acting on it safe.
public struct Explanation: Codable, Sendable {
    public enum Status: String, Codable, Sendable {
        /// In the scan output.
        case reported
        /// A detector found it, but a `.xcpurgeignore` rule or inline marker hides it.
        case suppressed
        /// A detector found it below `--min-confidence`.
        case belowThreshold
        /// No detector reports it (it is used, or it is hidden by `--targets` / `--exclude`; see `note`).
        case notReported
    }

    /// One place the name (or a symbol derived from it) appears.
    public struct ReferenceSite: Codable, Hashable, Sendable {
        public var path: String
        public var line: Int
        public var module: String
        /// True when the site's module can see the subject's owners (the visibility rule), so it counts.
        public var visible: Bool
        /// `stringLiteral`, `memberSymbol`, `identifier`, `ibAttribute(image)`, `plistValue`, `buildSetting(KEY)`, `accessorUse(path)`.
        public var kind: String
        /// False for a case-insensitive-only match.
        public var exact: Bool
        /// The token as written at the site.
        public var value: String

        public init(path: String, line: Int, module: String, visible: Bool, kind: String, exact: Bool, value: String) {
            self.path = path
            self.line = line
            self.module = module
            self.visible = visible
            self.kind = kind
            self.exact = exact
            self.value = value
        }
    }

    /// A runtime-built name that could produce the subject.
    public struct DynamicSite: Codable, Hashable, Sendable {
        public var path: String
        public var line: Int
        public var module: String
        /// Literal parts joined by `…` (`icon_…`, `…_title`).
        public var pattern: String
        public var domain: String
        public var visible: Bool

        public init(path: String, line: Int, module: String, pattern: String, domain: String, visible: Bool) {
            self.path = path
            self.line = line
            self.module = module
            self.pattern = pattern
            self.domain = domain
            self.visible = visible
        }
    }

    /// The finding's confidence and how it came about: the kind's starting tier, then one line per reason.
    public struct ConfidenceDerivation: Codable, Sendable {
        public var value: String
        /// `base: …`, then `<code>: <reason text>` per reason.
        public var derivation: [String]

        public init(value: String, derivation: [String]) {
            self.value = value
            self.derivation = derivation
        }
    }

    public var status: Status
    public var finding: Finding?
    /// `.xcpurgeignore:<line> <rule>` or `<path>:<line> xcpurge:ignore marker`; only for `suppressed`.
    public var suppressedBy: String?
    /// Extra context for `notReported`/`belowThreshold` (`hidden by --targets`, `used: 3 visible references`).
    public var note: String?
    /// Modules that own the subject (`container:name`).
    public var owners: [String]
    /// Modules whose references count: the owners plus everything that depends on or embeds them.
    public var modulesChecked: [String]
    public var visibilityRule: String
    /// Capped at `Explainer.siteCap`; `referenceSitesTruncated` says how many more exist.
    public var referenceSites: [ReferenceSite]
    public var referenceSitesTruncated: Int
    public var dynamicPatterns: [DynamicSite]
    public var confidence: ConfidenceDerivation?
    public var toMakeSafe: [String]

    public init(status: Status, finding: Finding? = nil, suppressedBy: String? = nil, note: String? = nil,
                owners: [String] = [], modulesChecked: [String] = [], visibilityRule: String = "",
                referenceSites: [ReferenceSite] = [], referenceSitesTruncated: Int = 0,
                dynamicPatterns: [DynamicSite] = [], confidence: ConfidenceDerivation? = nil, toMakeSafe: [String] = []) {
        self.status = status
        self.finding = finding
        self.suppressedBy = suppressedBy
        self.note = note
        self.owners = owners
        self.modulesChecked = modulesChecked
        self.visibilityRule = visibilityRule
        self.referenceSites = referenceSites
        self.referenceSitesTruncated = referenceSitesTruncated
        self.dynamicPatterns = dynamicPatterns
        self.confidence = confidence
        self.toMakeSafe = toMakeSafe
    }

    enum CodingKeys: String, CodingKey {
        case status, finding, suppressedBy, note, owners, modulesChecked, visibilityRule, referenceSites,
             referenceSitesTruncated, dynamicPatterns, confidence, toMakeSafe
    }

    /// `finding` and `suppressedBy` are always present (`null` when absent) so consumers can key on them.
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(status, forKey: .status)
        try c.encode(finding, forKey: .finding)
        try c.encode(suppressedBy, forKey: .suppressedBy)
        try c.encodeIfPresent(note, forKey: .note)
        try c.encode(owners, forKey: .owners)
        try c.encode(modulesChecked, forKey: .modulesChecked)
        try c.encode(visibilityRule, forKey: .visibilityRule)
        try c.encode(referenceSites, forKey: .referenceSites)
        try c.encode(referenceSitesTruncated, forKey: .referenceSitesTruncated)
        try c.encode(dynamicPatterns, forKey: .dynamicPatterns)
        try c.encodeIfPresent(confidence, forKey: .confidence)
        try c.encode(toMakeSafe, forKey: .toMakeSafe)
    }
}

/// The `explain --format json` document.
public struct ExplainReport: Codable, Sendable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    public var tool: String
    /// The subject as given.
    public var subject: String
    /// Absolute scan root.
    public var root: String
    public var matches: [Explanation]

    public init(subject: String, root: String, matches: [Explanation]) {
        self.schemaVersion = Self.schemaVersion
        self.tool = "\(XcpurgeVersion.name) \(XcpurgeVersion.current)"
        self.subject = subject
        self.root = root
        self.matches = matches
    }
}
