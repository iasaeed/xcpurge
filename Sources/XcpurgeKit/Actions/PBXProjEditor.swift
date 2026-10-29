// LANE: A
import Foundation

/// Removes file references (PBXFileReference, PBXBuildFile and their list entries) for deleted paths from a
/// classic `project.pbxproj`, editing the text line by line so Xcode's formatting survives, and backing the
/// file up into the `TrashStore` first. Synchronized folders need no edit (membership follows the disk).
public enum PBXProjEditor {
    /// Dry run: the edit removing every reference to `paths`, nil when the project references none of them.
    /// Throws when the references cannot be removed safely (unusual formatting, unreadable result).
    /// `.xcdatamodeld` version groups go with their `.xcdatamodel` children.
    /// - Parameter foldingCase: match project paths to `paths` ignoring case (case-insensitive volume);
    ///   `PBXProjEdit.paths` keeps the spelling of `paths`.
    public static func plan(removing paths: Set<String>, in project: ProjectModel, root: URL,
                            foldingCase: Bool = false) throws -> PBXProjEdit? {
        guard project.format == .pbxproj, !paths.isEmpty else { return nil }
        let rel = RelPath.join(project.container, "project.pbxproj")
        let data = try Data(contentsOf: root.appendingPathComponent(rel))
        let rootPath = root.standardizedFileURL.path
        guard let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let objects = plist["objects"] as? [String: [String: Any]],
              let rootID = plist["rootObject"] as? String, let projectObj = objects[rootID]
        else { throw XcpurgeError.invalidProject(project.container, "not a pbxproj property list") }

        let projPath = RelPath.join(rootPath, project.container)
        let projectDir = RelPath.join(RelPath.parent(projPath), projectObj["projectDirPath"] as? String ?? "")
        var graph = PBXObjectGraph(objects: objects, rootID: rootID, projectDir: projectDir)
        let fold = { (p: String) in foldingCase ? p.lowercased() : p }
        let requested = Dictionary(paths.map { (fold($0), $0) }, uniquingKeysWith: { a, _ in a })
        var refIDs = Set<String>(), matched = Set<String>()
        for id in objects.keys.sorted() where graph.isa(id) == "PBXFileReference" || graph.isa(id) == "XCVersionGroup" {
            guard let abs = graph.path(of: id) else { continue }
            guard let path = requested[fold(RelPath.relative(abs, to: rootPath))] else { continue }
            refIDs.insert(id)
            matched.insert(path)
            if graph.isa(id) == "XCVersionGroup" { refIDs.formUnion(graph.ids(id, "children")) }
        }
        guard !refIDs.isEmpty else { return nil }
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
        return PBXProjEdit(projectFile: rel, paths: matched, referenceCount: refIDs.count, output: output, original: data)
    }

    /// Backs the project file up into `store`, then writes the planned edit.
    public static func apply(_ edit: PBXProjEdit, root: URL, store: TrashStore) throws {
        try store.backup(edit.projectFile)
        try edit.output.write(to: root.appendingPathComponent(edit.projectFile), options: .atomic)
    }

    /// Writes back the contents `edit` was planned from.
    public static func revert(_ edit: PBXProjEdit, root: URL) throws {
        try edit.original.write(to: root.appendingPathComponent(edit.projectFile), options: .atomic)
    }

    /// The paths of `paths` whose references can be removed in one edit: all of them, or else every path that
    /// can be removed alone (re-checked together). Failures carry the reason, per path.
    public static func removable(_ paths: Set<String>, in project: ProjectModel, root: URL, foldingCase: Bool = false)
        -> (paths: Set<String>, failures: [String: String]) {
        let check = { (set: Set<String>) in try plan(removing: set, in: project, root: root, foldingCase: foldingCase) }
        if (try? check(paths)) != nil { return (paths, [:]) }
        var ok = Set<String>(), failures: [String: String] = [:]
        for path in paths.sorted() {
            do { _ = try check([path]); ok.insert(path) } catch {
                failures[path] = "\(error)"
            }
        }
        if !ok.isEmpty, (try? check(ok)) == nil {
            for path in ok { failures[path] = "references cannot be removed together with the others" }
            ok = []
        }
        return (ok, failures)
    }

    /// Drops object definitions (one-line or multi-line) and list entries whose first token is one of `ids`.
    /// Lines end in `\n`, `\r\n` or `\r`; each kept line keeps its own ending.
    static func removeObjects(_ ids: Set<String>, from text: String) -> String {
        var out = ""
        var skipping = false
        for (line, ending) in lines(text) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if skipping {
                if trimmed == "};" { skipping = false }
                continue
            }
            let token = String(trimmed.prefix { $0 != " " && $0 != "," && $0 != "\t" && $0 != ";" })
            if ids.contains(token) {
                if trimmed.contains("= {") {
                    if !trimmed.hasSuffix("};") { skipping = true }
                    continue
                }
                // Only a lone list entry (`ID,` or `ID /* name */,`); anything else on the line stays, and the
                // left-over ID makes `plan` refuse the edit.
                let rest = trimmed.dropFirst(token.count).trimmingCharacters(in: .whitespaces)
                if rest == "," || (rest.hasPrefix("/*") && rest.hasSuffix("*/,") && !rest.dropLast(3).contains("*/")
                    && !rest.dropLast().contains(",")) { continue }
            }
            out += line + ending
        }
        return out
    }

    /// Splits on `\r\n`, `\n` and `\r` (scalar-wise: `"\r\n"` is one `Character`), keeping each terminator.
    static func lines(_ text: String) -> [(line: String, ending: String)] {
        var result: [(String, String)] = []
        var current = String.UnicodeScalarView()
        var scalars = text.unicodeScalars.makeIterator()
        var pending = scalars.next()
        while let c = pending {
            pending = scalars.next()
            switch c {
            case "\n":
                result.append((String(current), "\n")); current = .init()
            case "\r":
                if pending == "\n" { pending = scalars.next(); result.append((String(current), "\r\n")) }
                else { result.append((String(current), "\r")) }
                current = .init()
            default:
                current.append(c)
            }
        }
        result.append((String(current), ""))
        return result
    }
}
