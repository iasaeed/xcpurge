import Foundation

/// Enumerates the scan root, skipping build output and VCS folders and treating bundle-like folders as units.
public struct FileWalker: Sendable {
    public var includePods: Bool
    /// `--exclude` globs: files there are still inventoried (they stay reference sources; the engine drops
    /// findings about them), but no project, workspace or package is discovered inside them.
    public var excludes: [Glob]

    public init(includePods: Bool = false, excludes: [Glob] = []) {
        self.includePods = includePods
        self.excludes = excludes
    }

    static let skippedNames: Set<String> = ["DerivedData", "node_modules", "xcuserdata"]
    /// Build products that may sit in a repo-local `build/` folder.
    static let skippedExtensions: Set<String> = ["app", "appex", "xcarchive", "dSYM", "noindex", "xctest"]
    /// A directory containing any of these is build output (DerivedData-style, SwiftPM scratch, legacy `build/`).
    static let buildMarkers = ["workspace-state.json", "XCBuildData", "Index.noindex", "ModuleCache.noindex",
                               "Build/Intermediates.noindex"]

    /// - Parameter onFile: called with the running file count after each file is inventoried.
    public func walk(root: URL, onFile: (Int) -> Void = { _ in }) -> WalkResult {
        let fm = FileManager.default
        let rootPath = root.standardizedFileURL.path
        var result = WalkResult(files: [], xcodeprojs: [], workspaces: [], packages: [])
        guard let enumerator = fm.enumerator(atPath: rootPath) else { return result }

        while let rel = enumerator.nextObject() as? String {
            let name = RelPath.lastComponent(rel)
            let type = enumerator.fileAttributes?[.type] as? FileAttributeType
            let isDir = type == .typeDirectory
            if name.hasPrefix(".") || name == "Icon\r" {
                if isDir { enumerator.skipDescendants() }
                continue
            }
            let excluded = excludes.contains { $0.matches(rel) }
            guard isDir else {
                guard type == .typeRegular else { continue }
                // A report or baseline xcpurge wrote names every finding; read as a source it would hide them all.
                if ToolOutput.isGeneratedReport(path: rel, absolute: rootPath + "/" + rel) { continue }
                if name == "Package.swift", !excluded { result.packages.append(RelPath.parent(rel)) }
                let size = (enumerator.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
                result.files.append(SourceFile(path: rel, kind: FileKind(path: rel), size: size))
                onFile(result.files.count)
                continue
            }
            let ext = (name as NSString).pathExtension
            if ext == "xcodeproj" || ext == "xcworkspace" {
                if !excluded { ext == "xcodeproj" ? result.xcodeprojs.append(rel) : result.workspaces.append(rel) }
                enumerator.skipDescendants()
                continue
            }
            if shouldSkip(dir: rel, name: name, ext: ext, absolute: rootPath + "/" + rel) {
                enumerator.skipDescendants()
                continue
            }
            if FileKind.bundleExtensions.contains(ext.lowercased()) {
                enumerator.skipDescendants()
                result.files.append(SourceFile(path: rel, kind: FileKind(path: rel),
                                               size: Self.treeSize(rootPath + "/" + rel), isUnit: true))
                onFile(result.files.count)
            }
        }
        result.xcodeprojs.sort()
        result.workspaces.sort()
        result.packages.sort()
        return result
    }

    private func shouldSkip(dir rel: String, name: String, ext: String, absolute: String) -> Bool {
        if Self.skippedNames.contains(name) || Self.skippedExtensions.contains(ext) { return true }
        if ToolOutput.directoryNames.contains(name) { return true }
        if name == "build", Self.isBuildOutput(rel: rel, absolute: absolute) { return true }
        if name == "Pods" && !includePods { return true }
        if rel.hasSuffix("Carthage/Build") || rel.hasSuffix("Carthage/Checkouts") { return true }
        let fm = FileManager.default
        return Self.buildMarkers.contains { fm.fileExists(atPath: absolute + "/" + $0) }
    }

    /// Files whose presence next to a `build/` folder marks it as that build system's output.
    static let buildSystemFiles: Set<String> = [
        "Package.swift", "build.gradle", "build.gradle.kts", "settings.gradle", "gradlew", "CMakeLists.txt",
        "package.json", "Makefile", "pubspec.yaml",
    ]

    /// `build/` is Xcode's legacy SYMROOT, the conventional `-derivedDataPath` and Gradle's/Flutter's output, but
    /// also a plausible source folder name. It is source when it holds a package or project; otherwise it is build
    /// output at the scan root, beside a project, package or build script, or when it holds a build folder
    /// (`Debug`, `Release-iphoneos`, `intermediates`, `outputs`, `*.build`; directories only, exact names).
    static func isBuildOutput(rel: String, absolute: String) -> Bool {
        let fm = FileManager.default
        let children = (try? fm.contentsOfDirectory(atPath: absolute)) ?? []
        if children.contains(where: { $0 == "Package.swift" || $0.hasSuffix(".xcodeproj") }) { return false }
        if !rel.contains("/") { return true }
        let parent = (absolute as NSString).deletingLastPathComponent
        let siblings = (try? fm.contentsOfDirectory(atPath: parent)) ?? []
        if siblings.contains(where: { buildSystemFiles.contains($0) || $0.hasSuffix(".xcodeproj") || $0.hasSuffix(".xcworkspace") }) {
            return true
        }
        return children.contains { child in
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: absolute + "/" + child, isDirectory: &isDir), isDir.boolValue else { return false }
            let name = child.lowercased()
            return name.hasSuffix(".build") || ["debug", "release", "intermediates", "outputs"].contains(name)
                || name.hasPrefix("debug-") || name.hasPrefix("release-")
        }
    }

    /// Total byte size of a folder tree.
    static func treeSize(_ path: String) -> Int64 {
        guard let e = FileManager.default.enumerator(atPath: path) else { return 0 }
        var total: Int64 = 0
        while e.nextObject() != nil {
            if e.fileAttributes?[.type] as? FileAttributeType == .typeRegular {
                total += (e.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
            }
        }
        return total
    }
}
