import Foundation

/// `xcpurge explain <root> <subject>`: runs discovery, indexing and the detectors unfiltered, then explains every
/// finding the subject (an id, a root-relative path or a name) matches, or where an unreported subject is used.
public enum Explainer {
    /// Reference sites listed per match; the rest are counted.
    public static let siteCap = 50

    /// Nothing matched the subject and it is neither a file in the tree nor a referenced name.
    public struct NoMatch: Error, CustomStringConvertible, Sendable {
        public let subject: String
        /// Closest finding names, file names and ids by edit distance.
        public let suggestions: [String]

        public var description: String {
            var text = "nothing matches '\(subject)': not a finding id, a path in the tree or a referenced name"
            if !suggestions.isEmpty { text += ". Did you mean: " + suggestions.joined(separator: ", ") + "?" }
            return text
        }
    }

    public static func explain(subject: String, root: URL, config: Config) async throws -> ExplainReport {
        let engine = ScanEngine(root: root, config: config)
        let context = try await engine.makeContext()
        let raw = DetectorRegistry.detectors(for: Category.scannable).flatMap { $0.run(context) }
        let capped = engine.capForSkippedSources(raw, refs: context.refs)
        let stale = config.staleIgnores
            ? StaleIgnoreDetector.find(unfiltered: capped, context: context, categories: Category.scannable) : []
        let all = Array(Set(capped + stale)).sorted(by: Finding.reportOrder)
        let reported = Set(engine.filter(capped, context: context) + stale)
        let rootPath = context.root.path
        let normalized = normalize(subject, root: rootPath)
        let matched = all.filter { matches(subject, normalized, $0) }
        var explanations: [Explanation] = []
        if matched.isEmpty {
            guard let one = explainUnreported(normalized, context: context) else {
                throw NoMatch(subject: subject, suggestions: suggestions(for: normalized, among: all))
            }
            explanations = [one]
        } else {
            explanations = matched.map { explain($0, reported: reported.contains($0), context: context) }
        }
        return ExplainReport(subject: subject, root: rootPath, matches: explanations)
    }

    // MARK: - Matching

    /// Absolute paths inside the root become root-relative; `./`, `..` and trailing slashes are collapsed.
    static func normalize(_ subject: String, root: String) -> String {
        let trimmed = subject.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("/") {
            let rel = RelPath.relative(trimmed, to: root)
            return rel.hasPrefix("../") ? trimmed : rel
        }
        if trimmed.hasPrefix("./") || trimmed.contains("//") || trimmed.hasSuffix("/") || trimmed.contains("/./") {
            return RelPath.normalize(trimmed)
        }
        return trimmed
    }

    /// A path subject matches the finding at that path, the finding whose unit contains it (a file inside an asset
    /// set) and every finding under it (a folder or catalog lists what it contains).
    static func matches(_ subject: String, _ normalized: String, _ f: Finding) -> Bool {
        if f.id == subject || f.id == normalized { return true }
        if f.path == normalized || RelPath.isUnder(normalized, f.path) { return true }
        if !normalized.isEmpty, RelPath.isUnder(f.path, normalized) { return true }
        if let name = f.name, name == subject || name.lowercased() == normalized.lowercased() { return true }
        let last = RelPath.lastComponent(f.path)
        return last == normalized || RelPath.stem(last) == normalized
    }

    // MARK: - One finding

    static func explain(_ f: Finding, reported: Bool, context: ScanContext) -> Explanation {
        let config = context.config
        let owners = owners(of: f.path, context: context)
        let checked = consumers(of: owners, graph: context.graph)
        let names = candidateNames(f)
        let (sites, truncated) = referenceSites(names, visible: checked, refs: context.refs)
        var e = Explanation(status: .reported, finding: f,
                            owners: owners.sorted().map(\.description),
                            modulesChecked: checked.sorted().map(\.description),
                            visibilityRule: visibilityRule(owners: owners, config: config),
                            referenceSites: sites, referenceSitesTruncated: truncated,
                            dynamicPatterns: dynamicSites(for: f, visible: checked, refs: context.refs),
                            confidence: derivation(f))
        if reported {
            e.status = .reported
        } else if context.ignore.suppresses(f, refs: context.refs, inventory: context.inventory) {
            e.status = .suppressed
            e.suppressedBy = suppressor(of: f, context: context)
        } else if f.confidence < config.minConfidence {
            e.status = .belowThreshold
            e.note = "below --min-confidence \(config.minConfidence.rawValue)"
        } else {
            e.status = .notReported
            let targets = Set(config.targets)
            if !targets.isEmpty, !targets.contains(f.module) {
                e.note = "hidden by --targets (module \(f.module))"
            } else if config.exclude.contains(where: { Glob($0).matches(f.path) }) {
                e.note = "hidden by --exclude"
            } else if ScanEngine.isTestFixture(f, directories: config.testFixtureDirectories) {
                e.note = "snapshot-test fixture folder (testFixtureDirectories); files there are loaded by test name"
            } else {
                e.note = "filtered out of the report"
            }
        }
        e.toMakeSafe = toMakeSafe(f)
        return e
    }

    /// Modules of the inventory file at `path` or of its nearest ancestor (asset sets live inside a catalog unit).
    static func owners(of path: String, context: ScanContext) -> Set<ModuleID> {
        var p = path
        while !p.isEmpty {
            if let file = context.inventory.file(at: p) { return file.effectiveModules }
            p = RelPath.parent(p)
        }
        return [.unknown]
    }

    static func consumers(of owners: Set<ModuleID>, graph: ModuleGraph) -> Set<ModuleID> {
        owners.reduce(into: Set<ModuleID>()) { $0.formUnion(graph.consumers(of: $1)) }
    }

    static func visibilityRule(owners: Set<ModuleID>, config: Config) -> String {
        let names = owners.sorted().map(\.description).joined(separator: ", ")
        var text = "A reference counts when its file belongs to \(names) or to a module that depends on or embeds "
            + "one of them, directly or transitively; files no target builds count everywhere."
        text += config.ignoreTestReferences ? " Test targets do not count (--ignore-test-references)." : " Test targets count."
        return text
    }

    /// The spellings a reference to this finding could take: its name, file stem and the symbols Xcode generates.
    static func candidateNames(_ f: Finding) -> [String] {
        var names: [String] = []
        let last = RelPath.lastComponent(f.path)
        switch f.kind {
        case .unusedAsset:
            if let name = f.name {
                names.append(name)
                let parts = name.split(separator: "/").map(String.init)
                let leaf = parts.last ?? name
                let ext = (last as NSString).pathExtension.lowercased()
                let type = AssetType.byExtension[ext] ?? .image
                names.append(leaf)
                names += AssetSymbolMangler.symbols(leaf: leaf, type: type, namespace: Array(parts.dropLast()))
                if let objc = AssetSymbolMangler.objcSymbol(leaf: leaf, type: type) { names.append(objc) }
            } else {
                names += [RelPath.stem(last), last]
            }
        case .unusedString, .staleString:
            if let key = f.name {
                names.append(key)
                if let symbol = StringSymbolMangler.symbol(forKey: key) { names.append(symbol) }
            }
        case .dynamicLookup, .staleIgnore:
            if let name = f.name { names.append(name) }
        default:
            if let name = f.name { names.append(name) }
            names += [RelPath.stem(last), last]
        }
        var seen = Set<String>()
        return names.filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Exact and case-insensitive sites of every candidate name, sorted, capped at `siteCap`.
    static func referenceSites(_ names: [String], visible: Set<ModuleID>, refs: ReferenceIndex)
        -> (sites: [Explanation.ReferenceSite], truncated: Int) {
        var out = Set<Explanation.ReferenceSite>()
        for name in names {
            let exact = refs.sites(name)
            for r in exact { out.insert(site(r, exact: true, visible: visible, refs: refs)) }
            let exactSet = Set(exact)
            for r in refs.sites(name, caseInsensitive: true) where !exactSet.contains(r) {
                out.insert(site(r, exact: false, visible: visible, refs: refs))
            }
        }
        let sorted = out.sorted { a, b in
            (a.path, a.line, a.value, a.kind) < (b.path, b.line, b.value, b.kind)
        }
        return (Array(sorted.prefix(siteCap)), max(0, sorted.count - siteCap))
    }

    static func site(_ r: Reference, exact: Bool, visible: Set<ModuleID>, refs: ReferenceIndex) -> Explanation.ReferenceSite {
        Explanation.ReferenceSite(path: refs.path(of: r.file), line: Int(r.line),
                                  module: refs.modules(of: r.file).sorted().first?.description ?? ModuleID.unknown.name,
                                  visible: refs.isVisible(r.file, visible), kind: describe(r.kind), exact: exact,
                                  value: r.value)
    }

    static func describe(_ kind: RefKind) -> String {
        switch kind {
        case .stringLiteral: "stringLiteral"
        case .memberSymbol: "memberSymbol"
        case .identifier: "identifier"
        case .ibAttribute(let attr): "ibAttribute(\(attr))"
        case .plistValue: "plistValue"
        case .buildSetting(let key): "buildSetting(\(key))"
        case .accessorUse(let path): "accessorUse(\(path))"
        }
    }

    /// Runtime-built names that could produce the finding's name (keyless localization calls count for strings).
    static func dynamicSites(for f: Finding, visible: Set<ModuleID>, refs: ReferenceIndex) -> [Explanation.DynamicSite] {
        guard f.kind != .dynamicLookup, f.kind != .staleIgnore else { return [] }
        let name = f.name ?? RelPath.stem(RelPath.lastComponent(f.path))
        let hits = refs.dynamicPatterns.filter { p in
            p.isKeyless ? (f.category == .strings && p.domain == .string) : p.couldBuild(name)
        }
        let sites = hits.map { p in
            Explanation.DynamicSite(path: refs.path(of: p.file), line: Int(p.line),
                                    module: refs.modules(of: p.file).sorted().first?.description ?? ModuleID.unknown.name,
                                    pattern: p.segments.joined(separator: "…"), domain: p.domain.rawValue,
                                    visible: refs.isVisible(p.file, visible))
        }
        return Array(Set(sites).sorted { ($0.path, $0.line, $0.pattern) < ($1.path, $1.line, $1.pattern) }.prefix(siteCap))
    }

    static func derivation(_ f: Finding) -> Explanation.ConfidenceDerivation {
        let base: String
        switch f.kind {
        case .dynamicLookup: base = "base: dynamic-lookup is informational and always low"
        case .staleIgnore: base = "base: set by the stale-ignore check (glob medium, kind/module high, asset/string low)"
        case .duplicate: base = "base: duplicate starts at high (byte-identical content)"
        default:
            base = "base: \(f.kind.flagName) starts at high when no visible reference exists; a weak hint lowers it to "
                + "medium, a runtime-built name, previews-only use or public library API to low"
        }
        return .init(value: f.confidence.rawValue,
                     derivation: [base] + f.reasons.map { "\(ReasonCodes.classify($0)): \($0)" })
    }

    static func toMakeSafe(_ f: Finding) -> [String] {
        if f.kind == .dynamicLookup {
            return ["Nothing to remove: this marks a site whose runtime-built name lowers the confidence of matching findings."]
        }
        var out = ReasonCodes.codes(for: f).map { ReasonCodes.entry(for: $0).toMakeSafe }
        if f.kind == .staleIgnore { return out }
        if f.confidence == .high {
            out.append("Remove with `xcpurge remove <root> <path>`, build every scheme and configuration, run the tests; "
                + "`xcpurge restore <root>` undoes it.")
        } else {
            out.append("Do not remove until each reason above is checked; a green build does not prove a runtime-built "
                + "name or a convention-loaded file unused.")
        }
        return out
    }

    /// Which rule or marker hides the finding: the inline marker on its line, else the last matching
    /// `.xcpurgeignore` line (re-read here so the line number can be shown).
    static func suppressor(of f: Finding, context: ScanContext) -> String {
        if let line = f.line, let index = context.inventory.index(of: f.path),
           context.refs.isIgnored(file: Int32(index), line: Int32(line)) {
            return "\(f.path):\(line) xcpurge:ignore marker"
        }
        let url = context.root.appendingPathComponent(Ignore.fileName)
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return "\(Ignore.fileName) rule" }
        var winner: (line: Int, text: String)?
        for (i, raw) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let negated = line.hasPrefix("!")
            let rule = negated ? String(line.dropFirst()) : line
            guard Ignore(contents: rule).suppresses(f) else { continue }
            winner = negated ? nil : (i + 1, line)
        }
        guard let winner else { return "\(Ignore.fileName) rule" }
        return "\(Ignore.fileName):\(winner.line) \(winner.text)"
    }

    // MARK: - Subjects no detector reports

    /// A file, folder, asset set or name that exists or is referenced: where it is used. Nil when the subject is
    /// neither in the tree nor referenced anywhere.
    static func explainUnreported(_ subject: String, context: ScanContext) -> Explanation? {
        let inventory = context.inventory
        let isFile = inventory.file(at: subject) != nil || !inventory.indices(under: subject).isEmpty
        var onDisk = isFile || FileManager.default.fileExists(atPath: context.url(for: subject).path)
        var path = subject
        var names = [subject]
        // A bare asset name: find its set in the catalogs, so owners and symbols come from the real set.
        if !onDisk, let asset = catalogAsset(named: subject, context: context) {
            onDisk = true
            path = asset.path
            names = [asset.name, asset.leaf] + asset.aliases
                + AssetSymbolMangler.symbols(leaf: asset.leaf, type: asset.type, namespace: asset.namespace)
            if let objc = AssetSymbolMangler.objcSymbol(leaf: asset.leaf, type: asset.type) { names.append(objc) }
        } else if onDisk {
            let last = RelPath.lastComponent(subject)
            names = [RelPath.stem(last), last]
            let ext = (last as NSString).pathExtension.lowercased()
            if let type = AssetType.byExtension[ext] {
                let leaf = RelPath.stem(last)
                names += AssetSymbolMangler.symbols(leaf: leaf, type: type)
                if let objc = AssetSymbolMangler.objcSymbol(leaf: leaf, type: type) { names.append(objc) }
            }
        } else {
            names += AssetSymbolMangler.symbols(leaf: RelPath.lastComponent(subject))
            if let objc = AssetSymbolMangler.objcSymbol(leaf: RelPath.lastComponent(subject), type: .image) { names.append(objc) }
            if let symbol = StringSymbolMangler.symbol(forKey: subject) { names.append(symbol) }
        }
        var seen = Set<String>()
        names = names.filter { !$0.isEmpty && seen.insert($0).inserted }
        let owners = onDisk ? owners(of: path, context: context) : [ModuleID.unknown]
        let checked = consumers(of: owners, graph: context.graph)
        let (sites, truncated) = referenceSites(names, visible: checked, refs: context.refs)
        guard onDisk || !sites.isEmpty else { return nil }
        let visibleCount = sites.filter(\.visible).count
        let what = onDisk ? "\(path) is in the tree" : "not a file in the tree"
        return Explanation(status: .notReported, note: "\(what); \(visibleCount) visible reference\(visibleCount == 1 ? "" : "s"), "
                           + "\(sites.count + truncated) in total; no detector reports it",
                           owners: owners.sorted().map(\.description), modulesChecked: checked.sorted().map(\.description),
                           visibilityRule: visibilityRule(owners: owners, config: context.config),
                           referenceSites: sites, referenceSitesTruncated: truncated,
                           toMakeSafe: ["Nothing to do: it is referenced (see the sites) or no detector covers it."])
    }

    /// The catalog entry whose lookup name (or leaf) is `name`, searching every `.xcassets` in the inventory.
    static func catalogAsset(named name: String, context: ScanContext) -> CatalogAsset? {
        for unit in context.inventory.files where unit.kind == .assetCatalog {
            let assets = AssetCatalogReader.read(catalog: unit.path, root: context.root)
            if let hit = assets.first(where: { $0.name == name }) ?? assets.first(where: { $0.leaf == name }) { return hit }
        }
        return nil
    }

    /// The three closest finding names, file names and ids by edit distance.
    static func suggestions(for subject: String, among findings: [Finding]) -> [String] {
        var candidates = Set<String>()
        for f in findings {
            candidates.insert(f.id)
            candidates.insert(RelPath.lastComponent(f.path))
            if let name = f.name { candidates.insert(name) }
        }
        let lowered = subject.lowercased()
        let ranked = candidates.map { ($0, editDistance(lowered, $0.lowercased())) }
            .filter { $0.1 < max(subject.count, $0.0.count) }
            .sorted { ($0.1, $0.0) < ($1.1, $1.0) }
        return ranked.prefix(3).map(\.0)
    }

    static func editDistance(_ a: String, _ b: String) -> Int {
        let a = Array(a), b = Array(b)
        if a.isEmpty { return b.count }
        if b.isEmpty { return a.count }
        var prev = Array(0...b.count), cur = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            cur[0] = i
            for j in 1...b.count {
                cur[j] = min(prev[j] + 1, cur[j - 1] + 1, prev[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1))
            }
            swap(&prev, &cur)
        }
        return prev[b.count]
    }

    // MARK: - Text

    public static func renderText(_ report: ExplainReport) -> String {
        var lines = ["\(report.subject): \(report.matches.count) match\(report.matches.count == 1 ? "" : "es")"]
        for e in report.matches {
            lines.append("")
            if let f = e.finding {
                lines.append("## \(f.id) · \(e.status.rawValue) · \(f.confidence.rawValue)")
                var head = "kind: \(f.kind.flagName) · path: \(f.path)"
                if let line = f.line, line > 0 { head += ":\(line)" }
                if let name = f.name, name != f.path { head += " · name: \(name)" }
                head += " · module: \(f.module)"
                lines.append(head)
            } else {
                lines.append("## \(report.subject) · \(e.status.rawValue)")
            }
            if let by = e.suppressedBy { lines.append("suppressed by: \(by)") }
            if let note = e.note { lines.append("note: \(note)") }
            lines.append("owners: " + e.owners.joined(separator: ", "))
            lines.append("modules checked (\(e.modulesChecked.count)): " + e.modulesChecked.joined(separator: ", "))
            lines.append("visibility rule: \(e.visibilityRule)")
            let total = e.referenceSites.count + e.referenceSitesTruncated
            lines.append("reference sites (\(total)):" + (total == 0 ? " none" : ""))
            for s in e.referenceSites {
                lines.append("  - \(s.path):\(s.line) \(s.module) \(s.visible ? "visible" : "not visible") \(s.kind) "
                    + "\"\(s.value)\"" + (s.exact ? "" : " (case differs)"))
            }
            if e.referenceSitesTruncated > 0 { lines.append("  … \(e.referenceSitesTruncated) more") }
            lines.append("dynamic patterns (\(e.dynamicPatterns.count)):" + (e.dynamicPatterns.isEmpty ? " none" : ""))
            for d in e.dynamicPatterns {
                lines.append("  - \(d.path):\(d.line) \(d.module) \(d.visible ? "visible" : "not visible") \(d.domain) \"\(d.pattern)\"")
            }
            if let c = e.confidence {
                lines.append("confidence: \(c.value)")
                for step in c.derivation { lines.append("  \(step)") }
            }
            if !e.toMakeSafe.isEmpty {
                lines.append("to make this safe:")
                for step in e.toMakeSafe { lines.append("  - \(step)") }
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    public static func renderJSON(_ report: ExplainReport) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(report)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
