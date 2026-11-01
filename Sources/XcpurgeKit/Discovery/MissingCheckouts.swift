import Foundation

/// Folders a fresh clone lacks until one command runs: git submodules not yet initialised (listed in
/// `.gitmodules`, missing or empty) and CocoaPods output (`Pods/` beside a `Podfile`, without `Pods.xcodeproj`).
/// Project references into them are expected to dangle, so they are explained once instead of reported.
public struct MissingCheckout: Sendable, Hashable {
    public enum Kind: Sendable, Hashable { case submodule, pods }
    public var kind: Kind
    /// Root-relative folder.
    public var path: String

    /// The note printed once for this folder.
    public var message: String {
        switch kind {
        case .submodule: "uninitialised git submodule \(path); run git submodule update --init"
        case .pods: "CocoaPods output missing; run pod install"
        }
    }
}

public enum MissingCheckouts {
    /// - Parameter files: the inventory, to find `Podfile`s.
    public static func detect(root: URL, files: [SourceFile]) -> [MissingCheckout] {
        let fm = FileManager.default
        let rootPath = root.path
        var out: [MissingCheckout] = []
        for path in submodulePaths(rootPath: rootPath) {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: RelPath.join(rootPath, path), isDirectory: &isDir)
            if !exists || (isDir.boolValue && isEmpty(RelPath.join(rootPath, path))) {
                out.append(MissingCheckout(kind: .submodule, path: path))
            }
        }
        for podfile in files where RelPath.lastComponent(podfile.path) == "Podfile" {
            let pods = RelPath.join(RelPath.parent(podfile.path), "Pods")
            guard !fm.fileExists(atPath: RelPath.join(rootPath, pods + "/Pods.xcodeproj")),
                  !out.contains(where: { RelPath.isUnder(pods, $0.path) }) else { continue }
            out.append(MissingCheckout(kind: .pods, path: pods))
        }
        return out.sorted { $0.path < $1.path }
    }

    /// `path = X` entries of the root's `.gitmodules`, normalised and sorted.
    static func submodulePaths(rootPath: String) -> [String] {
        guard let text = try? String(contentsOfFile: rootPath + "/.gitmodules", encoding: .utf8) else { return [] }
        var out = Set<String>()
        for line in text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("path"), let eq = trimmed.firstIndex(of: "="),
                  trimmed[..<eq].trimmingCharacters(in: .whitespaces) == "path" else { continue }
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            let path = RelPath.normalize(value)
            if !path.isEmpty, !path.hasPrefix("/"), !path.hasPrefix("..") { out.insert(path) }
        }
        return out.sorted()
    }

    private static func isEmpty(_ path: String) -> Bool {
        ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).isEmpty
    }

    /// True when `path` lies under one of `checkouts`.
    public static func contains(_ checkouts: [MissingCheckout], path: String) -> Bool {
        checkouts.contains { RelPath.isUnder(path, $0.path) }
    }
}
