import Foundation

/// Decides which projects and packages to parse: explicit flags, else a root-level workspace, else everything
/// the walker found. Also picks `project.xcproj` over `project.pbxproj` when it is newer.
public enum ProjectLocator {
    public static func locate(root: URL, walk: WalkResult, config: Config) throws -> LocatedProjects {
        let rootPath = root.standardizedFileURL.path
        let fm = FileManager.default
        func rel(_ p: String) -> String {
            RelPath.relative(p.hasPrefix("/") ? RelPath.normalize(p) : RelPath.join(rootPath, p), to: rootPath)
        }
        func requireExists(_ p: String) throws {
            guard fm.fileExists(atPath: RelPath.join(rootPath, p)) else { throw XcpurgeError.notFound(p) }
        }

        if config.project != nil || config.package != nil || config.workspace != nil {
            var located = LocatedProjects()
            if let p = config.project { let r = rel(p); try requireExists(r); located.xcodeprojs.append(r) }
            if let p = config.package {
                var r = rel(p)
                if r.hasSuffix("Package.swift") { r = RelPath.parent(r) }
                try requireExists(RelPath.join(r, "Package.swift"))
                located.packages.append(r)
            }
            if let w = config.workspace {
                let r = rel(w); try requireExists(r)
                let expanded = try expand(workspace: r, rootPath: rootPath)
                located.xcodeprojs += expanded.xcodeprojs
                located.packages += expanded.packages
                located.workspaces.append(r)
            }
            return located
        }

        let rootWorkspaces = walk.workspaces.filter { !$0.contains("/") }
        if !rootWorkspaces.isEmpty {
            var located = LocatedProjects(workspaces: rootWorkspaces)
            for w in rootWorkspaces {
                let expanded = try expand(workspace: w, rootPath: rootPath)
                located.xcodeprojs += expanded.xcodeprojs.filter { !located.xcodeprojs.contains($0) }
                located.packages += expanded.packages.filter { !located.packages.contains($0) }
            }
            return located
        }
        return LocatedProjects(xcodeprojs: walk.xcodeprojs, packages: walk.packages)
    }

    static func expand(workspace: String, rootPath: String) throws -> LocatedProjects {
        let url = URL(fileURLWithPath: RelPath.join(rootPath, workspace))
        var located = LocatedProjects()
        for abs in try WorkspaceParser.parse(workspace: url) {
            let r = RelPath.relative(abs, to: rootPath)
            if abs.hasSuffix(".xcodeproj") { located.xcodeprojs.append(r) }
            else if FileManager.default.fileExists(atPath: abs + "/Package.swift") { located.packages.append(r) }
            else if abs.hasSuffix("Package.swift") { located.packages.append(RelPath.parent(r)) }
        }
        return located
    }

    /// `xcproj` when `project.xcproj` exists and is at least as new as `project.pbxproj`; nil when neither exists.
    public static func preferredFormat(xcodeproj: URL) -> ProjectModel.Format? {
        let fm = FileManager.default
        func mtime(_ name: String) -> Date? {
            (try? fm.attributesOfItem(atPath: xcodeproj.appendingPathComponent(name).path))?[.modificationDate] as? Date
        }
        switch (mtime("project.pbxproj"), mtime("project.xcproj")) {
        case (nil, nil): return nil
        case (.some, nil): return .pbxproj
        case (nil, .some): return .xcproj
        case let (.some(p), .some(x)): return x >= p ? .xcproj : .pbxproj
        }
    }
}
