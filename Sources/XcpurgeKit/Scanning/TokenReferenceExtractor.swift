/// Turns a token stream into references and dynamic patterns, tracking call frames so each string literal
/// knows its callee, argument label, and the call's `tableName:` / `bundle:` arguments.
struct TokenReferenceExtractor {
    private struct Frame {
        var id: Int
        var callee: String?
        var label: String?
        var argIndex = 0
        var awaitingArg = true
        var table: String?
        var bundleTokens: [String] = []
        /// `[`/`{` barriers just isolate inner tokens.
        var isBarrier: Bool
        var closer: String
        var refStart: Int
        var patternStart: Int
    }

    let tokens: [SwiftToken]
    let file: Int32
    let dialect: SwiftTokenizer.Dialect
    let localizationMacros: [String]
    private var out = ScanOutput()
    private var frames: [Frame] = []
    private var refFrame: [Int] = []
    private var patternFrame: [Int] = []
    private var nextFrameID = 0
    /// Accessor chain (OSS scan #1): the outermost `var`/`let`/`func` being declared and the frame depth it sits at,
    /// then the one whose `{ … }` body (by frame id) or `= …` initializer (until the next line at its depth) is open.
    /// Heuristic, no type checking: nested declarations count for the outer one.
    private var pendingDecl: (name: String, depth: Int)?
    private var bodyDecl: (name: String, frame: Int)?
    private var initDecl: (name: String, depth: Int, line: Int32)?
    /// `enum Name: String` (OSS scan #3c): its name once declared, then with the frame id of its `{ … }` body.
    private var pendingRawEnum: String?
    private var rawEnum: (name: String, frame: Int)?
    /// Names bound to a string expression in this file (`let themeName = "theme_" + mode`): passing one to a lookup is
    /// already covered by the literal's own dynamic pattern, so it is no keyless lookup.
    private var stringBound = Set<String>()

    static let declarationKeywords: Set<String> = ["var", "let", "func"]
    /// Keywords that end a pending `var`/`let`/`func` without a body (protocol requirements, new scopes).
    static let declarationResets: Set<String> = [
        "class", "struct", "enum", "extension", "protocol", "actor", "init", "deinit", "subscript", "case", "import",
        "typealias",
    ]
    /// Binding keywords preceded by these are conditions, not declarations (`if let x = y {`).
    static let conditionKeywords: Set<String> = ["if", "guard", "while", "case", "for"]

    init(tokens: [SwiftToken], file: Int32, dialect: SwiftTokenizer.Dialect, localizationMacros: [String]) {
        self.tokens = tokens
        self.file = file
        self.dialect = dialect
        self.localizationMacros = localizationMacros
    }

    static func extract(_ tokenized: SwiftTokenizer.Output, file: Int32, dialect: SwiftTokenizer.Dialect,
                        localizationMacros: [String]) -> ScanOutput {
        var x = TokenReferenceExtractor(tokens: tokenized.tokens, file: file, dialect: dialect,
                                        localizationMacros: localizationMacros)
        x.run()
        x.out.ignoredLines = tokenized.ignoredLines
        x.out.ignoreMarkers = tokenized.ignoreMarkers
        return x.out
    }

    private mutating func run() {
        for t in tokens.indices { visit(t) }
        while !frames.isEmpty { popFrame() }
    }

    private func token(_ t: Int) -> SwiftToken? { tokens.indices.contains(t) ? tokens[t] : nil }

    private mutating func visit(_ t: Int) {
        let tok = tokens[t]
        if dialect == .swift {
            trackDeclaration(t, tok)
            trackRawValueEnum(t, tok)
            if tok.kind == .identifier, tok.text == "let" || tok.text == "var", let name = token(t + 1),
               name.kind == .identifier, let eq = token(t + 2), eq.isPunct("="),
               tokens[(t + 3)..<min(tokens.count, t + 40)].prefix(while: { $0.line == eq.line }).contains(where: { $0.kind == .string }) {
                stringBound.insert(name.text)
            }
        }
        if tok.kind == .punct {
            switch tok.text {
            case "(":
                let prev = token(t - 1)
                frames.append(newFrame(callee: prev.flatMap { $0.isName || $0.kind == .macro ? $0.text : nil },
                                       barrier: false, closer: ")"))
                return
            case "[":
                if dialect == .objc, let receiver = token(t + 1), receiver.isName {
                    frames.append(newFrame(callee: receiver.text, barrier: false, closer: "]"))
                } else {
                    frames.append(newFrame(callee: nil, barrier: true, closer: "]"))
                }
                return
            case "{":
                frames.append(newFrame(callee: nil, barrier: true, closer: "}"))
                return
            case ")", "]", "}":
                if let index = frames.lastIndex(where: { $0.closer == tok.text }) {
                    while frames.count > index { popFrame() }
                }
                return
            case ",":
                if var f = frames.last, !f.isBarrier {
                    f.argIndex += 1; f.label = nil; f.awaitingArg = true
                    frames[frames.count - 1] = f
                }
                return
            default:
                break
            }
        }

        // Argument labels: `name:` at the start of an argument (Swift) or anywhere in a message send (ObjC).
        if tok.isName, token(t + 1)?.isPunct(":") == true, var f = frames.last, !f.isBarrier,
           f.awaitingArg || dialect == .objc {
            f.label = tok.text
            f.awaitingArg = true
            frames[frames.count - 1] = f
            return
        }
        if tok.isPunct(":") { return }

        if var f = frames.last, !f.isBarrier {
            // `bundle:` (localization, `Image(_:bundle:)`) and `in:` (`UIImage(named:in:compatibleWith:)`).
            if f.label == "bundle" || f.label == "in" { f.bundleTokens.append(tok.text) }
            if f.awaitingArg {
                f.awaitingArg = false
                // A localization call whose key is a variable: keyless lookup. An argument starting with a type
                // name (`Text(Date(), …)`, `Text(String(localized: …))`, `Text(L10n.x)`) is not a variable key.
                if tok.kind == .identifier, let first = tok.text.first, first.isLowercase || first == "_",
                   context(for: f).isLocalization(extraMacros: localizationMacros) {
                    addPattern(prefix: "", suffix: "", line: tok.line, context: context(for: f))
                }
                // OSS scan #3e: an asset name passed as a bare variable (`UIImage(named: entityName)`): keyless asset
                // lookup. Not a member chain, a ternary of literals or a variable bound to a string on its line.
                if tok.kind == .identifier, let first = tok.text.first, first.isLowercase || first == "_",
                   !Self.literalKeywords.contains(tok.text), !stringBound.contains(tok.text),
                   let after = token(t + 1), after.isPunct(",") || after.isPunct(")") || after.isPunct("]"),
                   Self.isNameArgument(context(for: f)) {
                    addPattern(prefix: "", suffix: "", line: tok.line, context: context(for: f))
                }
            }
            if tok.kind == .string, !tok.interpolated {
                if f.label == "tableName" || f.label == "table" { f.table = tok.text }
                if f.argIndex == 1, f.label == nil, f.callee?.hasPrefix("NSLocalizedStringFromTable") == true {
                    f.table = tok.text
                }
            }
            frames[frames.count - 1] = f
        }

        switch tok.kind {
        case .string:
            emitString(t, tok)
        case .member:
            var ctx = frames.last.flatMap { $0.isBarrier ? nil : context(for: $0) } ?? CallContext()
            ctx.qualifier = qualifier(before: t)
            addRef(.memberSymbol, tok.text, tok.line, ctx)
        case .identifier, .attribute, .macro:
            addRef(.identifier, tok.text, tok.line, nil)
        default:
            break
        }
    }

    private mutating func emitString(_ t: Int, _ tok: SwiftToken) {
        let ctx = frames.last.flatMap { $0.isBarrier ? nil : context(for: $0) }
        if tok.interpolated {
            addPattern(prefix: tok.text, suffix: tok.suffix, line: tok.line, context: ctx, segments: tok.segments)
            return
        }
        addRef(.stringLiteral, tok.text, tok.line, ctx)
        // `"lit" + x` -> prefix; `x + "lit"` -> suffix.
        if token(t + 1)?.isPunct("+") == true, let next = token(t + 2), next.kind != .string, !next.isPunct("=") {
            addPattern(prefix: tok.text, suffix: "", line: tok.line, context: ctx)
        }
        if token(t - 1)?.isPunct("+") == true, let prev = token(t - 2), prev.kind != .string, !tok.text.isEmpty {
            addPattern(prefix: "", suffix: tok.text, line: tok.line, context: ctx)
        }
        // `String(format: "img%d", n)` / `stringWithFormat:@"img%d"` -> cut at the specifiers.
        if let ctx, ctx.label == "format" || ctx.label == "stringWithFormat" || ctx.callee == "localizedStringWithFormat",
           let (prefix, suffix) = Self.formatParts(tok.text) {
            addPattern(prefix: prefix, suffix: suffix, line: tok.line, context: ctx)
        }
    }

    /// Follows `var`/`let`/`func` declarations so string literals know the declaration whose body holds them.
    private mutating func trackDeclaration(_ t: Int, _ tok: SwiftToken) {
        if let d = initDecl, frames.count < d.depth || (frames.count == d.depth && tok.line > d.line) { initDecl = nil }
        guard bodyDecl == nil, initDecl == nil else { return }
        if tok.kind == .identifier {
            if Self.declarationKeywords.contains(tok.text), let name = token(t + 1), name.kind == .identifier,
               !(token(t - 1).map { $0.kind == .identifier && Self.conditionKeywords.contains($0.text) } ?? false) {
                pendingDecl = (name.text, frames.count)
                out.declarationCounts[name.text, default: 0] += 1
            } else if Self.declarationResets.contains(tok.text) {
                pendingDecl = nil
            }
            return
        }
        guard let pending = pendingDecl, tok.kind == .punct, frames.count == pending.depth else { return }
        switch tok.text {
        case "=":
            initDecl = (pending.name, frames.count, tok.line)
            pendingDecl = nil
        case "{":
            bodyDecl = (pending.name, nextFrameID + 1)  // the frame `visit` pushes next
            pendingDecl = nil
        case "}", ";":
            pendingDecl = nil
        default:
            break
        }
    }

    /// Lowercase keywords that are values, not variables.
    static let literalKeywords: Set<String> = ["nil", "true", "false", "self", "super", "try", "await"]

    /// True for the name argument of an asset lookup: `named:` / `name:` / `imageNamed:` / `colorNamed:`, or SwiftUI
    /// `Image(name)`. Not `systemName:`, `decorative:` (also takes a `CGImage`), `contentsOfFile:` and the like.
    static func isNameArgument(_ c: CallContext) -> Bool {
        guard c.isAssetLookup else { return false }
        if let label = c.label { return ["named", "name", "imageNamed", "colorNamed"].contains(label) }
        return c.callee == "Image" && c.argIndex == 0
    }

    /// Emits each case of an `enum Name: String` without an explicit raw value as an implicit raw value: the case name
    /// is the string `rawValue` returns (`Bundle.main.url(forResource: effect.rawValue, …)` with `case pull`).
    private mutating func trackRawValueEnum(_ t: Int, _ tok: SwiftToken) {
        if tok.kind == .identifier, tok.text == "enum", let name = token(t + 1), name.kind == .identifier,
           token(t + 2)?.isPunct(":") == true, let raw = token(t + 3), raw.kind == .identifier, raw.text == "String" {
            pendingRawEnum = name.text
            return
        }
        if let name = pendingRawEnum, tok.isPunct("{") {
            rawEnum = (name, nextFrameID + 1)  // the frame `visit` pushes next
            pendingRawEnum = nil
            return
        }
        guard let e = rawEnum, tok.kind == .identifier, tok.text == "case", frames.last?.id == e.frame else { return }
        var k = t + 1
        while let name = token(k), name.kind == .identifier {
            var next = k + 1
            if token(next)?.isPunct("=") == true {
                next += 2  // explicit raw value: `case b = "bee"`
            } else if token(next)?.isPunct("(") != true {
                addRef(.implicitRawValue(e.name), name.text, name.line, nil)
            }
            guard token(next)?.isPunct(",") == true else { break }
            k = next + 1
        }
    }

    /// Splits a format string at its first and last `%` specifiers; nil when there is none.
    static func formatParts(_ s: String) -> (String, String)? {
        let chars = Array(s)
        var specs: [(Int, Int)] = []
        var i = 0
        while i < chars.count {
            if chars[i] == "%" {
                if i + 1 < chars.count, chars[i + 1] == "%" { i += 2; continue }
                var j = i + 1
                while j < chars.count, !chars[j].isLetter || "hlqLzjt".contains(chars[j]) { j += 1 }
                specs.append((i, min(j + 1, chars.count)))
                i = j + 1
                continue
            }
            i += 1
        }
        guard let first = specs.first, let last = specs.last else { return nil }
        return (String(chars[..<first.0]), String(chars[last.1...]))
    }

    /// Dotted chain before the member at `t` (`Asset.Colors` for `Asset.Colors.brand`, `""` for `.brand`).
    private func qualifier(before t: Int) -> String {
        var parts: [String] = []
        var k = t - 1
        while k >= 1, tokens[k].isPunct("."), tokens[k - 1].isName, parts.count < 8 {
            parts.insert(tokens[k - 1].text, at: 0)
            if tokens[k - 1].kind == .identifier { break }
            k -= 2
        }
        return parts.joined(separator: ".")
    }

    private func context(for f: Frame) -> CallContext {
        CallContext(callee: f.callee, label: f.label, argIndex: f.argIndex, table: f.table)
    }

    private mutating func newFrame(callee: String?, barrier: Bool, closer: String) -> Frame {
        nextFrameID += 1
        return Frame(id: nextFrameID, callee: callee, isBarrier: barrier, closer: closer,
                     refStart: out.references.count, patternStart: out.patterns.count)
    }

    /// Pops the innermost frame and back-fills its table / bundle arguments into the references it produced.
    private mutating func popFrame() {
        guard let f = frames.popLast() else { return }
        if bodyDecl?.frame == f.id { bodyDecl = nil }
        if rawEnum?.frame == f.id { rawEnum = nil }
        guard !f.isBarrier else { return }
        let bundle = f.bundleTokens.isEmpty ? nil : f.bundleTokens.prefix(4).joined()
        guard f.table != nil || bundle != nil else { return }
        for r in f.refStart..<out.references.count where refFrame[r] == f.id {
            out.references[r].context?.table = f.table
            out.references[r].context?.bundle = bundle
        }
        for p in f.patternStart..<out.patterns.count where patternFrame[p] == f.id {
            out.patterns[p].context?.table = f.table
            out.patterns[p].context?.bundle = bundle
        }
    }

    private mutating func addRef(_ kind: RefKind, _ value: String, _ line: Int32, _ ctx: CallContext?) {
        if kind == .stringLiteral, let decl = bodyDecl?.name ?? initDecl?.name {
            out.enclosingDeclarations[out.references.count] = decl
        }
        out.references.append(Reference(kind: kind, value: value, file: file, line: line, context: ctx))
        refFrame.append(frames.last.map { $0.isBarrier ? 0 : $0.id } ?? 0)
    }

    private mutating func addPattern(prefix: String, suffix: String, line: Int32, context: CallContext?,
                                     segments: [String]? = nil) {
        out.patterns.append(DynamicPattern(prefix: prefix, suffix: suffix, file: file, line: line,
                                           domain: DynamicPattern.domain(for: context, extraMacros: localizationMacros),
                                           context: context, segments: segments))
        patternFrame.append(frames.last.map { $0.isBarrier ? 0 : $0.id } ?? 0)
    }
}
