/// Computes per-target membership of a synchronized folder (plan §4.1): owners get every unit minus their
/// exclusions; exception sets naming other targets add files to those targets.
public enum SyncedFolderResolver {
    /// - Parameters:
    ///   - group: the synchronized folder.
    ///   - files: root-relative inventory paths under `group.path`.
    /// - Returns: target name -> root-relative member paths.
    public static func resolve(_ group: SyncedGroup, files: [String]) -> [String: Set<String>] {
        let prefix = group.path.isEmpty ? "" : group.path + "/"
        let relative = files.compactMap { $0.hasPrefix(prefix) ? String($0.dropFirst(prefix.count)) : nil }
        let headers = Set(relative.filter { isHeader($0, explicitType: group.explicitFileTypes[$0]) })
        let base = Set(relative).subtracting(headers)
        var result: [String: Set<String>] = [:]

        for owner in group.owners {
            var members = base
            for ex in group.exceptions where ex.target == owner && !ex.isBuildPhase {
                if ex.sense != .inclusions { members.subtract(expand(ex.paths, in: relative)) }
                members.formUnion(expand(ex.publicHeaders + ex.privateHeaders, in: relative))
            }
            result[owner, default: []].formUnion(members)
        }
        for ex in group.exceptions where ex.isBuildPhase || !group.owners.contains(ex.target) {
            guard ex.sense != .exclusions else { continue }
            result[ex.target, default: []].formUnion(expand(ex.paths + ex.publicHeaders + ex.privateHeaders, in: relative))
        }
        return result.mapValues { Set($0.map { prefix + $0 }) }
    }

    /// Exception entries are files or directories; a directory covers its subtree.
    static func expand(_ entries: [String], in files: [String]) -> Set<String> {
        var out = Set<String>()
        for entry in entries {
            let e = entry.hasSuffix("/") ? String(entry.dropLast()) : entry
            for f in files where f == e || f.hasPrefix(e + "/") { out.insert(f) }
        }
        return out
    }

    static func isHeader(_ path: String, explicitType: String?) -> Bool {
        if let explicitType { return explicitType.hasPrefix("sourcecode.c.h") || explicitType.hasSuffix(".h") }
        return FileKind(path: path) == .header
    }
}
