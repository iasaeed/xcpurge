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

    public init(id: String, createdAt: Date, entries: [TrashEntry] = []) {
        self.schemaVersion = Self.schemaVersion
        self.id = id
        self.createdAt = createdAt
        self.toolVersion = XcpurgeVersion.current
        self.entries = entries
    }
}
