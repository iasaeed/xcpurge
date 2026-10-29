import Foundation

/// Every file and bundle unit under the scan root, sorted by path, with attribution. On a case-insensitive
/// volume path lookups ignore case, so a project's `images/Logo.png` finds `Images/logo.png` on disk.
public struct FileInventory: Sendable {
    public private(set) var files: [SourceFile]
    /// True when lookups fold case (the scan root's volume is case-insensitive).
    public let isCaseInsensitive: Bool
    /// Path (folded when case-insensitive) -> index.
    private var indexByPath: [String: Int]
    /// Case-insensitive only: folded paths in folded order, for `indices(under:)`.
    private let folded: [(path: String, index: Int)]

    public init(files: [SourceFile], caseInsensitive: Bool = false) {
        self.files = files.sorted { $0.path < $1.path }
        self.isCaseInsensitive = caseInsensitive
        // ponytail: `lowercased()` stands in for APFS case folding; good enough for file names.
        let keys = self.files.map { caseInsensitive ? $0.path.lowercased() : $0.path }
        self.indexByPath = Dictionary(keys.enumerated().map { ($1, $0) }, uniquingKeysWith: { a, _ in a })
        self.folded = caseInsensitive ? keys.enumerated().map { ($1, $0) }.sorted { $0.0 < $1.0 } : []
    }

    /// True unless the volume holding `url` is known to be case-insensitive.
    public static func isCaseSensitiveVolume(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.volumeSupportsCaseSensitiveNamesKey]).volumeSupportsCaseSensitiveNames) ?? true
    }

    private func key(_ path: String) -> String { isCaseInsensitive ? path.lowercased() : path }

    public func index(of path: String) -> Int? { indexByPath[key(path)] }
    public func file(at path: String) -> SourceFile? { index(of: path).map { files[$0] } }
    public func files(of kind: FileKind) -> [SourceFile] { files.filter { $0.kind == kind } }

    /// Files whose path equals `dir` or lies under it.
    public func files(under dir: String) -> [SourceFile] { indices(under: dir).map { files[$0] } }

    /// Indices of files equal to or beneath `dir` (binary search; paths under `dir/` are contiguous).
    public func indices(under dir: String) -> [Int] {
        if dir.isEmpty { return Array(files.indices) }
        var out: [Int] = []
        if let exact = index(of: dir) { out.append(exact) }
        let prefix = key(dir) + "/"
        if isCaseInsensitive {
            var lo = 0, hi = folded.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if folded[mid].path < prefix { lo = mid + 1 } else { hi = mid }
            }
            while lo < folded.count, folded[lo].path.hasPrefix(prefix) { out.append(folded[lo].index); lo += 1 }
            return out.sorted()
        }
        var lo = 0, hi = files.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if files[mid].path < prefix { lo = mid + 1 } else { hi = mid }
        }
        while lo < files.count, files[lo].path.hasPrefix(prefix) { out.append(lo); lo += 1 }
        return out
    }

    public mutating func update(_ path: String, _ body: (inout SourceFile) -> Void) {
        guard let i = index(of: path) else { return }
        body(&files[i])
    }

    public mutating func update(index: Int, _ body: (inout SourceFile) -> Void) { body(&files[index]) }
}
