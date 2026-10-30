// LANE: A
import Foundation

/// `.xcpurgeignore` rules, one per line, gitignore style: root-relative path globs (`**`, `*`, `?`, leading `/`
/// anchors, trailing `/` matches directories only), plus `asset:`, `string:`, `module:` and `kind:` name entries
/// (wildcards allowed). `!` negates a rule, the last matching rule wins, `#` starts a comment.
public struct Ignore: Sendable {
    public static let fileName = ".xcpurgeignore"

    /// Starter `.xcpurgeignore` written by `xcpurge init`.
    public static let template = """
    # xcpurge ignore rules, one per line. Paths are relative to the scan root, gitignore style.
    # The last matching rule wins; `!` re-includes something an earlier rule ignored.
    #
    # Path globs:
    #   Vendor/**                 everything under Vendor
    #   /Scripts/                 the top-level Scripts directory only (trailing / = directories)
    #   **/*Generated*.swift      any generated Swift file
    #   !Vendor/Keep.swift        but still report this file
    #
    # Names (wildcards allowed):
    #   asset:server_driven_*     assets loaded by name from the server
    #   string:push.*             localization keys sent in push payloads
    #   module:LegacyKit          every finding in a module
    #   kind:deadSource           a whole finding kind (camelCase or kebab-case)
    #
    # Single lines in source: add a `// xcpurge:ignore` comment on or above the declaration.

    """

    enum Matcher: Sendable, Hashable {
        case path(Glob, directoryOnly: Bool)
        case asset(String)
        case string(String)
        case module(String)
        case kind(String)
    }

    struct Rule: Sendable, Hashable {
        var matcher: Matcher
        var negated: Bool
        /// 1-based line in the ignore file.
        var line: Int
        /// The rule as written (trimmed, including a leading `!`).
        var text: String
    }

    /// A rule's position and text, for reports about the ignore file itself.
    public struct RuleSummary: Sendable, Hashable {
        public var line: Int
        public var text: String
        public var negated: Bool
    }

    let rules: [Rule]

    public init() { rules = [] }

    /// Parses ignore-file text.
    public init(contents: String) {
        var rules: [Rule] = []
        for (index, raw) in contents.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
            var line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let text = line
            var negated = false
            if line.hasPrefix("!") { negated = true; line.removeFirst() }
            if line.hasPrefix("\\") { line.removeFirst() }  // `\#file`, `\!file`
            guard !line.isEmpty else { continue }
            rules.append(Rule(matcher: Self.matcher(for: line), negated: negated, line: index + 1, text: text))
        }
        self.rules = rules
    }

    /// Every rule's line and text, in file order.
    public var ruleSummaries: [RuleSummary] {
        rules.map { RuleSummary(line: $0.line, text: $0.text, negated: $0.negated) }
    }

    private static func matcher(for line: String) -> Matcher {
        for (prefix, make) in [("asset:", Matcher.asset), ("string:", Matcher.string), ("module:", Matcher.module),
                               ("kind:", Matcher.kind)] where line.hasPrefix(prefix) {
            return make(String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces))
        }
        return .path(Glob(line), directoryOnly: line.hasSuffix("/"))
    }

    /// Loads `<root>/.xcpurgeignore`, or an empty rule set when absent.
    public static func load(root: URL) throws -> Ignore {
        let url = root.appendingPathComponent(fileName)
        guard FileManager.default.fileExists(atPath: url.path) else { return Ignore() }
        return Ignore(contents: try String(contentsOf: url, encoding: .utf8))
    }

    public var isEmpty: Bool { rules.isEmpty }

    /// True when a rule suppresses this finding (last matching rule wins).
    public func suppresses(_ finding: Finding) -> Bool {
        var suppressed = false
        for rule in rules where Self.matches(rule.matcher, finding) { suppressed = !rule.negated }
        return suppressed
    }

    /// `suppresses(_:)`, plus inline `// xcpurge:ignore` markers on the finding's line.
    public func suppresses(_ finding: Finding, refs: ReferenceIndex, inventory: FileInventory) -> Bool {
        if let line = finding.line, let index = inventory.index(of: finding.path),
           refs.isIgnored(file: Int32(index), line: Int32(line)) {
            return true
        }
        return suppresses(finding)
    }

    private static func matches(_ matcher: Matcher, _ f: Finding) -> Bool {
        switch matcher {
        case let .path(glob, directoryOnly):
            // Directory-only rules match an ancestor of the finding's path, or the path itself when it is a folder unit.
            guard directoryOnly else { return glob.matches(f.path) }
            let ext = (RelPath.lastComponent(f.path) as NSString).pathExtension.lowercased()
            return glob.matches(RelPath.parent(f.path)) || (folderExtensions.contains(ext) && glob.matches(f.path))
        case .asset(let p):
            return f.category == .assets && f.kind != .duplicate && nameMatches(p, f.name)
        case .string(let p):
            return f.category == .strings && nameMatches(p, f.name)
        case .module(let p):
            return nameMatches(p, f.module)
        case .kind(let k):
            return k == f.kind.rawValue || k == f.kind.flagName
        }
    }

    /// Findings whose path is one of these folders count as directories for trailing-`/` rules.
    private static let folderExtensions = FileKind.bundleExtensions.union([
        "imageset", "colorset", "appiconset", "dataset", "symbolset", "iconset", "lproj", "mlpackage",
    ])

    static func nameMatches(_ pattern: String, _ name: String?) -> Bool {
        guard let name, !pattern.isEmpty else { return false }
        return Glob.matchSegment(Array(pattern), Array(name))
    }
}
