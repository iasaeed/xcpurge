import Foundation

/// `.xcpurgeignore` rules and inline `xcpurge:ignore` markers that no longer suppress anything, reported as
/// informational `staleIgnore` findings. Computed from the unfiltered findings (ignores off), see ScanEngine.run.
///
/// Every rule errs on the side of silence: a path glob is stale only when it matches nothing on disk (not merely
/// nothing in the inventory), `kind:` only on a typo, `module:` only when no module has such a name, `asset:` /
/// `string:` only when that category was scanned, and an inline marker only when a second detector pass with
/// markers switched off still finds nothing on its lines, no dynamic pattern sits there, and the file is not a
/// dead source the marker keeps. Block-comment markers and markers in generic text files are never flagged.
enum StaleIgnoreDetector {
    static let markerName = SwiftTokenizer.ignoreMarker

    static func find(unfiltered: [Finding], context ctx: ScanContext, categories: Set<Category>) -> [Finding] {
        var out = staleRules(unfiltered, ctx, categories: categories)
        if categories.isSuperset(of: [.assets, .strings, .files]) {
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

    private static func staleRules(_ unfiltered: [Finding], _ ctx: ScanContext, categories: Set<Category>) -> [Finding] {
        let rules = ctx.ignore.rules
        guard !rules.isEmpty else { return [] }
        let knownKinds = Set(FindingKind.allCases.flatMap { [$0.rawValue, $0.flagName] })
        let moduleNames = Set(ctx.graph.modules.keys.map(\.name)).union([ModuleID.unknown.name])
        var assetNamesOnDisk: Set<String>?
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
                guard !moduleNames.contains(where: { Ignore.nameMatches(p, $0) }) else { continue }
                out.append(stale(rule, .high, "no module named like this"))
            case .asset(let p):
                guard categories.contains(.assets) else { continue }
                if unfiltered.contains(where: { $0.category == .assets && $0.kind != .duplicate && Ignore.nameMatches(p, $0.name) }) {
                    continue
                }
                if assetNamesOnDisk == nil { assetNamesOnDisk = assetNames(ctx) }
                if assetNamesOnDisk!.contains(where: { Ignore.nameMatches(p, $0) }) {
                    out.append(stale(rule, .low, "asset exists but is used; rule suppresses nothing"))
                } else {
                    out.append(stale(rule, .medium, "no asset named like this"))
                }
            case .string(let p):
                guard categories.contains(.strings) else { continue }
                if unfiltered.contains(where: { $0.category == .strings && Ignore.nameMatches(p, $0.name) }) { continue }
                out.append(stale(rule, .low, "no string key reported like this"))
            }
        }
        for rule in stalePathRules(pathRules, ctx) { out.append(stale(rule, .medium, "matches no file on disk")) }
        return out
    }

    private static func stale(_ rule: Ignore.Rule, _ confidence: Confidence, _ reason: String) -> Finding {
        Finding(kind: .staleIgnore, category: .ignores, path: Ignore.fileName, line: rule.line, name: rule.text,
                module: ModuleID.unknown.name, confidence: confidence, reasons: [reason])
    }

    /// Catalog entries (name, leaf, aliases) plus loose image and font file names, as `asset:` rules see them.
    private static func assetNames(_ ctx: ScanContext) -> Set<String> {
        var names = Set<String>()
        for file in ctx.inventory.files {
            switch file.kind {
            case .assetCatalog:
                for asset in AssetCatalogReader.read(catalog: file.path, root: ctx.root) {
                    names.insert(asset.name)
                    names.insert(asset.leaf)
                    names.formUnion(asset.aliases)
                }
            case .image, .font:
                names.insert(file.fileName)
                names.insert(RelPath.stem(file.path))
            default:
                break
            }
        }
        return names
    }

    private struct PathRule {
        var rule: Ignore.Rule
        var glob: Glob
        var directoryOnly: Bool

        func matches(_ path: String, isDirectory: Bool) -> Bool {
            if directoryOnly, !isDirectory { return false }
            return glob.matches(path)
        }
    }

    /// Path rules (negated or not) that match nothing on disk. Pass 1 checks the inventory and its ancestor
    /// directories; rules still unmatched get one lazy enumeration of the root (skipping `.git` and the trash,
    /// never following symlinks) that stops as soon as every rule has matched. Scope flags (`--targets`,
    /// `--project`, `--exclude`, skipped `Pods/`) cannot make a rule look stale.
    private static func stalePathRules(_ rules: [PathRule], _ ctx: ScanContext) -> [Ignore.Rule] {
        guard !rules.isEmpty else { return [] }
        var unmatched = Array(rules.indices)
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
        if !unmatched.isEmpty { enumerateDisk(ctx.root) { path, isDirectory in
            consume(path, isDirectory: isDirectory)
            return !unmatched.isEmpty
        } }
        return unmatched.map { rules[$0].rule }
    }

    /// Walks the root once; `visit` returns false to stop early.
    private static func enumerateDisk(_ root: URL, visit: (String, Bool) -> Bool) {
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
            if isDirectory, name == ".git" || name == TrashStore.directoryName { enumerator.skipDescendants(); continue }
            if !visit(rel, isDirectory) { return }
        }
    }

    // MARK: - Inline markers

    /// Line-style markers in Swift/ObjC sources that suppress nothing. A marker counts as used when (a) the
    /// ignores-off detector pass reports a finding on one of its lines, (b) a dynamic pattern sits on one of its
    /// lines (such markers change analysis elsewhere), or (c) the ignores-off pass reports the file as a dead
    /// source (the marker is what keeps it). Excluded, generated and skipped files are never candidates.
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
