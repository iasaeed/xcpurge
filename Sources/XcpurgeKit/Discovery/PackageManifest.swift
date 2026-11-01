import Foundation

/// Loads Swift packages via `swift package dump-package` (concurrently, in its own process group, 60 s timeout per
/// manifest, private scratch path), falling back to `PackageManifestRegexFallback` when `--no-swift` /
/// `XCPURGE_NO_SWIFT=1` is set or swift fails or times out. Note that dump-package compiles and runs the manifest.
public enum PackageManifest {
    /// Longest a single `dump-package` may run before its manifest is read as text instead.
    public static let dumpTimeout: TimeInterval = 60
    public static let swiftCommand = ["/usr/bin/env", "swift"]

    /// - Parameters:
    ///   - packageDirs: root-relative package directories (`""` for the root).
    ///   - timeout: per-manifest limit for `dump-package` (tests shorten it).
    ///   - swift: the command that runs swift (tests substitute a fake that hangs).
    public static func load(packageDirs: [String], root: URL, useSwift: Bool, diagnostics: Diagnostics,
                            timeout: TimeInterval = dumpTimeout, swift: [String] = swiftCommand) async -> [ProjectModel] {
        let rootPath = root.standardizedFileURL.path
        let swiftAllowed = useSwift && ProcessInfo.processInfo.environment["XCPURGE_NO_SWIFT"] != "1"
        // Ctrl-C or SIGTERM must take the swift-package / swift-frontend children with it.
        let interrupts = swiftAllowed ? ProcessRunner.InterruptGuard() : nil
        defer { interrupts?.dispose() }
        return await withTaskGroup(of: (Int, ProjectModel?).self) { group in
            for (i, dir) in packageDirs.enumerated() {
                group.addTask {
                    let abs = RelPath.join(rootPath, dir)
                    if swiftAllowed {
                        do {
                            let data = try await dumpPackage(at: abs, timeout: timeout, swift: swift)
                            return (i, try model(fromDump: data, packageDir: dir, rootPath: rootPath))
                        } catch {
                            diagnostics.warn("swift package dump-package failed (\(error)); using manifest text fallback",
                                             path: RelPath.join(dir, "Package.swift"))
                        }
                    }
                    guard let text = try? String(contentsOfFile: abs + "/Package.swift", encoding: .utf8) else {
                        diagnostics.warn("cannot read Package.swift", path: dir)
                        return (i, nil)
                    }
                    if swiftAllowed == false {
                        diagnostics.info("Package.swift parsed without swift (text fallback)", path: RelPath.join(dir, "Package.swift"))
                    }
                    return (i, PackageManifestRegexFallback.parse(text: text, packageDir: dir, rootPath: rootPath))
                }
            }
            var results: [(Int, ProjectModel)] = []
            for await (i, model) in group { if let model { results.append((i, model)) } }
            return results.sorted { $0.0 < $1.0 }.map(\.1)
        }
    }

    /// Runs `swift package dump-package` with a per-package scratch directory under `$TMPDIR/xcpurge`.
    static func dumpPackage(at dir: String, timeout: TimeInterval = dumpTimeout, swift: [String] = swiftCommand) async throws -> Data {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcpurge/\(stableHash(dir))").path
        let result = try await ProcessRunner.runAsync(
            swift[0], Array(swift.dropFirst()) + ["package", "dump-package", "--package-path", dir, "--scratch-path", scratch],
            timeout: timeout)
        guard result.status == 0, !result.timedOut else {
            throw XcpurgeError.invalidProject(dir, result.timedOut ? "timed out after \(Int(timeout)) s" : "exit status \(result.status)")
        }
        return result.stdout
    }

    static func stableHash(_ s: String) -> String {
        var h: UInt64 = 0xcbf29ce484222325
        for byte in s.utf8 { h = (h ^ UInt64(byte)) &* 0x100000001b3 }
        return String(h, radix: 16)
    }

    /// Converts `dump-package` JSON into a `ProjectModel`.
    public static func model(fromDump data: Data, packageDir: String, rootPath: String) throws -> ProjectModel {
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data), let top = json.objectValue else {
            throw XcpurgeError.invalidProject(packageDir, "dump-package output is not JSON")
        }
        var targets: [ManifestTarget] = []
        for t in top["targets"]?.arrayValue ?? [] {
            guard let name = t["name"]?.stringValue else { continue }
            var target = ManifestTarget(name: name, type: t["type"]?.stringValue ?? "regular", path: t["path"]?.stringValue)
            target.exclude = (t["exclude"]?.arrayValue ?? []).compactMap(\.stringValue)
            for r in t["resources"]?.arrayValue ?? [] {
                guard let path = r["path"]?.stringValue else { continue }
                let ruleKey = r["rule"]?.objectValue?.keys.first ?? "process"
                target.resources.append(PackageResource(path: path, rule: PackageResource.Rule(rawValue: ruleKey) ?? .process))
            }
            for d in t["dependencies"]?.arrayValue ?? [] {
                if let n = d["byName"]?.arrayValue?.first?.stringValue { target.dependencies.append(.byName(n)) }
                else if let n = d["target"]?.arrayValue?.first?.stringValue { target.dependencies.append(.target(n)) }
                else if let p = d["product"]?.arrayValue, let n = p.first?.stringValue {
                    target.dependencies.append(.product(name: n, package: p.count > 1 ? p[1].stringValue : nil))
                }
            }
            targets.append(target)
        }
        var products: [String: [String]] = [:]
        for p in top["products"]?.arrayValue ?? [] {
            if let name = p["name"]?.stringValue { products[name] = (p["targets"]?.arrayValue ?? []).compactMap(\.stringValue) }
        }
        var deps: [String: String] = [:]
        for d in top["dependencies"]?.arrayValue ?? [] {
            for local in d["fileSystem"]?.arrayValue ?? [] {
                guard let identity = local["identity"]?.stringValue, let path = local["path"]?.stringValue else { continue }
                deps[identity] = RelPath.relative(path, to: rootPath)
            }
        }
        let name = top["name"]?.stringValue ?? RelPath.lastComponent(RelPath.join(rootPath, packageDir))
        return build(name: name, packageDir: packageDir, rootPath: rootPath, targets: targets, products: products,
                     dependencies: deps)
    }

    /// Shared model builder: target directories, excludes, resources and dependency resolution inputs.
    static func build(name: String, packageDir: String, rootPath: String, targets: [ManifestTarget],
                      products: [String: [String]], dependencies: [String: String]) -> ProjectModel {
        let container = packageDir.isEmpty ? "." : packageDir
        var model = ProjectModel(container: container, format: .package, name: name, directory: packageDir,
                                 products: products, packageDependencies: dependencies)
        let absDir = RelPath.join(rootPath, packageDir)
        let localNames = Set(targets.map(\.name))
        for t in targets where t.type != "binary" && t.type != "system" {
            let dir = RelPath.join(packageDir, t.path ?? defaultPath(for: t, packageDir: absDir))
            var target = TargetModel(name: t.name, kind: ModuleKind(packageTargetType: t.type), sourceDir: dir)
            target.excludes = t.exclude.map { RelPath.join(dir, $0) }
            target.resources = t.resources.map { PackageResource(path: RelPath.join(dir, $0.path), rule: $0.rule) }
            for dep in t.dependencies {
                switch dep {
                case .byName(let n) where localNames.contains(n), .target(let n):
                    target.dependencies.append(n)
                case .byName(let n):
                    target.productDependencies.append(ProductDependency(product: n))
                case .product(let n, let package):
                    let identity = package?.lowercased()
                    target.productDependencies.append(ProductDependency(
                        packageDir: identity.flatMap { dependencies[$0] }, package: package, product: n))
                }
            }
            model.targets.append(target)
        }
        model.localPackages = dependencies.values.sorted()
        return model
    }

    /// SwiftPM's default target directory (`Sources/<name>`, `Tests/<name>`, `Plugins/<name>`, or `Source`, `src`, `srcs`).
    static func defaultPath(for t: ManifestTarget, packageDir: String) -> String {
        let roots: [String] = switch t.type {
        case "test": ["Tests", "Sources", "Source", "src", "srcs"]
        case "plugin": ["Plugins"]
        default: ["Sources", "Source", "src", "srcs"]
        }
        for r in roots where FileManager.default.fileExists(atPath: "\(packageDir)/\(r)/\(t.name)") {
            return "\(r)/\(t.name)"
        }
        return "\(roots[0])/\(t.name)"
    }
}
