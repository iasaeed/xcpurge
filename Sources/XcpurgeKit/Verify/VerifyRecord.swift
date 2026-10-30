// LANE: C
import Foundation

/// What `--verify` did in one trash session; stored in the session manifest.
public struct VerifyRecord: Codable, Hashable, Sendable {
    public enum Outcome: String, Codable, Sendable {
        /// Every removal built.
        case passed
        /// Some units were restored (blocked or unverified); the rest stayed removed and build.
        case partial
        /// Everything was restored (timeout, or no removal built).
        case restoredAll
        /// The command failed before any change; nothing was removed.
        case preflightFailed
    }

    public struct Blocked: Codable, Hashable, Sendable {
        /// Root-relative path that was restored because the build failed without it.
        public var path: String
        public var reason: String
        /// The compiler line that named it, when attribution (not bisection) found it.
        public var diagnostic: String?

        public init(path: String, reason: String, diagnostic: String? = nil) {
            self.path = path
            self.reason = reason
            self.diagnostic = diagnostic
        }
    }

    public var command: String
    public var startedAt: Date
    /// Builds run, the preflight included.
    public var builds: Int
    public var outcome: Outcome
    public var blocked: [Blocked]

    public init(command: String, startedAt: Date, builds: Int, outcome: Outcome, blocked: [Blocked] = []) {
        self.command = command
        self.startedAt = startedAt
        self.builds = builds
        self.outcome = outcome
        self.blocked = blocked
    }
}
