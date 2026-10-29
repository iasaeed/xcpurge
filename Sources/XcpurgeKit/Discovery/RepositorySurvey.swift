import Foundation

/// Spots a scan root that is a folder of unrelated repositories (e.g. `~/Projects`), where one scan mixes
/// many projects and takes long.
public enum RepositorySurvey {
    /// Top-level folders of `root` that are their own repository: a folder with `.git`, or, when `root` itself is
    /// not a repository, project or package, a folder holding an `.xcodeproj`, `.xcworkspace` or `Package.swift`.
    public static func independentRepositories(under root: URL) -> Int {
        let fm = FileManager.default
        let names = (try? fm.contentsOfDirectory(atPath: root.path)) ?? []
        let rootIsProject = names.contains { isProjectMarker($0) }
        return names.filter { name in
            guard !name.hasPrefix(".") else { return false }
            let dir = root.appendingPathComponent(name)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: dir.path, isDirectory: &isDir), isDir.boolValue,
                  !FileKind.bundleExtensions.contains(dir.pathExtension.lowercased()),
                  !["xcodeproj", "xcworkspace"].contains(dir.pathExtension) else { return false }
            let children = (try? fm.contentsOfDirectory(atPath: dir.path)) ?? []
            if children.contains(".git") { return true }
            return !rootIsProject && children.contains { $0 != ".git" && isProjectMarker($0) }
        }.count
    }

    private static func isProjectMarker(_ name: String) -> Bool {
        name == ".git" || name == "Package.swift" || name.hasSuffix(".xcodeproj") || name.hasSuffix(".xcworkspace")
    }
}
