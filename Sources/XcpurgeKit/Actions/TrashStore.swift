import Foundation

/// Reversible deletion store. Each session lives in `<root>/.xcpurge-trash/<id>/` with one `manifest.json`;
/// moved files keep their root-relative layout under `files/`, pre-rewrite copies under `originals/`.
/// Never writes `.bak` files next to sources (they would ship in synced folders and `.lproj`s).
public final class TrashStore: @unchecked Sendable {
    public static let directoryName = ".xcpurge-trash"
    public static let manifestName = "manifest.json"

    public let root: URL
    public let sessionURL: URL
    private let lock = NSLock()
    private var manifest: TrashManifest

    private init(root: URL, sessionURL: URL, manifest: TrashManifest) {
        self.root = root
        self.sessionURL = sessionURL
        self.manifest = manifest
    }

    public var sessionID: String { lock.withLock { manifest.id } }
    public var entries: [TrashEntry] { lock.withLock { manifest.entries } }
    public var verify: VerifyRecord? { lock.withLock { manifest.verify } }

    /// Starts a session. Its directory and manifest are created by the first move or backup, so an action that
    /// ends up changing nothing leaves no empty session behind.
    public static func begin(root: URL, now: Date = Date()) throws -> TrashStore {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        let base = formatter.string(from: now)
        let trash = root.appendingPathComponent(directoryName)
        var id = base, n = 1
        // Sessions materialize lazily, so IDs handed out in this process are reserved as well as those on disk.
        while FileManager.default.fileExists(atPath: trash.appendingPathComponent(id).path)
            || !Reservations.shared.reserve(trash.appendingPathComponent(id).path) {
            n += 1
            id = "\(base)-\(n)"
        }
        let url = trash.appendingPathComponent(id)
        return TrashStore(root: root, sessionURL: url, manifest: TrashManifest(id: id, createdAt: now))
    }

    /// Reopens an existing session (for partial restores and `--verify`).
    public static func open(root: URL, id: String) throws -> TrashStore {
        let url = sessionURL(root: root, id: id)
        guard let data = FileManager.default.contents(atPath: url.appendingPathComponent(manifestName).path) else {
            throw XcpurgeError.notFound(id)
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return TrashStore(root: root, sessionURL: url, manifest: try decoder.decode(TrashManifest.self, from: data))
    }

    /// Forgets the entries for `paths` (whatever their action) after their files went back; rewrites the manifest.
    public func dropEntries(paths: Set<String>) throws {
        lock.withLock { manifest.entries.removeAll { paths.contains($0.path) } }
        try flush()
    }

    /// Re-reads the manifest after another `TrashStore` (a partial `Restore`) changed the session on disk; a
    /// session that was removed reads as empty.
    public func reload() throws {
        guard let data = FileManager.default.contents(atPath: sessionURL.appendingPathComponent(Self.manifestName).path) else {
            lock.withLock { manifest.entries = [] }
            return
        }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let fresh = try decoder.decode(TrashManifest.self, from: data)
        lock.withLock { manifest = fresh }
    }

    /// Records what `--verify` did and rewrites the manifest.
    public func setVerify(_ record: VerifyRecord) throws {
        lock.withLock { manifest.verify = record }
        try flush()
    }

    /// Moves a root-relative file or folder into the session and records a `moved` entry.
    public func move(_ path: String) throws {
        let source = root.appendingPathComponent(path)
        let stored = "files/" + path
        let destination = sessionURL.appendingPathComponent(stored)
        let size = Self.size(of: source)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.moveItem(at: source, to: destination)
        try record(TrashEntry(action: .moved, path: path, stored: stored, sizeBytes: size))
    }

    /// Copies a root-relative file into the session before it is rewritten and records a `rewritten` entry.
    /// Backing up the same path twice in one session keeps the first (original) copy.
    public func backup(_ path: String) throws {
        if entries.contains(where: { $0.path == path && $0.action == .rewritten }) { return }
        let source = root.appendingPathComponent(path)
        let stored = "originals/" + path
        let destination = sessionURL.appendingPathComponent(stored)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        // A copy left behind by a partial restore (its entry was dropped once the file was back to the original).
        if FileManager.default.fileExists(atPath: destination.path) { try FileManager.default.removeItem(at: destination) }
        try FileManager.default.copyItem(at: source, to: destination)
        try record(TrashEntry(action: .rewritten, path: path, stored: stored, sizeBytes: Self.size(of: source)))
    }

    /// Absolute URL of an entry's stored copy.
    public func storedURL(_ entry: TrashEntry) -> URL { sessionURL.appendingPathComponent(entry.stored) }

    /// All sessions under `root`, newest first.
    public static func sessions(root: URL) throws -> [TrashManifest] {
        let trash = root.appendingPathComponent(directoryName)
        guard FileManager.default.fileExists(atPath: trash.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try FileManager.default.contentsOfDirectory(atPath: trash.path).compactMap { name in
            let url = trash.appendingPathComponent(name).appendingPathComponent(manifestName)
            guard let data = FileManager.default.contents(atPath: url.path) else { return nil }
            return try decoder.decode(TrashManifest.self, from: data)
        }.sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
    }

    /// Directory of a session by ID.
    public static func sessionURL(root: URL, id: String) -> URL {
        root.appendingPathComponent(directoryName).appendingPathComponent(id)
    }

    private func record(_ entry: TrashEntry) throws {
        lock.withLock { manifest.entries.append(entry) }
        try flush()
    }

    private func flush() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .iso8601
        let data = try lock.withLock { try encoder.encode(manifest) }
        try FileManager.default.createDirectory(at: sessionURL, withIntermediateDirectories: true)
        try data.write(to: sessionURL.appendingPathComponent(Self.manifestName), options: .atomic)
    }

    static func size(of url: URL) -> Int64 {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { return 0 }
        if isDir.boolValue { return FileWalker.treeSize(url.path) }
        return ((try? FileManager.default.attributesOfItem(atPath: url.path))?[.size] as? NSNumber)?.int64Value ?? 0
    }
}

/// Session directories handed out by `TrashStore.begin` in this process (not yet on disk).
private final class Reservations: @unchecked Sendable {
    static let shared = Reservations()
    private let lock = NSLock()
    private var paths = Set<String>()

    /// False when `path` was already reserved.
    func reserve(_ path: String) -> Bool { lock.withLock { paths.insert(path).inserted } }
}
