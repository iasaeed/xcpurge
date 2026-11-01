/// String catalog key -> Xcode-generated `LocalizedStringResource` symbol name (STRING_CATALOG_GENERATE_SYMBOLS),
/// plus printf-style format specifier helpers. The symbol rules reproduce `xcrun xcstringstool generate-symbols`
/// (Xcode 26 and 27, checked key by key), which differ from the asset-symbol rules:
/// specifiers xcstringstool understands are dropped (`%#@files@` becomes `1$files`), and a key using one it has no
/// Swift type for (`%x`, `%s`, `%hd`) or skipping an argument number gets no symbol; apostrophes are deleted; words
/// split on characters a Swift identifier cannot hold (and `_`), and inside a word before a letter that follows a
/// non-letter or an uppercase letter that follows a lowercase one; the leading part of each word is lowercased
/// entirely when it starts with two capitals (`XMLHttpRequest` -> `xmlhttpRequest`), otherwise only its first
/// letter; later parts and words are capitalized; a key starting with `_` or a character that cannot start an
/// identifier (digit, `$`) gets an `_` prefix and a capitalized first word (`_private` -> `_Private`,
/// `2fa` -> `_2Fa`). Keywords are backticked; `self`, `Type` and `Protocol` are refused.
public enum StringSymbolMangler {
    /// Keys and symbols xcstringstool backticks. A key spelled exactly like one keeps that spelling (`Self`, `Any`).
    static let keywords: Set<String> = [
        "associatedtype", "borrowing", "class", "consuming", "deinit", "enum", "extension", "fileprivate", "func",
        "import", "init", "inout", "internal", "let", "nonisolated", "open", "operator", "private", "precedencegroup",
        "protocol", "public", "rethrows", "static", "struct", "subscript", "typealias", "var", "break", "case",
        "catch", "continue", "default", "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat",
        "return", "throw", "switch", "where", "while", "Any", "as", "await", "false", "is", "nil", "self", "Self",
        "super", "throws", "true", "try", "_", "Type", "Protocol",
    ]

    /// Symbols xcstringstool refuses ("too close to a reserved keyword").
    static let rejected: Set<String> = ["self", "Type", "Protocol"]

    /// Generated symbol for a key in its table (`` `default` ``, `helloWorld`, `items` for `%lld items`), or nil
    /// when xcstringstool would refuse the key.
    public static func symbol(forKey key: String) -> String? {
        guard let stripped = stripForSymbol(key) else { return nil }
        let text = stripped.filter { $0 != "'" && $0 != "\u{2019}" }
        guard let start = text.firstIndex(where: isIdentifierCharacter) else { return nil }
        let first = text[start]
        let prefixed = first == "_" || !isIdentifierHead(first)
        let chunks = text.split(whereSeparator: { $0 == "_" || !isIdentifierCharacter($0) }).map(String.init)
        var out = prefixed ? "_" : ""
        for (i, chunk) in chunks.enumerated() {
            let parts = segments(chunk)
            let word = normalize(parts[0]) + parts.dropFirst().map(capitalize).joined()
            out += i == 0 && !prefixed ? word : capitalize(word)
        }
        let symbol = keywords.contains(key) ? key : out
        if rejected.contains(symbol) { return nil }
        return keywords.contains(symbol) ? "`\(symbol)`" : symbol
    }

    /// Namespace enum Xcode generates for a non-default table (`Feature-Strings` -> `FeatureStrings`, `2fa` -> `_2Fa`).
    public static func tableNamespace(_ table: String) -> String {
        let out = table.split(whereSeparator: { $0 == "_" || !isIdentifierCharacter($0) })
            .map { segments(String($0)).map(capitalize).joined() }.joined()
        guard let first = out.first else { return out }
        return isIdentifierHead(first) ? out : "_" + out
    }

    /// The key with the specifiers xcstringstool understands blanked out and `%#@name@` / `%N$#@name@` replaced by
    /// `N$name` (N: the argument position; blanked too when another specifier gives argument N a type); nil when a
    /// specifier has no Swift type or argument numbers skip one.
    static func stripForSymbol(_ key: String) -> String? {
        let c = Array(key)
        var out = "", i = 0, sequence = 0
        var typed = Set<Int>()
        var substitutions: [(offset: Int, position: Int, name: String)] = []
        func digits(from j: Int) -> Int {
            var k = j
            while k < c.count, c[k].isASCII, c[k].isNumber { k += 1 }
            return k
        }
        while i < c.count {
            guard c[i] == "%" else { out.append(c[i]); i += 1; continue }
            if i + 1 < c.count, c[i + 1] == "%" { out += " "; i += 2; continue }
            var j = i + 1, position: Int?
            let end = digits(from: j)
            if end > j, end < c.count, c[end] == "$" { position = Int(String(c[j..<end])); j = end + 1 }
            if j + 1 < c.count, c[j] == "#", c[j + 1] == "@",
               let close = c[(j + 2)...].firstIndex(of: "@"), close > j + 2 {
                if position == nil { sequence += 1 }
                substitutions.append((out.count, position ?? sequence, String(c[(j + 2)..<close])))
                out += " "
                i = close + 1
                continue
            }
            if j < c.count, c[j] == "(", let close = c[j...].firstIndex(of: ")"), close > j + 1 { j = close + 1 }
            if j < c.count, c[j] == "-" || c[j] == "+" { j += 1 }
            if j < c.count, c[j] == "0" { j += 1 }
            j = digits(from: j)
            if j < c.count, c[j] == "." {
                let precision = digits(from: j + 1)
                j = precision > j + 1 ? precision : c.count
            }
            var length = ""
            for candidate in ["hh", "h", "ll", "l", "q", "L", "z", "t", "j"] where j + candidate.count <= c.count
                && String(c[j..<(j + candidate.count)]) == candidate {
                length = candidate
                break
            }
            j += length.count
            guard j < c.count, conversions[length]?.contains(c[j]) == true else {
                out += " "
                i += 1
                continue
            }
            guard supported.contains(length + String(c[j])) else { return nil }
            if position == nil { sequence += 1 }
            typed.insert(position ?? sequence)
            out += " "
            i = j + 1
        }
        if let highest = typed.max(), typed.count != highest { return nil }
        var text = Array(out)
        for s in substitutions.reversed() where !typed.contains(s.position) {
            text.replaceSubrange(s.offset...s.offset, with: Array("\(s.position)$" + s.name))
        }
        return String(text)
    }

    /// Conversions xcstringstool recognizes after each length modifier.
    private static let conversions: [String: Set<Character>] = [
        "": Set("@dDiuUxXoOfFeEgGcCsSaAp"), "l": Set("dDiuUxXoOfFeEgGaA"), "L": Set("fFeEgGaA"),
        "hh": Set("diuxXo"), "h": Set("diuxXo"), "ll": Set("diuxXo"), "q": Set("diuxXo"), "z": Set("diuxXo"),
        "t": Set("diuxXo"), "j": Set("diuxXo"),
    ]

    /// Specifiers xcstringstool maps to a Swift type (`String`, `Int32`, `Int`, `UInt32`, `UInt`, `Float`, `Double`).
    private static let supported: Set<String> = ["@", "d", "ld", "lld", "u", "lu", "llu", "f", "lf", "g"]

    /// Parts of a word: a new part starts at a letter after a non-letter and at an uppercase after a lowercase letter.
    private static func segments(_ word: String) -> [String] {
        var parts: [String] = [], current = ""
        var previous: Character?
        for ch in word {
            if let p = previous, !current.isEmpty,
               (isCased(ch) && !isCased(p)) || (p.isLowercase && ch.isUppercase) {
                parts.append(current)
                current = ""
            }
            current.append(ch)
            previous = ch
        }
        if !current.isEmpty { parts.append(current) }
        return parts
    }

    private static func isCased(_ c: Character) -> Bool { c.isUppercase || c.isLowercase }

    private static func normalize(_ word: String) -> String {
        guard let first = word.first, first.isUppercase else { return word }
        let rest = word.dropFirst()
        if let second = rest.first, second.isUppercase { return word.lowercased() }
        return first.lowercased() + rest
    }

    private static func capitalize(_ word: String) -> String {
        guard let first = word.first else { return word }
        return first.uppercased() + word.dropFirst()
    }

    // MARK: - Swift identifier characters (The Swift Programming Language, Lexical Structure)

    /// `$` counts too: xcstringstool keeps it (`$x` -> `_$X`).
    static func isIdentifierCharacter(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        if c == "$" || (0x30...0x39).contains(s) { return true }
        if [0x0300...0x036F, 0x1DC0...0x1DFF, 0x20D0...0x20FF, 0xFE20...0xFE2F].contains(where: { $0.contains(s) }) {
            return true
        }
        return isIdentifierHead(c)
    }

    static func isIdentifierHead(_ c: Character) -> Bool {
        guard let s = c.unicodeScalars.first?.value else { return false }
        if (0x41...0x5A).contains(s) || (0x61...0x7A).contains(s) || s == 0x5F { return true }
        return identifierHeadRanges.contains { $0.contains(s) }
    }

    private static let identifierHeadRanges: [ClosedRange<UInt32>] = [
        0xA8...0xA8, 0xAA...0xAA, 0xAD...0xAD, 0xAF...0xAF, 0xB2...0xB5, 0xB7...0xBA, 0xBC...0xBE, 0xC0...0xD6,
        0xD8...0xF6, 0xF8...0xFF, 0x100...0x2FF, 0x370...0x167F, 0x1681...0x180D, 0x180F...0x1DBF, 0x1E00...0x1FFF,
        0x200B...0x200D, 0x202A...0x202E, 0x203F...0x2040, 0x2054...0x2054, 0x2060...0x206F, 0x2070...0x20CF,
        0x2100...0x218F, 0x2460...0x24FF, 0x2776...0x2793, 0x2C00...0x2DFF, 0x2E80...0x2FFF, 0x3004...0x3007,
        0x3021...0x302F, 0x3031...0x303F, 0x3040...0xD7FF, 0xF900...0xFD3D, 0xFD40...0xFDCF, 0xFDF0...0xFE1F,
        0xFE30...0xFE44, 0xFE47...0xFFFD, 0x10000...0x1FFFD, 0x20000...0x2FFFD, 0x30000...0x3FFFD, 0x40000...0x4FFFD,
        0x50000...0x5FFFD, 0x60000...0x6FFFD, 0x70000...0x7FFFD, 0x80000...0x8FFFD, 0x90000...0x9FFFD,
        0xA0000...0xAFFFD, 0xB0000...0xBFFFD, 0xC0000...0xCFFFD, 0xD0000...0xDFFFD, 0xE0000...0xEFFFD,
    ]

    // MARK: - Format specifiers

    /// Ranges (in `Character` offsets) of printf-style specifiers (`%@`, `%lld`, `%1$@`, `%.2f`, `%#@var@`).
    public static func formatSpecifierRanges(_ s: String) -> [Range<Int>] {
        let c = Array(s)
        var ranges: [Range<Int>] = []
        var i = 0
        while i < c.count {
            guard c[i] == "%" else { i += 1; continue }
            if i + 1 < c.count, c[i + 1] == "%" { i += 2; continue }
            var j = i + 1
            if j + 1 < c.count, c[j] == "#", c[j + 1] == "@" {  // %#@variable@
                var k = j + 2
                while k < c.count, c[k] != "@" { k += 1 }
                if k < c.count { ranges.append(i..<(k + 1)); i = k + 1; continue }
            }
            var digits = j
            while digits < c.count, c[digits].isASCII, c[digits].isNumber { digits += 1 }
            if digits < c.count, c[digits] == "$", digits > j { j = digits + 1 }
            while j < c.count, "-+ #0'".contains(c[j]) { j += 1 }
            while j < c.count, (c[j].isASCII && c[j].isNumber) || c[j] == "*" { j += 1 }
            if j < c.count, c[j] == "." {
                j += 1
                while j < c.count, (c[j].isASCII && c[j].isNumber) || c[j] == "*" { j += 1 }
            }
            for length in ["hh", "ll", "h", "l", "q", "L", "z", "j", "t"] {
                let chars = Array(length)
                if j + chars.count <= c.count, Array(c[j..<(j + chars.count)]) == chars { j += chars.count; break }
            }
            if j < c.count, "@dDiuUxXoOfFeEgGcCsSaAp".contains(c[j]) {
                ranges.append(i..<(j + 1))
                i = j + 1
            } else {
                i += 1
            }
        }
        return ranges
    }

    public static func hasFormatSpecifiers(_ s: String) -> Bool { !formatSpecifierRanges(s).isEmpty }

    /// The string with every specifier replaced by `replacement`.
    public static func stripFormatSpecifiers(_ s: String, replacement: String = "") -> String {
        let ranges = formatSpecifierRanges(s)
        guard !ranges.isEmpty else { return s }
        let c = Array(s)
        var out = "", last = 0
        for r in ranges {
            out += String(c[last..<r.lowerBound]) + replacement
            last = r.upperBound
        }
        return out + String(c[last...])
    }

    /// True for keys that are nothing but specifiers and punctuation (`%@`, `%lld %@`): Xcode's keys for
    /// interpolation-only literals such as `Text("\(name)")`.
    public static func isFormatOnly(_ key: String) -> Bool {
        hasFormatSpecifiers(key) && !stripFormatSpecifiers(key).contains { $0.isLetter || $0.isNumber }
    }

    /// Literal text before the first and after the last specifier, nil without specifiers.
    public static func formatAffixes(_ s: String) -> (prefix: String, suffix: String)? {
        let ranges = formatSpecifierRanges(s)
        guard let first = ranges.first, let last = ranges.last else { return nil }
        let c = Array(s)
        return (String(c[..<first.lowerBound]), String(c[last.upperBound...]))
    }

    /// Literal text between specifiers, in order, with `%%` unescaped (`"%lld of %lld"` -> `["", " of ", ""]`):
    /// the segments a Swift interpolation (`"\(a) of \(b)"`) of the same key has. Nil without specifiers.
    public static func formatSegments(_ s: String) -> [String]? {
        let ranges = formatSpecifierRanges(s)
        guard !ranges.isEmpty else { return nil }
        let c = Array(s)
        var segments: [String] = [], last = 0
        for r in ranges + [c.count..<c.count] {
            segments.append(String(c[last..<r.lowerBound]).replacingOccurrences(of: "%%", with: "%"))
            last = r.upperBound
        }
        return segments
    }
}
