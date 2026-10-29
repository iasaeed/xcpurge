/// One lexical token from `SwiftTokenizer`.
public struct SwiftToken: Sendable, Hashable {
    public enum Kind: Sendable, Hashable {
        /// Bare identifier or keyword (backticks stripped).
        case identifier
        /// Identifier directly after a `.` (`.hero`, `Foo.bar`).
        case member
        /// `@name` (Swift attribute, ObjC directive).
        case attribute
        /// `#name` (Swift macro / directive, ObjC preprocessor).
        case macro
        /// String literal; `text` is the decoded value (prefix when interpolated).
        case string
        case number
        /// Regex literal (`/…/`, `#/…/#`); `text` is empty.
        case regex
        /// Single punctuation / operator character.
        case punct
    }

    public var kind: Kind
    public var text: String
    public var line: Int32
    /// Strings only: contains `\(…)` interpolation.
    public var interpolated: Bool
    /// Strings only: literal text after the last interpolation.
    public var suffix: String

    public init(kind: Kind, text: String, line: Int32, interpolated: Bool = false, suffix: String = "") {
        self.kind = kind
        self.text = text
        self.line = line
        self.interpolated = interpolated
        self.suffix = suffix
    }

    public func isPunct(_ c: String) -> Bool { kind == .punct && text == c }
    public var isName: Bool { kind == .identifier || kind == .member }
}
