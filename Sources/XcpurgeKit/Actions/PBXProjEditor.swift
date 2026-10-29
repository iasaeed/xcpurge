// LANE: A
import Foundation

/// Removes file references (PBXFileReference, PBXBuildFile and their list entries) for deleted paths from a
/// classic `project.pbxproj`, editing the text line by line so Xcode's formatting survives, and backing the
/// file up into the `TrashStore` first. Synchronized folders need no edit (membership follows the disk).
public enum PBXProjEditor {
    /// - Parameters:
    ///   - paths: root-relative paths that were deleted.
    ///   - project: the parsed project that may reference them.
    /// - Returns: number of file references removed.
    public static func removeReferences(to paths: Set<String>, in project: ProjectModel, root: URL,
                                        store: TrashStore) throws -> Int {
        guard project.format == .pbxproj, !paths.isEmpty else { return 0 }
        let rel = RelPath.join(project.container, "project.pbxproj")
        let url = root.appendingPathComponent(rel)
        let data = try Data(contentsOf: url)
        let rootPath = root.standardizedFileURL.path
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String, let projectObj = objects[rootID]
        else { throw XcpurgeError.invalidProject(project.container, "not a pbxproj property list") }

        let projPath = RelPath.join(rootPath, project.container)
        let projectDir = RelPath.join(RelPath.parent(projPath), projectObj["projectDirPath"] as? String ?? "")
        var graph = PBXObjectGraph(objects: objects, rootID: rootID, projectDir: projectDir)
        var refIDs = Set<String>()
        for id in objects.keys.sorted() where graph.isa(id) == "PBXFileReference" {
            if let abs = graph.path(of: id), paths.contains(RelPath.relative(abs, to: rootPath)) { refIDs.insert(id) }
        }
        guard !refIDs.isEmpty else { return 0 }
        let buildIDs = objects.filter { $0.value["isa"] as? String == "PBXBuildFile" && refIDs.contains($0.value["fileRef"] as? String ?? "") }
        let ids = refIDs.union(buildIDs.keys)

        let edited = removeObjects(ids, from: String(decoding: data, as: UTF8.self))
        guard ids.allSatisfy({ !edited.contains($0) }) else {
            throw XcpurgeError.invalidProject(project.container, "unusual formatting; references not removed")
        }
        let output = Data(edited.utf8)
        guard (try? PropertyListSerialization.propertyList(from: output, format: nil)) != nil else {
            throw XcpurgeError.invalidProject(project.container, "edit would produce an unreadable project")
        }
        try store.backup(rel)
        try output.write(to: url, options: .atomic)
        return refIDs.count
    }

    /// Drops object definitions (one-line or multi-line) and list entries whose first token is one of `ids`.
    static func removeObjects(_ ids: Set<String>, from text: String) -> String {
        var out: [Substring] = []
        var skipping = false
        for line in text.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if skipping {
                if trimmed == "};" { skipping = false }
                continue
            }
            let token = String(trimmed.prefix { $0 != " " && $0 != "," && $0 != "\t" && $0 != ";" })
            guard ids.contains(token) else { out.append(line); continue }
            if trimmed.contains("= {") {
                if !trimmed.hasSuffix("};") { skipping = true }
                continue
            }
            if trimmed.hasSuffix(",") { continue }
            out.append(line)
        }
        return out.joined(separator: "\n")
    }
}
