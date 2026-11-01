/// OSS scan #1: an exact reference in a module the visibility rule does not count (a framework or package the app
/// links, a sibling target). At runtime a lookup there still resolves through the main bundle, so the match caps the
/// finding instead of being ignored: low when it is the argument of a main-bundle lookup, medium otherwise.
public struct UnseenMatch: Sendable {
    public var reference: Reference
    /// The name argument of a lookup that reads `Bundle.main` (no bundle argument, `nil` or `.main`).
    public var isMainBundleLookup: Bool

    public var confidence: Confidence { isMainBundleLookup ? .low : .medium }
}

extension ReferenceIndex {
    /// The strongest exact match of any name outside `visible`: a main-bundle lookup first, else the first other match.
    /// Lookups that pass another bundle (`.module`, `#bundle`) target that module's own resources and never count.
    /// - Parameters:
    ///   - isLookup: true when a literal's call context is the lookup API for this kind of resource.
    ///   - accept: references that may count (e.g. not the resource's own file, not a declaration).
    func unseenMatch(_ names: [String], kinds: RefKindMask = .names, visible: Set<ModuleID>,
                     isLookup: (CallContext) -> Bool, accept: (Reference) -> Bool = { _ in true }) -> UnseenMatch? {
        var plain: Reference?
        for name in names {
            for r in sites(name, kinds: kinds) where !isVisible(r.file, visible) && accept(r) {
                if r.kind == .stringLiteral, let context = r.context, isLookup(context) {
                    switch LocalizationCallClassifier.bundle(context) {
                    case .none, .main: return UnseenMatch(reference: r, isMainBundleLookup: true)
                    case .module: continue
                    case .other: break
                    }
                }
                if plain == nil { plain = r }
            }
        }
        return plain.map { UnseenMatch(reference: $0, isMainBundleLookup: false) }
    }

    /// The finding reason for a match; `owner` names the module whose resource it is.
    func reason(for match: UnseenMatch, owner: String) -> String {
        let r = match.reference
        let site = r.line > 0 ? "\(path(of: r.file)):\(r.line)" : path(of: r.file)
        let module = modules(of: r.file).sorted().first?.name ?? ModuleID.unknown.name
        guard match.isMainBundleLookup else {
            return "exact match \"\(r.value)\" at \(site) in \(module), a module that cannot see \(owner)"
        }
        let how = r.context?.bundle == nil ? "without a bundle" : "with the main bundle"
        return "referenced from \(module) \(how) at \(site); resolves to the main bundle at runtime"
    }
}
