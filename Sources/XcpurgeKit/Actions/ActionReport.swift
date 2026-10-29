/// What an action (trash, prune, restore) did.
public struct ActionReport: Sendable, Equatable {
    /// Root-relative paths moved to (or restored from) the trash.
    public var moved: [String]
    /// Root-relative paths rewritten in place.
    public var rewritten: [String]
    /// Paths left alone, with the reason.
    public var skipped: [Skip]

    public struct Skip: Sendable, Equatable {
        public var path: String
        public var reason: String
        public init(path: String, reason: String) {
            self.path = path
            self.reason = reason
        }
    }

    public init(moved: [String] = [], rewritten: [String] = [], skipped: [Skip] = []) {
        self.moved = moved
        self.rewritten = rewritten
        self.skipped = skipped
    }

    public var isEmpty: Bool { moved.isEmpty && rewritten.isEmpty && skipped.isEmpty }
}
