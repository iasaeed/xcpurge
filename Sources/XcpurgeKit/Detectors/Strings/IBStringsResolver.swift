// LANE: B
/// Interface Builder string tables (`fr.lproj/Main.strings`, `Main.xcstrings`) use `ObjectID.property` keys
/// (`"abc-12-def.text"`). Such a key is used iff the object ID still exists in the storyboard / xib with the
/// table's stem. Object IDs come from `IBScanner`'s `id` attribute references.
public struct IBStringsResolver: Sendable {
    private struct Interface: Sendable {
        var path: String
        var modules: Set<ModuleID>
        var ids: Set<String>
    }

    private let interfaces: [String: [Interface]]

    public init(_ ctx: ScanContext) {
        var ids: [Int32: Set<String>] = [:]
        for r in ctx.refs.references where r.kind == .ibAttribute("id") { ids[r.file, default: []].insert(r.value) }
        var byStem: [String: [Interface]] = [:]
        for (i, file) in ctx.inventory.files.enumerated() where file.kind == .storyboard || file.kind == .xib {
            byStem[RelPath.stem(file.path), default: []].append(
                Interface(path: file.path, modules: file.effectiveModules, ids: ids[Int32(i)] ?? []))
        }
        interfaces = byStem
    }

    /// True when `stem` names a storyboard or xib anywhere in the scan.
    public func isInterfaceTable(_ stem: String) -> Bool { interfaces[stem] != nil }

    /// `("abc-12-def", "text")` for an IB-style key, nil otherwise.
    public static func split(_ key: String) -> (id: String, property: String)? {
        guard let dot = key.firstIndex(of: ".") else { return nil }
        let id = key[..<dot], property = key[key.index(after: dot)...]
        guard !id.isEmpty, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }),
              let first = property.first, first.isLetter else { return nil }
        return (String(id), String(property))
    }

    /// For an IB-style key in table `stem` owned by `owners`: the interface file and whether the ID exists there.
    /// Prefers interface files in the same module; nil when the key is not IB-style or no interface matches.
    public func resolve(key: String, stem: String, owners: Set<ModuleID>) -> (path: String, exists: Bool)? {
        guard let candidates = interfaces[stem], let (id, _) = Self.split(key) else { return nil }
        let sameModule = candidates.filter { !$0.modules.isDisjoint(with: owners) }
        let pool = sameModule.isEmpty ? candidates : sameModule
        if let hit = pool.first(where: { $0.ids.contains(id) }) { return (hit.path, true) }
        return (pool[0].path, false)
    }
}
