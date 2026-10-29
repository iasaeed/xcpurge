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
            scanLine(raw, line: line, kind: kind, file: file, into: &out)
        }
        return out
    }

    /// Files too large to load whole (over `ReferenceIndex.maxFileSize`): read in chunks and scanned line by line
    /// as text (JSON included, without key labels). A line longer than one chunk is cut at the chunk boundary,
    /// so a literal straddling that cut can be missed. Nil when the file cannot be read.
    public static func scanStreaming(_ url: URL, file: Int32, kind: FileKind, chunkSize: Int = 1 << 20) -> ScanOutput? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        var out = ScanOutput()
        var line: Int32 = 0
        var carry = Data()
        func flush(_ bytes: Data) {
            line += 1
            scanLine(Substring(String(decoding: bytes, as: UTF8.self)), line: line, kind: kind, file: file, into: &out)
        }
        while true {
            let read: Data?
            do { read = try handle.read(upToCount: chunkSize) } catch { return nil }
            guard let chunk = read, !chunk.isEmpty else { break }   // nil or empty at end of file
            carry.append(chunk)
            var start = carry.startIndex
            while let newline = carry[start...].firstIndex(of: 0x0A) {
                flush(carry[start..<newline])
                start = carry.index(after: newline)
            }
            carry = carry[start...]
            if carry.count > chunkSize {   // one huge line (minified JSON): scan what we have
                flush(carry)
                line -= 1
                carry = Data()
            }
        }
        flush(carry)
        return out
    }

    private static func scanLine(_ raw: Substring, line: Int32, kind: FileKind, file: Int32, into out: inout ScanOutput) {
        if raw.contains(SwiftTokenizer.ignoreMarker) { out.ignoredLines.append(line) }
        if kind == .xcconfig {
            if let eq = raw.firstIndex(of: "="), !raw.hasPrefix("//") {
                let key = raw[..<eq].trimmingCharacters(in: .whitespaces)
                for word in BuildSettings.splitList(String(raw[raw.index(after: eq)...])) {
                    add(word, line: line, label: key, file: file, to: &out)
                }
            }
            return
        }
        for value in quoted(raw) { add(value, line: line, label: nil, file: file, to: &out) }
        if kind == .css || kind == .html {
            for value in cssValues(raw) { add(value, line: line, label: "css", file: file, to: &out) }
        }
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
