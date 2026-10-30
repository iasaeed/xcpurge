import Foundation

/// The pull-request comment for `xcpurge size --compare --format markdown|github`: a sticky, edited-in-place body
/// that starts with `<!-- xcpurge-size -->`, says honestly what was measured, and lists the paths that changed most.
public enum SizeMarkdown {
    /// First line of every body; the workflow's sticky-comment action finds the comment by it.
    public static let marker = "<!-- xcpurge-size -->"
    /// Stays under GitHub's 65,536-character comment limit with room for the action's own header.
    public static let maxLength = 60_000

    public struct Options: Sendable {
        /// Paths listed under "Top changes"; the rest fold into `<details>`.
        public var top = 20
        /// Paths whose |change| is below this many bytes are not listed at all.
        public var minPathDelta: Int64 = 500
        public var maxLength = SizeMarkdown.maxLength
        public var version = XcpurgeVersion.current

        public init(top: Int = 20, minPathDelta: Int64 = 500, maxLength: Int = SizeMarkdown.maxLength,
                    version: String = XcpurgeVersion.current) {
            self.top = top
            self.minPathDelta = minPathDelta
            self.maxLength = maxLength
            self.version = version
        }
    }

    public static func render(before: SizeSnapshot, after: SizeSnapshot, options: Options = Options()) -> String {
        let metric = SizeGate.metric(before, after)
        var out = marker + "\n"
        out += "### xcpurge size: \(headline(metric))\n\n"
        out += measuredOn(before, after) + "\n\n"

        // Totals and categories.
        var rows = [SizeText.Row(name: "Whole tree", before: before.tree.total, after: after.tree.total)]
        rows += SizeText.categoryRows(before, after)
        out += table(["", "Base", "PR", "Change"], rows.map(cells)) + "\n"

        if let app = SizeText.appRows(before, after) {
            out += details("App bundle sections", table(["Section", "Base", "PR", "Change"], app.map(cells))) + "\n"
        }
        let modules = SizeText.moduleRows(before, after)
        if !modules.isEmpty {
            out += details("Modules (\(modules.count))", table(["Module", "Base", "PR", "Change"], modules.map(cells))) + "\n"
        }

        out += topChanges(before, after, options: options)
        out += "Reclaimable (high+medium): \(ByteFormatter.string(before.reclaimable.highMedium)) → "
            + "\(ByteFormatter.string(after.reclaimable.highMedium))\n\n"
        out += "<sub>xcpurge \(options.version) · this comment is edited in place on each push.</sub>\n"
        return truncate(out, to: options.maxLength)
    }

    // MARK: - Parts

    /// `+142.3 KB (+0.8%)`, `-2.0 KB (-1.1%)`, `no change`.
    static func headline(_ m: SizeGate.Metric) -> String { SizeText.change(m.row) }

    /// Says what the numbers are: install size (and download size for an `.ipa`) with `--app` on both sides,
    /// otherwise bytes of files in the repository.
    static func measuredOn(_ before: SizeSnapshot, _ after: SizeSnapshot) -> String {
        guard let b = before.app, let a = after.app else {
            return "Source-tree bytes (files in the repository), not shipped bytes."
        }
        var lines = ["**Install size** (uncompressed .app, unthinned): "
            + "\(ByteFormatter.string(b.total)) → \(ByteFormatter.string(a.total))"]
        if let bc = b.compressedBytes, let ac = a.compressedBytes {
            let row = SizeText.Row(name: "Download", before: bc, after: ac)
            lines.append("**Download size** (≈ .ipa bytes, compressed, unthinned; not the App Store download): "
                + "\(ByteFormatter.string(bc)) → \(ByteFormatter.string(ac)), \(SizeText.change(row))")
        }
        lines.append("Tree rows below are source-tree bytes (files in the repository).")
        return lines.joined(separator: "  \n")
    }

    static func topChanges(_ before: SizeSnapshot, _ after: SizeSnapshot, options: Options) -> String {
        guard let basePaths = before.paths else {
            return "_Path breakdown unavailable (base snapshot from xcpurge < 0.4)._\n\n"
        }
        let rows = SizeText.rows(basePaths.map { ($0.name, $0.bytes) }, (after.paths ?? []).map { ($0.name, $0.bytes) })
            .filter { abs($0.delta) >= max(1, options.minPathDelta) }
            .sorted { (abs($1.delta), $0.name) < (abs($0.delta), $1.name) }
        let floor = "|change| ≥ \(ByteFormatter.string(options.minPathDelta))"
        guard !rows.isEmpty else { return "**Top changes**: no path changed by \(floor).\n\n" }
        let shown = Array(rows.prefix(max(0, options.top))), rest = Array(rows.dropFirst(shown.count))
        let pathCells = { (r: SizeText.Row) -> [String] in
            let name = r.before == 0 ? "`\(code(r.name))` _(new)_" : r.after == 0 ? "`\(code(r.name))` _(removed)_" : "`\(code(r.name))`"
            return [name, ByteFormatter.string(r.before), ByteFormatter.string(r.after), SizeText.change(r)]
        }
        var out = "**Top changes** (\(floor); grown and shrunk)\n\n"
        if !shown.isEmpty { out += table(["Path", "Base", "PR", "Change"], shown.map(pathCells)) + "\n" }
        if !rest.isEmpty {
            out += details("\(rest.count) more changed path\(rest.count == 1 ? "" : "s")",
                           table(["Path", "Base", "PR", "Change"], rest.map(pathCells))) + "\n"
        }
        return out
    }

    static func cells(_ r: SizeText.Row) -> [String] {
        [escape(r.name), ByteFormatter.string(r.before), ByteFormatter.string(r.after), SizeText.change(r)]
    }

    /// A GitHub-flavoured table; numeric columns right-aligned.
    static func table(_ header: [String], _ rows: [[String]]) -> String {
        var out = "| " + header.joined(separator: " | ") + " |\n"
        out += "|" + header.indices.map { $0 == 0 ? "---" : "---:" }.joined(separator: "|") + "|\n"
        for row in rows { out += "| " + row.joined(separator: " | ") + " |\n" }
        return out
    }

    static func details(_ summary: String, _ body: String) -> String {
        "<details><summary>\(summary)</summary>\n\n\(body)\n</details>\n"
    }

    /// Table cells cannot contain a bare `|`.
    static func escape(_ s: String) -> String { s.replacingOccurrences(of: "|", with: "\\|") }

    /// Inside backticks a `|` still breaks the table row; backticks themselves are replaced.
    static func code(_ s: String) -> String { escape(s).replacingOccurrences(of: "`", with: "'") }

    /// Cuts at a line boundary and says so; the marker line always survives.
    static func truncate(_ text: String, to limit: Int) -> String {
        guard text.count > limit else { return text }
        let note = "\n\n_Truncated to fit the GitHub comment limit; run `xcpurge size --compare` locally for the full table._\n"
        let budget = max(marker.count + 1, limit - note.count)
        var head = String(text.prefix(budget))
        if let cut = head.lastIndex(of: "\n") { head = String(head[..<cut]) }
        // An open <details> would swallow the note.
        if head.components(separatedBy: "<details>").count > head.components(separatedBy: "</details>").count { head += "\n</details>" }
        return head + note
    }
}
