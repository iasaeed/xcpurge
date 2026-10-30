import Foundation

/// Reads `.stringsdict` tables. Only top-level keys are localization keys; nested `NSStringLocalizedFormatKey`
/// variables and plural categories are not.
public enum StringsDictReader {
    /// Top-level key -> 1-based line of its `<key>` element (nil for binary plists).
    public static func keys(_ data: Data) -> [String: Int?]? {
        guard let dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            return nil
        }
        let lines = topLevelKeyLines(data)
        var out: [String: Int?] = [:]
        for key in dict.keys { out[key] = lines[key] }
        return out
    }

    /// `data` without `keys`, rewritten as an XML plist; nil when no key matches.
    public static func removing(_ keys: Set<String>, from data: Data) -> Data? {
        guard var dict = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any],
              !keys.isDisjoint(with: dict.keys) else { return nil }
        for key in keys { dict.removeValue(forKey: key) }
        return try? PropertyListSerialization.data(fromPropertyList: dict, format: .xml, options: 0)
    }

    /// Lines of `<key>` elements directly inside the root `<dict>` (XML only).
    static func topLevelKeyLines(_ data: Data) -> [String: Int] {
        var lines: [String: Int] = [:]
        var depth = 0, number = 0
        for raw in String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            number += 1
            var rest = raw[...]
            while let open = rest.firstIndex(of: "<") {
                rest = rest[open...]
                if rest.hasPrefix("<dict>") { depth += 1 }
                else if rest.hasPrefix("</dict>") { depth -= 1 }
                else if rest.hasPrefix("<dict/>") {}
                else if depth == 1, rest.hasPrefix("<key>"), let close = rest.range(of: "</key>") {
                    let key = String(rest[rest.index(rest.startIndex, offsetBy: 5)..<close.lowerBound])
                        .replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
                        .replacingOccurrences(of: "&amp;", with: "&")
                    if lines[key] == nil { lines[key] = number }
                }
                rest = rest.dropFirst()
            }
        }
        return lines
    }
}
