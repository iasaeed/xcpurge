// LANE: C
/// Lexical declaration summary of one source file for dead-file analysis (plan §4.5 step 2): nominal types (top-level
/// and nested), top-level functions and variables, extension members, ObjC classes and categories, attributes, macros,
/// inheritance clauses and `public`/`open` use. Token-based, so it never fails on code it does not understand.
enum DeclarationCollector {
    struct Result: Sendable, Equatable {
        /// Top-level nominal types (`class struct enum actor protocol`, ObjC `@interface`/`@implementation`).
        var types: [String] = []
        /// Nominal types nested in another declaration or an extension (`Foo.Coordinator`).
        var nestedTypes: [String] = []
        /// Top-level `func var let typealias macro` names.
        var members: [String] = []
        /// Members added by `extension X { … }` (and extended type names of ObjC categories).
        var extensionMembers: [String] = []
        /// An extension adds a conformance, an initializer, a subscript or an operator: its use is invisible by name.
        var hasOpaqueExtension = false
        /// ObjC categories (`@interface X (Cat)`), by class name.
        var categories: [String] = []
        /// `@attr` tokens seen anywhere (with the sigil).
        var attributes: Set<String> = []
        /// `#macro` tokens seen anywhere (with the sigil).
        var macros: Set<String> = []
        /// Names in inheritance clauses of the file's types and extensions.
        var supertypes: Set<String> = []
        /// A top-level declaration is `public` or `open`.
        var hasPublic = false
        /// Line of the first declaration.
        var firstLine: Int32?

        var allNames: [String] { types + members + extensionMembers }
    }

    static let typeKeywords: Set<String> = ["class", "struct", "enum", "actor", "protocol"]
    static let memberKeywords: Set<String> = ["func", "var", "let", "typealias", "macro"]
    /// Words after `class` that make it a modifier (`class func`), not a declaration.
    static let notNames: Set<String> = [
        "func", "var", "let", "override", "final", "private", "fileprivate", "internal", "public", "open", "static",
        "subscript", "init", "deinit", "required", "convenience", "dynamic", "nonisolated", "mutating", "typealias",
        "lazy", "weak", "unowned", "indirect", "case", "some", "any",
    ]

    static func collect(_ tokens: [SwiftToken], dialect: SwiftTokenizer.Dialect) -> Result {
        dialect == .objc ? collectObjC(tokens) : collectSwift(tokens)
    }

    // MARK: - Swift

    private static func collectSwift(_ tokens: [SwiftToken]) -> Result {
        var r = Result()
        var depth = 0
        var pendingExtension = false     // saw `extension` at depth 0, waiting for its `{`
        var inExtension = false          // inside a top-level extension body
        func next(_ i: Int) -> SwiftToken? { i + 1 < tokens.count ? tokens[i + 1] : nil }
        func note(_ line: Int32) { if r.firstLine == nil { r.firstLine = line } }

        var i = 0
        while i < tokens.count {
            let t = tokens[i]
            switch t.kind {
            case .attribute: r.attributes.insert(t.text)
            case .macro: r.macros.insert(t.text)
            case .punct where t.text == "{":
                if depth == 0 { inExtension = pendingExtension; pendingExtension = false }
                depth += 1
            case .punct where t.text == "}":
                depth = max(0, depth - 1)
                if depth == 0 { inExtension = false }
            case .identifier:
                let prev = i > 0 ? tokens[i - 1] : nil
                if prev?.kind == .identifier, prev?.text == "import" { break }
                if depth == 0, t.text == "public" || t.text == "open", next(i)?.isPunct("(") != true { r.hasPublic = true }
                if typeKeywords.contains(t.text), let n = next(i), n.kind == .identifier, !notNames.contains(n.text) {
                    if depth == 0 { r.types.append(n.text) } else { r.nestedTypes.append(n.text) }
                    note(t.line)
                    i = inheritance(tokens, after: i + 2, into: &r)
                    continue
                }
                if depth == 0, t.text == "extension", let n = next(i), n.isName {
                    pendingExtension = true
                    note(t.line)
                    // `extension A.B` — the dotted name; a `:` right after it is a conformance.
                    var j = i + 2
                    while j + 1 < tokens.count, tokens[j].isPunct("."), tokens[j + 1].isName { j += 2 }
                    if j < tokens.count, tokens[j].isPunct(":") {
                        r.hasOpaqueExtension = true
                        j = inheritance(tokens, after: j, into: &r)
                    }
                    i = j
                    continue
                }
                if depth == 0, memberKeywords.contains(t.text) {
                    if let n = next(i), n.kind == .identifier { r.members.append(n.text); note(t.line) }
                } else if depth == 1, inExtension {
                    if memberKeywords.contains(t.text) || t.text == "case" {
                        if let n = next(i), n.kind == .identifier, !notNames.contains(n.text) {
                            r.extensionMembers.append(n.text)
                        } else if t.text == "func" {
                            r.hasOpaqueExtension = true   // operator
                        }
                    } else if t.text == "init" || t.text == "subscript" {
                        r.hasOpaqueExtension = true
                    }
                }
            default: break
            }
            i += 1
        }
        return r
    }

    /// Reads `: A, B & C<D>` up to `{` / `where`, recording names; returns the index of the stopping token.
    private static func inheritance(_ tokens: [SwiftToken], after start: Int, into r: inout Result) -> Int {
        var j = start
        var angle = 0
        // Skip generic parameters right after the type name.
        if j < tokens.count, tokens[j].isPunct("<") {
            while j < tokens.count {
                if tokens[j].isPunct("<") { angle += 1 } else if tokens[j].isPunct(">") { angle -= 1 }
                j += 1
                if angle == 0 { break }
            }
        }
        guard j < tokens.count, tokens[j].isPunct(":") else { return j }
        j += 1
        while j < tokens.count, !tokens[j].isPunct("{"), !(tokens[j].kind == .identifier && tokens[j].text == "where") {
            if tokens[j].isName { r.supertypes.insert(tokens[j].text) }
            if tokens[j].kind == .attribute { r.attributes.insert(tokens[j].text) }   // `@MainActor`, `@unchecked`
            j += 1
        }
        return j
    }

    // MARK: - Objective-C

    private static func collectObjC(_ tokens: [SwiftToken]) -> Result {
        var r = Result()
        for (i, t) in tokens.enumerated() {
            if t.kind == .attribute { r.attributes.insert(t.text) }
            if t.kind == .macro { r.macros.insert(t.text) }
            guard t.kind == .attribute, ["@interface", "@implementation", "@protocol"].contains(t.text),
                  i + 1 < tokens.count, tokens[i + 1].kind == .identifier else { continue }
            let name = tokens[i + 1].text
            if r.firstLine == nil { r.firstLine = t.line }
            if i + 2 < tokens.count, tokens[i + 2].isPunct("(") {
                if t.text != "@protocol" { r.categories.append(name) }
            } else if i + 2 < tokens.count, tokens[i + 2].isPunct(";") || tokens[i + 2].isPunct(",") {
                continue   // forward declaration `@protocol X;`
            } else {
                r.types.append(name)
                if i + 3 < tokens.count, tokens[i + 2].isPunct(":"), tokens[i + 3].kind == .identifier {
                    r.supertypes.insert(tokens[i + 3].text)
                }
            }
        }
        return r
    }
}
