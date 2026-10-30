// Optional-field additions only; the fields below are a frozen contract.
/// Git history of the file or bundle unit a finding is about (`--git`). Never changes confidence or reasons.
public struct FindingHistory: Codable, Hashable, Sendable {
    public enum Status: String, Codable, Sendable {
        case ok, shallow, untracked, notGit = "not-git", unavailable
    }

    public enum Bucket: String, Codable, Sendable {
        case recentlyAdded, leftover
    }

    public struct Commit: Codable, Hashable, Sendable {
        public var sha: String
        /// ISO 8601 author date.
        public var date: String
        public var authorName: String
        /// Only with `--git-emails`.
        public var authorEmail: String?
        public var subject: String

        public init(sha: String, date: String, authorName: String, authorEmail: String? = nil, subject: String) {
            self.sha = sha
            self.date = date
            self.authorName = authorName
            self.authorEmail = authorEmail
            self.subject = subject
        }
    }

    public var status: Status
    public var lastCommit: Commit?
    public var ageDays: Int?
    public var bucket: Bucket?
    /// Heuristic: the commit that removed the last use of the name; only with `--git-dead-since`.
    public var deadSince: Commit?
    /// e.g. "n/a (shallow clone)".
    public var note: String?

    public init(status: Status, lastCommit: Commit? = nil, ageDays: Int? = nil, bucket: Bucket? = nil,
                deadSince: Commit? = nil, note: String? = nil) {
        self.status = status
        self.lastCommit = lastCommit
        self.ageDays = ageDays
        self.bucket = bucket
        self.deadSince = deadSince
        self.note = note
    }
}
