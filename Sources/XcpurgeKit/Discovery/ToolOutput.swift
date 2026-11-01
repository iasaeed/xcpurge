import Foundation

/// What xcpurge itself writes into a scanned tree, so no walk ever reads it back as part of the project: a report
/// names every finding, and indexed as a reference source it would mark every reported asset, string or file used.
public enum ToolOutput {
    /// Default folder for HTML reports (`<root>/.xcpurge/report-<timestamp>.html`).
    public static let reportDirectoryName = ".xcpurge"

    /// Folders xcpurge writes under the root: reports and the trash. Never walked, whatever the dot-folder rule.
    public static let directoryNames: Set<String> = [reportDirectoryName, TrashStore.directoryName]

    /// Bytes read from each end of a candidate file.
    static let probeBytes = 4096

    /// `<title>xcpurge report · …` in the HTML template's head.
    static let htmlMarker = "<title>\(XcpurgeVersion.name) report"
    /// `"tool": {"name": "xcpurge"` (JSON report: last key; baseline: second line; size snapshot) or
    /// `"tool": "xcpurge 0.4.0"` (`explain --format json`).
    static let toolMarker = try! NSRegularExpression(
        pattern: #""tool"\s*:\s*(\{\s*"name"\s*:\s*)?"\#(XcpurgeVersion.name)[\s"]"#)
    /// A size snapshot (`size --save`, `size --format json`, trash `size-*.json`), also one written by 0.4.0 without
    /// `tool`: sorted keys put `measuredAt` first (after an optional `app`, or inside `after`/`before` of a
    /// comparison) ...
    static let snapshotHead = try! NSRegularExpression(
        pattern: #"^\{\s*"(after|app|measuredAt)"\s*:"#)
    static let measuredAt = try! NSRegularExpression(pattern: #""measuredAt"\s*:\s*""#)
    /// ... and `tree.total` last.
    static let snapshotTail = try! NSRegularExpression(pattern: #""total"\s*:\s*\d+(\s*\})+\s*$"#)

    /// True for an HTML or JSON report, a baseline file, an explain document or a size snapshot that xcpurge wrote,
    /// wherever it sits (`--output` into the project, a saved `.json`, a baseline under another name). Only regular
    /// `.html`/`.json` files are read (never a symlink, FIFO or device), and only up to `probeBytes` at each end.
    public static func isGeneratedReport(path: String, absolute: String) -> Bool {
        let kind = FileKind(path: path)
        guard kind == .html || kind == .json,
              (try? FileManager.default.attributesOfItem(atPath: absolute))?[.type] as? FileAttributeType == .typeRegular,
              let handle = FileHandle(forReadingAtPath: absolute) else { return false }
        defer { try? handle.close() }
        let raw = String(decoding: (try? handle.read(upToCount: probeBytes)) ?? Data(), as: UTF8.self)
        let head = String(raw.drop { $0.isWhitespace || $0 == "\u{FEFF}" })
        if kind == .html { return head.hasPrefix("<") && head.contains(htmlMarker) }
        guard head.hasPrefix("{") else { return false }
        if matches(toolMarker, head) { return true }
        var tail = head
        if let end = try? handle.seekToEnd(), end > UInt64(probeBytes) {
            try? handle.seek(toOffset: end - UInt64(probeBytes))
            tail = String(decoding: (try? handle.read(upToCount: probeBytes)) ?? Data(), as: UTF8.self)
        }
        if matches(toolMarker, tail) { return true }
        return matches(snapshotHead, head) && matches(measuredAt, head) && matches(snapshotTail, tail)
    }

    private static func matches(_ regex: NSRegularExpression, _ s: String) -> Bool {
        regex.firstMatch(in: s, range: NSRange(s.startIndex..., in: s)) != nil
    }
}
