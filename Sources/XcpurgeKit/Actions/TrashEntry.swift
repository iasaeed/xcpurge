/// One file operation recorded in a trash session manifest.
public struct TrashEntry: Codable, Sendable, Hashable {
    public enum Action: String, Codable, Sendable {
        /// The file or folder was moved into the session (deleted from the project).
        case moved
        /// The file was rewritten in place (pruned catalog, edited pbxproj); `stored` is the original copy.
        case rewritten
    }

    public var action: Action
    /// Root-relative original path.
    public var path: String
    /// Path of the stored copy, relative to the session directory.
    public var stored: String
    public var sizeBytes: Int64
    /// `rewritten` only: SHA-256 (lowercase hex) of the file as the rewrite left it, so `Restore` can tell when it
    /// changed since. Nil in sessions written by older versions.
    public var afterSHA256: String?

    public init(action: Action, path: String, stored: String, sizeBytes: Int64, afterSHA256: String? = nil) {
        self.action = action
        self.path = path
        self.stored = stored
        self.sizeBytes = sizeBytes
        self.afterSHA256 = afterSHA256
    }
}
