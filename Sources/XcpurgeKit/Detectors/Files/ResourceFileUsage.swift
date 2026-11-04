import Foundation

/// Loose bundle resources (plist, json, media, Core ML, Core Data, scenes, documents, databases) that no visible
/// file names by stem, `stem.ext` or a path ending in either; folder-like units also count when a path names
/// them as any component (`"art.scnassets/ship.scn"`).
/// Folder loads (`urls(forResourcesWithExtension:)`, blue folder references, synchronized folders copied whole,
/// `Package.swift` `.copy`) and dynamic name patterns downgrade to low instead of clearing. Core ML models and
/// Reality Composer projects also count by their generated class; Core Data models are never high, since
/// `NSManagedObjectModel.mergedModel(from: nil)` loads them without a name.
enum ResourceFileUsage {
    static let kinds: Set<FileKind> = [.plist, .json, .html, .css, .js, .audio, .video, .dataModel, .sceneAssets]
    static let extensions: Set<String> = [
        "txt", "mlmodel", "gpx", "rtf", "scn", "usdz", "reality", "lottie", "pdf", "sqlite", "db", "csv",
    ]
    /// Call labels that load every resource with a given extension.
    static let folderLoadLabels: Set<String> = [
        "forResourcesWithExtension", "forResourcesOfType", "pathsForResourcesOfType", "URLsForResourcesWithExtension",
    ]
    /// Plists SDKs read by convention, never by a name in app code.
    static let conventionalPlists: Set<String> = ["Info", "GoogleService-Info", "Root", "PrivacyInfo"]

    static func find(_ ctx: ScanContext, skipping orphans: Set<String>) -> [Finding] {
        let consumed = OrphanFinder.consumedFiles(ctx)
        let roots = AssetsDetector.folderLoadRoots(ctx)
        let tails = pathTails(ctx.refs)
        let components = pathComponents(ctx.refs)
        let isUser = FilesDetector.userFilter(ctx, orphans: orphans)
        let shapes = dynamicShapes(ctx, domains: [.resource, .any])
        var out: [Finding] = []
        for (i, file) in ctx.inventory.files.enumerated() where isCandidate(file) {
            guard !file.modules.isEmpty, !orphans.contains(file.path), !consumed.contains(file.path),
                  !FilesDetector.isInsideOpaqueFolder(file.path) else { continue }
            let stem = RelPath.stem(file.path)
            if file.kind == .plist, conventionalPlists.contains(stem) || stem.hasSuffix("-Info") { continue }
            let visible = FilesDetector.visibility(of: file, in: ctx)
            let canSee = { (source: Int32) in source != Int32(i) && isUser(source) && ctx.refs.isVisible(source, visible) }
            let kinds: RefKindMask = generatesClass(file) ? [.names, .symbols] : .names
            let names = [stem, file.fileName]
            if names.contains(where: { name in
                ctx.refs.sites(name, kinds: kinds, caseInsensitive: true).contains { !isUserText($0) && canSee($0.file) }
                    || (tails[name.lowercased()] ?? []).contains { canSee($0.file) }
            }) { continue }
            if file.isUnit, (components[file.fileName.lowercased()] ?? []).contains(where: { canSee($0.file) }) { continue }
            if ctx.refs.accessorChain(names, visible: visible) != nil { continue }

            let ext = (file.fileName as NSString).pathExtension.lowercased()
            let low: String?
            var hint: String?
            if let root = roots.first(where: { RelPath.isUnder(file.path, $0.0, foldingCase: ctx.inventory.isCaseInsensitive) }) {
                low = root.1
            } else if let site = folderLoad(ext, ctx, canSee: canSee) {
                low = "every .\(ext) resource is loaded at \(site)"
            } else if let hit = dynamicMatch(stem, fileName: file.fileName, fileHint: true, shapes, ctx, canSee: canSee) {
                if hit.weak {
                    low = nil
                    hint = "may be built dynamically at \(hit.site) (an untyped name ending in \".\(ext)\")"
                } else {
                    low = "may be built dynamically at \(hit.site)"
                }
            } else {
                low = nil
            }
            var reasons = ["no reference to '\(stem)' or '\(file.fileName)' from a visible file"]
            var confidence = Confidence.high
            if let low {
                confidence = .low
                reasons.append(low)
            } else {
                if file.kind == .plist {
                    confidence = .medium
                    reasons.append("plists are sometimes read by SDKs by convention")
                } else if file.kind == .dataModel {
                    confidence = .medium
                    reasons.append("Core Data models load without a name (NSManagedObjectModel.mergedModel(from:))")
                }
                if let hint {
                    confidence = .medium
                    reasons.append(hint)
                }
            }
            // OSS scan #1: `Bundle.main.url(forResource:)` (low) or another exact match (medium) in a module that
            // cannot see the file. Heuristic: the receiver of `url(forResource:)` is not tracked, only `bundle:`.
            let accept = { (r: Reference) in r.file != Int32(i) && isUser(r.file) && !isUserText(r) }
            if let match = ctx.refs.unseenMatch(names, visible: visible, graph: ctx.graph, isLookup: \.isResourceLookup,
                                                accept: accept),
               match.confidence < confidence {
                confidence = match.confidence
                reasons.append(ctx.refs.reason(for: match, owner: ctx.moduleName(for: file.path)))
            }
            out.append(Finding(kind: .unusedResource, category: .files, path: file.path,
                               module: ctx.moduleName(for: file.path), confidence: confidence, reasons: reasons,
                               sizeBytes: file.size))
        }
        return out
    }

    /// Core ML models and Reality Composer projects are used through a generated type named after the file.
    static func generatesClass(_ file: SourceFile) -> Bool {
        ["mlmodel", "mlpackage", "rcproject", "reality"].contains((file.fileName as NSString).pathExtension.lowercased())
    }

    static func isCandidate(_ file: SourceFile) -> Bool {
        kinds.contains(file.kind) || extensions.contains((file.fileName as NSString).pathExtension.lowercased())
    }

    /// Literals that look like paths (`"Tables/rates.csv"`), keyed by lowercased last component and its stem.
    static func pathTails(_ refs: ReferenceIndex) -> [String: [Reference]] {
        var out: [String: [Reference]] = [:]
        for r in refs.references where r.kind == .stringLiteral && r.value.contains("/") && r.value.count < 512 {
            let last = RelPath.lastComponent(r.value).lowercased()
            out[last, default: []].append(r)
            let stem = RelPath.stem(last)
            if stem != last { out[stem, default: []].append(r) }
        }
        return out
    }

    /// Path literals keyed by each lowercased inner component (`"art.scnassets/ship.scn"` -> `art.scnassets`), for
    /// folder-like units loaded through a path inside them. Whole names only: a stem would match too loosely.
    static func pathComponents(_ refs: ReferenceIndex) -> [String: [Reference]] {
        var out: [String: [Reference]] = [:]
        for r in refs.references where r.kind == .stringLiteral && r.value.contains("/") && r.value.count < 512 {
            for component in Set(r.value.lowercased().split(separator: "/").dropLast()) where component.contains(".") {
                out[String(component), default: []].append(r)
            }
        }
        return out
    }

    /// IB labels and titles are user-visible text, not resource names.
    static func isUserText(_ r: Reference) -> Bool {
        if case .ibAttribute(let attribute) = r.kind { return IBScanner.textAttributes.contains(attribute) }
        return false
    }

    /// `file:line` of a call loading every resource with this extension, from a source `canSee` accepts.
    static func folderLoad(_ ext: String, _ ctx: ScanContext, canSee: (Int32) -> Bool) -> String? {
        ctx.refs.sites(ext, kinds: .stringLiteral, caseInsensitive: true).first {
            folderLoadLabels.contains($0.context?.label ?? "") && canSee($0.file)
        }.map { "\(ctx.refs.path(of: $0.file)):\($0.line)" }
    }

    /// A dynamic pattern with everything `dynamicMatch` needs precomputed, so the per-file loop does no string or
    /// bundle classification work.
    struct DynamicShape {
        let pattern: DynamicPattern
        let prefix: String
        let suffix: String
        let literal: Int
        let prefixed: Bool
        let anchored: Bool
    }

    /// Shapes of the patterns of these domains that carry literal text, built once so a per-file loop does not rescan
    /// them all. Resource lookups are case-insensitive and may anchor on a distinctive suffix or constant prefix from any
    /// module that reads the main bundle; interface files (`caseInsensitive: false`, `anchoring: false`) are neither:
    /// every pattern and separator literal there must be visible.
    struct DynamicShapes {
        let list: [DynamicShape]
        let caseInsensitive: Bool
        let anchoring: Bool
        /// Literals ending in a separator (`"intro-"`), keyed by the lowercased (or exact) value, off `xcpurge:ignore` lines.
        /// With `anchoring`, only those that read the main bundle.
        let separators: [String: [Reference]]

        /// A separator literal that is a proper prefix of `name` (already folded like the keys), from any module when
        /// `anchoring`, else from a source `canSee` accepts.
        func separatorSite(of name: String, canSee: (Int32) -> Bool) -> Reference? {
            var prefix = ""
            for (n, c) in name.enumerated() {
                prefix.append(c)
                guard ReferenceIndex.nameSeparators.contains(c), n < name.count - 1,
                      let hit = separators[prefix]?.first(where: { anchoring || canSee($0.file) }) else { continue }
                return hit
            }
            return nil
        }
    }

    static func dynamicShapes(_ ctx: ScanContext, domains: Set<DynamicPattern.Domain>, caseInsensitive: Bool = true,
                              anchoring: Bool = true) -> DynamicShapes {
        let list = ctx.refs.dynamicPatterns.filter { domains.contains($0.domain) && !$0.isKeyless }.map {
            shape($0, caseInsensitive: caseInsensitive, anchoring: anchoring)
        }
        var separators: [String: [Reference]] = [:]
        for r in ctx.refs.references where r.kind == .stringLiteral && ReferenceIndex.isSeparatorPrefix(r.value)
            && !ctx.refs.isIgnored(file: r.file, line: r.line) && (!anchoring || AssetReferenceResolver.readsMainBundle(r.context)) {
            separators[caseInsensitive ? r.value.lowercased() : r.value, default: []].append(r)
        }
        return DynamicShapes(list: list, caseInsensitive: caseInsensitive, anchoring: anchoring, separators: separators)
    }

    static func shape(_ p: DynamicPattern, caseInsensitive: Bool, anchoring: Bool) -> DynamicShape {
        let prefix = caseInsensitive ? p.prefix.lowercased() : p.prefix
        let suffix = caseInsensitive ? p.suffix.lowercased() : p.suffix
        let readsMainBundle = anchoring && AssetReferenceResolver.readsMainBundle(p.context)
        return DynamicShape(pattern: p, prefix: prefix, suffix: suffix, literal: prefix.count + suffix.count,
                            prefixed: readsMainBundle && prefix.count >= (p.domain == .any ? 3 : 1),
                            anchored: readsMainBundle && p.hasAnchoredSuffix)
    }

    /// The names a pattern is compared with, folded like the shapes.
    struct DynamicNames {
        let stem: String
        let fileName: String
        let ext: String

        init(stem: String, fileName: String, caseInsensitive: Bool) {
            let fold = { (s: String) in caseInsensitive ? s.lowercased() : s }
            self.stem = fold(stem)
            self.fileName = fold(fileName)
            self.ext = (fileName as NSString).pathExtension.lowercased()
        }
    }

    /// How a pattern relates to a file: it builds the stem or, for a resource lookup, the file name (`strong`, low);
    /// or it is an untyped name (`.any`: a cache path builder, a local `let name = "x-\(n).txt"`) whose literal
    /// suffix ends with the file's extension and fits the file name (`weak`, medium: it may well build the file name,
    /// but `appendingPathComponent("\(id).json")` builds paths that are not bundle lookups).
    enum DynamicStrength { case strong, weak }

    /// `s` against `names`, or nil when it cannot apply. Needs enough literal text (three characters for untyped
    /// strings); a constant prefix or an anchored suffix on a main-bundle lookup counts from any module, anything else
    /// needs a site `canSee` accepts. `fileHint` allows the weak extension match.
    static func strength(of s: DynamicShape, _ names: DynamicNames, fileHint: Bool, canSee: (Int32) -> Bool) -> DynamicStrength? {
        let any = s.pattern.domain == .any
        guard any ? s.literal >= 3 : s.literal >= 1 else { return nil }
        let fits = { (n: String) in n.count > s.literal && n.hasPrefix(s.prefix) && n.hasSuffix(s.suffix) }
        let strength: DynamicStrength
        if fits(names.stem) || (!any && fits(names.fileName)) {
            strength = .strong
        } else if fileHint, any, !names.ext.isEmpty, s.suffix.hasSuffix(".\(names.ext)"), fits(names.fileName) {
            strength = .weak
        } else {
            return nil
        }
        return s.prefixed || s.anchored || canSee(s.pattern.file) ? strength : nil
    }

    /// `file:line` of the dynamic pattern (`"intro_\(n)"`) that could produce the stem or file name (plan §4.7 step 3),
    /// or of a literal ending in a separator that starts the name (`"intro-"`); `weak` when only an untyped pattern
    /// matches the file name (see `DynamicStrength`). A strong match from any pattern wins over a weak one. Case
    /// folding follows `shapes`.
    static func dynamicMatch(_ stem: String, fileName: String, fileHint: Bool = false, _ shapes: DynamicShapes,
                             _ ctx: ScanContext, canSee: (Int32) -> Bool) -> (site: String, weak: Bool)? {
        let names = DynamicNames(stem: stem, fileName: fileName, caseInsensitive: shapes.caseInsensitive)
        var weak: DynamicPattern?
        for s in shapes.list {
            switch strength(of: s, names, fileHint: fileHint, canSee: canSee) {
            case .strong: return ("\(ctx.refs.path(of: s.pattern.file)):\(s.pattern.line)", false)
            case .weak: weak = weak ?? s.pattern
            case nil: break
            }
        }
        if let r = shapes.separatorSite(of: names.stem, canSee: canSee) {
            return ("\(ctx.refs.path(of: r.file)):\(r.line)", false)
        }
        return weak.map { ("\(ctx.refs.path(of: $0.file)):\($0.line)", true) }
    }
}
