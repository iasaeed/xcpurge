import Foundation

/// Removes unused keys from `.xcstrings` / `.strings` / `.stringsdict` (plan §4.6 step 6), backing every
/// file up into the `TrashStore` first. `.xcstrings` are rewritten in Xcode's format; `.strings` lose the
/// statement plus its directly preceding comment; `.stringsdict` are rewritten as XML plists. Keys of
/// `.lproj` tables are removed from every sibling `.lproj` variant of the same file.
public struct PruneStrings: Sendable {
    public let store: TrashStore

    public init(store: TrashStore) {
        self.store = store
    }

    public func apply(_ findings: [Finding], context: ScanContext) throws -> ActionReport {
        var report = ActionReport()
        var keysByFile: [String: Set<String>] = [:]
        for f in findings where f.category == .strings {
            guard f.kind == .unusedString || f.kind == .staleString, let key = f.name else {
                if !f.kind.isInformational { report.skipped.append(.init(path: f.path, reason: "not a prunable string finding")) }
                continue
            }
            for path in variants(of: f.path, root: context.root) { keysByFile[path, default: []].insert(key) }
        }
        let fm = FileManager.default
        for path in keysByFile.keys.sorted() {
            let url = context.root.appendingPathComponent(path)
            guard let data = fm.contents(atPath: url.path) else {
                report.skipped.append(.init(path: path, reason: "cannot read file"))
                continue
            }
            let keys = keysByFile[path]!
            let updated: Data?
            switch FileKind(path: path) {
            case .stringCatalog:
                do {
                    let catalog = try StringCatalogReader.read(data)
                    updated = Set(catalog.entries.map(\.key)).isDisjoint(with: keys)
                        ? nil : try StringCatalogReader.removing(keys, from: data)
                } catch {
                    report.skipped.append(.init(path: path, reason: "cannot parse string catalog: \(error)"))
                    continue
                }
            case .strings: updated = StringsFileReader.removing(keys, from: data)
            case .stringsdict: updated = StringsDictReader.removing(keys, from: data)
            default:
                report.skipped.append(.init(path: path, reason: "not a string table"))
                continue
            }
            guard let updated, updated != data else { continue }
            try store.backup(path)
            try updated.write(to: url, options: .atomic)
            report.rewritten.append(path)
        }
        return report
    }

    /// The file itself plus, for `X.lproj/Name.ext`, every `*.lproj/Name.ext` beside it.
    func variants(of path: String, root: URL) -> [String] {
        let dir = RelPath.parent(path)
        guard dir.hasSuffix(".lproj") else { return [path] }
        let base = RelPath.parent(dir), name = RelPath.lastComponent(path)
        let baseURL = base.isEmpty ? root : root.appendingPathComponent(base)
        let lprojs = (try? FileManager.default.contentsOfDirectory(atPath: baseURL.path)) ?? []
        let found = lprojs.filter { $0.hasSuffix(".lproj") }.map { RelPath.join(base, "\($0)/\(name)") }
            .filter { FileManager.default.fileExists(atPath: root.appendingPathComponent($0).path) }
        return Array(Set(found + [path])).sorted()
    }
}
