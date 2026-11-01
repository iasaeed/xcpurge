import Foundation

/// The scan pipeline: discovery -> inventory -> reference index -> detectors -> filter -> sort.
public struct ScanEngine: Sendable {
    public let root: URL
    public let config: Config
    /// Receives each phase as it runs; `NoProgress` by default.
    public let progress: any ProgressSink

    /// - Parameter root: scan root; resolved to an absolute, symlink-free path.
    public init(root: URL, config: Config, progress: (any ProgressSink)? = nil) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.config = config
        self.progress = progress ?? NoProgress()
    }

    /// Runs discovery and indexing without detectors.
    public func makeContext() async throws -> ScanContext {
        try await buildContext(indexingReferences: true)
    }

    /// Discovery only: inventory, projects and module graph, with an empty reference index. Enough for actions
    /// that edit projects and move files (`xcpurge remove`) without reading every source file.
    public func discover() async throws -> ScanContext {
        try await buildContext(indexingReferences: false)
    }

    private func buildContext(indexingReferences: Bool) async throws -> ScanContext {
        let diagnostics = Diagnostics()
        let rootPath = root.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            throw XcpurgeError.notFound(rootPath)
        }
        let progress = self.progress
        var walk = FileWalker(includePods: config.includePods, excludes: config.exclude.map(Glob.init))
            .walk(root: root) { progress.report(.walking(files: $0)) }
        // A baseline inside the root names every finding, so it must never be read as a reference source.
        if let baseline = Self.baselinePath(config, rootPath: rootPath) { walk.files.removeAll { $0.path == baseline } }
        progress.report(.walking(files: walk.files.count))
        let located = try ProjectLocator.locate(root: root, walk: walk, config: config)
        progress.report(.discovering(projects: located.xcodeprojs.count, packages: located.packages.count))
        let projects = await parseProjects(located, diagnostics: diagnostics)
        let packageCount = projects.filter { $0.format == .package }.count
        progress.report(.discovering(projects: projects.count - packageCount, packages: packageCount))
        if projects.isEmpty { diagnostics.info("no Xcode project or Swift package found; all files are unattributed") }
        let graph = ModuleGraph.build(projects: projects, rootPath: rootPath,
                                      ignoreTestReferences: config.ignoreTestReferences, diagnostics: diagnostics)
        progress.report(.attributing(modules: graph.modules.count))
        var inventory = FileInventory(files: walk.files, caseInsensitive: !FileInventory.isCaseSensitiveVolume(root))
        Attribution.apply(to: &inventory, projects: projects, graph: graph)
        let refs = indexingReferences
            ? await ReferenceIndex.build(inventory: inventory, graph: graph, rootPath: rootPath,
                                         localizationMacros: config.localizationMacros, diagnostics: diagnostics,
                                         progress: { progress.report(.indexing(done: $0, total: $1)) })
            : ReferenceIndex(references: [], dynamicPatterns: [], ignoredLines: [], accessors: [:], generatedFiles: [],
                             sourcePaths: [], sourceModules: [])
        let names = (located.workspaces + located.xcodeprojs).map(RelPath.stem)
        let derivedData = DerivedDataLocator.locate(names: names, override: config.derivedData)
        let ignore: Ignore
        do { ignore = try Ignore.load(root: root) } catch {
            diagnostics.warn("cannot read \(Ignore.fileName): \(error)")
            ignore = Ignore()
        }
        return ScanContext(root: root, config: config, inventory: inventory, graph: graph, refs: refs,
                           projects: projects, derivedData: derivedData, diagnostics: diagnostics, ignore: ignore)
    }

    /// Root-relative path of `config.baseline` (absolute from the command line, root-relative from `xcpurge.json`),
    /// or nil when it is unset or outside the root.
    static func baselinePath(_ config: Config, rootPath: String) -> String? {
        guard let baseline = config.baseline else { return nil }
        let rel = RelPath.relative(RelPath.join(rootPath, baseline), to: rootPath)
        return rel.isEmpty || rel.hasPrefix("..") ? nil : rel
    }

    /// Kinds that say "nothing uses this file", which snapshot-test reference images never satisfy by name.
    static let fixtureKinds: Set<FindingKind> = [.unusedAsset, .unusedFont, .orphanFile, .unusedResource]

    /// True for an unused-style finding inside a snapshot-test fixture folder (`testFixtureDirectories`).
    static func isTestFixture(_ f: Finding, directories: [String]) -> Bool {
        guard !directories.isEmpty, fixtureKinds.contains(f.kind) else { return false }
        return inTestFixtureDirectory(f.path, directories: directories)
    }

    static func inTestFixtureDirectory(_ path: String, directories: [String]) -> Bool {
        let names = Set(directories)
        return path.split(separator: "/").dropLast().contains { names.contains(String($0)) }
    }

    /// Full scan for the given categories.
    public func run(categories: Set<Category> = Category.scannable) async throws -> ScanResult {
        let start = Date()
        let context = try await makeContext()
        let detectors = DetectorRegistry.detectors(for: categories)
        var states = detectors.map { ScanProgress.DetectorState(name: $0.category.rawValue, done: false) }
        progress.report(.detecting(states))
        let raw: [Finding] = await withTaskGroup(of: (Int, [Finding]).self) { group in
            for (i, detector) in detectors.enumerated() { group.addTask { (i, detector.run(context)) } }
            var all: [Finding] = []
            for await (i, part) in group {
                all += part
                states[i].done = true
                progress.report(.detecting(states))
            }
            return all
        }
        let capped = capForSkippedSources(raw, refs: context.refs)
        var out = filter(capped, context: context)
        if config.staleIgnores {
            // Staleness needs the unfiltered findings: markers and rules are also honoured inside the detectors.
            out = (out + StaleIgnoreDetector.find(unfiltered: capped, context: context, categories: categories))
                .sorted(by: Finding.reportOrder)
        }
        let result = ScanResult(context: context, findings: out, elapsed: Date().timeIntervalSince(start))
        progress.report(.finished(ScanSummary(result)))
        return result
    }

    /// A reference source that could not be read may hold the only use of anything, so no unused-style
    /// finding stays high when one was skipped. Duplicates do not depend on references.
    /// Files under `--exclude` do not count: the user chose not to vouch for them.
    func capForSkippedSources(_ findings: [Finding], refs: ReferenceIndex) -> [Finding] {
        let excludes = config.exclude.map(Glob.init)
        let skipped = refs.skippedSources.filter { s in !excludes.contains { $0.matches(s.path) } }
        guard let first = skipped.first else { return findings }
        let more = skipped.count > 1 ? " and \(skipped.count - 1) more" : ""
        let reason = "source \(first.path) skipped (\(first.reason))\(more); capped at medium"
        return findings.map { f in
            guard f.confidence == .high, f.category != .duplicates else { return f }
            var capped = f
            capped.confidence = .medium
            capped.reasons.append(reason)
            return capped
        }
    }

    /// Applies confidence threshold, `.xcpurgeignore` rules and inline `xcpurge:ignore` markers (for every
    /// detector), `--targets` and `--exclude`, then sorts.
    public func filter(_ findings: [Finding], context: ScanContext) -> [Finding] {
        let excludes = config.exclude.map(Glob.init)
        let targets = Set(config.targets)
        return Array(Set(findings)).filter { f in
            f.confidence >= config.minConfidence
                && !Self.isTestFixture(f, directories: config.testFixtureDirectories)
                && !context.ignore.suppresses(f, refs: context.refs, inventory: context.inventory)
                && (targets.isEmpty || targets.contains(f.module))
                && !excludes.contains { $0.matches(f.path) }
        }.sorted(by: Finding.reportOrder)
    }

    private func parseProjects(_ located: LocatedProjects, diagnostics: Diagnostics) async -> [ProjectModel] {
        let rootPath = root.path
        var projects: [ProjectModel] = []
        for xcodeproj in located.xcodeprojs {
            let url = URL(fileURLWithPath: RelPath.join(rootPath, xcodeproj))
            do {
                switch ProjectLocator.preferredFormat(xcodeproj: url) {
                case .xcproj: projects.append(try XcprojParser.parse(xcodeproj: url, root: root, diagnostics: diagnostics))
                case .pbxproj: projects.append(try PBXProjParser.parse(xcodeproj: url, root: root, diagnostics: diagnostics))
                default: diagnostics.warn("no project.pbxproj or project.xcproj", path: xcodeproj)
                }
            } catch {
                diagnostics.warn("cannot parse project: \(error)", path: xcodeproj)
            }
        }
        // Packages: located ones, plus local packages referenced by projects and packages, until closed.
        var loaded = Set<String>()
        var pending = located.packages + projects.flatMap(\.localPackages)
        while true {
            let batch = Array(Set(pending)).filter { dir in
                !loaded.contains(dir) && FileManager.default.fileExists(atPath: RelPath.join(rootPath, dir) + "/Package.swift")
            }.sorted()
            if batch.isEmpty { break }
            loaded.formUnion(batch)
            let packages = await PackageManifest.load(packageDirs: batch, root: root, useSwift: !config.noSwift,
                                                      diagnostics: diagnostics)
            projects += packages
            pending = packages.flatMap(\.localPackages)
        }
        return projects
    }
}
