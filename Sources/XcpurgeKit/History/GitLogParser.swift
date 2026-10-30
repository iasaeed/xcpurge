import Foundation

/// Incremental parser for `git log --format=%x1e%H%x1f%aI%x1f%aN%x1f%aE%x1f%s --name-only -z`: each commit is one
/// record starting with `\u{1e}`, its header fields separated by `\u{1f}`, then NUL-separated paths (git puts a
/// newline before the first path). Feed chunks as they arrive; `finish()` flushes the last record.
struct GitLogParser {
    struct Commit: Equatable, Sendable {
        var sha: String
        /// ISO 8601 author date (`%aI`).
        var date: String
        var authorName: String
        var authorEmail: String
        var subject: String
        var paths: [String]
    }

    private static let recordSeparator: UInt8 = 0x1e
    private static let fieldSeparator: UInt8 = 0x1f
    private var buffer = Data()

    /// Commits completed by this chunk (a record is complete when the next one starts).
    mutating func feed(_ chunk: Data) -> [Commit] {
        buffer.append(chunk)
        var out: [Commit] = []
        // Keep the last (possibly incomplete) record in the buffer.
        while let start = buffer.firstIndex(of: Self.recordSeparator) {
            let afterStart = buffer.index(after: start)
            guard let next = buffer[afterStart...].firstIndex(of: Self.recordSeparator) else { break }
            if let commit = Self.parse(record: buffer[afterStart..<next]) { out.append(commit) }
            buffer.removeSubrange(buffer.startIndex..<next)
        }
        return out
    }

    /// The trailing record, if any.
    mutating func finish() -> [Commit] {
        defer { buffer = Data() }
        guard let start = buffer.firstIndex(of: Self.recordSeparator) else { return [] }
        return Self.parse(record: buffer[buffer.index(after: start)...]).map { [$0] } ?? []
    }

    /// `sha\u{1f}date\u{1f}name\u{1f}email\u{1f}subject\0\npath\0path\0…`
    static func parse(record: Data) -> Commit? {
        let parts = record.split(separator: 0, omittingEmptySubsequences: false)
        guard let header = parts.first else { return nil }
        let fields = header.split(separator: fieldSeparator, maxSplits: 4, omittingEmptySubsequences: false)
            .map { String(decoding: $0, as: UTF8.self) }
        guard fields.count >= 2, !fields[0].isEmpty else { return nil }
        func field(_ i: Int) -> String { i < fields.count ? fields[i] : "" }
        var paths: [String] = []
        for part in parts.dropFirst() {
            var p = part[...]
            while let first = p.first, first == UInt8(ascii: "\n") { p = p.dropFirst() }
            if p.isEmpty { continue }
            paths.append(String(decoding: p, as: UTF8.self))
        }
        return Commit(sha: field(0), date: field(1), authorName: field(2), authorEmail: field(3), subject: field(4), paths: paths)
    }

    /// NUL-separated paths of `git log --name-only -z --format=` (empty format): blank entries dropped.
    static func paths(fromNulSeparated data: Data) -> [String] {
        data.split(separator: 0).compactMap { part in
            var p = part[...]
            while let first = p.first, first == UInt8(ascii: "\n") { p = p.dropFirst() }
            return p.isEmpty ? nil : String(decoding: p, as: UTF8.self)
        }
    }
}
