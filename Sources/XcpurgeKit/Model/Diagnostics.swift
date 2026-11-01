import Foundation

/// Thread-safe collector of warnings and notes produced while scanning; never fails a scan.
public final class Diagnostics: @unchecked Sendable {
    public struct Entry: Codable, Hashable, Sendable {
        public enum Level: String, Codable, Sendable, Comparable {
            case info, warning, error
            private var rank: Int { self == .info ? 0 : self == .warning ? 1 : 2 }
            public static func < (a: Level, b: Level) -> Bool { a.rank < b.rank }
        }
        public var level: Level
        public var message: String
        public var path: String?

        public init(level: Level, message: String, path: String? = nil) {
            self.level = level
            self.message = message
            self.path = path
        }
    }

    private let lock = NSLock()
    private var storage: [Entry] = []
    private var quiet: [String] = []
    /// Absolute paths under this root are stored root-relative.
    private let rootPath: String?

    public init(rootPath: String? = nil) {
        self.rootPath = rootPath.map(RelPath.normalize)
    }

    /// Drops warnings (not notes) about paths under these root-relative folders: the folder is known to be
    /// missing (an uninitialised submodule, `pod install` not run), which one note already says.
    public func suppressWarnings(under folders: [String]) {
        lock.withLock { quiet += folders }
    }

    public func add(_ level: Entry.Level, _ message: String, path: String? = nil) {
        let path = relative(path)
        lock.withLock {
            if level == .warning, let path, quiet.contains(where: { RelPath.isUnder(path, $0) }) { return }
            storage.append(Entry(level: level, message: message, path: path))
        }
    }

    private func relative(_ path: String?) -> String? {
        guard let path, let rootPath, path.hasPrefix("/") else { return path }
        let rel = RelPath.relative(path, to: rootPath)
        return rel.hasPrefix("../") || rel == ".." ? path : rel
    }

    public func warn(_ message: String, path: String? = nil) { add(.warning, message, path: path) }
    public func info(_ message: String, path: String? = nil) { add(.info, message, path: path) }

    /// Deduplicated entries in a stable order.
    public var entries: [Entry] {
        let all = lock.withLock { storage }
        return Array(Set(all)).sorted {
            ($0.path ?? "", $0.message, $0.level.rawValue) < ($1.path ?? "", $1.message, $1.level.rawValue)
        }
    }
}
