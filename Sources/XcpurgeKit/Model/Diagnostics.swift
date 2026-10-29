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

    public init() {}

    public func add(_ level: Entry.Level, _ message: String, path: String? = nil) {
        lock.withLock { storage.append(Entry(level: level, message: message, path: path)) }
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
