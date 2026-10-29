// LANE: C
import Foundation

/// `<abs path>:<line>: warning: [xcpurge] <kind>: <message> (<confidence>)` lines that Xcode shows as
/// build-phase warnings (informational kinds use `note:`). Folder findings point at the folder's
/// `Contents.json`, line 1 when the finding has no line. Output follows report order, so it is deterministic.
public struct XcodeReporter: Reporter {
    public init() {}

    public func render(_ result: ScanResult) -> String {
        let root = result.context.root.path
        return result.findings.map { f in
            let (path, line) = Self.location(f, root: root)
            let severity = f.kind.isInformational ? "note" : "warning"
            let message = Self.message(f).replacingOccurrences(of: "\r", with: " ").replacingOccurrences(of: "\n", with: " ")
            return "\(path):\(line): \(severity): [xcpurge] \(f.kind.flagName): \(message) (\(f.confidence.rawValue))\n"
        }.joined()
    }

    /// Absolute file and line Xcode can open: folders (imagesets, catalogs) resolve to their `Contents.json`.
    static func location(_ f: Finding, root: String) -> (String, Int) {
        let absolute = RelPath.join(root, f.path)
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: absolute, isDirectory: &isDir), isDir.boolValue {
            let contents = absolute + "/Contents.json"
            if FileManager.default.fileExists(atPath: contents) { return (contents, f.line ?? 1) }
        }
        return (absolute, f.line ?? 1)
    }

    /// One-line description shared by the CI reporters: the name (or file name), module, then the first reason.
    public static func message(_ f: Finding) -> String {
        var text = "'\(f.name ?? RelPath.lastComponent(f.path))'"
        if f.module != ModuleID.unknown.name { text += " in \(f.module)" }
        if let reason = f.reasons.first { text += ": \(reason)" }
        if let group = f.groupID { text += " [group \(group)]" }
        return text
    }
}
