import Foundation

/// Reads `.xcconfig` files, following `#include` / `#include?` and resolving in-file `$(inherited)`.
public enum XCConfigParser {
    /// Returns the merged settings and every file read (for attribution).
    public static func parse(url: URL, diagnostics: Diagnostics?) -> (settings: [String: String], files: [URL]) {
        var settings: [String: String] = [:]
        var files: [URL] = []
        var visiting = Set<String>()
        read(url: url, into: &settings, files: &files, visiting: &visiting, diagnostics: diagnostics, depth: 0)
        return (settings, files)
    }

    /// Parses xcconfig text without following includes.
    public static func parse(text: String) -> [String: String] {
        var settings: [String: String] = [:]
        for line in text.components(separatedBy: .newlines) {
            if let (key, value) = assignment(line) {
                settings[key] = BuildSettings.replacingInherited(value, with: settings[key] ?? "$(inherited)")
            }
        }
        return settings
    }

    private static func read(url: URL, into settings: inout [String: String], files: inout [URL],
                             visiting: inout Set<String>, diagnostics: Diagnostics?, depth: Int) {
        let key = url.standardizedFileURL.path
        guard depth < 16, visiting.insert(key).inserted else { return }
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            diagnostics?.warn("cannot read xcconfig", path: url.path)
            return
        }
        files.append(url)
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("#include") {
                let optional = trimmed.hasPrefix("#include?")
                guard let open = trimmed.firstIndex(of: "\""), let close = trimmed.lastIndex(of: "\""), open < close
                else { continue }
                let rel = String(trimmed[trimmed.index(after: open)..<close])
                let target = rel.hasPrefix("/") ? URL(fileURLWithPath: rel)
                    : url.deletingLastPathComponent().appendingPathComponent(rel)
                if FileManager.default.fileExists(atPath: target.path) {
                    read(url: target, into: &settings, files: &files, visiting: &visiting,
                         diagnostics: diagnostics, depth: depth + 1)
                } else if !optional {
                    diagnostics?.warn("missing xcconfig include \(rel)", path: url.path)
                }
                continue
            }
            if let (k, value) = assignment(line) {
                settings[k] = BuildSettings.replacingInherited(value, with: settings[k] ?? "$(inherited)")
            }
        }
    }

    private static func assignment(_ line: String) -> (String, String)? {
        var text = line
        if let comment = text.range(of: "//") { text = String(text[..<comment.lowerBound]) }
        guard let eq = text.firstIndex(of: "=") else { return nil }
        let key = text[..<eq].trimmingCharacters(in: .whitespaces)
        guard !key.isEmpty, !key.hasPrefix("#") else { return nil }
        var value = text[text.index(after: eq)...].trimmingCharacters(in: .whitespaces)
        if value.hasSuffix(";") { value.removeLast() }
        return (key, value)
    }
}
