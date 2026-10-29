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
        return x.out
    }

    private mutating func run() {
        for t in tokens.indices { visit(t) }
        while !frames.isEmpty { popFrame() }
    }

    private func token(_ t: Int) -> SwiftToken? { tokens.indices.contains(t) ? tokens[t] : nil }

    private mutating func visit(_ t: Int) {
        let tok = tokens[t]
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
            if f.label == "bundle" { f.bundleTokens.append(tok.text) }
            if f.awaitingArg {
                f.awaitingArg = false
                // A localization call whose key is a variable: keyless lookup. An argument starting with a type
                // name (`Text(Date(), …)`, `Text(String(localized: …))`, `Text(L10n.x)`) is not a variable key.
                if tok.kind == .identifier, let first = tok.text.first, first.isLowercase || first == "_",
                   context(for: f).isLocalization(extraMacros: localizationMacros) {
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
        guard let f = frames.popLast(), !f.isBarrier else { return }
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
