// LANE: B
import Foundation

/// Reads `.strings` tables: `PropertyListSerialization` is the source of truth for keys; a light tokenizer
/// (`/* */` and `//` comments, escaped quotes, `"k" = "v";`, bare `"k";`, unquoted words) supplies line numbers
/// and statement ranges so pruning can delete a statement plus its directly preceding comment and leave the
/// rest of the file byte-identical. UTF-8 and UTF-16 (with BOM) files round-trip in their own encoding.
public enum StringsFileReader {
    public struct Statement: Sendable, Hashable {
        public var key: String
        /// 1-based line of the key token.
        public var line: Int
        /// Unicode-scalar offsets of the statement (key through `;`, plus a same-line trailing comment).
        public var range: Range<Int>
        /// The comment directly above the statement (at most one line break between), if any.
        public var comment: Range<Int>?
    }

    /// Key -> 1-based line (nil when the tokenizer could not place it, e.g. XML-format `.strings`).
    public static func keys(_ data: Data) -> [String: Int?]? {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        var lines: [String: Int] = [:]
        if let (text, _) = decode(data) {
            for s in statements(in: text) where lines[s.key] == nil { lines[s.key] = s.line }
        }
        var out: [String: Int?] = [:]
        for key in dict.keys { out[key] = lines[key] }
        return out
    }

    /// `data` without the statements (and their preceding comments) for `keys`; nil when nothing changes.
    public static func removing(_ keys: Set<String>, from data: Data) -> Data? {
        guard let (text, encoding) = decode(data) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("<?xml") || trimmed.hasPrefix("<plist") || data.starts(with: Data("bplist".utf8)) {
            return rewritePlist(data, removing: keys)
        }
        let hits = statements(in: text).filter { keys.contains($0.key) }
        guard !hits.isEmpty else { return nil }
        var scalars = Array(text.unicodeScalars)
        for s in hits.reversed() {
            var start = s.comment?.lowerBound ?? s.range.lowerBound
            var end = s.range.upperBound
            // Swallow the rest of the line and leading indentation.
            while end < scalars.count, scalars[end] == " " || scalars[end] == "\t" { end += 1 }
            if end < scalars.count, scalars[end] == "\r" { end += 1 }
            if end < scalars.count, scalars[end] == "\n" { end += 1 }
            while start > 0, scalars[start - 1] == " " || scalars[start - 1] == "\t" { start -= 1 }
            // Collapse the blank line the removal would leave behind.
            let followedByBlank = end >= scalars.count || scalars[end] == "\n" || scalars[end] == "\r"
            if followedByBlank, start >= 2, scalars[start - 1] == "\n", scalars[start - 2] == "\n" {
                start -= 1
            } else if start == 0, end < scalars.count, scalars[end] == "\n" {
                end += 1
            }
            scalars.removeSubrange(start..<end)
        }
        var out = String(String.UnicodeScalarView(scalars))
        if data.starts(with: [0xEF, 0xBB, 0xBF]), !out.hasPrefix("\u{FEFF}") { out = "\u{FEFF}" + out }
        return encode(out, like: data, encoding: encoding)
    }

    // MARK: - Encoding

    /// Decoded text (BOM stripped for UTF-16) and the encoding it came in.
    static func decode(_ data: Data) -> (String, String.Encoding)? {
        if data.starts(with: [0xFF, 0xFE]) {
            return String(data: data.dropFirst(2), encoding: .utf16LittleEndian).map { ($0, .utf16LittleEndian) }
        }
        if data.starts(with: [0xFE, 0xFF]) {
            return String(data: data.dropFirst(2), encoding: .utf16BigEndian).map { ($0, .utf16BigEndian) }
        }
        if let s = String(data: data, encoding: .utf8) { return (s, .utf8) }
        return String(data: data, encoding: .utf16).map { ($0, .utf16) }
    }

    private static func encode(_ text: String, like original: Data, encoding: String.Encoding) -> Data? {
        switch encoding {
        case .utf16LittleEndian: return text.data(using: .utf16LittleEndian).map { Data([0xFF, 0xFE]) + $0 }
        case .utf16BigEndian: return text.data(using: .utf16BigEndian).map { Data([0xFE, 0xFF]) + $0 }
        default: return text.data(using: encoding)
        }
    }

    private static func rewritePlist(_ data: Data, removing keys: Set<String>) -> Data? {
        var format = PropertyListSerialization.PropertyListFormat.xml
        guard var dict = (try? PropertyListSerialization.propertyList(from: data, format: &format)) as? [String: Any],
              !keys.isDisjoint(with: dict.keys) else { return nil }
        for key in keys { dict.removeValue(forKey: key) }
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: format == .binary ? .binary : .xml, options: 0)
    }

    // MARK: - Tokenizer

    /// Statements in source order.
    public static func statements(in text: String) -> [Statement] {
        let s = Array(text.unicodeScalars)
        var out: [Statement] = []
        var i = 0, line = 1
        var lastComment: (range: Range<Int>, endLine: Int)?
        var key: (value: String, start: Int, line: Int)?
        var previousEnd: (offset: Int, line: Int)?

        func isWordChar(_ c: Unicode.Scalar) -> Bool {
            CharacterSet.alphanumerics.contains(c) || "_.-$/:".unicodeScalars.contains(c)
        }

        while i < s.count {
            let c = s[i]
            if c == "\n" { line += 1; i += 1; continue }
            if c == " " || c == "\t" || c == "\r" || c == "\u{FEFF}" { i += 1; continue }
            if c == "/", i + 1 < s.count, s[i + 1] == "*" || s[i + 1] == "/" {
                let start = i, startLine = line
                if s[i + 1] == "*" {
                    i += 2
                    while i < s.count, !(s[i] == "*" && i + 1 < s.count && s[i + 1] == "/") {
                        if s[i] == "\n" { line += 1 }
                        i += 1
                    }
                    i = min(i + 2, s.count)
                } else {
                    while i < s.count, s[i] != "\n" { i += 1 }
                }
                if key == nil, let prev = previousEnd, prev.line == startLine, let last = out.indices.last {
                    out[last].range = out[last].range.lowerBound..<i  // trailing comment of the previous statement
                } else if key == nil {
                    lastComment = (start..<i, line)
                }
                continue
            }
            if c == "\"" || isWordChar(c) {
                let start = i, startLine = line
                var value = ""
                if c == "\"" {
                    i += 1
                    while i < s.count, s[i] != "\"" {
                        if s[i] == "\\", i + 1 < s.count {
                            i += 1
                            switch s[i] {
                            case "n": value += "\n"
                            case "t": value += "\t"
                            case "r": value += "\r"
                            case "U", "u":
                                let hex = String(String.UnicodeScalarView(s[(i + 1)..<min(i + 5, s.count)]))
                                if let v = UInt32(hex, radix: 16), let scalar = Unicode.Scalar(v) {
                                    value.unicodeScalars.append(scalar)
                                    i += 4
                                } else {
                                    value.unicodeScalars.append(s[i])
                                }
                            default: value.unicodeScalars.append(s[i])
                            }
                        } else {
                            if s[i] == "\n" { line += 1 }
                            value.unicodeScalars.append(s[i])
                        }
                        i += 1
                    }
                    i = min(i + 1, s.count)
                } else {
                    while i < s.count, isWordChar(s[i]) { value.unicodeScalars.append(s[i]); i += 1 }
                }
                if key == nil { key = (value, start, startLine) }
                continue
            }
            if c == ";", let k = key {
                var comment: Range<Int>?
                if let lc = lastComment, k.line - lc.endLine <= 1, lc.range.lowerBound >= (previousEnd?.offset ?? 0) {
                    comment = lc.range
                }
                out.append(Statement(key: k.value, line: k.line, range: k.start..<(i + 1), comment: comment))
                previousEnd = (i + 1, line)
                key = nil
                lastComment = nil
            }
            i += 1
        }
        return out
    }
}
