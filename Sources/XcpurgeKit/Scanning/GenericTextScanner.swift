import Foundation

/// Extracts candidate names from JSON, HTML, CSS, JS and xcconfig files: quoted strings (JSON: string values),
/// CSS `url(…)` and `font-family`, xcconfig values. Path-like values also yield their file name and stem.
public enum GenericTextScanner {
    public static func scan(_ data: Data, file: Int32, kind: FileKind) -> ScanOutput {
        var out = ScanOutput()
        if kind == .json, let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) {
            for leaf in JSONValue(any: object).stringLeaves() {
                add(leaf.value, line: 0, label: leaf.path.last, file: file, to: &out)
            }
            return out
        }
        let text = String(decoding: data, as: UTF8.self)
        var line: Int32 = 0
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            line += 1
            if raw.contains(SwiftTokenizer.ignoreMarker) { out.ignoredLines.append(line) }
            if kind == .xcconfig {
                if let eq = raw.firstIndex(of: "="), !raw.hasPrefix("//") {
                    let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
                    for word in BuildSettings.splitList(String(raw[raw.index(after: eq)...])) {
                        add(word, line: line, label: key, file: file, to: &out)
                    }
                }
                continue
            }
            for value in quoted(raw) { add(value, line: line, label: nil, file: file, to: &out) }
            if kind == .css || kind == .html {
                for value in cssValues(raw) { add(value, line: line, label: "css", file: file, to: &out) }
            }
        }
        return out
    }

    private static func add(_ value: String, line: Int32, label: String?, file: Int32, to out: inout ScanOutput) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count < 512 else { return }
        var values = [trimmed]
        if trimmed.contains("/") || trimmed.contains(".") {
            let name = RelPath.lastComponent(trimmed)
            values.append(name)
            values.append(RelPath.stem(name))
        }
        for v in Set(values).sorted() where !v.isEmpty {
            out.references.append(Reference(kind: .stringLiteral, value: v, file: file, line: line,
                                            context: label.map { CallContext(label: $0) }))
        }
    }

    /// Contents of `"…"` and `'…'` on one line.
    static func quoted(_ line: Substring) -> [String] {
        var values: [String] = [], current = "", quote: Character?
        var escaped = false
        for c in line {
            if let q = quote {
                if escaped { current.append(c); escaped = false }
                else if c == "\\" { escaped = true }
                else if c == q { values.append(current); current = ""; quote = nil }
                else { current.append(c) }
            } else if c == "\"" || c == "'" {
                quote = c
            }
        }
        return values
    }

    /// Unquoted `url(x)` and `font-family: A, B` values.
    static func cssValues(_ line: Substring) -> [String] {
        var values: [String] = []
        var rest = line[...]
        while let r = rest.range(of: "url(") {
            let after = rest[r.upperBound...]
            guard let close = after.firstIndex(of: ")") else { break }
            values.append(after[..<close].trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")))
            rest = after[close...]
        }
        if let r = line.range(of: "font-family:") {
            let list = line[r.upperBound...].prefix { $0 != ";" && $0 != "}" }
            values += list.split(separator: ",").map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"' ")) }
        }
        return values
    }
}
