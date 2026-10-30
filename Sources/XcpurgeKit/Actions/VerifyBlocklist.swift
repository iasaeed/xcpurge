import Foundation

/// `.xcpurge-trash/verify-blocked.json`: paths an earlier `--verify` had to put back because the build failed
/// without them. `--delete` skips them; `remove` warns. Survives `restore` (the trash folder stays while it exists).
public enum VerifyBlocklist {
    public static let fileName = "verify-blocked.json"

    public struct Entry: Codable, Hashable, Sendable, Comparable {
        public var path: String
        public var reason: String
        /// Trash session that recorded it.
        public var session: String
        public var date: Date

        public init(path: String, reason: String, session: String, date: Date) {
            self.path = path
            self.reason = reason
            self.session = session
            self.date = date
        }

        public static func < (a: Entry, b: Entry) -> Bool { (a.path, a.session) < (b.path, b.session) }
    }

    public static func url(root: URL) -> URL {
        root.appendingPathComponent(TrashStore.directoryName).appendingPathComponent(fileName)
    }

    /// Entries sorted by path; an unreadable file reads as empty.
    public static func load(root: URL) -> [Entry] {
        guard let data = FileManager.default.contents(atPath: url(root: root).path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return ((try? decoder.decode([Entry].self, from: data)) ?? []).sorted()
    }

    /// Blocked root-relative paths.
    public static func paths(root: URL) -> Set<String> { Set(load(root: root).map(\.path)) }

    /// Adds entries (one per path; a path already listed keeps the newest entry) and rewrites the file.
    public static func add(_ entries: [Entry], root: URL) throws {
        guard !entries.isEmpty else { return }
        var byPath = Dictionary(load(root: root).map { ($0.path, $0) }, uniquingKeysWith: { a, b in a.date >= b.date ? a : b })
        for e in entries { byPath[e.path] = e }
        try write(byPath.values.sorted(), root: root)
    }

    /// Drops `paths` from the list; removes the file when nothing is left.
    public static func remove(_ paths: Set<String>, root: URL) throws {
        let rest = load(root: root).filter { !paths.contains($0.path) }
        if rest.isEmpty {
            try? FileManager.default.removeItem(at: url(root: root))
        } else {
            try write(rest, root: root)
        }
    }

    private static func write(_ entries: [Entry], root: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let file = url(root: root)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoder.encode(entries).write(to: file, options: .atomic)
    }
}
