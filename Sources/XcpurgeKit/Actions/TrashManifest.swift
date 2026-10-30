import Foundation

/// `manifest.json` of one trash session (`.xcpurge-trash/<id>/manifest.json`).
public struct TrashManifest: Codable, Sendable, Hashable {
    public static let schemaVersion = 1

    public var schemaVersion: Int
    /// Session ID, also the directory name (`20261029-081500`, with a suffix when taken).
    public var id: String
    public var createdAt: Date
    public var toolVersion: String
    public var entries: [TrashEntry]
    /// What `--verify` did in this session (nil when it was not used).
    public var verify: VerifyRecord?

    public init(id: String, createdAt: Date, entries: [TrashEntry] = [], verify: VerifyRecord? = nil) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.toolVersion = XcpurgeVersion.current
        self.entries = entries
        self.verify = verify
    }
}
