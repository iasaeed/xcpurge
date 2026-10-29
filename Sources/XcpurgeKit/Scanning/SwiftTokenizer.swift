import Foundation

/// Hand-written lexer for Swift (and, in `.objc` mode, Objective-C/C): comments (nested in Swift), strings
/// (multiline, raw `#"…"#`, interpolation with nested strings), regex literals, backticks, member vs identifier,
/// `xcpurge:ignore` markers and line numbers. Never fails; malformed input just ends the token stream.
public struct SwiftTokenizer {
    public enum Dialect: Sendable {
        case swift, objc
    }

    public struct Output: Sendable {
        public var tokens: [SwiftToken]
        /// Lines marked with `xcpurge:ignore` (the comment's line, plus the next code line for a standalone comment).
        public var ignoredLines: [Int32]
    }

    public static let ignoreMarker = "xcpurge:ignore"

    public static func tokenize(_ text: String, dialect: Dialect = .swift) -> Output {
        var copy = text
        return copy.withUTF8 { tokenize($0, dialect: dialect) }
    }

    public static func tokenize(_ data: Data, dialect: Dialect = .swift) -> Output {
        data.withUnsafeBytes { raw in tokenize(raw.bindMemory(to: UInt8.self), dialect: dialect) }
    }

    public static func tokenize(_ bytes: UnsafeBufferPointer<UInt8>, dialect: Dialect = .swift) -> Output {
        var lexer = SwiftTokenizer(bytes: bytes, dialect: dialect)
        lexer.scanCode(inInterpolation: false)
        return Output(tokens: lexer.tokens, ignoredLines: lexer.ignored)
    }

    private let b: UnsafeBufferPointer<UInt8>
    private let n: Int
    private let dialect: Dialect
    private var i = 0
    private var line: Int32 = 1
    private var tokens: [SwiftToken] = []
    private var ignored: [Int32] = []
    private var lineHasToken = false
    private var pendingIgnore = false

    private init(bytes: UnsafeBufferPointer<UInt8>, dialect: Dialect) {
        self.b = bytes
        self.n = bytes.count
        self.dialect = dialect
    }

    // MARK: - Helpers

    private func peek(_ offset: Int = 0) -> UInt8 { i + offset < n ? b[i + offset] : 0 }

    private static func isIdentStart(_ c: UInt8) -> Bool {
        (c >= 0x61 && c <= 0x7A) || (c >= 0x41 && c <= 0x5A) || c == 0x5F || c == 0x24 || c >= 0x80
    }

    private static func isIdentChar(_ c: UInt8) -> Bool { isIdentStart(c) || (c >= 0x30 && c <= 0x39) }
    private static func isDigit(_ c: UInt8) -> Bool { c >= 0x30 && c <= 0x39 }

    private func text(_ start: Int, _ end: Int) -> String {
        String(decoding: UnsafeBufferPointer(rebasing: b[start..<end]), as: UTF8.self)
    }

    private mutating func emit(_ kind: SwiftToken.Kind, _ text: String, line tokenLine: Int32? = nil,
                               interpolated: Bool = false, suffix: String = "") {
        let l = tokenLine ?? line
        if pendingIgnore { ignored.append(l); pendingIgnore = false }
        tokens.append(SwiftToken(kind: kind, text: text, line: l, interpolated: interpolated, suffix: suffix))
        lineHasToken = true
    }

    private var previousIsDot: Bool {
        guard let last = tokens.last, last.isPunct(".") else { return false }
        if tokens.count >= 2, tokens[tokens.count - 2].isPunct(".") { return false }  // `..<`, `...`
        return true
    }

    // MARK: - Code

    private mutating func scanCode(inInterpolation: Bool) {
        var parenDepth = 0
        while i < n {
            let c = b[i]
            switch c {
            case 0x0A:
                line += 1; i += 1; lineHasToken = false
            case 0x20, 0x09, 0x0D, 0x0C:
                i += 1
            case 0x2F where peek(1) == 0x2F:  // //
                scanLineComment()
            case 0x2F where peek(1) == 0x2A:  // /*
                scanBlockComment()
            case 0x2F where dialect == .swift && regexAllowed():
                if !scanBareRegex() { emit(.punct, "/"); i += 1 }
            case 0x22:  // "
                scanString(hashes: 0)
            case 0x23:  // #
                scanHash()
            case 0x40:  // @
                if dialect == .objc, peek(1) == 0x22 { i += 1; scanString(hashes: 0) }
                else if Self.isIdentStart(peek(1)) {
                    let start = i; i += 1
                    while i < n, Self.isIdentChar(b[i]) { i += 1 }
                    emit(.attribute, text(start, i))
                } else { emit(.punct, "@"); i += 1 }
            case 0x60:  // `
                scanBacktick()
            case 0x27 where dialect == .objc:  // 'c'
                scanCharLiteral()
            case _ where Self.isDigit(c):
                scanNumber()
            case _ where Self.isIdentStart(c):
                let start = i
                while i < n, Self.isIdentChar(b[i]) { i += 1 }
                emit(previousIsDot ? .member : .identifier, text(start, i))
            case 0x28:  // (
                if inInterpolation { parenDepth += 1 }
                emit(.punct, "("); i += 1
            case 0x29:  // )
                if inInterpolation {
                    if parenDepth == 0 { i += 1; return }
                    parenDepth -= 1
                }
                emit(.punct, ")"); i += 1
            default:
                emit(.punct, String(UnicodeScalar(c))); i += 1
            }
        }
    }

    private mutating func scanNumber() {
        let start = i
        while i < n {
            let c = b[i]
            if Self.isIdentChar(c) { i += 1; continue }
            if c == 0x2E, Self.isDigit(peek(1)) { i += 1; continue }
            break
        }
        emit(.number, text(start, i))
    }

    private mutating func scanBacktick() {
        let start = i + 1
        var j = start
        while j < n, b[j] != 0x60, b[j] != 0x0A { j += 1 }
        guard j < n, b[j] == 0x60 else { emit(.punct, "`"); i += 1; return }
        i = j + 1
        emit(previousIsDot ? .member : .identifier, text(start, j))
    }

    private mutating func scanCharLiteral() {
        i += 1
        while i < n, b[i] != 0x27, b[i] != 0x0A {
            if b[i] == 0x5C { i += 1 }
            i += 1
        }
        if i < n, b[i] == 0x27 { i += 1 }
    }

    // MARK: - Comments

    private mutating func noteComment(_ body: String, startLine: Int32, standalone: Bool) {
        guard body.contains(Self.ignoreMarker) else { return }
        ignored.append(startLine)
        if standalone { pendingIgnore = true }
    }

    private mutating func scanLineComment() {
        let start = i, startLine = line, standalone = !lineHasToken
        while i < n, b[i] != 0x0A { i += 1 }
        noteComment(text(start, i), startLine: startLine, standalone: standalone)
    }

    private mutating func scanBlockComment() {
        let start = i, startLine = line, standalone = !lineHasToken
        var depth = 0
        while i < n {
            if b[i] == 0x2F, peek(1) == 0x2A, dialect == .swift || depth == 0 { depth += 1; i += 2; continue }
            if b[i] == 0x2A, peek(1) == 0x2F { depth -= 1; i += 2; if depth == 0 { break }; continue }
            if b[i] == 0x0A { line += 1 }
            i += 1
        }
        noteComment(text(start, min(i, n)), startLine: startLine, standalone: standalone)
    }

    // MARK: - Hash: raw strings, extended regex, macros, ObjC preprocessor

    private mutating func scanHash() {
        var hashes = 0
        while peek(hashes) == 0x23 { hashes += 1 }
        let after = peek(hashes)
        if after == 0x22 && dialect == .swift { i += hashes; scanString(hashes: hashes); return }
        if after == 0x2F && dialect == .swift { scanExtendedRegex(hashes: hashes); return }
        if hashes == 1, Self.isIdentStart(after) {
            let start = i; i += 1
            while i < n, Self.isIdentChar(b[i]) { i += 1 }
            let name = text(start, i)
            emit(.macro, name)
            if dialect == .objc, name == "#import" || name == "#include" { scanObjCInclude() }
            return
        }
        for _ in 0..<hashes { emit(.punct, "#") }
        i += hashes
    }

    /// `#import "X.h"` emits identifier `X.h`; `#import <…>` lines are skipped.
    private mutating func scanObjCInclude() {
        while i < n, b[i] == 0x20 || b[i] == 0x09 { i += 1 }
        guard i < n else { return }
        if b[i] == 0x22 {
            let start = i + 1
            var j = start
            while j < n, b[j] != 0x22, b[j] != 0x0A { j += 1 }
            emit(.identifier, text(start, j))
            i = min(j + 1, n)
        } else if b[i] == 0x3C {
            while i < n, b[i] != 0x0A { i += 1 }
        }
    }

    // MARK: - Regex

    private func regexAllowed() -> Bool {
        let next = peek(1)
        if next == 0x20 || next == 0x09 || next == 0x0A || next == 0x3D { return false }  // `/ `, `/=`
        guard let last = tokens.last else { return true }
        switch last.kind {
        case .punct: return "(,=:[{;!&|?^~+-*<>".contains(last.text) && last.text != ")"
        case .identifier: return ["return", "case", "in", "where", "try", "await", "if", "guard", "while"].contains(last.text)
        default: return false
        }
    }

    private mutating func scanBareRegex() -> Bool {
        var j = i + 1, inClass = false
        while j < n, b[j] != 0x0A {
            let c = b[j]
            if c == 0x5C { j += 2; continue }
            if c == 0x5B { inClass = true } else if c == 0x5D { inClass = false }
            else if c == 0x2F, !inClass {
                i = j + 1
                emit(.regex, "")
                return true
            }
            j += 1
        }
        return false
    }

    private mutating func scanExtendedRegex(hashes: Int) {
        let startLine = line
        i += hashes + 1
        while i < n {
            if b[i] == 0x0A { line += 1 }
            if b[i] == 0x5C { i += 2; continue }
            if b[i] == 0x2F {
                var k = 0
                while k < hashes, peek(1 + k) == 0x23 { k += 1 }
                if k == hashes { i += 1 + hashes; break }
            }
            i += 1
        }
        emit(.regex, "", line: startLine)
    }

    // MARK: - Strings

    private func closes(at j: Int, multiline: Bool, hashes: Int) -> Int? {
        let quotes = multiline ? 3 : 1
        for q in 0..<quotes where j + q >= n || b[j + q] != 0x22 { return nil }
        for h in 0..<hashes where j + quotes + h >= n || b[j + quotes + h] != 0x23 { return nil }
        return quotes + hashes
    }

    private mutating func scanString(hashes: Int) {
        let startLine = line
        let multiline = dialect == .swift && peek(1) == 0x22 && peek(2) == 0x22
        i += multiline ? 3 : 1
        var buf: [UInt8] = []
        var prefix: String?
        while i < n {
            let c = b[i]
            if c == 0x0A {
                line += 1
                if !multiline { break }
                buf.append(c); i += 1; continue
            }
            if c == 0x22, let len = closes(at: i, multiline: multiline, hashes: hashes) {
                i += len
                break
            }
            if c == 0x5C {
                var k = 0
                while k < hashes, peek(1 + k) == 0x23 { k += 1 }
                if k == hashes {
                    let e = peek(1 + hashes)
                    if e == 0x28 && dialect == .swift {
                        if prefix == nil { prefix = decode(buf, multiline: multiline, trailing: false) }
                        buf.removeAll()
                        i += 2 + hashes
                        scanCode(inInterpolation: true)
                        continue
                    }
                    i += 1 + hashes
                    appendEscape(&buf, multiline: multiline)
                    continue
                }
            }
            buf.append(c); i += 1
        }
        if let prefix {
            emit(.string, prefix, line: startLine, interpolated: true, suffix: decode(buf, multiline: multiline, trailing: true))
        } else {
            emit(.string, decode(buf, multiline: multiline, trailing: true), line: startLine)
        }
    }

    private mutating func appendEscape(_ buf: inout [UInt8], multiline: Bool) {
        guard i < n else { return }
        let e = b[i]
        i += 1
        switch e {
        case 0x6E: buf.append(0x0A)          // n
        case 0x74: buf.append(0x09)          // t
        case 0x72: buf.append(0x0D)          // r
        case 0x30: buf.append(0)             // 0
        case 0x0A: line += 1                 // line continuation
        case 0x75 where peek() == 0x7B:      // u{…}
            var j = i + 1
            while j < n, b[j] != 0x7D, j - i < 10 { j += 1 }
            if let v = UInt32(text(i + 1, j), radix: 16), let scalar = UnicodeScalar(v) {
                buf.append(contentsOf: Array(String(Character(scalar)).utf8))
            }
            i = min(j + 1, n)
        default: buf.append(e)
        }
    }

    /// Decodes buffered bytes; for multiline strings drops the opening newline and the closing indent line.
    private func decode(_ buf: [UInt8], multiline: Bool, trailing: Bool) -> String {
        var s = String(decoding: buf, as: UTF8.self)
        guard multiline else { return s }
        // ponytail: indentation is not stripped from inner lines; keys are single-line in practice.
        if s.hasPrefix("\n") { s.removeFirst() }
        if trailing, let lastNewline = s.lastIndex(of: "\n"),
           s[s.index(after: lastNewline)...].allSatisfy({ $0 == " " || $0 == "\t" }) {
            s = String(s[..<lastNewline])
        }
        return s.trimmingCharacters(in: .whitespaces)
    }
}
