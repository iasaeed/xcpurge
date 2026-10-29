import Foundation

/// Extracts every string value from a property list (Info.plist, entitlements, Settings.bundle, intents)
/// as `plistValue` references; the context carries the top-level key and the immediate key.
public enum PlistScanner {
    public static func scan(_ data: Data, file: Int32) -> ScanOutput {
        var out = ScanOutput()
        guard let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) else { return out }
        let lines = lineIndex(data)
        for leaf in JSONValue(any: plist).stringLeaves() where !leaf.value.isEmpty {
            out.references.append(Reference(
                kind: .plistValue, value: leaf.value, file: file, line: lines[leaf.value] ?? 0,
                context: CallContext(callee: leaf.path.first, label: leaf.path.last)))
        }
        return out
    }

    /// First line on which each `<string>value</string>` appears (XML plists only).
    private static func lineIndex(_ data: Data) -> [String: Int32] {
        var index: [String: Int32] = [:]
        let text = String(decoding: data, as: UTF8.self)
        guard text.hasPrefix("<?xml") || text.contains("<plist") else { return index }
        var line: Int32 = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            line += 1
            guard let open = raw.range(of: "<string>"), let close = raw.range(of: "</string>"),
                  open.upperBound <= close.lowerBound else { continue }
            let value = String(raw[open.upperBound..<close.lowerBound])
                .replacingOccurrences(of: "&amp;", with: "&").replacingOccurrences(of: "&lt;", with: "<")
                .replacingOccurrences(of: "&gt;", with: ">")
            if index[value] == nil { index[value] = line }
        }
        return index
    }
}
