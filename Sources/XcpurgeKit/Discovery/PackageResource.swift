/// A SwiftPM `resources:` entry.
public struct PackageResource: Sendable, Hashable {
    public enum Rule: String, Sendable, Codable {
        case process, copy, embedInCode
    }

    /// Root-relative path.
    public var path: String
    public var rule: Rule

    public init(path: String, rule: Rule) {
        self.path = path
        self.rule = rule
    }
}
