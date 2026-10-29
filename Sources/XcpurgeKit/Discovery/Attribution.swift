/// Assigns modules, `inSourceRoot` and `projectRefs` to inventory files from parsed projects and packages.
public enum Attribution {
    public static func apply(to inventory: inout FileInventory, projects: [ProjectModel], graph: ModuleGraph) {
        for project in projects {
            let id = { (name: String) in ModuleID(container: project.container, name: name) }
            if project.format == .package {
                for t in project.targets {
                    guard let dir = t.sourceDir else { continue }
                    for i in inventory.indices(under: dir) {
                        let path = inventory.files[i].path
                        if t.excludes.contains(where: { RelPath.isUnder(path, $0) }) { continue }
                        inventory.update(index: i) { $0.modules.insert(id(t.name)); $0.inSourceRoot = true }
                    }
                }
                continue
            }
            for ref in project.fileRefs {
                if inventory.index(of: ref.path) != nil {
                    inventory.update(ref.path) { $0.projectRefs.insert(project.container) }
                }
                guard !project.membershipUnknown, !ref.targets.isEmpty else { continue }
                for i in inventory.indices(under: ref.path) {
                    inventory.update(index: i) { $0.modules.formUnion(ref.targets.map(id)) }
                }
            }
            for dir in project.groupPaths {
                for i in inventory.indices(under: dir) { inventory.update(index: i) { $0.inSourceRoot = true } }
            }
            for group in project.syncedGroups {
                let indices = inventory.indices(under: group.path)
                for i in indices { inventory.update(index: i) { $0.inSourceRoot = true } }
                let members = SyncedFolderResolver.resolve(group, files: indices.map { inventory.files[$0].path })
                for (target, paths) in members {
                    for path in paths { inventory.update(path) { $0.modules.insert(id(target)) } }
                }
            }
        }
        for module in graph.sorted {
            for path in module.settingsFiles { inventory.update(path) { $0.modules.insert(module.id) } }
        }
    }
}
