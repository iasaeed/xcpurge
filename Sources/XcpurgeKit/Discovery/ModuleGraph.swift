/// All modules and their dependency / embedding edges, with the precomputed `consumers` closure (plan §4.2):
/// a reference in module S counts for a resource in module M iff S ∈ consumers(M).
public struct ModuleGraph: Sendable {
    public let modules: [ModuleID: Module]
    public let ignoresTestReferences: Bool
    private let consumerMap: [ModuleID: Set<ModuleID>]

    public init(modules: [Module], ignoreTestReferences: Bool = false) {
        var byID: [ModuleID: Module] = [:]
        for m in modules { byID[m.id] = m }
        self.modules = byID
        self.ignoresTestReferences = ignoreTestReferences
        var reverse: [ModuleID: Set<ModuleID>] = [:]
        for m in modules {
            for d in m.dependsOn.union(m.embeds) { reverse[d, default: []].insert(m.id) }
        }
        var map: [ModuleID: Set<ModuleID>] = [:]
        for m in modules {
            var seen: Set<ModuleID> = [m.id]
            var queue = [m.id]
            while let next = queue.popLast() {
                for c in reverse[next] ?? [] where seen.insert(c).inserted { queue.append(c) }
            }
            if ignoreTestReferences {
                seen = seen.filter { $0 == m.id || byID[$0]?.kind.isTest != true }
            }
            seen.insert(.unknown)
            map[m.id] = seen
        }
        var everyone = Set(byID.keys)
        if ignoreTestReferences { everyone = everyone.filter { byID[$0]?.kind.isTest != true } }
        map[.unknown] = everyone.union([.unknown])
        self.consumerMap = map
    }

    /// Modules sorted by container then name.
    public var sorted: [Module] { modules.values.sorted { $0.id < $1.id } }

    public func module(_ id: ModuleID) -> Module? { modules[id] }

    public func modules(named name: String) -> [Module] { sorted.filter { $0.id.name == name } }

    /// `{M, .unknown}` ∪ every module that depends on or embeds M, transitively.
    public func consumers(of id: ModuleID) -> Set<ModuleID> { consumerMap[id] ?? [id, .unknown] }

    /// True when a site attributed to `siteModules` can see resources of `id`.
    public func isVisible(from siteModules: Set<ModuleID>, to id: ModuleID) -> Bool {
        let sites = siteModules.isEmpty ? [ModuleID.unknown] : siteModules
        return !consumers(of: id).isDisjoint(with: sites)
    }

    /// Builds modules from parsed projects and packages and links their edges.
    public static func build(projects: [ProjectModel], rootPath: String, ignoreTestReferences: Bool,
                             diagnostics: Diagnostics) -> ModuleGraph {
        var modules: [ModuleID: Module] = [:]
        var packageByDir: [String: ProjectModel] = [:]
        for p in projects where p.format == .package { packageByDir[p.directory] = p }

        for project in projects {
            let projectDir = RelPath.join(rootPath, project.directory)
            for t in project.targets {
                let id = ModuleID(container: project.container, name: t.name)
                var settingsFiles = t.settingsFiles
                var plist: [String: JSONValue] = [:]
                if project.format != .package {
                    let read = InfoPlistReader.read(settings: t.settings, projectDir: projectDir)
                    plist = read.plist
                    if let file = read.file { settingsFiles.append(RelPath.relative(file, to: rootPath)) }
                    if let entitlements = t.settings.value("CODE_SIGN_ENTITLEMENTS"), !entitlements.isEmpty {
                        settingsFiles.append(RelPath.relative(RelPath.join(projectDir, entitlements), to: rootPath))
                    }
                }
                let rootPaths = project.syncedGroups.filter { t.syncedGroupIDs.contains($0.id) }.map(\.path)
                    + (t.sourceDir.map { [$0] } ?? [])
                let moduleName = project.format == .package ? BuildSettings.c99Identifier(t.name)
                    : (t.settings.value("PRODUCT_MODULE_NAME").flatMap { $0.isEmpty ? nil : $0 }
                        ?? BuildSettings.c99Identifier(t.productName))
                modules[id] = Module(id: id, kind: t.kind, productName: t.productName, moduleName: moduleName,
                                     settings: t.settings, infoPlist: plist, rootPaths: rootPaths.sorted(),
                                     settingsFiles: Array(Set(settingsFiles)).sorted())
            }
        }

        for project in projects {
            for t in project.targets {
                let id = ModuleID(container: project.container, name: t.name)
                var depends = Set<ModuleID>(), embeds = Set<ModuleID>()
                for name in t.dependencies {
                    let dep = ModuleID(container: project.container, name: name)
                    if modules[dep] != nil, dep != id { depends.insert(dep) }
                }
                for file in t.linkedProducts { depends.formUnion(productOwners(file, preferring: project, in: projects)) }
                for file in t.embeddedProducts { embeds.formUnion(productOwners(file, preferring: project, in: projects)) }
                for dep in t.productDependencies {
                    let resolved = resolve(dep, from: project, packages: packageByDir, all: projects)
                    if resolved.isEmpty, dep.packageDir != nil {
                        diagnostics.info("package product \(dep.product) not found in \(dep.packageDir!)", path: project.container)
                    }
                    depends.formUnion(resolved)
                }
                depends.remove(id)
                embeds.remove(id)
                modules[id]?.dependsOn = depends
                modules[id]?.embeds = embeds
            }
        }
        return ModuleGraph(modules: Array(modules.values), ignoreTestReferences: ignoreTestReferences)
    }

    private static func productOwners(_ file: String, preferring project: ProjectModel, in projects: [ProjectModel]) -> Set<ModuleID> {
        let ordered = [project] + projects.filter { $0.container != project.container }
        for p in ordered {
            if let t = p.targets.first(where: { $0.productFile == file }) {
                return [ModuleID(container: p.container, name: t.name)]
            }
        }
        return []
    }

    private static func resolve(_ dep: ProductDependency, from project: ProjectModel,
                                packages: [String: ProjectModel], all: [ProjectModel]) -> Set<ModuleID> {
        var candidates: [ProjectModel] = []
        if let dir = dep.packageDir {
            candidates = packages[dir].map { [$0] } ?? []
        } else if let identity = dep.package?.lowercased(), let dir = project.packageDependencies[identity] {
            candidates = packages[dir].map { [$0] } ?? []
        } else {
            let declared = Set(project.packageDependencies.values)
            candidates = packages.keys.sorted().compactMap { packages[$0] }
                .sorted { declared.contains($0.directory) && !declared.contains($1.directory) }
        }
        for pkg in candidates {
            if let targets = pkg.products[dep.product] {
                return Set(targets.map { ModuleID(container: pkg.container, name: $0) })
            }
            if pkg.target(named: dep.product) != nil { return [ModuleID(container: pkg.container, name: dep.product)] }
        }
        return []
    }
}
