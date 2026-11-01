import Foundation

/// Unused image/color/data/symbol sets, app icons, loose images and fonts (plan §4.3, §4.7, §5).
/// Each resource is checked against references visible to its owning module; dynamic names downgrade
/// confidence instead of hiding findings.
public struct AssetsDetector: Detector {
    public init() {}

    public var category: Category { .assets }

    /// One resource under evaluation.
    private struct Candidate {
        var kind: FindingKind
        var path: String
        var name: String
        /// Names a lookup may spell (for dynamic patterns and numbered siblings).
        var names: [String]
        var module: String
        var visible: Set<ModuleID>
        /// Modules that own the resource (for same-module keyless lookups).
        var owners: Set<ModuleID> = []
        /// Catalog or directory; numbered siblings are only compared within one group.
        var group: String
        var sizeBytes: Int64
        var used = false
        var confidence: Confidence = .high
        var reasons: [String] = []
        var domains: Set<DynamicPattern.Domain> = [.asset]
    }

    static let fontDeclarationKeys: Set<String> = ["UIAppFonts", "ATSApplicationFontsPath"]
    static let folderLoadLabels: Set<String> = [
        "forResourcesWithExtension", "forResourcesOfType", "pathsForResourcesOfType", "URLsForResourcesWithExtension",
    ]

    public func run(_ ctx: ScanContext) -> [Finding] {
        let resolver = AssetReferenceResolver(ctx)
        let protection = AppIconProtection(graph: ctx.graph)
        let index = GeneratedAssetSymbolsIndex.load(derivedData: ctx.derivedData, root: ctx.root)
        var candidates: [Candidate] = []

        let catalogs = ctx.inventory.files.filter { $0.kind == .assetCatalog }
            .map { (unit: $0, assets: AssetCatalogReader.read(catalog: $0.path, root: ctx.root)) }
        // A target's catalogs share one generated-symbols file, so symbol collisions are settled per owner set.
        let owned = Dictionary(grouping: catalogs, by: \.unit.effectiveModules).values
            .reduce(into: [String: AssetSymbolMangler.OwnedSymbols]()) { all, group in
                all.merge(AssetSymbolMangler.ownedSymbols(in: group.flatMap(\.assets))) { a, _ in a }
            }
        for (unit, assets) in catalogs {
            let visible = resolver.consumers(of: unit.effectiveModules)
            let module = ctx.moduleName(for: unit.path)
            for asset in assets where !asset.type.isAlwaysKept {
                var c = evaluate(asset, owned: owned[asset.path] ?? .init(), module: module, visible: visible,
                                 resolver: resolver, protection: protection, index: index, ctx: ctx)
                Self.applyUnseenEvidence(&c, resolver: resolver, isLookup: \.isAssetLookup)
                c.owners = unit.effectiveModules
                candidates.append(c)
            }
        }
        for unit in ctx.inventory.files where unit.kind == .iconComposer {
            candidates.append(evaluateIcon(unit, ctx: ctx, resolver: resolver, protection: protection))
        }
        let folderLoads = Self.folderLoadRoots(ctx)
        for file in ctx.inventory.files where file.kind == .image && !file.modules.isEmpty {
            var c = evaluateLooseImage(file, ctx: ctx, resolver: resolver, protection: protection, folderLoads: folderLoads)
            Self.applyUnseenEvidence(&c, resolver: resolver, isLookup: { $0.isAssetLookup || $0.isResourceLookup })
            c.owners = file.effectiveModules
            candidates.append(c)
        }
        for file in ctx.inventory.files where file.kind == .font && !file.modules.isEmpty {
            var c = evaluateFont(file, ctx: ctx, resolver: resolver, folderLoads: folderLoads)
            // Fonts register process-wide: a name in any module is a use, never a bundle lookup.
            Self.applyUnseenEvidence(&c, resolver: resolver, isLookup: { _ in false },
                                     accept: { !Self.isFontDeclaration($0) })
            candidates.append(c)
        }

        var usedPatterns = Set<DynamicPattern>()
        let siblings = Self.usedNumberedNames(candidates)
        var findings: [Finding] = []
        for var c in candidates where !c.used {
            if let d = resolver.downgrade(c.names, visible: c.visible, domains: c.domains), d.confidence < c.confidence {
                c.confidence = d.confidence
                c.reasons.append(d.reason)
                if d.pattern.domain == .any { usedPatterns.insert(d.pattern) }
            }
            if c.confidence > .medium, c.domains.contains(.asset), let p = resolver.keylessLookup(in: c.owners) {
                c.confidence = .medium
                c.reasons.append("may be built dynamically at \(resolver.location(p.file, p.line)) (name passed as a variable)")
                usedPatterns.insert(p)
            }
            if c.confidence > .medium, let sibling = Self.numberedSibling(of: c, used: siblings) {
                c.confidence = .medium
                c.reasons.append("numbered sibling of used \"\(sibling)\"")
            }
            findings.append(Finding(kind: c.kind, category: .assets, path: c.path, name: c.name, module: c.module,
                                    confidence: c.confidence, reasons: c.reasons, sizeBytes: c.sizeBytes))
        }

        let derived = usedPatterns.subtracting(resolver.patterns).sorted { ($0.file, $0.line, $0.prefix) < ($1.file, $1.line, $1.prefix) }
        for p in resolver.patterns.filter({ $0.domain == .asset || usedPatterns.contains($0) }) + derived {
            findings.append(Finding(
                kind: .dynamicLookup, category: .assets, path: ctx.refs.path(of: p.file), line: Int(p.line),
                name: p.prefix + "*" + p.suffix,
                module: ctx.refs.modules(of: p.file).sorted().first?.name ?? ModuleID.unknown.name,
                confidence: .low,
                reasons: ["asset name built at runtime; matching assets are reported with lower confidence"]))
        }
        return findings
    }

    // MARK: - Catalog entries

    private func evaluate(_ asset: CatalogAsset, owned: AssetSymbolMangler.OwnedSymbols, module: String,
                          visible: Set<ModuleID>, resolver: AssetReferenceResolver, protection: AppIconProtection,
                          index: GeneratedAssetSymbolsIndex, ctx: ScanContext) -> Candidate {
        var seen = Set<String>()
        let names = ([asset.name, asset.leaf] + asset.aliases).filter { seen.insert($0).inserted }
        var c = Candidate(kind: .unusedAsset, path: asset.path, name: asset.name, names: names, module: module,
                          visible: visible, group: asset.catalog, sizeBytes: asset.sizeBytes)
        if protection.reason(for: names, consumers: visible, includeAllApplies: asset.type.isAppIconLike) != nil
            || resolver.nameEvidence(names, visible: visible) != nil {
            c.used = true
            return c
        }
        if asset.type.isAppIconLike {
            c.confidence = .medium
            let label = asset.type == .appIcon ? "app icon set" : asset.type == .launchImage ? "launch image"
                : asset.type == .complication ? "complication set" : "\(asset.type.rawValue) icon set"
            c.reasons = ["\(label) not named by ASSETCATALOG_COMPILER_APPICON_NAME, "
                + "ALTERNATE_APPICON_NAMES, INCLUDE_ALL_APPICON_ASSETS or Info.plist icons"]
            return c
        }
        if let exact = index.symbols(for: asset) {
            if resolver.symbolEvidence(swift: exact.swift.sorted(), objc: exact.objc.sorted(), visible: visible,
                                       strength: .high) != nil {
                c.used = true
                return c
            }
        } else {
            // Only the asset that owns a symbol gets it: `.icWallet` is `Ic Wallet`, not `ic_wallet` or `ic-wallet`.
            // When two namespace folders mangle alike, either may own the enum, so both keep their symbol.
            let guess = owned.orderDependent
                ? AssetSymbolMangler.swiftSymbol(leaf: asset.leaf, type: asset.type, namespace: asset.namespace) : nil
            let swift = (owned.swift ?? guess).map { [$0] } ?? []
            let objc = owned.objc.map { [$0] } ?? []
            if resolver.symbolEvidence(swift: swift, objc: objc, visible: visible, strength: .medium) != nil {
                c.used = true
                return c
            }
            if !owned.lostSwift || owned.orderDependent, let fuzzy = resolver.fuzzyEvidence(asset.leaf, visible: visible) {
                ctx.diagnostics.info("treated as used: \(fuzzy.reason)", path: asset.path)
                c.used = true
                return c
            }
        }
        c.reasons = ["no reference by name, generated symbol or accessor visible to \(module)"]
        if !asset.odrTags.isEmpty {
            let tagged = resolver.nameEvidence(asset.odrTags, visible: visible) != nil
            if tagged || resolver.mentions("NSBundleResourceRequest", visible: visible) {
                c.confidence = .low
                c.reasons.append("on-demand resource (tags: \(asset.odrTags.joined(separator: ", "))) loaded via NSBundleResourceRequest")
            }
        }
        return c
    }

    private func evaluateIcon(_ unit: SourceFile, ctx: ScanContext, resolver: AssetReferenceResolver,
                              protection: AppIconProtection) -> Candidate {
        let visible = resolver.consumers(of: unit.effectiveModules)
        let name = RelPath.stem(unit.path)
        var c = Candidate(kind: .unusedAsset, path: unit.path, name: name, names: [name],
                          module: ctx.moduleName(for: unit.path), visible: visible, group: RelPath.parent(unit.path),
                          sizeBytes: unit.size, confidence: .medium)
        if protection.reason(for: [name], consumers: visible, includeAllApplies: true) != nil
            || resolver.nameEvidence([name, unit.fileName], visible: visible) != nil {
            c.used = true
        } else {
            c.reasons = ["Icon Composer icon not named by ASSETCATALOG_COMPILER_APPICON_NAME or ALTERNATE_APPICON_NAMES"]
        }
        return c
    }

    // MARK: - Loose files

    private func evaluateLooseImage(_ file: SourceFile, ctx: ScanContext, resolver: AssetReferenceResolver,
                                    protection: AppIconProtection, folderLoads: [(String, String)]) -> Candidate {
        let visible = resolver.consumers(of: file.effectiveModules)
        let names = LooseImageNormalizer.candidates(file.fileName)
        var c = Candidate(kind: .unusedAsset, path: file.path, name: file.fileName, names: names,
                          module: ctx.moduleName(for: file.path), visible: visible, group: RelPath.parent(file.path),
                          sizeBytes: file.size, domains: [.asset, .resource])
        if protection.reason(for: names, consumers: visible) != nil || resolver.nameEvidence(names, visible: visible) != nil {
            c.used = true
            return c
        }
        c.reasons = ["loose image not referenced by name visible to \(c.module)"]
        if let reason = Self.folderLoad(file, ctx: ctx, resolver: resolver, visible: visible, roots: folderLoads) {
            c.confidence = .low
            c.reasons.append(reason)
        }
        return c
    }

    private func evaluateFont(_ file: SourceFile, ctx: ScanContext, resolver: AssetReferenceResolver,
                              folderLoads: [(String, String)]) -> Candidate {
        let visible = resolver.consumers(of: file.effectiveModules)
        let names = FontInspector.lookupNames(of: ctx.url(for: file.path))
        var c = Candidate(kind: .unusedFont, path: file.path, name: file.fileName, names: names,
                          module: ctx.moduleName(for: file.path), visible: visible, group: RelPath.parent(file.path),
                          sizeBytes: file.size, domains: [.resource])
        let isDeclaration: (Reference) -> Bool = Self.isFontDeclaration
        if resolver.nameEvidence(names, visible: visible, excluding: isDeclaration) != nil {
            c.used = true
            return c
        }
        let lowered = file.fileName.lowercased()
        let declaredBy = visible.sorted().first { id in
            (ctx.graph.module(id)?.infoPlist["UIAppFonts"]?.arrayValue ?? [])
                .contains { RelPath.lastComponent($0.stringValue ?? "").lowercased() == lowered }
        }
        let declaredInPlist = ctx.refs.sites(file.fileName, kinds: .plistValue, caseInsensitive: true)
            .contains { isDeclaration($0) && resolver.counts($0.file, visible) }
        if declaredBy != nil || declaredInPlist {
            c.confidence = .medium
            c.reasons = ["declared in UIAppFonts\(declaredBy.map { " of \($0.name)" } ?? "") but never used by "
                + "file, PostScript, family or full name"]
        } else {
            c.reasons = ["not declared in UIAppFonts and never referenced by file, PostScript, family or full name"]
        }
        if c.confidence > .low, let reason = Self.folderLoad(file, ctx: ctx, resolver: resolver, visible: visible, roots: folderLoads) {
            c.confidence = .low
            c.reasons.append(reason)
        }
        return c
    }

    /// The `UIAppFonts` / `ATSApplicationFontsPath` entry that declares a font is not a use of it.
    static func isFontDeclaration(_ r: Reference) -> Bool {
        r.kind == .plistValue && fontDeclarationKeys.contains(r.context?.callee ?? "")
    }

    /// OSS scan #1 (supersedes review #9's medium cap for bundle-less lookups in dependencies): exact names in modules
    /// the visibility rule does not count. A visible accessor whose body there holds the name is a use; otherwise a
    /// main-bundle lookup (`UIImage(named:)`, `Image("…")`, `NSDataAsset`) caps at low and any other exact match at medium.
    private static func applyUnseenEvidence(_ c: inout Candidate, resolver: AssetReferenceResolver,
                                            isLookup: (CallContext) -> Bool,
                                            accept: (Reference) -> Bool = { _ in true }) {
        guard !c.used else { return }
        if resolver.refs.accessorChain(c.names, visible: c.visible) != nil {
            c.used = true
            return
        }
        guard let match = resolver.refs.unseenMatch(c.names, visible: c.visible, isLookup: isLookup, accept: accept),
              match.confidence < c.confidence else { return }
        c.confidence = match.confidence
        c.reasons.append(resolver.refs.reason(for: match, owner: c.module))
    }

    /// Folders whose contents are copied or loaded wholesale: package `.copy` resources, folder references
    /// and synced-folder opaque folders, as (root-relative path, reason).
    static func folderLoadRoots(_ ctx: ScanContext) -> [(String, String)] {
        var roots: [(String, String)] = []
        for project in ctx.projects {
            for target in project.targets {
                for r in target.resources where r.rule == .copy { roots.append((r.path, "inside .copy resource \(r.path)")) }
            }
            for ref in project.fileRefs where ref.isFolder { roots.append((ref.path, "inside folder reference \(ref.path)")) }
            for group in project.syncedGroups {
                for folder in group.explicitFolders {
                    let path = RelPath.join(group.path, folder)
                    roots.append((path, "inside folder copied as a whole: \(path)"))
                }
            }
        }
        return roots
    }

    /// Why a loose file may be loaded without its name appearing anywhere, or nil.
    static func folderLoad(_ file: SourceFile, ctx: ScanContext, resolver: AssetReferenceResolver,
                           visible: Set<ModuleID>, roots: [(String, String)]) -> String? {
        let folding = ctx.inventory.isCaseInsensitive
        if let root = roots.first(where: { RelPath.isUnder(file.path, $0.0, foldingCase: folding) && file.path != $0.0 }) {
            return root.1
        }
        let ext = (file.fileName as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        let loads = ctx.refs.sites(ext, kinds: .stringLiteral, caseInsensitive: true).first {
            folderLoadLabels.contains($0.context?.label ?? "") && resolver.counts($0.file, visible)
        }
        return loads.map { "files with extension .\(ext) are enumerated at \(resolver.location($0.file, $0.line))" }
    }

    // MARK: - Numbered siblings (plan §4.7 step 4)

    /// Splits `icon_12@2x` into ("icon_", "12", "@2x") around its last digit run.
    static func numberParts(_ name: String) -> (prefix: String, suffix: String)? {
        let chars = Array(name)
        guard let end = chars.lastIndex(where: \.isNumber) else { return nil }
        var start = end
        while start > 0, chars[start - 1].isNumber { start -= 1 }
        return (String(chars[..<start]).lowercased(), String(chars[(end + 1)...]).lowercased())
    }

    private static func usedNumberedNames(_ candidates: [Candidate]) -> [String: String] {
        var out: [String: String] = [:]
        for c in candidates where c.used {
            guard let parts = numberParts(c.name) else { continue }
            let key = c.group + "\u{0}" + parts.prefix + "\u{0}" + parts.suffix
            if out[key] == nil || c.name < out[key]! { out[key] = c.name }
        }
        return out
    }

    private static func numberedSibling(of c: Candidate, used: [String: String]) -> String? {
        guard let parts = numberParts(c.name) else { return nil }
        return used[c.group + "\u{0}" + parts.prefix + "\u{0}" + parts.suffix]
    }
}
