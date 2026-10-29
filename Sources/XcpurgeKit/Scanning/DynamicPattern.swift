/// A name built at runtime (`"icon_\(i)"`, `"img" + x`, `String(format: "img%d")`): prefix and suffix are
/// the literal parts around the dynamic pieces; `segments` keeps every literal part in order
/// (`"\(a) of \(b)"` -> `["", " of ", ""]`).
public struct DynamicPattern: Sendable, Hashable {
    public enum Domain: String, Sendable, Codable {
        case asset, string, resource, any
    }

    public var prefix: String
    public var suffix: String
    /// Literal parts in order; first is `prefix`, last is `suffix` (two elements unless interpolated more than once).
    public var segments: [String]
    public var file: Int32
    public var line: Int32
    public var domain: Domain
    public var context: CallContext?

    public init(prefix: String, suffix: String, file: Int32, line: Int32, domain: Domain, context: CallContext? = nil,
                segments: [String]? = nil) {
        self.prefix = prefix
        self.suffix = suffix
        self.segments = segments ?? [prefix, suffix]
        self.file = file
        self.line = line
        self.domain = domain
        self.context = context
    }

    /// True when the pattern carries no literal text (a localization call with a variable key).
    public var isKeyless: Bool { prefix.isEmpty && suffix.isEmpty }

    /// True when some literal part (prefix, suffix or a middle segment) carries text.
    public var hasLiteralText: Bool { segments.contains { !$0.isEmpty } }

    /// True when `s` could be this pattern's output: it starts with the first segment, ends with the last,
    /// contains the middle ones in order, and is longer than the literal text.
    public func couldBuild(_ s: String) -> Bool {
        guard let first = segments.first, let last = segments.last,
              s.count > segments.reduce(0, { $0 + $1.count }), s.hasPrefix(first), s.hasSuffix(last) else { return false }
        var rest = s.dropFirst(first.count).dropLast(last.count)
        for middle in segments.dropFirst().dropLast() where !middle.isEmpty {
            guard let r = rest.range(of: middle) else { return false }
            rest = rest[r.upperBound...]
        }
        return true
    }

    public static func domain(for context: CallContext?, extraMacros: [String] = []) -> Domain {
        guard let context else { return .any }
        if context.isAssetLookup { return .asset }
        if context.isLocalization(extraMacros: extraMacros) { return .string }
        if context.isResourceLookup { return .resource }
        return .any
    }
}
