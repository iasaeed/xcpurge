/// Every file and bundle unit under the scan root, sorted by path, with attribution.
public struct FileInventory: Sendable {
    public private(set) var files: [SourceFile]
    private var indexByPath: [String: Int]

    public init(files: [SourceFile]) {
        self.files = files.sorted { $0.path < $1.path }
        self.indexByPath = Dictionary(uniqueKeysWithValues: self.files.enumerated().map { ($1.path, $0) })
    }

    public func index(of path: String) -> Int? { indexByPath[path] }
    public func file(at path: String) -> SourceFile? { indexByPath[path].map { files[$0] } }
    public func files(of kind: FileKind) -> [SourceFile] { files.filter { $0.kind == kind } }

    /// Files whose path equals `dir` or lies under it.
    public func files(under dir: String) -> [SourceFile] { indices(under: dir).map { files[$0] } }

    /// Indices of files equal to or beneath `dir` (binary search; paths under `dir/` are contiguous).
    public func indices(under dir: String) -> [Int] {
        if dir.isEmpty { return Array(files.indices) }
        var out: [Int] = []
        if let exact = indexByPath[dir] { out.append(exact) }
        let prefix = dir + "/"
        var lo = 0, hi = files.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if files[mid].path < prefix { lo = mid + 1 } else { hi = mid }
        }
        while lo < files.count, files[lo].path.hasPrefix(prefix) { out.append(lo); lo += 1 }
        return out
    }

    public mutating func update(_ path: String, _ body: (inout SourceFile) -> Void) {
        guard let i = indexByPath[path] else { return }
        body(&files[i])
    }

    public mutating func update(index: Int, _ body: (inout SourceFile) -> Void) { body(&files[index]) }
}
