import Foundation

/// Reference lookups shared by the asset, loose-image and font checks: visibility-filtered name, symbol and
/// fuzzy matches, plus the dynamic-name downgrade of plan §4.7.
struct AssetReferenceResolver: Sendable {
    /// Why something counts as used, and how strong that evidence is.
    struct Evidence: Sendable {
        var strength: Confidence
        var reason: String
    }

    /// Strongest dynamic-pattern match for a candidate.
    struct Downgrade: Sendable {
        var confidence: Confidence
        var reason: String
        var pattern: DynamicPattern
    }

    let refs: ReferenceIndex
    let graph: ModuleGraph
    /// Fuzzy key of member symbols -> files using them.
    private let fuzzyMembers: [String: [Int32]]
    /// Lowercased last component and stem of path-like name references -> reference indices.
    private let pathTails: [String: [Int]]
    /// Non-keyless dynamic patterns not on an `xcpurge:ignore` line.
    let patterns: [DynamicPattern]

    init(_ ctx: ScanContext) {
        let refs = ctx.refs
        self.refs = refs
        self.graph = ctx.graph
        var fuzzy: [String: [Int32]] = [:], tails: [String: [Int]] = [:]
        for (i, r) in refs.references.enumerated() {
            if r.kind == .memberSymbol {
                fuzzy[AssetSymbolMangler.fuzzyKey(r.value), default: []].append(r.file)
            } else if RefKindMask.names.contains(r.kind.mask), r.value.contains("/") {
                let last = RelPath.lastComponent(r.value).lowercased()
                tails[last, default: []].append(i)
                let stem = RelPath.stem(last)
                if stem != last { tails[stem, default: []].append(i) }
            }
        }
        fuzzyMembers = fuzzy
        pathTails = tails
        patterns = refs.dynamicPatterns.filter { !$0.isKeyless && !refs.isIgnored(file: $0.file, line: $0.line) }
    }

    /// Union of `consumers(of:)` over the owning modules (plan §4.2).
    func consumers(of owners: Set<ModuleID>) -> Set<ModuleID> {
        (owners.isEmpty ? [ModuleID.unknown] : owners).reduce(into: Set<ModuleID>()) { $0.formUnion(graph.consumers(of: $1)) }
    }

    /// True when a reference in `file` counts for a resource visible to `visible`.
    func counts(_ file: Int32, _ visible: Set<ModuleID>) -> Bool {
        refs.isVisible(file, visible)
    }

    func location(_ file: Int32, _ line: Int32) -> String {
        line > 0 ? "\(refs.path(of: file)):\(line)" : refs.path(of: file)
    }

    /// Exact (high), case-insensitive (medium) or path-tail (medium) match of any name in a name-carrying reference.
    /// - Parameter excluding: references that must not count (e.g. the `UIAppFonts` declaration itself).
    func nameEvidence(_ names: [String], visible: Set<ModuleID>,
                      excluding: (Reference) -> Bool = { _ in false }) -> Evidence? {
        for name in names {
            if let r = refs.sites(name, kinds: .names).first(where: { counts($0.file, visible) && !excluding($0) }) {
                return Evidence(strength: .high, reason: "referenced as \"\(name)\" at \(location(r.file, r.line))")
            }
        }
        for name in names {
            if let r = refs.sites(name, kinds: .names, caseInsensitive: true)
                .first(where: { counts($0.file, visible) && !excluding($0) }) {
                return Evidence(strength: .medium,
                                reason: "referenced as \"\(r.value)\" (case differs) at \(location(r.file, r.line))")
            }
        }
        for name in names {
            for i in pathTails[name.lowercased()] ?? [] {
                let r = refs.references[i]
                if counts(r.file, visible), !excluding(r) {
                    return Evidence(strength: .medium, reason: "referenced by path \"\(r.value)\" at \(location(r.file, r.line))")
                }
            }
        }
        return nil
    }

    /// Review #9: a lookup without a bundle argument in a module the owning app depends on reads `Bundle.main`, i.e.
    /// the app's own resources (`Image("brandLogo")` in a design-system package). Medium evidence at best.
    func mainBundleEvidence(_ names: [String], owners: Set<ModuleID>) -> Evidence? {
        let reach = graph.mainBundleReach(of: owners)
        guard !reach.isEmpty else { return nil }
        for name in names {
            for r in refs.sites(name, kinds: .stringLiteral) where refs.isVisible(r.file, reach) {
                guard let context = r.context, context.isAssetLookup,
                      context.bundle == nil || LocalizationCallClassifier.bundle(context) == .main else { continue }
                let module = refs.modules(of: r.file).intersection(reach).sorted().first?.name ?? "a dependency"
                return Evidence(strength: .medium, reason: "referenced from \(module) without a bundle at "
                    + "\(location(r.file, r.line)); resolves to the main bundle at runtime")
            }
        }
        return nil
    }

    /// Generated-symbol use: Swift member symbols (`.brandMark`, `ImageResource.hero`) or ObjC identifiers.
    func symbolEvidence(swift: [String], objc: [String], visible: Set<ModuleID>, strength: Confidence) -> Evidence? {
        for symbol in swift {
            let member = String(symbol.split(separator: ".").last ?? Substring(symbol))
                .trimmingCharacters(in: CharacterSet(charactersIn: "`"))
            if let r = refs.sites(member, kinds: .memberSymbol).first(where: { counts($0.file, visible) }) {
                return Evidence(strength: strength, reason: "generated symbol .\(symbol) at \(location(r.file, r.line))")
            }
        }
        for symbol in objc {
            if let r = refs.sites(symbol, kinds: .identifier).first(where: { counts($0.file, visible) }) {
                return Evidence(strength: strength, reason: "generated symbol \(symbol) at \(location(r.file, r.line))")
            }
        }
        return nil
    }

    /// Member symbol equal to the name once lowercased with separators removed.
    func fuzzyEvidence(_ name: String, visible: Set<ModuleID>) -> Evidence? {
        let key = AssetSymbolMangler.fuzzyKey(name)
        guard !key.isEmpty, let file = fuzzyMembers[key]?.first(where: { counts($0, visible) }) else { return nil }
        return Evidence(strength: .low, reason: "member symbol loosely matching \"\(name)\" in \(refs.path(of: file))")
    }

    /// True when `identifier` appears as an identifier or member symbol visible to `visible`.
    func mentions(_ identifier: String, visible: Set<ModuleID>) -> Bool {
        refs.sites(identifier, kinds: .symbols).contains { counts($0.file, visible) }
    }

    /// Plan §4.7 step 3: the most severe downgrade any visible pattern implies for `names`.
    /// - Parameter domains: pattern domains that load this kind of resource; `.any` patterns always apply.
    func downgrade(_ names: [String], visible: Set<ModuleID>, domains: Set<DynamicPattern.Domain>) -> Downgrade? {
        var best: Downgrade?
        for p in patterns where domains.contains(p.domain) || p.domain == .any {
            let literal = p.prefix.count + p.suffix.count
            let matches = p.domain == .any ? literal >= 3 : literal >= 1
            guard matches, counts(p.file, visible) else { continue }
            let prefix = p.prefix.lowercased(), suffix = p.suffix.lowercased()
            guard names.contains(where: { n in
                let l = n.lowercased()
                return l.count > literal && l.hasPrefix(prefix) && l.hasSuffix(suffix)
            }) else { continue }
            let confidence: Confidence = p.domain == .any ? .medium : .low
            if best == nil || confidence < best!.confidence {
                best = Downgrade(confidence: confidence,
                                 reason: "may be built dynamically at \(location(p.file, p.line)) (\"\(p.prefix)…\(p.suffix)\")",
                                 pattern: p)
            }
        }
        return best
    }
}
