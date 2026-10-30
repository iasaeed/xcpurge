/// String catalog key -> Xcode-generated `LocalizedStringResource` symbol name (STRING_CATALOG_GENERATE_SYMBOLS),
/// plus printf-style format specifier helpers. Rules were derived from `xcrun xcstringstool generate-symbols`
/// output (Xcode 26), which differ from the asset-symbol rules in a few places:
/// format specifiers are dropped; words split on non-alphanumerics and at digit -> letter boundaries;
/// the first word is lowercased entirely when it starts with two capitals (`ABCLogo` -> `abclogo`), otherwise only
/// its first letter (`HelloWorld` -> `helloWorld`); later words get the same treatment and are then capitalized
/// (`My_URL_Key` -> `myUrlKey`); a leading `_` or digit yields an `_` prefix and a capitalized first word
/// (`_private` -> `_Private`, `2fa` -> `_2Fa`).
public enum StringSymbolMangler {
    /// Keys Xcode refuses to generate a symbol for ("too close to a reserved keyword").
    static let rejected: Set<String> = ["self", "type", "protocol"]

    /// Generated symbol for a key in its table, or nil when Xcode would not generate one.
    public static func symbol(forKey key: String) -> String? {
        var text = String(stripFormatSpecifiers(key, replacement: " "))
        text = String(text.drop { !($0.isLetter || $0.isNumber || $0 == "_") })
        guard let first = text.first else { return nil }
        let prefixed = first == "_" || first.isNumber
        let words = splitWords(text)
        if words.isEmpty { return prefixed ? "_" : nil }
        var out = prefixed ? "_" : ""
        for (i, word) in words.enumerated() {
            let normalized = normalize(word)
            out += (i == 0 && !prefixed) ? normalized : capitalize(normalized)
        }
        return rejected.contains(out.lowercased()) ? nil : out
    }

    /// Namespace enum Xcode generates for a non-default table (`Feature-Strings` -> `FeatureStrings`).
    public static func tableNamespace(_ table: String) -> String {
        table.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map { capitalize(String($0)) }.joined()
    }

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

    // MARK: - Words

    private static func splitWords(_ s: String) -> [String] {
        var words: [String] = [], current = ""
        var previous: Character?
        for ch in s {
            if !(ch.isLetter || ch.isNumber) {
                if !current.isEmpty { words.append(current); current = "" }
                previous = nil
                continue
            }
            if let p = previous, p.isNumber, ch.isLetter, !current.isEmpty { words.append(current); current = "" }
            current.append(ch)
            previous = ch
        }
        if !current.isEmpty { words.append(current) }
        return words
    }

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
}
