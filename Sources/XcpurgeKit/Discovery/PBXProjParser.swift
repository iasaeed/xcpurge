import Foundation

/// Parses `project.pbxproj` (OpenStep plist) into a `ProjectModel`, including synchronized folders.
public enum PBXProjParser {
    public static func parse(xcodeproj: URL, root: URL, diagnostics: Diagnostics) throws -> ProjectModel {
        let file = xcodeproj.appendingPathComponent("project.pbxproj")
        return try parse(data: Data(contentsOf: file), xcodeproj: xcodeproj, root: root, diagnostics: diagnostics)
    }

    public static func parse(data: Data, xcodeproj: URL, root: URL, diagnostics: Diagnostics) throws -> ProjectModel {
        let rootPath = root.standardizedFileURL.path
        let projPath = xcodeproj.standardizedFileURL.path
        let container = RelPath.relative(projPath, to: rootPath)
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String, objects[rootID] != nil
        else { throw XcpurgeError.invalidProject(container, "not a pbxproj property list") }

        let projectObj = objects[rootID]!
        let projectDir = RelPath.join(RelPath.parent(projPath), projectObj["projectDirPath"] as? String ?? "")
        var graph = PBXObjectGraph(objects: objects, rootID: rootID, projectDir: projectDir)
        let rel = { (abs: String) in RelPath.relative(abs, to: rootPath) }

        let unknown = Set(objects.values.compactMap { $0["isa"] as? String }).subtracting(PBXObjectGraph.knownISAs)
        for isa in unknown.sorted() { diagnostics.warn("unknown pbxproj object type \(isa)", path: container) }

        let projectName = RelPath.stem(projPath)
        var model = ProjectModel(container: container, format: .pbxproj, name: projectName,
                                 directory: rel(projectDir),
                                 objectVersion: Int(plist["objectVersion"] as? String ?? ""))

        // Products: file-ref ID -> owning target name, and product file names.
        var productOwner: [String: String] = [:]
        for id in graph.ids(rootID, "targets") {
            if let product = graph.string(id, "productReference"), let name = graph.string(id, "name") {
                productOwner[product] = name
            }
        }

        // Project-level settings layers per configuration.
        let projectLayers = configurationLayers(graph.string(rootID, "buildConfigurationList"), graph: &graph,
                                                diagnostics: diagnostics)

        // Synchronized folders.
        var syncedByID: [String: SyncedGroup] = [:]
        for (id, obj) in objects where obj["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" {
            guard let abs = graph.path(of: id) else { continue }
            syncedByID[id] = SyncedGroup(
                id: id, path: rel(abs),
                explicitFolders: obj["explicitFolders"] as? [String] ?? [],
                explicitFileTypes: obj["explicitFileTypes"] as? [String: String] ?? [:])
        }

        var phaseOwner: [String: String] = [:]
        var membership: [String: Set<String>] = [:]   // file-ref ID -> targets
        for targetID in graph.ids(rootID, "targets") {
            guard let name = graph.string(targetID, "name") else { continue }
            for phase in graph.ids(targetID, "buildPhases") { phaseOwner[phase] = name }
        }

        for targetID in graph.ids(rootID, "targets") {
            guard let obj = graph.object(targetID), let name = obj["name"] as? String else { continue }
            let isa = obj["isa"] as? String ?? ""
            let kind: ModuleKind = isa == "PBXNativeTarget"
                ? ModuleKind(productType: obj["productType"] as? String ?? "") : .aggregate
            var target = TargetModel(name: name, kind: kind, productName: obj["productName"] as? String,
                                     productFile: graph.string(obj["productReference"] as? String, "path"))

            for phaseID in graph.ids(targetID, "buildPhases") {
                let phaseISA = graph.isa(phaseID) ?? ""
                for buildFileID in graph.ids(phaseID, "files") {
                    if let productRef = graph.string(buildFileID, "productRef"),
                       let dep = productDependency(productRef, graph: &graph, rootPath: rootPath) {
                        if !target.productDependencies.contains(dep) { target.productDependencies.append(dep) }
                        continue
                    }
                    guard let refID = graph.string(buildFileID, "fileRef") else { continue }
                    // Products: our own, a subproject's reference proxy, or another workspace project's product
                    // (`sourceTree = BUILT_PRODUCTS_DIR`), matched by file name in `ModuleGraph`.
                    if productOwner[refID] != nil || graph.isa(refID) == "PBXReferenceProxy"
                        || graph.string(refID, "sourceTree") == "BUILT_PRODUCTS_DIR" {
                        let file = graph.string(refID, "path") ?? ""
                        if phaseISA == "PBXFrameworksBuildPhase" { target.linkedProducts.append(file) }
                        else if phaseISA == "PBXCopyFilesBuildPhase" { target.embeddedProducts.append(file) }
                        continue
                    }
                    for member in memberRefIDs(refID, graph: graph) {
                        membership[member, default: []].insert(name)
                        if let abs = graph.path(of: member) { target.members.insert(rel(abs)) }
                    }
                }
            }

            for depID in graph.ids(targetID, "dependencies") {
                if let t = graph.string(depID, "target"), let depName = graph.string(t, "name") {
                    target.dependencies.append(depName)
                } else if let proxy = graph.string(depID, "targetProxy"),
                          graph.string(proxy, "containerPortal") == rootID,
                          let remote = graph.string(proxy, "remoteGlobalIDString"),
                          let depName = graph.string(remote, "name") {
                    target.dependencies.append(depName)
                } else if let proxy = graph.string(depID, "targetProxy"),
                          let portal = graph.string(proxy, "containerPortal"), portal != rootID,
                          let remoteName = graph.string(proxy, "remoteInfo") {
                    let container = graph.path(of: portal).map(rel)
                    let dep = ExternalTargetDependency(container: container, target: remoteName)
                    if !target.externalDependencies.contains(dep) { target.externalDependencies.append(dep) }
                } else if let productRef = graph.string(depID, "productRef"),
                          let dep = productDependency(productRef, graph: &graph, rootPath: rootPath),
                          !target.productDependencies.contains(dep) {
                    target.productDependencies.append(dep)
                }
            }
            for productRef in graph.ids(targetID, "packageProductDependencies") {
                if let dep = productDependency(productRef, graph: &graph, rootPath: rootPath),
                   !target.productDependencies.contains(dep) {
                    target.productDependencies.append(dep)
                }
            }
            target.syncedGroupIDs = graph.ids(targetID, "fileSystemSynchronizedGroups")
            for gid in target.syncedGroupIDs { syncedByID[gid]?.owners.append(name) }

            let targetLayers = configurationLayers(obj["buildConfigurationList"] as? String, graph: &graph,
                                                   diagnostics: diagnostics)
            var configs: [String: [String: String]] = [:]
            var settingsFiles = Set<String>()
            for configName in Set(projectLayers.keys).union(targetLayers.keys) {
                let p = projectLayers[configName] ?? ConfigLayers()
                let t = targetLayers[configName] ?? ConfigLayers()
                settingsFiles.formUnion((p.xcconfigFiles + t.xcconfigFiles).map(rel))
                let builtins = [
                    "SRCROOT": projectDir, "PROJECT_DIR": projectDir, "SOURCE_ROOT": projectDir,
                    "PROJECT_NAME": projectName, "TARGET_NAME": name, "CONFIGURATION": configName,
                    "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_MODULE_NAME": "$(PRODUCT_NAME:c99extidentifier)",
                    "PROJECT_FILE_PATH": projPath,
                ]
                configs[configName] = BuildSettings.resolve(
                    layers: [p.xcconfig, p.settings, t.xcconfig, t.settings], builtins: builtins)
            }
            target.settings = BuildSettings(configurations: configs)
            target.settingsFiles = settingsFiles.sorted()
            if let product = target.settings.value("PRODUCT_NAME"), !product.isEmpty { target.productName = product }
            model.targets.append(target)
        }

        // Exception sets.
        for (gid, obj) in objects where obj["isa"] as? String == "PBXFileSystemSynchronizedRootGroup" {
            for exID in obj["exceptions"] as? [String] ?? [] {
                guard let ex = graph.object(exID) else { continue }
                let paths = ex["membershipExceptions"] as? [String] ?? []
                switch ex["isa"] as? String {
                case "PBXFileSystemSynchronizedBuildFileExceptionSet":
                    guard let targetName = graph.string(ex["target"] as? String, "name") else { continue }
                    syncedByID[gid]?.exceptions.append(SyncedException(
                        target: targetName, sense: .byOwnership, paths: paths,
                        publicHeaders: ex["publicHeaders"] as? [String] ?? [],
                        privateHeaders: ex["privateHeaders"] as? [String] ?? []))
                case "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet":
                    guard let phase = ex["buildPhase"] as? String, let owner = phaseOwner[phase] else { continue }
                    syncedByID[gid]?.exceptions.append(SyncedException(
                        target: owner, sense: .inclusions, isBuildPhase: true, paths: paths))
                default:
                    continue
                }
            }
        }
        model.syncedGroups = syncedByID.values.sorted { $0.path < $1.path }

        // File references and group paths.
        var refs: [ProjectFileRef] = []
        var groupPaths = Set<String>()
        var localPackages = Set<String>()
        for (id, obj) in objects {
            let isa = obj["isa"] as? String
            if isa == "PBXGroup", id != graph.mainGroupID, obj["path"] != nil, let abs = graph.path(of: id) {
                groupPaths.insert(rel(abs))
            }
            guard isa == "PBXFileReference" || isa == "XCVersionGroup", productOwner[id] == nil,
                  graph.isa(graph.parent(of: id)) != "XCVersionGroup",
                  let abs = graph.path(of: id) else { continue }
            let type = obj["lastKnownFileType"] as? String ?? obj["explicitFileType"] as? String ?? ""
            if FileManager.default.fileExists(atPath: abs + "/Package.swift") {
                localPackages.insert(rel(abs))
                continue
            }
            refs.append(ProjectFileRef(path: rel(abs), targets: membership[id] ?? [], isFolder: type == "folder"))
        }
        for packageID in graph.ids(rootID, "packageReferences")
        where graph.isa(packageID) == "XCLocalSwiftPackageReference" {
            if let relative = graph.string(packageID, "relativePath") {
                localPackages.insert(rel(RelPath.join(projectDir, relative)))
            }
        }
        model.fileRefs = refs.sorted { $0.path < $1.path }
        model.groupPaths = groupPaths.sorted()
        model.localPackages = localPackages.sorted()
        return model
    }

    /// File-ref IDs a build file stands for (variant groups expand to their localized children).
    private static func memberRefIDs(_ id: String, graph: PBXObjectGraph) -> [String] {
        switch graph.isa(id) {
        case "PBXVariantGroup", "PBXGroup": graph.ids(id, "children")
        default: [id]
        }
    }

    private static func productDependency(_ id: String, graph: inout PBXObjectGraph, rootPath: String) -> ProductDependency? {
        guard var product = graph.string(id, "productName") else { return nil }
        if product.hasPrefix("plugin:") { product = String(product.dropFirst("plugin:".count)) }
        let packageID = graph.string(id, "package")
        switch graph.isa(packageID) {
        case "XCLocalSwiftPackageReference":
            let relative = graph.string(packageID, "relativePath") ?? ""
            let dir = RelPath.relative(RelPath.join(graph.projectDir, relative), to: rootPath)
            return ProductDependency(packageDir: dir, package: RelPath.lastComponent(relative), product: product)
        case "XCRemoteSwiftPackageReference":
            let url = graph.string(packageID, "repositoryURL") ?? ""
            var identity = RelPath.lastComponent(url)
            if identity.hasSuffix(".git") { identity.removeLast(4) }
            return ProductDependency(package: identity, product: product)
        default:
            return ProductDependency(product: product)
        }
    }

    struct ConfigLayers {
        var xcconfig: [String: String] = [:]
        var settings: [String: String] = [:]
        var xcconfigFiles: [String] = []
    }

    private static func configurationLayers(_ listID: String?, graph: inout PBXObjectGraph,
                                            diagnostics: Diagnostics) -> [String: ConfigLayers] {
        var out: [String: ConfigLayers] = [:]
        for configID in graph.ids(listID, "buildConfigurations") {
            guard let name = graph.string(configID, "name") else { continue }
            var layers = ConfigLayers(settings: graph.buildSettings(configID))
            var xcconfigPath: String?
            if let base = graph.string(configID, "baseConfigurationReference") {
                xcconfigPath = graph.path(of: base)
            } else if let anchor = graph.string(configID, "baseConfigurationReferenceAnchor"),
                      let anchorPath = graph.path(of: anchor),
                      let relative = graph.string(configID, "baseConfigurationReferenceRelativePath") {
                xcconfigPath = RelPath.join(anchorPath, relative)
            }
            if let path = xcconfigPath {
                let parsed = XCConfigParser.parse(url: URL(fileURLWithPath: path), diagnostics: diagnostics)
                layers.xcconfig = parsed.settings
                layers.xcconfigFiles = parsed.files.map { $0.standardizedFileURL.path }
            }
            out[name] = layers
        }
        return out
    }
}
