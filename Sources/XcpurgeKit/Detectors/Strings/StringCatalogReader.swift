// LANE: B
import Foundation

/// Tolerant reader and format-preserving writer for `.xcstrings` (plan §4.6 steps 1-2 and 6).
/// Parsing uses `JSONSerialization`; unknown fields are ignored. Writing reproduces Xcode's own output
/// byte for byte (verified against `xcstringstool sync`): 2-space indent, `"key" : value`, keys sorted by
/// Unicode scalar order (Xcode is case-sensitive: `B` < `_` < `a` < `Ü`), unescaped slashes, empty objects
/// as `{\n\n<indent>}`, no trailing newline. `JSONSerialization.sortedKeys` sorts case-insensitively, so a
/// small custom writer is used instead.
public enum StringCatalogReader {
    public struct Entry: Sendable, Hashable {
        public var key: String
        /// `extracted_with_value`, `manual`, `migrated`, `stale`, or nil (= extracted by the compiler).
        public var extractionState: String?
        public var shouldTranslate: Bool
        /// Key or source-language values contain printf-style specifiers (generated symbol is a function).
        public var hasFormatSpecifiers: Bool
        /// Plural / device / width variations or substitutions are present.
        public var hasVariations: Bool
        public var comment: String?
        /// 1-based line of `"key" : {` in Xcode-formatted files, nil when not found.
        public var line: Int?
    }

    public struct Catalog: Sendable {
        public var sourceLanguage: String?
        public var version: String?
        /// Sorted the way Xcode writes them.
        public var entries: [Entry]
    }

    public enum ReadError: Error, CustomStringConvertible {
        case notJSON
        case missingStrings

        public var description: String {
            switch self {
            case .notJSON: "not a JSON object"
            case .missingStrings: "no \"strings\" object"
            }
        }
    }

    public static func read(_ data: Data) throws -> Catalog {
        let root = try object(from: data)
        guard let strings = root["strings"] as? [String: Any] else { throw ReadError.missingStrings }
        let source = root["sourceLanguage"] as? String
        let lines = keyLines(data)
        let entries = sortedKeys(strings).map { key -> Entry in
            let body = strings[key] as? [String: Any] ?? [:]
            let localizations = body["localizations"] as? [String: Any] ?? [:]
            let sourceLoc = source.flatMap { localizations[$0] }
            var values: [String] = []
            collectValues(sourceLoc as Any, into: &values)
            return Entry(key: key, extractionState: body["extractionState"] as? String,
                         shouldTranslate: (body["shouldTranslate"] as? Bool) ?? true,
                         hasFormatSpecifiers: StringSymbolMangler.hasFormatSpecifiers(key)
                             || values.contains(where: StringSymbolMangler.hasFormatSpecifiers),
                         hasVariations: localizations.values.contains { containsVariations($0) },
                         comment: body["comment"] as? String, line: lines[key])
        }
        return Catalog(sourceLanguage: source, version: root["version"] as? String, entries: entries)
    }

    /// The catalog with `keys` removed from `strings`, re-serialized in Xcode's format.
    /// A trailing newline in the input is kept.
    /// ponytail: hand-formatted input comes out in Xcode's format (as Xcode itself would rewrite it); no textual fallback.
    public static func removing(_ keys: Set<String>, from data: Data) throws -> Data {
        var root = try object(from: data)
        guard var strings = root["strings"] as? [String: Any] else { throw ReadError.missingStrings }
        for key in keys { strings.removeValue(forKey: key) }
        root["strings"] = strings
        var out = serialize(root)
        if data.last == UInt8(ascii: "\n") { out.append(UInt8(ascii: "\n")) }
        return out
    }

    /// Xcode-style JSON for a `JSONSerialization` object tree.
    public static func serialize(_ value: Any) -> Data {
        var out = ""
        write(value, indent: 0, into: &out)
        return Data(out.utf8)
    }

    // MARK: - Parsing helpers

    private static func object(from data: Data) throws -> [String: Any] {
        guard let root = try? JSONSerialization.jsonObject(with: data, options: [.json5Allowed]) as? [String: Any] else {
            throw ReadError.notJSON
        }
        return root
    }

    private static func collectValues(_ node: Any, into values: inout [String]) {
        if let dict = node as? [String: Any] {
            for (k, v) in dict {
                if k == "value", let s = v as? String { values.append(s) } else { collectValues(v, into: &values) }
            }
        } else if let array = node as? [Any] {
            for v in array { collectValues(v, into: &values) }
        }
    }

    private static func containsVariations(_ node: Any) -> Bool {
        guard let dict = node as? [String: Any] else { return false }
        return dict["variations"] != nil || dict["substitutions"] != nil
    }

    /// Line of each `    "key" : {` (4-space indent = direct child of the top-level `strings` object).
    static func keyLines(_ data: Data) -> [String: Int] {
        var lines: [String: Int] = [:]
        var number = 0
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            guard raw.hasPrefix("    \""), !raw.hasPrefix("     "), let end = closingQuote(raw, from: 4) else { continue }
            let token = raw[raw.index(raw.startIndex, offsetBy: 4)...end]
            guard let key = try? JSONSerialization.jsonObject(with: Data(token.utf8), options: .fragmentsAllowed) as? String
            else { continue }
            if lines[key] == nil { lines[key] = number }
        }
        return lines
    }

    private static func closingQuote(_ line: Substring, from offset: Int) -> Substring.Index? {
        var i = line.index(line.startIndex, offsetBy: offset + 1)
        var escaped = false
        while i < line.endIndex {
            let c = line[i]
            if escaped { escaped = false } else if c == "\\" { escaped = true } else if c == "\"" { return i }
            i = line.index(after: i)
        }
        return nil
    }

    // MARK: - Writer

    static func sortedKeys(_ dict: [String: Any]) -> [String] {
        dict.keys.sorted { $0.unicodeScalars.lexicographicallyPrecedes($1.unicodeScalars) }
    }

    private static func write(_ value: Any, indent: Int, into out: inout String) {
        let pad = String(repeating: " ", count: indent)
        let inner = String(repeating: " ", count: indent + 2)
        switch value {
        case let dict as [String: Any]:
            guard !dict.isEmpty else { out += "{\n\n\(pad)}"; return }
            out += "{\n"
            for (i, key) in sortedKeys(dict).enumerated() {
                if i > 0 { out += ",\n" }
                out += inner
                writeString(key, into: &out)
                out += " : "
                write(dict[key]!, indent: indent + 2, into: &out)
            }
            out += "\n\(pad)}"
        case let array as [Any]:
            guard !array.isEmpty else { out += "[\n\n\(pad)]"; return }
            out += "[\n"
            for (i, item) in array.enumerated() {
                if i > 0 { out += ",\n" }
                out += inner
                write(item, indent: indent + 2, into: &out)
            }
            out += "\n\(pad)]"
        case let string as String:
            writeString(string, into: &out)
        case let number as NSNumber:
            if CFGetTypeID(number) == CFBooleanGetTypeID() {
                out += number.boolValue ? "true" : "false"
            } else if CFNumberIsFloatType(number), number.doubleValue.rounded() != number.doubleValue {
                out += "\(number.doubleValue)"
            } else {
                out += "\(number.int64Value)"
            }
        default:
            out += "null"
        }
    }

    private static func writeString(_ s: String, into out: inout String) {
        out += "\""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if scalar.value < 0x20 {
                    out += String(format: "\\u%04x", scalar.value)
                } else {
                    out.unicodeScalars.append(scalar)
                }
            }
        }
        out += "\""
    }
}
