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
    /// Asset lookups whose name is a variable (`UIImage(named: entityName)`), not on an `xcpurge:ignore` line.
    let keylessLookups: [DynamicPattern]
    /// `patterns` with their lowercased literal parts, computed once.
    private let shapes: [PatternShape]
    /// Indices of patterns with a constant prefix (they apply in any module), keyed by the prefix's first one to three
    /// lowercased characters; a name looks up its own first one, two and three characters.
    private let prefixedIndex: [String: [Int]]
    /// Indices of patterns that apply only from visible modules (no constant prefix, no anchored main-bundle suffix).
    private let visibleOnly: [Int]
    /// Indices of anchored-suffix patterns that read the main bundle (they apply in any module), keyed by the last
    /// one to three lowercased characters of the suffix; a name looks up its own last three.
    private let suffixIndex: [String: [Int]]
    /// Explicit raw values of `String` enums (`case red = "AppIcon-Red"`), for `"\(iconName)-Preview"` style affix patterns.
    private let rawValues: Set<String>

    /// One dynamic pattern prepared for matching against many names.
    private struct PatternShape: Sendable {
        var prefix: String
        var suffix: String
        var literal: Int
        var matches: Bool
        var prefixed: Bool
        /// A distinctive literal suffix on a lookup that reads the main bundle: applies in any module.
        var anchored: Bool
    }

    init(_ ctx: ScanContext) {
        let refs = ctx.refs
        self.refs = refs
        self.graph = ctx.graph
        var fuzzy: [String: [Int32]] = [:], tails: [String: [Int]] = [:], raw = Set<String>()
        for (i, r) in refs.references.enumerated() {
            if r.kind == .memberSymbol {
                fuzzy[AssetSymbolMangler.fuzzyKey(r.value), default: []].append(r.file)
            } else if r.kind == .stringLiteral, r.context?.label == "rawValue", r.context?.callee?.hasPrefix("enum ") == true {
                raw.insert(r.value)
            } else if RefKindMask.names.contains(r.kind.mask), r.value.contains("/") {
                let last = RelPath.lastComponent(r.value).lowercased()
                tails[last, default: []].append(i)
                let stem = RelPath.stem(last)
                if stem != last { tails[stem, default: []].append(i) }
            }
        }
        fuzzyMembers = fuzzy
        pathTails = tails
        rawValues = raw
        patterns = refs.dynamicPatterns.filter { !$0.isKeyless && !refs.isIgnored(file: $0.file, line: $0.line) }
        var shapes: [PatternShape] = [], index: [String: [Int]] = [:], visibleOnly: [Int] = []
        var suffixes: [String: [Int]] = [:]
        for (i, p) in patterns.enumerated() {
            let literal = p.prefix.count + p.suffix.count
            // OSS scan #3a: a constant prefix (`"avatar_\(rawValue)"`) builds names whatever module the site is in.
            let prefixed = p.prefix.count >= (p.domain == .any ? 3 : 1)
            // OSS scan #4: `code.lowercased() + "-large"` builds names whatever module the site is in, as long as the
            // lookup reads the main bundle; `.module`, `#bundle` and other bundles never reach another module's catalog.
            let anchored = !prefixed && p.hasAnchoredSuffix && p.context.map {
                [.none, .main].contains(LocalizationCallClassifier.bundle($0))
            } ?? true
            let shape = PatternShape(prefix: p.prefix.lowercased(), suffix: p.suffix.lowercased(), literal: literal,
                                     matches: p.domain == .any ? literal >= 3 : literal >= 1,
                                     prefixed: prefixed, anchored: anchored)
            shapes.append(shape)
            if prefixed {
                index[String(shape.prefix.prefix(3)), default: []].append(i)
            } else if anchored {
                suffixes[String(shape.suffix.suffix(3)), default: []].append(i)
            } else {
                visibleOnly.append(i)
            }
        }
        self.shapes = shapes
        self.prefixedIndex = index
        self.visibleOnly = visibleOnly
        self.suffixIndex = suffixes
        keylessLookups = refs.dynamicPatterns.filter {
            $0.isKeyless && $0.domain == .asset && !refs.isIgnored(file: $0.file, line: $0.line)
        }
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

    /// Indices (in pattern order) of the patterns that apply to `names` as seen from `visible`: right domain, enough
    /// literal text, visible or module-independent, and shaped like one of the names.
    private func applicablePatterns(_ names: [String], visible: Set<ModuleID>, domains: Set<DynamicPattern.Domain>) -> [Int] {
        let lowered = names.map { $0.lowercased() }
        var candidates = Set(visibleOnly)
        for name in lowered {
            for k in 1...3 where name.count >= k {
                candidates.formUnion(prefixedIndex[String(name.prefix(k))] ?? [])
                candidates.formUnion(suffixIndex[String(name.suffix(k))] ?? [])
            }
        }
        return candidates.sorted().filter { i in
            let p = patterns[i], shape = shapes[i]
            guard domains.contains(p.domain) || p.domain == .any else { return false }
            guard shape.matches, shape.prefixed || shape.anchored || counts(p.file, visible) else { return false }
            return lowered.contains { l in l.count > shape.literal && l.hasPrefix(shape.prefix) && l.hasSuffix(shape.suffix) }
        }
    }

    /// OSS scan #4: `"\(iconName)-Preview"` with `enum AppIconOption: String { case red = "AppIcon-Red" }` builds
    /// `AppIcon-Red-Preview`: a two-part pattern whose dynamic middle is a raw value of some `String` enum.
    func enumAffixMatch(_ names: [String], visible: Set<ModuleID>, domains: Set<DynamicPattern.Domain>) -> Evidence? {
        guard !rawValues.isEmpty else { return nil }
        for i in applicablePatterns(names, visible: visible, domains: domains) {
            let p = patterns[i], shape = shapes[i]
            guard p.segments.count == 2 else { continue }
            for name in names where name.count > shape.literal {
                let lowered = name.lowercased()
                guard lowered.hasPrefix(shape.prefix), lowered.hasSuffix(shape.suffix) else { continue }
                let middle = String(name.dropFirst(shape.prefix.count).dropLast(shape.suffix.count))
                if rawValues.contains(middle) {
                    return Evidence(strength: .high, reason: "built from enum raw value \"\(middle)\" at \(location(p.file, p.line))")
                }
            }
        }
        return nil
    }

    /// Plan §4.7 step 3: the most severe downgrade any visible pattern implies for `names`.
    /// - Parameter domains: pattern domains that load this kind of resource; `.any` patterns always apply.
    func downgrade(_ names: [String], visible: Set<ModuleID>, domains: Set<DynamicPattern.Domain>) -> Downgrade? {
        var best: Downgrade?
        // Candidates in pattern order (the first most severe match wins, as before the index existed).
        for i in applicablePatterns(names, visible: visible, domains: domains) {
            let p = patterns[i], shape = shapes[i]
            let confidence: Confidence = p.domain == .any && !shape.prefixed && !shape.anchored ? .medium : .low
            if best == nil || confidence < best!.confidence {
                best = Downgrade(confidence: confidence,
                                 reason: "may be built dynamically at \(location(p.file, p.line)) (\"\(p.prefix)…\(p.suffix)\")",
                                 pattern: p)
            }
        }
        // OSS scan #3b: `generateAnimation(with: "pause-animation-", …)` appends the rest at runtime, in any module.
        if best?.confidence != .low,
           let r = names.lazy.compactMap({ refs.separatorPrefix(of: $0) }).first(where: { !refs.isIgnored(file: $0.file, line: $0.line) }) {
            best = Downgrade(confidence: .low, reason: "may be built dynamically at \(location(r.file, r.line)) (\"\(r.value)…\")",
                             pattern: DynamicPattern(prefix: r.value, suffix: "", file: r.file, line: r.line, domain: .any,
                                                     context: r.context))
        }
        return best
    }

    /// OSS scan #3e: an asset lookup whose name is a variable, in one of `owners`, or in a module in `reach`
    /// (`graph.mainBundleReach(of: owners)`) when it reads the main bundle.
    func keylessLookup(in owners: Set<ModuleID>, reach: Set<ModuleID> = []) -> DynamicPattern? {
        keylessLookups.first { p in
            let sites = refs.modules(of: p.file)
            if !sites.isDisjoint(with: owners) { return true }
            guard !reach.isEmpty, !sites.isDisjoint(with: reach) else { return false }
            return p.context.map { [.none, .main].contains(LocalizationCallClassifier.bundle($0)) } ?? true
        }
    }
}
