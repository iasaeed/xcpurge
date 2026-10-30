// LANE: C
import Foundation

/// What `--verify` removes and restores together: one unit per trashed path, except source files that refer to
/// one another, which form one unit (removing `A` alone fails when `B`, also dead, still mentions it).
public struct RemovalUnit: Hashable, Sendable, Comparable {
    /// Root-relative paths, sorted.
    public var paths: [String]
    public var id: String { paths.first ?? "" }

    public init(paths: [String]) { self.paths = paths.sorted() }

    public static func < (a: RemovalUnit, b: RemovalUnit) -> Bool { a.id < b.id }
}

public enum RemovalUnits {
    /// Groups `paths` into units. Source files (`.swift`, `.m`, `.mm`, `.h`) are connected when a name one of
    /// them declares (`DeclarationCollector`) appears among the identifiers of the other
    /// (`refs.identifiersByFile`); everything else is its own unit.
    public static func make(paths: [String], context: ScanContext) -> [RemovalUnit] {
        let unique = Array(Set(paths)).sorted()
        var parent = Array(unique.indices)
        func find(_ i: Int) -> Int {
            var i = i
            while parent[i] != i { parent[i] = parent[parent[i]]; i = parent[i] }
            return i
        }
        func union(_ a: Int, _ b: Int) { let ra = find(a), rb = find(b); if ra != rb { parent[max(ra, rb)] = min(ra, rb) } }

        let sources = unique.indices.filter { isSource(unique[$0]) }
        if sources.count > 1 {
            var declared: [Int: Set<String>] = [:], identifiers: [Int: Set<String>] = [:]
            for i in sources {
                declared[i] = declaredNames(of: unique[i], context: context)
                if let index = context.inventory.index(of: unique[i]) {
                    identifiers[i] = context.refs.identifiersByFile[Int32(index)] ?? []
                }
            }
            for a in sources {
                for b in sources where a < b {
                    let aNames = declared[a] ?? [], bNames = declared[b] ?? []
                    if !aNames.isDisjoint(with: identifiers[b] ?? []) || !bNames.isDisjoint(with: identifiers[a] ?? []) {
                        union(a, b)
                    }
                }
            }
        }
        var groups: [Int: [String]] = [:]
        for i in unique.indices { groups[find(i), default: []].append(unique[i]) }
        return groups.values.map(RemovalUnit.init).sorted()
    }

    public static func isSource(_ path: String) -> Bool {
        ["swift", "m", "mm", "h"].contains((path as NSString).pathExtension.lowercased())
    }

    /// Names a source file declares (types, members, extension members, categories), by tokenizing it. The file
    /// may already sit in the trash (`stored` URL), so the caller passes the URL to read when known.
    public static func declaredNames(of path: String, context: ScanContext, at url: URL? = nil) -> Set<String> {
        let file = url ?? context.url(for: path)
        guard let data = try? Data(contentsOf: file, options: .alwaysMapped) else { return [] }
        let dialect: SwiftTokenizer.Dialect = (path as NSString).pathExtension.lowercased() == "swift" ? .swift : .objc
        let decls = DeclarationCollector.collect(SwiftTokenizer.tokenize(data, dialect: dialect).tokens, dialect: dialect)
        return Set(decls.allNames + decls.nestedTypes + decls.categories)
    }
}
