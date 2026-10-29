// LANE: B
import Foundation

/// Unused and stale localized strings in `.xcstrings` / `.strings` / `.stringsdict` (plan §4.6, §4.7).
/// Tables are grouped by (owning modules, stem) so `.lproj` variants count once; each key is checked against
/// visible references (consumers of the owning module), narrowed by `tableName:` and `bundle:` (§4.2 step 5).
public struct StringsDetector: Detector {
    public init() {}

    public var category: Category { .strings }

    public func run(_ ctx: ScanContext) -> [Finding] {
        let evaluator = Evaluator(ctx)
        let tables = loadTables(ctx)
        var findings = tables.flatMap { table in
            table.keys.keys.sorted().compactMap { evaluator.evaluate(table.keys[$0]!, in: table) }
        }
        findings += settingsBundleFindings(ctx)
        findings += dynamicLookupFindings(ctx, tables: tables, evaluator: evaluator)
        return findings
    }

    // MARK: - Tables

    /// One key of a table, at its preferred file (catalog, then `Base`/`en` `.lproj`, then path order).
    struct TableKey {
        var key: String
        var path: String
        var line: Int?
        var state: String?
        var isCatalog: Bool
        var rank: (Int, Int, String)
    }

    struct Table {
        var stem: String
        var owners: Set<ModuleID>
        var keys: [String: TableKey] = [:]
    }

    static func lprojRank(_ path: String) -> Int {
        switch RelPath.lastComponent(RelPath.parent(path)) {
        case "Base.lproj": 0
        case "en.lproj": 1
        default: 2
        }
    }

    func loadTables(_ ctx: ScanContext) -> [Table] {
        var tables: [String: Table] = [:]
        for file in ctx.inventory.files where !file.isUnit {
            guard [.stringCatalog, .strings, .stringsdict].contains(file.kind) else { continue }
            guard let data = FileManager.default.contents(atPath: ctx.url(for: file.path).path) else {
                ctx.diagnostics.warn("cannot read file", path: file.path)
                continue
            }
            var entries: [(key: String, line: Int?, state: String?)] = []
            switch file.kind {
            case .stringCatalog:
                do {
                    entries = try StringCatalogReader.read(data).entries.map { ($0.key, $0.line, $0.extractionState) }
                } catch {
                    ctx.diagnostics.warn("cannot read string catalog: \(error)", path: file.path)
                    continue
                }
            default:
                let keys = file.kind == .strings ? StringsFileReader.keys(data) : StringsDictReader.keys(data)
                guard let keys else {
                    ctx.diagnostics.warn("cannot parse \(file.kind.rawValue) file", path: file.path)
                    continue
                }
                entries = keys.map { ($0.key, $0.value, nil) }
            }
            let owners = file.effectiveModules
            let stem = RelPath.stem(file.path)
            let id = owners.sorted().map(\.description).joined(separator: ",") + "|" + stem
            var table = tables[id] ?? Table(stem: stem, owners: owners)
            let isCatalog = file.kind == .stringCatalog
            let rank = (isCatalog ? 0 : 1, Self.lprojRank(file.path), file.path)
            for e in entries {
                let candidate = TableKey(key: e.key, path: file.path, line: e.line, state: e.state, isCatalog: isCatalog, rank: rank)
                if let existing = table.keys[e.key], existing.rank <= rank { continue }
                table.keys[e.key] = candidate
            }
            tables[id] = table
        }
        return tables.keys.sorted().map { tables[$0]! }
    }

    // MARK: - Evaluation

    struct Evidence {
        var strong = false
        var weak: [String] = []
    }

    enum Match {
        case strong
        case weak(String)
        case none
    }

    struct Evaluator {
        let ctx: ScanContext
        let macros: [String]
        let ib: IBStringsResolver
        let intentStems: Set<String>
        /// Non-keyless patterns that may build string keys (§4.7: string domain, plus `any`).
        let patterns: [DynamicPattern]

        init(_ ctx: ScanContext) {
            self.ctx = ctx
            macros = ctx.config.localizationMacros
            ib = IBStringsResolver(ctx)
            intentStems = Set(ctx.inventory.files(of: .intentDefinition).map { RelPath.stem($0.path) })
            patterns = ctx.refs.dynamicPatterns.filter { $0.hasLiteralText && ($0.domain == .string || $0.domain == .any) }
        }

        func site(_ file: Int32, _ line: Int32) -> String { "\(ctx.refs.path(of: file)):\(line)" }

        func visible(_ table: Table) -> Set<ModuleID> {
            table.owners.reduce(into: Set<ModuleID>()) { $0.formUnion(ctx.graph.consumers(of: $1)) }
        }

        /// True when an owner's resources live in `Bundle.main` (apps, extensions, unattributed files).
        func ownsMainBundle(_ table: Table) -> Bool {
            table.owners.contains { (ctx.graph.module($0)?.resourceBundleAccess ?? .main) == .main }
        }

        func evaluate(_ entry: TableKey, in table: Table) -> Finding? {
            let key = entry.key
            if key.isEmpty || StringSymbolMangler.isFormatOnly(key) { return nil }
            if SystemStringKeys.systemTables.contains(table.stem) || intentStems.contains(table.stem) { return nil }
            let infoPlist = SystemStringKeys.isInfoPlistTable(table.stem)
            if infoPlist {
                if SystemStringKeys.isSystemKey(key) { return nil }
                let terms = table.owners.reduce(into: Set<String>()) {
                    $0.formUnion(SystemStringKeys.infoPlistTerms(ctx.graph.module($1)?.infoPlist ?? [:]))
                }
                if terms.contains(key) { return nil }
            }
            func finding(_ kind: FindingKind, _ confidence: Confidence, _ reasons: [String]) -> Finding {
                Finding(kind: kind, category: .strings, path: entry.path, line: entry.line, name: key,
                        module: ctx.moduleName(for: entry.path), confidence: confidence, reasons: reasons)
            }
            if let hit = ib.resolve(key: key, stem: table.stem, owners: table.owners) {
                if hit.exists { return nil }
                let id = IBStringsResolver.split(key)?.id ?? key
                return finding(.unusedString, .high, ["object ID \(id) no longer exists in \(hit.path)"])
            }

            let visibleModules = visible(table)
            let ev = evidence(entry, table, visibleModules)
            var result: Finding
            if entry.state == "stale" {
                result = ev.strong || !ev.weak.isEmpty
                    ? finding(.staleString, .medium, ["Xcode marked this key stale, but a reference was found"] + ev.weak)
                    : finding(.staleString, .high, ["Xcode marked this key stale (no longer found in source)"])
            } else if ev.strong {
                return nil
            } else if !ev.weak.isEmpty {
                result = finding(.unusedString, .medium, ev.weak)
            } else if infoPlist {
                result = finding(.unusedString, .medium, ["not a known Info.plist key and not referenced"])
            } else if entry.state == "extracted_with_value" {
                result = finding(.unusedString, .medium, ["no reference found; Xcode will mark it stale on the next build"])
            } else if StringSymbolMangler.hasFormatSpecifiers(key) {
                // Interpolated uses are matched by their literal segments only; never certain enough to prune.
                result = finding(.unusedString, .medium, ["no reference found; format keys are matched only by literal text"])
            } else {
                result = finding(.unusedString, .high, ["no reference found"])
            }
            downgrade(&result, key: key, table: table, visibleModules)
            return result
        }

        func evidence(_ entry: TableKey, _ table: Table, _ visibleModules: Set<ModuleID>) -> Evidence {
            var ev = Evidence()
            let refs = ctx.refs
            for r in refs.sites(entry.key, kinds: .names) where refs.isVisible(r.file, visibleModules) {
                switch r.kind {
                case .accessorUse:
                    ev.strong = true
                case .stringLiteral where LocalizationCallClassifier.isLocalization(r.context, extraMacros: macros):
                    switch literalMatch(r, table) {
                    case .strong: ev.strong = true
                    case .weak(let reason): ev.weak.append(reason)
                    case .none: break
                    }
                case .stringLiteral:
                    ev.weak.append("\(site(r.file, r.line)) has the key as a string literal outside a localization call")
                default:
                    ev.weak.append("\(site(r.file, r.line)) names the key outside code")
                }
                if ev.strong { return ev }
            }
            // Generated symbols (STRING_CATALOG_GENERATE_SYMBOLS) exist for manually managed catalog keys only.
            // ponytail: matched whether or not the setting is on; a stray `.name` can only hide a finding.
            if entry.isCatalog, entry.state == "manual", let symbol = StringSymbolMangler.symbol(forKey: entry.key) {
                let namespace = table.stem == "Localizable" ? nil : StringSymbolMangler.tableNamespace(table.stem)
                for r in refs.sites(symbol, kinds: .memberSymbol) where refs.isVisible(r.file, visibleModules) {
                    let qualifier = r.context?.qualifier ?? ""
                    let last = qualifier.split(separator: ".").last.map(String.init) ?? ""
                    if let namespace {
                        guard last == namespace else { continue }
                        ev.strong = true
                    } else {
                        guard qualifier.isEmpty || last == "LocalizedStringResource" else { continue }
                        if qualifier.isEmpty, !LocalizationCallClassifier.isLocalization(r.context, extraMacros: macros) {
                            ev.weak.append("\(site(r.file, r.line)) uses .\(symbol) outside a localization call")
                        } else {
                            ev.strong = true
                        }
                    }
                    if ev.strong { return ev }
                }
            }
            // Interpolated literals: `Text("Hello \(name)")` is the key "Hello %@", `Text("\(a) of \(b)")` is
            // "%lld of %lld": every literal segment must match, in order.
            if let segments = StringSymbolMangler.formatSegments(entry.key), segments.contains(where: { !$0.isEmpty }) {
                for p in patterns where p.domain == .string && p.segments == segments
                    && refs.isVisible(p.file, visibleModules) && (p.context?.table ?? table.stem) == table.stem {
                    ev.strong = true
                    return ev
                }
            }
            return ev
        }

        /// Narrowing of a localization literal by `tableName:` and `bundle:` (§4.2 step 5).
        func literalMatch(_ r: Reference, _ table: Table) -> Match {
            let context = r.context ?? CallContext()
            let here = site(r.file, r.line)
            if let t = context.table {
                if t != table.stem { return .none }
            } else if table.stem != "Localizable", !SystemStringKeys.isInfoPlistTable(table.stem) {
                return .weak("\(here) uses the key without tableName: \"\(table.stem)\"")
            }
            let siteModules = ctx.refs.modules(of: r.file)
            let inOwner = !siteModules.isDisjoint(with: table.owners)
            switch LocalizationCallClassifier.bundle(context) {
            case .module: return inOwner ? .strong : .none
            case .other: return .strong
            case .none, .main:
                if ownsMainBundle(table) { return .strong }
                let owner = table.owners.sorted().first?.name ?? "the module"
                return inOwner
                    ? .weak("\(here) has no bundle: argument, so it reads Bundle.main (likely wrong bundle)")
                    : .weak("\(here) reads the main bundle, not \(owner)'s bundle")
            }
        }

        /// §4.7: keys a visible dynamic pattern could build are never high.
        func downgrade(_ f: inout Finding, key: String, table: Table, _ visibleModules: Set<ModuleID>) {
            for p in patterns where ctx.refs.isVisible(p.file, visibleModules) {
                if let t = p.context?.table, t != table.stem { continue }
                let literal = p.segments.reduce(0) { $0 + $1.count }
                guard p.couldBuild(key) else { continue }
                let target: Confidence
                if p.domain == .string, literal >= 1 { target = .low }
                else if p.domain == .any, literal >= 3 { target = .medium }
                else { continue }
                if target < f.confidence {
                    f.confidence = target
                    f.reasons.append("may be built dynamically at \(site(p.file, p.line))")
                }
            }
        }
    }

    // MARK: - Settings.bundle

    /// `Settings.bundle/*.lproj/*.strings` keys are used when a pane shows them as a title or footer.
    func settingsBundleFindings(_ ctx: ScanContext) -> [Finding] {
        let fm = FileManager.default
        var findings: [Finding] = []
        for unit in ctx.inventory.files where unit.isUnit && unit.fileName == "Settings.bundle" {
            let dir = ctx.url(for: unit.path)
            let names = ((try? fm.contentsOfDirectory(atPath: dir.path)) ?? []).sorted()
            var shown = Set<String>()
            for plist in names where plist.hasSuffix(".plist") {
                guard let data = fm.contents(atPath: dir.appendingPathComponent(plist).path),
                      let value = try? PropertyListSerialization.propertyList(from: data, format: nil) else { continue }
                for leaf in JSONValue(any: value).stringLeaves()
                where ["Title", "FooterText", "Titles", "ShortTitles"].contains(leaf.path.last ?? "") {
                    shown.insert(leaf.value)
                }
            }
            var best: [String: (path: String, line: Int?, rank: Int)] = [:]
            for lproj in names where lproj.hasSuffix(".lproj") {
                let lprojDir = dir.appendingPathComponent(lproj)
                for name in ((try? fm.contentsOfDirectory(atPath: lprojDir.path)) ?? []).sorted() where name.hasSuffix(".strings") {
                    guard let data = fm.contents(atPath: lprojDir.appendingPathComponent(name).path),
                          let keys = StringsFileReader.keys(data) else { continue }
                    let path = "\(unit.path)/\(lproj)/\(name)"
                    for (key, line) in keys where !shown.contains(key) {
                        let id = RelPath.stem(name) + "|" + key, rank = Self.lprojRank(path)
                        if let existing = best[id], existing.rank <= rank { continue }
                        best[id] = (path, line, rank)
                    }
                }
            }
            let module = unit.modules.sorted().first?.name ?? ModuleID.unknown.name
            for id in best.keys.sorted() {
                let hit = best[id]!
                findings.append(Finding(kind: .unusedString, category: .strings, path: hit.path, line: hit.line,
                                        name: String(id.split(separator: "|", maxSplits: 1).last ?? ""), module: module,
                                        confidence: .medium, reasons: ["no Settings.bundle pane shows this key as a title or footer"]))
            }
        }
        return findings
    }

    // MARK: - Dynamic lookups

    /// One info finding per localization lookup whose key is built at runtime (§4.7 step 2), limited to sites
    /// that can see a string table. Interpolations that equal an existing format key (`Text("Hello \(name)")` is
    /// "Hello %@") and SwiftUI interpolations that match no key (Xcode extracts them as format keys) are skipped.
    func dynamicLookupFindings(_ ctx: ScanContext, tables: [Table], evaluator: Evaluator) -> [Finding] {
        let refs = ctx.refs
        let visibleSets = tables.map { evaluator.visible($0) }
        var formatKeys = Set<String>()
        for table in tables {
            for key in table.keys.keys {
                if let segments = StringSymbolMangler.formatSegments(key) { formatKeys.insert(segments.joined(separator: "\u{0}")) }
            }
        }
        // Unattributed tables are visible everywhere but built by no target: they only count for unattributed sites.
        func relevantTables(_ p: DynamicPattern) -> [Table] {
            let attributedSite = !refs.modules(of: p.file).contains(.unknown)
            return tables.indices.filter {
                refs.isVisible(p.file, visibleSets[$0]) && !(attributedSite && tables[$0].owners == [.unknown])
            }.map { tables[$0] }
        }
        func buildsKey(_ p: DynamicPattern, _ candidates: [Table]) -> Bool {
            let runtimeAPI = p.context?.callee.map { $0.hasPrefix("NSLocalizedString") || $0.hasPrefix("localizedString") } ?? false
            return runtimeAPI || candidates.contains { table in table.keys.keys.contains { p.couldBuild($0) } }
        }
        let macros = ctx.config.localizationMacros
        var keyedLines = Set<FileLine>()
        for r in refs.references where r.kind == .stringLiteral
            && LocalizationCallClassifier.isLocalization(r.context, extraMacros: macros) {
            keyedLines.insert(FileLine(file: r.file, line: r.line))
        }
        for p in refs.dynamicPatterns where p.domain == .string && p.hasLiteralText {
            keyedLines.insert(FileLine(file: p.file, line: p.line))
        }
        var findings: [Finding] = []
        for p in refs.dynamicPatterns where p.domain == .string {
            let keyless = !p.hasLiteralText
            if refs.isIgnored(file: p.file, line: p.line)
                || (!keyless && formatKeys.contains(p.segments.joined(separator: "\u{0}"))) { continue }
            let candidates = relevantTables(p)
            if candidates.isEmpty || (!keyless && !buildsKey(p, candidates)) { continue }
            let path = refs.path(of: p.file)
            if keyless, keyedLines.contains(FileLine(file: p.file, line: p.line)) { continue }
            let name = keyless ? nil : p.segments.joined(separator: "*")
            let reason = keyless ? "localization call with a non-literal key"
                : "localization key built at runtime (\"\(p.segments.joined(separator: "…"))\")"
            findings.append(Finding(kind: .dynamicLookup, category: .strings, path: path, line: Int(p.line), name: name,
                                    module: ctx.moduleName(for: path), confidence: .low, reasons: [reason]))
        }
        return findings
    }
}
