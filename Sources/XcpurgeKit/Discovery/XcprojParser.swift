import Foundation

/// Parses the Xcode 27.2+ JSON5 `project.xcproj` tree (apple/xcode-project-format schema) into a `ProjectModel`.
/// Tolerant: unknown keys are ignored, unknown top-level keys and capabilities produce warnings.
public enum XcprojParser {
    static let knownTopLevelKeys: Set<String> = [
        "required-capabilities", "id", "root-group-debug-id", "configuration-list-debug-id", "organization",
        "class-prefix", "build-independent-targets-in-parallel", "default-configuration", "configurations",
        "localizations", "imported-products", "packages", "files", "targets", "build-settings", "products-group",
        "last-upgrade", "last-swift-update", "last-swift-migration",
    ]

    public static func parse(xcodeproj: URL, root: URL, diagnostics: Diagnostics) throws -> ProjectModel {
        let file = xcodeproj.appendingPathComponent("project.xcproj")
        return try parse(data: Data(contentsOf: file), xcodeproj: xcodeproj, root: root, diagnostics: diagnostics)
    }

    public static func parse(data: Data, xcodeproj: URL, root: URL, diagnostics: Diagnostics) throws -> ProjectModel {
        let rootPath = root.standardizedFileURL.path
        let projPath = xcodeproj.standardizedFileURL.path
        let container = RelPath.relative(projPath, to: rootPath)
        let decoder = JSONDecoder()
        decoder.allowsJSON5 = true
        let tree: JSONValue
        do { tree = try decoder.decode(JSONValue.self, from: data) } catch {
            throw XcpurgeError.invalidProject(container, "project.xcproj is not valid JSON5: \(error)")
        }
        guard let top = tree.objectValue else { throw XcpurgeError.invalidProject(container, "project.xcproj root is not an object") }
        for key in top.keys.sorted() where !knownTopLevelKeys.contains(key) {
            diagnostics.warn("unknown project.xcproj key \(key)", path: container)
        }
        let projectDir = RelPath.parent(projPath)
        let projectName = RelPath.stem(projPath)
        var model = ProjectModel(container: container, format: .xcproj, name: projectName,
                                 directory: RelPath.relative(projectDir, to: rootPath))
        let capabilities = (top["required-capabilities"]?.arrayValue ?? []).compactMap(\.stringValue)
        if !capabilities.isEmpty {
            diagnostics.warn("project.xcproj requires unsupported capabilities (\(capabilities.joined(separator: ", "))); file membership is not trusted",
                             path: container)
            model.membershipUnknown = true
        }

        // Configurations: project list (names or {name, file}).
        var configFiles: [String: String] = [:]
        var configNames: [String] = []
        for entry in top["configurations"]?.arrayValue ?? [] {
            if let name = entry.stringValue { configNames.append(name) }
            else if let name = entry["name"]?.stringValue {
                configNames.append(name)
                if let file = entry["file"]?.stringValue { configFiles[name] = file }
            }
        }
        if configNames.isEmpty { configNames = [top["default-configuration"]?.stringValue ?? "Release"] }
        let projectSettings = flatSettings(top["build-settings"])

        var walker = TreeWalker(projectDir: projectDir, rootPath: rootPath)
        for node in top["files"]?.arrayValue ?? [] { walker.visit(node, base: projectDir) }

        // Targets.
        for node in top["targets"]?.arrayValue ?? [] {
            guard let name = node["name"]?.stringValue else { continue }
            let kindString = node["kind"]?.stringValue ?? "native"
            let productType = node["product-type"]?.stringValue ?? node["full-product-type"]?.stringValue ?? ""
            let kind: ModuleKind = kindString == "native" ? ModuleKind(productType: productType) : .aggregate
            let productFile = node["product"]?.stringValue.map(RelPath.lastComponent)
            var target = TargetModel(name: name, kind: kind, productFile: productFile)
            for dep in node["dependencies"]?.arrayValue ?? [] {
                if let local = dep.stringValue { target.dependencies.append(local); continue }
                switch dep["kind"]?.stringValue ?? "localTarget" {
                case "localTarget": if let t = dep["target"]?.stringValue { target.dependencies.append(t) }
                case "package":
                    if let product = dep["product-name"]?.stringValue {
                        target.productDependencies.append(productDependency(dep["package"]?.stringValue, product,
                                                                            projectDir: projectDir, rootPath: rootPath))
                    }
                default: continue
                }
            }
            for member in node["package-product-members"]?.arrayValue ?? [] {
                guard let product = member["product-name"]?.stringValue else { continue }
                let dep = productDependency(member["package"]?.stringValue, product, projectDir: projectDir, rootPath: rootPath)
                if !target.productDependencies.contains(dep) { target.productDependencies.append(dep) }
            }

            var targetConfigFiles = configFiles
            for entry in node["specialized-configurations"]?.arrayValue ?? [] {
                if let n = entry["name"]?.stringValue, let file = entry["file"]?.stringValue { targetConfigFiles[n] = file }
            }
            let targetSettings = flatSettings(node["build-settings"])
            var configs: [String: [String: String]] = [:]
            var settingsFiles = Set<String>()
            for configName in configNames {
                var xcconfig: [String: String] = [:]
                if let file = targetConfigFiles[configName], let abs = walker.resolve(file, base: projectDir) {
                    let parsed = XCConfigParser.parse(url: URL(fileURLWithPath: abs), diagnostics: diagnostics)
                    xcconfig = parsed.settings
                    settingsFiles.formUnion(parsed.files.map { RelPath.relative($0.standardizedFileURL.path, to: rootPath) })
                }
                let builtins = [
                    "SRCROOT": projectDir, "PROJECT_DIR": projectDir, "SOURCE_ROOT": projectDir,
                    "PROJECT_NAME": projectName, "TARGET_NAME": name, "CONFIGURATION": configName,
                    "PRODUCT_NAME": "$(TARGET_NAME)", "PRODUCT_MODULE_NAME": "$(PRODUCT_NAME:c99extidentifier)",
                ]
                configs[configName] = BuildSettings.resolve(
                    layers: [projectSettings.layer(configName), xcconfig, targetSettings.layer(configName)],
                    builtins: builtins)
            }
            target.settings = BuildSettings(configurations: configs)
            target.settingsFiles = settingsFiles.sorted()
            if let product = target.settings.value("PRODUCT_NAME"), !product.isEmpty { target.productName = product }
            model.targets.append(target)
        }

        // File membership: products in copy/frameworks phases become embeds/links, the rest are members.
        let productOwners = Dictionary(model.targets.compactMap { t in t.productFile.map { ($0, t.name) } },
                                       uniquingKeysWith: { a, _ in a })
        var refs: [ProjectFileRef] = []
        for file in walker.files {
            var targets = Set<String>()
            let fileName = RelPath.lastComponent(file.path)
            for (targetName, phaseKind) in file.membership {
                guard let index = model.targets.firstIndex(where: { $0.name == targetName }) else { continue }
                if productOwners[fileName] != nil, phaseKind == "copy" || phaseKind == "frameworks" {
                    if phaseKind == "copy" { model.targets[index].embeddedProducts.append(fileName) }
                    else { model.targets[index].linkedProducts.append(fileName) }
                    continue
                }
                guard file.resolved else { continue }
                targets.insert(targetName)
                if !model.membershipUnknown { model.targets[index].members.insert(file.path) }
            }
            guard file.resolved, !(file.isProductsGroup && productOwners[fileName] != nil) else { continue }
            refs.append(ProjectFileRef(path: file.path, targets: model.membershipUnknown ? [] : targets))
        }
        model.fileRefs = refs.sorted { $0.path < $1.path }
        model.groupPaths = walker.groupPaths.sorted()
        model.syncedGroups = model.membershipUnknown ? [] : walker.folders
        for group in model.syncedGroups {
            for owner in group.owners {
                if let i = model.targets.firstIndex(where: { $0.name == owner }) { model.targets[i].syncedGroupIDs.append(group.id) }
            }
        }
        var packages = Set<String>()
        for package in top["packages"]?.arrayValue ?? [] where package["kind"]?.stringValue == "local" {
            if let path = package["path"]?.stringValue {
                packages.insert(RelPath.relative(RelPath.join(projectDir, path), to: rootPath))
            }
        }
        model.localPackages = packages.sorted()
        return model
    }

    private static func productDependency(_ package: String?, _ product: String, projectDir: String,
                                          rootPath: String) -> ProductDependency {
        guard let package else { return ProductDependency(product: product) }
        if package.contains("://") || package.hasPrefix("git@") {
            var identity = RelPath.lastComponent(package)
            if identity.hasSuffix(".git") { identity.removeLast(4) }
            return ProductDependency(package: identity, product: product)
        }
        let dir = RelPath.relative(RelPath.join(projectDir, package), to: rootPath)
        return ProductDependency(packageDir: dir, package: RelPath.lastComponent(package), product: product)
    }

    /// Splits `KEY[config=Debug]` keys into per-configuration layers.
    struct FlatSettings {
        var common: [String: String] = [:]
        var perConfig: [String: [String: String]] = [:]

        func layer(_ config: String) -> [String: String] {
            common.merging(perConfig[config] ?? [:]) { _, specific in specific }
        }
    }

    static func flatSettings(_ value: JSONValue?) -> FlatSettings {
        var out = FlatSettings()
        for (rawKey, v) in value?.objectValue ?? [:] {
            let text: String
            switch v {
            case .string(let s): text = s
            case .array(let a): text = a.compactMap(\.stringValue).map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
            default: continue
            }
            if let range = rawKey.range(of: #"\[config=([^\]]+)\]"#, options: .regularExpression) {
                let config = String(rawKey[range].dropFirst("[config=".count).dropLast())
                let key = rawKey.replacingCharacters(in: range, with: "")
                out.perConfig[config, default: [:]][key] = text
            } else {
                out.common[rawKey] = text
            }
        }
        return out
    }

    /// Walks the `files` tree resolving paths; collects file refs, group paths and folders.
    struct TreeWalker {
        struct FileNode {
            var path: String
            /// (target name, phase kind) pairs from `target-membership`.
            var membership: [(String, String)]
            var isProductsGroup: Bool
            /// False for build-products / SDK paths; `path` is then just the raw path.
            var resolved: Bool
        }

        let projectDir: String
        let rootPath: String
        var files: [FileNode] = []
        var groupPaths = Set<String>()
        var folders: [SyncedGroup] = []
        private var inProducts = false

        init(projectDir: String, rootPath: String) {
            self.projectDir = projectDir
            self.rootPath = rootPath
        }

        /// Resolves an xcproj FilePath string (`<PROJECT>/x`, `<USER:SRCROOT>/x`, `/abs`, `rel`).
        func resolve(_ path: String, base: String) -> String? {
            if path.hasPrefix("<USER:") {
                guard let end = path.range(of: ">/") else { return nil }
                let variable = String(path[path.index(path.startIndex, offsetBy: 6)..<end.lowerBound])
                guard ["SRCROOT", "PROJECT_DIR", "SOURCE_ROOT"].contains(variable) else { return nil }
                return RelPath.join(projectDir, String(path[end.upperBound...]))
            }
            if path.hasPrefix("<PROJECT>/") { return RelPath.join(projectDir, String(path.dropFirst("<PROJECT>/".count))) }
            if path.hasPrefix("<") { return nil }
            if path.hasPrefix("~") { return RelPath.normalize(NSString(string: path).expandingTildeInPath) }
            return RelPath.join(base, path.replacingOccurrences(of: "\\<", with: "<"))
        }

        /// - Parameter inherited: membership of an enclosing variant group, which its localized children share.
        mutating func visit(_ node: JSONValue, base: String, inherited: [(String, String)] = []) {
            let rawPath = node["path"]?.stringValue ?? ""
            guard let abs = resolve(rawPath, base: base) else {
                // Build products and SDK files: keep only their membership (embed / link phases).
                if (node["kind"]?.stringValue ?? "file-reference") == "file-reference" {
                    files.append(FileNode(path: rawPath, membership: membership(node) + inherited, isProductsGroup: inProducts,
                                          resolved: false))
                }
                return
            }
            let rel = RelPath.relative(abs, to: rootPath)
            switch node["kind"]?.stringValue ?? "file-reference" {
            case let kind where kind == "group" || kind == "variant-group":
                let name = node["name"]?.stringValue ?? RelPath.lastComponent(rawPath)
                if !rawPath.isEmpty { groupPaths.insert(rel) }
                let wasProducts = inProducts
                if name == "Products" { inProducts = true }
                let passed = kind == "variant-group" ? inherited + membership(node) : inherited
                for child in node["children"]?.arrayValue ?? [] { visit(child, base: abs, inherited: passed) }
                inProducts = wasProducts
            case "folder":
                var exceptions: [SyncedException] = []
                for ex in node["membership-exceptions"]?.arrayValue ?? [] {
                    let excluded = ex["exclusions"]?.arrayValue
                    let paths = (excluded ?? ex["inclusions"]?.arrayValue ?? []).compactMap(\.stringValue)
                    if let target = ex["target"]?.stringValue {
                        exceptions.append(SyncedException(
                            target: target, sense: excluded != nil ? .exclusions : .inclusions, paths: paths,
                            publicHeaders: (ex["public-headers"]?.arrayValue ?? []).compactMap(\.stringValue),
                            privateHeaders: (ex["private-headers"]?.arrayValue ?? []).compactMap(\.stringValue)))
                    } else if let phase = ex["build-phase"]?.stringValue,
                              let target = phase.split(separator: "/").first.map(String.init) {
                        exceptions.append(SyncedException(target: target, sense: .inclusions, isBuildPhase: true, paths: paths))
                    }
                }
                var fileTypes: [String: String] = [:]
                for (k, v) in node["file-types"]?.objectValue ?? [:] { fileTypes[k] = v.stringValue }
                folders.append(SyncedGroup(
                    id: node["id"]?.stringValue ?? rel, path: rel,
                    owners: (node["target-membership"]?.arrayValue ?? []).compactMap(\.stringValue),
                    exceptions: exceptions,
                    explicitFolders: (node["opaque-folders"]?.arrayValue ?? []).compactMap(\.stringValue),
                    explicitFileTypes: fileTypes))
            default:
                files.append(FileNode(path: rel, membership: membership(node) + inherited, isProductsGroup: inProducts,
                                      resolved: true))
            }
        }

        /// `target-membership` entries (`"App/compile-sources"` or `{ "build-phase": … }`) as (target, phase kind).
        private func membership(_ node: JSONValue) -> [(String, String)] {
            (node["target-membership"]?.arrayValue ?? []).compactMap { entry in
                guard let phase = entry.stringValue ?? entry["build-phase"]?.stringValue else { return nil }
                let parts = phase.split(separator: "/").map(String.init)
                guard let target = parts.first else { return nil }
                return (target, parts.count > 1 ? parts[1] : "")
            }
        }
    }
}
