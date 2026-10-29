import Foundation

/// The scan pipeline: discovery -> inventory -> reference index -> detectors -> filter -> sort.
public struct ScanEngine: Sendable {
    public let root: URL
    public let config: Config

    /// - Parameter root: scan root; resolved to an absolute, symlink-free path.
    public init(root: URL, config: Config) {
        self.root = root.standardizedFileURL.resolvingSymlinksInPath()
        self.config = config
    }

    /// Runs discovery and indexing without detectors.
    public func makeContext() async throws -> ScanContext {
        let diagnostics = Diagnostics()
        let rootPath = root.path
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: rootPath, isDirectory: &isDir), isDir.boolValue else {
            throw XcpurgeError.notFound(rootPath)
        }
        let walk = FileWalker(includePods: config.includePods, excludes: config.exclude.map(Glob.init)).walk(root: root)
        let located = try ProjectLocator.locate(root: root, walk: walk, config: config)
        let projects = await parseProjects(located, diagnostics: diagnostics)
        if projects.isEmpty { diagnostics.info("no Xcode project or Swift package found; all files are unattributed") }
        let graph = ModuleGraph.build(projects: projects, rootPath: rootPath,
                                      ignoreTestReferences: config.ignoreTestReferences, diagnostics: diagnostics)
        var inventory = FileInventory(files: walk.files)
        Attribution.apply(to: &inventory, projects: projects, graph: graph)
        let refs = await ReferenceIndex.build(inventory: inventory, graph: graph, rootPath: rootPath,
                                              localizationMacros: config.localizationMacros, diagnostics: diagnostics)
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

    /// Full scan for the given categories.
    public func run(categories: Set<Category> = Set(Category.allCases)) async throws -> ScanResult {
        let context = try await makeContext()
        let detectors = DetectorRegistry.detectors(for: categories)
        let raw: [Finding] = await withTaskGroup(of: [Finding].self) { group in
            for detector in detectors { group.addTask { detector.run(context) } }
            var all: [Finding] = []
            for await part in group { all += part }
            return all
        }
        return ScanResult(context: context, findings: filter(capForSkippedSources(raw, refs: context.refs), context: context))
    }

    /// A reference source that could not be read may hold the only use of anything, so no unused-style
    /// finding stays high when one was skipped. Duplicates do not depend on references.
    func capForSkippedSources(_ findings: [Finding], refs: ReferenceIndex) -> [Finding] {
        guard let first = refs.skippedSources.first else { return findings }
        let more = refs.skippedSources.count > 1 ? " and \(refs.skippedSources.count - 1) more" : ""
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
