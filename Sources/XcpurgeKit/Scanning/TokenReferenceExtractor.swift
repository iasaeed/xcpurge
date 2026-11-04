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
        /// Extension literal of `withExtension:` / `ofType:` / `extension:` and the keyless resource-name patterns of
        /// this call, which `popFrame` turns into `"." + ext` suffix patterns.
        var resourceExt: String?
        var resourcePatterns: [Int] = []
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
    private var rawEnums: [(name: String, frame: Int)] = []  // innermost last: `enum Inner: String` nests
    /// Names bound to an expression with literal text anywhere in this file (`let themeName = "theme_" + mode`,
    /// `let name = isSaved ? "a" : "b"`): the literals are indexed themselves, so passing one is no keyless lookup.
    private var stringBound = Set<String>()
    /// OSS scan #3e: locals of the current outermost declaration body computed without literal text (`let name =
    /// model.icon()`, `for name in names`). Only these make a keyless asset lookup: parameters (forwarding wrappers,
    /// whose callers' literals are indexed) and stored properties never do.
    private var computedLocals = Set<String>()
    /// A computed local and the token index where its initializer ends: `let image = UIImage(named: image)` still
    /// reads the parameter `image` inside its own initializer.
    private var pendingLocals: [(name: String, from: Int)] = []
    /// Computed local -> the same-file function its initializer calls (`let iconName = sectionIconName(for: s)`), and
    /// keyless pattern index -> that function: a function whose body holds literals returns names already indexed.
    private var localCallee: [String: String] = [:]
    private var keylessCallee: [Int: String] = [:]
    /// Keyless resource-name patterns whose call has no literal extension: dropped, they would match every file.
    private var droppedPatterns = Set<Int>()
    /// Token index of an explicit `case b = "lit"` raw value -> its enum's name.
    private var rawValueTokens: [Int: String] = [:]
    /// Token index of an interpolated string -> the literal chain before it (`"a" + "b" + "\(k)"` -> `"ab"`).
    private var foldedPrefixes: [Int: String] = [:]

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
        let returnsLiterals = Set(out.enclosingDeclarations.values)
        let drop = droppedPatterns.union(keylessCallee.filter { returnsLiterals.contains($0.value) }.keys)
        if !drop.isEmpty {
            out.patterns = out.patterns.enumerated().filter { !drop.contains($0.offset) }.map(\.element)
        }
    }

    private func token(_ t: Int) -> SwiftToken? { tokens.indices.contains(t) ? tokens[t] : nil }

    private mutating func visit(_ t: Int) {
        let tok = tokens[t]
        if dialect == .swift {
            trackDeclaration(t, tok)
            trackRawValueEnum(t, tok)
            if !pendingLocals.isEmpty {
                for local in pendingLocals where local.from <= t { computedLocals.insert(local.name) }
                pendingLocals.removeAll { $0.from <= t }
            }
            trackLocalBinding(t, tok)
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
                // OSS scan #3e: an asset name computed locally (`UIImage(named: name)` after `let name = f(x)`, or
                // `name.lowercased()`): keyless asset lookup. Never for parameters, properties, literal-bound names,
                // a plain property read (`model.iconName`) or an argument holding literal text (interpolation, ternary).
                if tok.kind == .identifier, computedLocals.contains(tok.text), !stringBound.contains(tok.text),
                   Self.isNameArgument(context(for: f)), !argumentHasLiteral(t), !isPropertyRead(t) {
                    if let callee = localCallee[tok.text] { keylessCallee[out.patterns.count] = callee }
                    addPattern(prefix: "", suffix: "", line: tok.line, context: context(for: f))
                }
                // A resource name read from a variable or property (`forResource: title.bundleName`): keyless pattern,
                // given the call's extension as suffix by `popFrame`. A plain name bound to literals is indexed instead.
                if tok.kind == .identifier, let first = tok.text.first, first.isLowercase || first == "_",
                   !Self.literalKeywords.contains(tok.text) || isSelfPropertyRead(t), context(for: f).isResourceLookup,
                   !argumentHasLiteral(t),
                   !(stringBound.contains(tok.text) && (token(t + 1)?.isPunct(",") == true || token(t + 1)?.isPunct(")") == true)) {
                    f.resourcePatterns.append(out.patterns.count)
                    addPattern(prefix: "", suffix: "", line: tok.line, context: context(for: f))
                }
            }
            if tok.kind == .string, !tok.interpolated {
                if f.label == "withExtension" || f.label == "ofType" || f.label == "extension" {
                    f.resourceExt = tok.text.hasPrefix(".") ? String(tok.text.dropFirst()) : tok.text
                }
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
        var ctx = frames.last.flatMap { $0.isBarrier ? nil : context(for: $0) }
        if let enumName = rawValueTokens[t] { ctx = CallContext(callee: "enum " + enumName, label: "rawValue") }
        if tok.interpolated {
            // `forResource: "\(name)"`: a keyless name whose extension the call supplies.
            if let ctx, ctx.isResourceLookup, tok.segments.allSatisfy(\.isEmpty), var f = frames.last, !f.isBarrier {
                f.resourcePatterns.append(out.patterns.count)
                frames[frames.count - 1] = f
            }
            var segments = tok.segments
            let lead = foldedPrefixes[t] ?? ""
            segments[0] = lead + segments[0]
            addPattern(prefix: lead + tok.text, suffix: tok.suffix, line: tok.line, context: ctx, segments: segments)
            return
        }
        addRef(.stringLiteral, tok.text, tok.line, ctx)
        // `"a" + "b"` (any chain of literals) is the constant `"ab"`: index it too, and use it as the literal part of
        // a surrounding `+ x` / `x +`.
        var chain = [tok.text], first = t
        while token(first - 1)?.isPunct("+") == true, let prev = token(first - 2), prev.kind == .string, !prev.interpolated {
            chain.insert(prev.text, at: 0)
            first -= 2
        }
        let folded = chain.joined()
        // A chain that goes on into an interpolated operand (`"a" + "b" + "\(k)"`) is not the constant either: its
        // folded text becomes the prefix of that interpolation's pattern. Only when the chain starts the expression:
        // after an operand (`theme + "_" + "\(size)"`) the chain is not the pattern's leading text.
        let startsExpression = token(first - 1)?.isPunct("+") != true
        let interpolatedNext = startsExpression && token(t + 1)?.isPunct("+") == true
            ? interpolatedOperand(at: t + 2, line: tok.line) : nil
        if let s = interpolatedNext { foldedPrefixes[s] = folded }
        let continues = interpolatedNext != nil
            || (token(t + 1)?.isPunct("+") == true && token(t + 2).map { $0.kind == .string && !$0.interpolated } == true)
        if chain.count > 1, !continues { addRef(.stringLiteral, folded, tok.line, ctx) }
        // `"lit" + x` -> prefix; `x + "lit"` -> suffix.
        if interpolatedNext == nil, token(t + 1)?.isPunct("+") == true, let next = token(t + 2), next.kind != .string,
           !next.isPunct("=") {
            addPattern(prefix: folded, suffix: "", line: tok.line, context: ctx)
        }
        if token(first - 1)?.isPunct("+") == true, let prev = token(first - 2), prev.kind != .string, !folded.isEmpty,
           !continues {
            addPattern(prefix: "", suffix: folded, line: tok.line, context: ctx)
        }
        // `String(format: "img%d", n)` / `stringWithFormat:@"img%d"` -> cut at the specifiers.
        if let ctx, ctx.label == "format" || ctx.label == "stringWithFormat" || ctx.callee == "localizedStringWithFormat",
           let (prefix, suffix) = Self.formatParts(tok.text) {
            addPattern(prefix: prefix, suffix: suffix, line: tok.line, context: ctx)
        }
    }

    /// Index of the interpolated string that is the `+` operand starting at `t` (`"a" + "\(k)"`; the tokenizer emits an
    /// interpolation's code tokens before its string). Only plain reads and calls count: `"\(k + 1)"` cannot be told
    /// from `k + "…\(1)"`, so an operator before the string, or a new line, means no match.
    private func interpolatedOperand(at t: Int, line: Int32) -> Int? {
        var k = t, depth = 0
        while let x = token(k), k < t + 24, x.line == line {
            if x.kind == .string {
                if depth == 0 { return x.interpolated ? k : nil }
            } else if x.isPunct("(") || x.isPunct("[") {
                depth += 1
            } else if x.isPunct(")") || x.isPunct("]") {
                depth -= 1
                if depth < 0 { return nil }
            } else if x.kind == .punct {
                let plain = x.isPunct(".") || x.isPunct("?") || x.isPunct("!") || (depth > 0 && (x.isPunct(",") || x.isPunct(":")))
                if !plain { return nil }
            }
            k += 1
        }
        return nil
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

    /// True when a string token with literal text appears in `tokens[range]` (`"x"`, `"icon_\(n)"`; not `"\(a)"`).
    private func hasLiteralText(_ range: Range<Int>) -> Bool {
        tokens[range].contains { $0.kind == .string && (!$0.interpolated || $0.segments.contains { !$0.isEmpty }) }
    }

    /// True when the call argument starting at `t` holds a string token of its own: an interpolation (the tokenizer
    /// emits `code` of `"flag_\(code)"` before the string itself) or literals (`flag ? "on" : "off"`). Strings nested
    /// in a call (`name.replacingOccurrences(of: " ", with: "-")`) are not the name's text. The argument ends at a `,`
    /// or, in Objective-C, at the next message label (`name ofType:@"mp4"`).
    private func argumentHasLiteral(_ t: Int) -> Bool {
        var k = t, depth = 0
        while let next = token(k), k < t + 64 {
            if next.isPunct("(") || next.isPunct("[") || next.isPunct("{") { depth += 1 }
            else if next.isPunct(")") || next.isPunct("]") || next.isPunct("}") { if depth == 0 { return false }; depth -= 1 }
            else if depth == 0, next.isPunct(",") { return false }
            else if depth == 0, dialect == .objc, k > t, next.isName, token(k + 1)?.isPunct(":") == true { return false }
            else if depth == 0, next.kind == .string { return true }
            k += 1
        }
        return false
    }

    /// True for a `self.property` read starting at `t`, the one use of a `self` argument that names a variable.
    private func isSelfPropertyRead(_ t: Int) -> Bool {
        token(t)?.text == "self" && token(t + 1)?.isPunct(".") == true && token(t + 2)?.isName == true
    }

    /// True when the tokens in `range` only read a value (`a`, `a.b?.c`): forwarding, not computing a name.
    private func isPlainChain(_ range: Range<Int>) -> Bool {
        !range.isEmpty && tokens[range].allSatisfy { $0.isName || $0.isPunct(".") || $0.isPunct("?") || $0.isPunct("!") }
    }

    /// True when the call argument starting at `t` is a member read of two or more names (`model.iconName`).
    private func isPropertyRead(_ t: Int) -> Bool {
        var k = t
        while let next = token(k), next.isName || next.isPunct(".") || next.isPunct("?") || next.isPunct("!") { k += 1 }
        guard let end = token(k), end.isPunct(",") || end.isPunct(")") || end.isPunct("]") else { return false }
        return k - t > 1
    }

    /// Records `let`/`var x = …` (also `if let`, `guard let`, `let x: T = …`) and `for x in …` bindings for keyless
    /// asset lookups: literal text on the initializer's line binds the name to literals for the whole file; otherwise a
    /// binding inside a declaration body is a computed local of that body, unless it only reads a value
    /// (`if let name = model.iconName`, `let name = other`).
    private mutating func trackLocalBinding(_ t: Int, _ tok: SwiftToken) {
        guard tok.kind == .identifier, let name = token(t + 1), name.kind == .identifier else { return }
        if tok.text == "for", token(t + 2)?.kind == .identifier, token(t + 2)?.text == "in" {
            localCallee[name.text] = nil  // a loop variable is not the earlier `let name = helper()`
            if bodyDecl != nil, token(t + 3)?.isPunct("[") != true { pendingLocals.append((name.text, t + 4)) }
            return
        }
        guard tok.text == "let" || tok.text == "var" else { return }
        var eq = t + 2
        if token(eq)?.isPunct(":") == true {
            while let next = token(eq), !next.isPunct("="), next.line == name.line, eq < t + 10 { eq += 1 }
        }
        guard let equals = token(eq), equals.isPunct("="), equals.line == name.line else { return }
        // The initializer: brackets are followed across lines (`let name: String = { switch … }()`); at depth 0 it
        // ends at a new line, a `,` (the next `if let` clause) or a `{` that is not the initializer itself (the body
        // of `if let x = y {`).
        var end = eq + 1, depth = 0
        while end < min(tokens.count, eq + 400) {
            let x = tokens[end]
            if depth == 0, x.line != equals.line || x.isPunct(",") || (x.isPunct("{") && end > eq + 1) { break }
            if x.isPunct("(") || x.isPunct("[") || x.isPunct("{") { depth += 1 }
            if x.isPunct(")") || x.isPunct("]") || x.isPunct("}") { depth -= 1 }
            end += 1
        }
        let value = (eq + 1)..<end
        localCallee[name.text] = nil
        if hasLiteralText(value) {
            stringBound.insert(name.text)
        } else if bodyDecl != nil, !isPlainChain(value) {
            pendingLocals.append((name.text, end))
            var c = eq + 1
            if token(c)?.text == "self", token(c + 1)?.isPunct(".") == true { c += 2 }
            if let callee = token(c), callee.isName, token(c + 1)?.isPunct("(") == true {
                localCallee[name.text] = callee.text
            }
        }
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
            rawEnums.append((name, nextFrameID + 1))  // the frame `visit` pushes next
            pendingRawEnum = nil
            return
        }
        guard let e = rawEnums.last, tok.kind == .identifier, tok.text == "case", frames.last?.id == e.frame else { return }
        var k = t + 1
        while let name = token(k), name.kind == .identifier {
            var next = k + 1
            if token(next)?.isPunct("=") == true {
                // Explicit raw value `case b = "bee"`: the literal is tagged as an enum raw value, not a lookup.
                if let value = token(next + 1), value.kind == .string, !value.interpolated { rawValueTokens[next + 1] = e.name }
                next += 2
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
        if bodyDecl?.frame == f.id {
            bodyDecl = nil
            computedLocals.removeAll()
            pendingLocals.removeAll()
            localCallee.removeAll()
        }
        if rawEnums.last?.frame == f.id { rawEnums.removeLast() }
        guard !f.isBarrier else { return }
        for p in f.resourcePatterns {
            if let ext = f.resourceExt, !ext.isEmpty {
                out.patterns[p].suffix = "." + ext
                out.patterns[p].segments = ["", "." + ext]
            } else {
                droppedPatterns.insert(p)
            }
        }
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
