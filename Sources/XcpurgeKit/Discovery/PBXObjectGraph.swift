import Foundation

/// Read-only view over a pbxproj `objects` table with group-tree path resolution.
struct PBXObjectGraph {
    let objects: [String: [String: Any]]
    let rootID: String
    /// Absolute directory `SRCROOT` points at.
    let projectDir: String
    private var parents: [String: String] = [:]
    private var pathCache: [String: String?] = [:]

    static let knownISAs: Set<String> = [
        "PBXProject", "PBXGroup", "PBXFileReference", "PBXVariantGroup", "XCVersionGroup", "PBXReferenceProxy",
        "PBXNativeTarget", "PBXAggregateTarget", "PBXLegacyTarget", "PBXBuildFile", "PBXSourcesBuildPhase",
        "PBXResourcesBuildPhase", "PBXFrameworksBuildPhase", "PBXHeadersBuildPhase", "PBXCopyFilesBuildPhase",
        "PBXShellScriptBuildPhase", "PBXRezBuildPhase", "PBXAppleScriptBuildPhase", "PBXBuildRule",
        "PBXTargetDependency", "PBXContainerItemProxy", "XCConfigurationList", "XCBuildConfiguration",
        "XCLocalSwiftPackageReference", "XCRemoteSwiftPackageReference", "XCSwiftPackageProductDependency",
        "PBXFileSystemSynchronizedRootGroup", "PBXFileSystemSynchronizedBuildFileExceptionSet",
        "PBXFileSystemSynchronizedGroupBuildPhaseMembershipExceptionSet",
    ]

    init(objects: [String: [String: Any]], rootID: String, projectDir: String) {
        self.objects = objects
        self.rootID = rootID
        self.projectDir = projectDir
        for (id, obj) in objects {
            for child in obj["children"] as? [String] ?? [] { parents[child] = id }
        }
    }

    func object(_ id: String?) -> [String: Any]? { id.flatMap { objects[$0] } }
    func isa(_ id: String?) -> String? { object(id)?["isa"] as? String }
    func string(_ id: String?, _ key: String) -> String? { object(id)?[key] as? String }
    func ids(_ id: String?, _ key: String) -> [String] { object(id)?[key] as? [String] ?? [] }

    var mainGroupID: String? { string(rootID, "mainGroup") }

    func parent(of id: String) -> String? { parents[id] }

    /// Absolute path of a group-tree item, or nil for build-products / SDK references.
    mutating func path(of id: String) -> String? {
        if let cached = pathCache[id] { return cached }
        let resolved = computePath(id, depth: 0)
        pathCache[id] = resolved
        return resolved
    }

    private mutating func computePath(_ id: String, depth: Int) -> String? {
        guard depth < 64, let obj = objects[id] else { return nil }
        let path = obj["path"] as? String
        let tree = obj["sourceTree"] as? String ?? "<group>"
        if id == mainGroupID { return RelPath.join(projectDir, path ?? "") }
        switch tree {
        case "<group>":
            let base: String
            if let parent = parents[id] { guard let p = self.path(of: parent) else { return nil }; base = p }
            else { base = projectDir }
            return path.map { RelPath.join(base, $0) } ?? base
        case "SOURCE_ROOT":
            return RelPath.join(projectDir, path ?? "")
        case "<absolute>":
            return path.map(RelPath.normalize)
        default:
            return nil
        }
    }

    func setting(_ obj: [String: Any], _ key: String) -> String? {
        switch obj[key] {
        case let s as String: s
        case let a as [String]: a.map { $0.contains(" ") ? "\"\($0)\"" : $0 }.joined(separator: " ")
        default: nil
        }
    }

    /// Build settings dictionary of an `XCBuildConfiguration`, list values joined by spaces.
    func buildSettings(_ configID: String) -> [String: String] {
        guard let dict = object(configID)?["buildSettings"] as? [String: Any] else { return [:] }
        var out: [String: String] = [:]
        for key in dict.keys { out[key] = setting(dict, key) }
        return out
    }
}
