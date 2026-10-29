/// A name built at runtime (`"icon_\(i)"`, `"img" + x`, `String(format: "img%d")`): prefix and suffix are
/// the literal parts around the dynamic piece.
public struct DynamicPattern: Sendable, Hashable {
    public enum Domain: String, Sendable, Codable {
        case asset, string, resource, any
    }

    public var prefix: String
    public var suffix: String
    public var file: Int32
    public var line: Int32
    public var domain: Domain
    public var context: CallContext?

    public init(prefix: String, suffix: String, file: Int32, line: Int32, domain: Domain, context: CallContext? = nil) {
        self.prefix = prefix
        self.suffix = suffix
        self.file = file
        self.line = line
        self.domain = domain
        self.context = context
    }

    /// True when the pattern carries no literal text (a localization call with a variable key).
    public var isKeyless: Bool { prefix.isEmpty && suffix.isEmpty }

    public static func domain(for context: CallContext?, extraMacros: [String] = []) -> Domain {
        guard let context else { return .any }
        if context.isAssetLookup { return .asset }
        if context.isLocalization(extraMacros: extraMacros) { return .string }
        if context.isResourceLookup { return .resource }
        return .any
    }
}
