import Foundation

/// `.xcpurgeignore` rules and inline `xcpurge:ignore` markers that no longer suppress anything, reported as
/// informational `staleIgnore` findings. Computed from the unfiltered findings (ignores off), see ScanEngine.run.
///
/// Every rule errs on the side of silence: a path glob is stale only when it matches nothing on disk (not merely
/// nothing in the inventory), `kind:` only on a typo, `module:` only when no module has such a name, `asset:` /
/// `string:` only when that category was scanned, and an inline marker only when a second detector pass with
/// markers switched off still finds nothing on its lines, no dynamic pattern sits there, and the file is not a
/// dead source the marker keeps. Block-comment markers and markers in generic text files are never flagged. A run
/// scoped with `--project`, `--package` or `--workspace` sees only part of the graph and sources, so it keeps the
/// glob and `kind:` checks only.
enum StaleIgnoreDetector {
    static let markerName = SwiftTokenizer.ignoreMarker
    /// Disk entries one lazy walk may visit before the remaining path rules are reported as not evaluable.
    static let walkCap = 200_000

    static func find(unfiltered: [Finding], context ctx: ScanContext, categories: Set<Category>) -> [Finding] {
        let scoped = ctx.config.project != nil || ctx.config.package != nil || ctx.config.workspace != nil
        if scoped, !ctx.ignore.isEmpty || ctx.refs.hasLineStyleMarkers {
            ctx.diagnostics.info("stale-ignore checks limited to path globs and kind: typos: scoped run (--project, --package or --workspace)")
        }
        var out = staleRules(unfiltered, ctx, categories: categories, scoped: scoped)
        if !scoped, categories.isSuperset(of: [.assets, .strings, .files]) {
            out += staleMarkers(ctx, categories: categories)
        }
        // Threshold and `.xcpurgeignore` rules (`kind:stale-ignore`) apply here too; inline findings honour
        // `--targets` like any other source finding, rule findings have no module.
        let targets = Set(ctx.config.targets)
        return out.filter { f in
            f.confidence >= ctx.config.minConfidence && !ctx.ignore.suppresses(f)
                && (f.path == Ignore.fileName || targets.isEmpty || targets.contains(f.module))
        }.sorted(by: Finding.reportOrder)
    }

    // MARK: - .xcpurgeignore rules

    private static func staleRules(_ unfiltered: [Finding], _ ctx: ScanContext, categories: Set<Category>,
                                   scoped: Bool) -> [Finding] {
        let rules = ctx.ignore.rules
        guard !rules.isEmpty else { return [] }
        let knownKinds = Set(FindingKind.allCases.flatMap { [$0.rawValue, $0.flagName] })
        let moduleNames = Set(ctx.graph.modules.keys.map(\.name)).union([ModuleID.unknown.name])
        var assetNamesOnDisk: [(name: String, loose: Bool)]?
        var out: [Finding] = []
        var pathRules: [PathRule] = []
        for rule in rules {
            switch rule.matcher {
            case let .path(glob, directoryOnly):
                pathRules.append(PathRule(rule: rule, glob: glob, directoryOnly: directoryOnly))
            case .kind(let k):
                guard !knownKinds.contains(k) else { continue }  // a known kind with no findings is policy, not stale
                out.append(stale(rule, .high, "`\(k)` is not a finding kind (known: \(FindingKind.allCases.map(\.flagName).joined(separator: ", ")))"))
            case .module(let p):
                guard !scoped, !moduleNames.contains(where: { Ignore.nameMatches(p, $0) }) else { continue }
                out.append(stale(rule, .high, "no module named like this"))
            case .asset(let p):
                guard !scoped, categories.contains(.assets) else { continue }
                if unfiltered.contains(where: { $0.category == .assets && $0.kind != .duplicate && Ignore.assetNameMatches(p, $0) }) {
                    continue
                }
                if assetNamesOnDisk == nil { assetNamesOnDisk = assetNames(ctx) }
                if assetNamesOnDisk!.contains(where: { Ignore.assetNameMatches(p, $0.name, looseFile: $0.loose) }) {
                    out.append(stale(rule, .low, "asset exists but is used; rule suppresses nothing"))
                } else {
                    out.append(stale(rule, .medium, "no asset named like this"))
                }
            case .string(let p):
                guard !scoped, categories.contains(.strings) else { continue }
                if unfiltered.contains(where: { $0.category == .strings && Ignore.nameMatches(p, $0.name) }) { continue }
                out.append(stale(rule, .low, "no string key reported like this"))
            }
        }
        let verdict = stalePathRules(pathRules, ctx)
        for rule in verdict.stale { out.append(stale(rule, .medium, "matches no file on disk")) }
        for rule in verdict.undecided {
            out.append(stale(rule, .low, "could not evaluate: matches nothing scanned, and the rest of the disk was not walked "
                + "(build output, or more than \(walkCap) entries)"))
        }
        return out
    }

    private static func stale(_ rule: Ignore.Rule, _ confidence: Confidence, _ reason: String) -> Finding {
        Finding(kind: .staleIgnore, category: .ignores, path: Ignore.fileName, line: rule.line, name: rule.text,
                module: ModuleID.unknown.name, confidence: confidence, reasons: [reason])
    }

    /// Catalog entries (name, leaf, aliases; matched exactly) plus loose image and font file names (matched with or
    /// without extension, like `Ignore.assetNameMatches`).
    private static func assetNames(_ ctx: ScanContext) -> [(name: String, loose: Bool)] {
        var names: [(name: String, loose: Bool)] = []
        for file in ctx.inventory.files {
            switch file.kind {
            case .assetCatalog:
                for asset in AssetCatalogReader.read(catalog: file.path, root: ctx.root) {
                    for name in [asset.name, asset.leaf] + asset.aliases { names.append((name, false)) }
                }
            case .image, .font:
                names.append((file.fileName, true))
            default:
                break
            }
        }
        return names
    }

    // MARK: - Path rules on disk

    struct PathRule {
        var rule: Ignore.Rule
        var glob: Glob
        var directoryOnly: Bool
        /// The glob's `/`-separated segments (leading `/` and trailing `/` dropped), or nil for an unanchored
        /// pattern (no slash: matches any component at any depth).
        let anchoredSegments: [String]?

        init(rule: Ignore.Rule, glob: Glob, directoryOnly: Bool) {
            self.rule = rule
            self.glob = glob
            self.directoryOnly = directoryOnly
            var p = glob.pattern.trimmingCharacters(in: .whitespaces)
            if p.hasPrefix("./") { p.removeFirst(2) }
            while p.hasSuffix("/") { p.removeLast() }
            anchoredSegments = p.contains("/") ? p.split(separator: "/", omittingEmptySubsequences: true).map(String.init) : nil
        }

        func matches(_ path: String, isDirectory: Bool) -> Bool {
            if directoryOnly, !isDirectory { return false }
            return glob.matches(path)
        }

        /// True when something inside directory `dir` could still match: an unanchored pattern can match anywhere;
        /// an anchored one only below a directory whose components agree with its leading segments (`**` opens
        /// everything beneath). A directory that already consumed every segment was tested itself.
        func canMatchBelow(_ dir: String) -> Bool {
            guard let segments = anchoredSegments else { return true }
            let parts = dir.split(separator: "/")
            for (i, part) in parts.enumerated() {
                guard i < segments.count else { return false }
                if segments[i] == "**" { return true }
                if !Glob.matchSegment(Array(segments[i]), Array(part)) { return false }
            }
            return true
        }
    }

    /// Path rules (negated or not) that match nothing on disk. Pass 1 checks the inventory and its ancestor
    /// directories; rules still unmatched get one lazy walk of the root (skipping `.git`, the trash and build output
    /// like the main walk, never following symlinks, never entering a directory no rule can match under) that stops
    /// as soon as every rule has matched. Rules that could only match inside skipped build output, or that are
    /// still open when the walk hits `walkCap` entries, are `undecided` rather than stale. Scope flags (`--targets`,
    /// `--project`, `--exclude`, skipped `Pods/`) cannot make a rule look stale.
    static func stalePathRules(_ rules: [PathRule], _ ctx: ScanContext, walkCap: Int = walkCap,
                               visited: ((String) -> Void)? = nil) -> (stale: [Ignore.Rule], undecided: [Ignore.Rule]) {
        guard !rules.isEmpty else { return ([], []) }
        var unmatched = Array(rules.indices)
        /// Rules that could match inside build output the walk did not enter (or past the cap). A later match
        /// anywhere else still settles them, so this never removes a rule from `unmatched`.
        var tentative = Set<Int>()
        var directories = Set<String>()
        for file in ctx.inventory.files {
            if file.isUnit { directories.insert(file.path) }
            var parent = RelPath.parent(file.path)
            while !parent.isEmpty, directories.insert(parent).inserted { parent = RelPath.parent(parent) }
        }
        func consume(_ path: String, isDirectory: Bool) {
            unmatched.removeAll { rules[$0].matches(path, isDirectory: isDirectory) }
        }
        for file in ctx.inventory.files where !unmatched.isEmpty { consume(file.path, isDirectory: file.isUnit) }
        for dir in directories.sorted() where !unmatched.isEmpty { consume(dir, isDirectory: true) }
        if !unmatched.isEmpty {
            var count = 0
            enumerateDisk(ctx.root) { path, isDirectory, absolute in
                count += 1
                visited?(path)
                if count > walkCap { tentative.formUnion(unmatched); return .stop }
                consume(path, isDirectory: isDirectory)
                if unmatched.isEmpty { return .stop }
                guard isDirectory else { return .descend }
                let open = unmatched.filter { rules[$0].canMatchBelow(path) }
                if open.isEmpty { return .skip }
                if isBuildOutput(path, absolute: absolute) {
                    // Nothing scanned lives there; a rule that only fits inside cannot be judged either way.
                    tentative.formUnion(open)
                    return .skip
                }
                return .descend
            }
        }
        let undecided = unmatched.filter { tentative.contains($0) }
        let stale = unmatched.filter { !tentative.contains($0) }
        return (stale.map { rules[$0].rule }, undecided.map { rules[$0].rule })
    }

    private enum Step { case descend, skip, stop }

    /// Build output the main walk skips (`FileWalker.shouldSkip`): DerivedData, node_modules, products, `build/`
    /// folders that are output, Carthage builds, and any folder holding a build marker. `Pods/` is not build output.
    private static func isBuildOutput(_ rel: String, absolute: String) -> Bool {
        let name = RelPath.lastComponent(rel)
        let ext = (name as NSString).pathExtension
        if FileWalker.skippedNames.contains(name) || FileWalker.skippedExtensions.contains(ext) { return true }
        if name == "build", FileWalker.isBuildOutput(rel: rel, absolute: absolute) { return true }
        if rel.hasSuffix("Carthage/Build") || rel.hasSuffix("Carthage/Checkouts") { return true }
        return FileWalker.buildMarkers.contains { FileManager.default.fileExists(atPath: absolute + "/" + $0) }
    }

    /// Walks the root once, depth first, asking `visit` what to do with each entry.
    private static func enumerateDisk(_ root: URL, visit: (String, Bool, String) -> Step) {
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey]
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: Array(keys),
                                                               options: [], errorHandler: { _, _ in true }) else { return }
        let rootPath = root.path
        while let url = enumerator.nextObject() as? URL {
            let values = try? url.resourceValues(forKeys: keys)
            let isDirectory = values?.isDirectory == true && values?.isSymbolicLink != true
            if values?.isSymbolicLink == true { enumerator.skipDescendants() }
            let rel = RelPath.relative(url.path, to: rootPath)
            let name = RelPath.lastComponent(rel)
            if isDirectory, name == ".git" || ToolOutput.directoryNames.contains(name) { enumerator.skipDescendants(); continue }
            if !isDirectory, ToolOutput.isGeneratedReport(path: rel, absolute: url.path) { continue }
            switch visit(rel, isDirectory, url.path) {
            case .descend: continue
            case .skip: if isDirectory { enumerator.skipDescendants() }
            case .stop: return
            }
        }
    }

    // MARK: - Inline markers

    /// Line-style markers in Swift/ObjC sources that suppress nothing. A marker counts as used when (a) the
    /// ignores-off detector pass reports a finding on one of its lines, (b) a dynamic pattern sits on one of its
    /// lines (such markers change analysis elsewhere), or (c) the ignores-off pass reports the file as a dead
    /// source (the marker is what keeps it). Excluded, generated and skipped files are never candidates. The
    /// finding's name carries the marker's ordinal among the file's line-style markers (`xcpurge:ignore #2`) so
    /// two stale markers in one file have distinct identities.
    private static func staleMarkers(_ ctx: ScanContext, categories: Set<Category>) -> [Finding] {
        let refs = ctx.refs
        let files = ctx.inventory.files
        let excludes = ctx.config.exclude.map(Glob.init)
        var candidates: [(file: Int32, path: String, marker: IgnoreMarker)] = []
        for (file, markers) in refs.ignoreMarkers.sorted(by: { $0.key < $1.key }) {
            guard files.indices.contains(Int(file)), !refs.generatedFiles.contains(file) else { continue }
            let path = files[Int(file)].path
            if excludes.contains(where: { $0.matches(path) }) { continue }
            for marker in markers where marker.style == .line { candidates.append((file, path, marker)) }
        }
        guard !candidates.isEmpty else { return [] }

        let patternLines = Set(refs.dynamicPatterns.map { FileLine(file: $0.file, line: $0.line) })
        let noIgnores = ScanContext(root: ctx.root, config: ctx.config, inventory: ctx.inventory, graph: ctx.graph,
                                    refs: refs.withoutIgnores(), projects: ctx.projects, derivedData: ctx.derivedData,
                                    diagnostics: Diagnostics(), ignore: ctx.ignore)
        // Duplicates never consult markers, so that detector is not rerun.
        let detectors = DetectorRegistry.detectors(for: categories.intersection([.assets, .strings, .files]))
        var findingLines = Set<FileLine>(), deadFiles = Set<String>()
        for f in detectors.flatMap({ $0.run(noIgnores) }) {
            if f.kind == .deadSource { deadFiles.insert(f.path) }
            if let line = f.line, let index = ctx.inventory.index(of: f.path) {
                findingLines.insert(FileLine(file: Int32(index), line: Int32(line)))
            }
        }

        var out: [Finding] = []
        for c in candidates {
            let used = deadFiles.contains(c.path) || c.marker.covers.contains { line in
                let at = FileLine(file: c.file, line: line)
                return findingLines.contains(at) || patternLines.contains(at)
            }
            if used { continue }
            out.append(Finding(kind: .staleIgnore, category: .ignores, path: c.path, line: Int(c.marker.line),
                               name: markerName, module: ctx.moduleName(for: c.path), confidence: .medium,
                               reasons: ["marker suppresses no finding on its lines"]))
        }
        return out
    }
}
