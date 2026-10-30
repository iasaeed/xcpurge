import Foundation

/// Text rendering of size snapshots and before/after comparisons.
public enum SizeText {
    /// One compared line: a category, module or app section.
    public struct Row: Equatable, Sendable {
        public var name: String
        public var before: Int64
        public var after: Int64
        public var delta: Int64 { after - before }
        /// Change in percent of `before`; nil when `before` is 0.
        public var percent: Double? { before == 0 ? nil : Double(delta) / Double(before) * 100 }

        public init(name: String, before: Int64, after: Int64) {
            self.name = name
            self.before = before
            self.after = after
        }
    }

    // MARK: - Snapshot

    /// The `xcpurge size` text report.
    public static func render(_ s: SizeSnapshot) -> String {
        let bytes = ByteFormatter.string
        var out = "Size of \(s.root)\n\n"
        out += table(["Category", "Files", "Size"],
                     s.tree.categories.map { [$0.name, ScanSummary.grouped($0.files), bytes($0.bytes)] }
                        + [["Total", ScanSummary.grouped(s.tree.files), bytes(s.tree.total)]])
        if let catalogs = s.tree.assetCatalogs, !catalogs.isEmpty {
            out += "\n" + table(["Asset catalog", "Files", "Size"],
                                catalogs.map { [$0.name, ScanSummary.grouped($0.files), bytes($0.bytes)] })
        }
        if let types = s.tree.assetTypes, !types.isEmpty {
            out += "\n" + table(["Asset type", "Files", "Size"], types.map { [$0.name, ScanSummary.grouped($0.files), bytes($0.bytes)] })
        }
        if !s.tree.modules.isEmpty {
            out += "\n" + table(["Module", "Files", "Size"], s.tree.modules.map { [$0.id, ScanSummary.grouped($0.files), bytes($0.bytes)] })
        }
        if let app = s.app {
            out += "\nApp bundle \(app.path)\n"
            out += table(["Section", "Size"], app.sections.map { [$0.name, bytes($0.bytes)] } + [["Total", bytes(app.total)]])
        }
        out += "\n" + reclaimableLine(s.reclaimable) + "\n"
        return out
    }

    /// `Estimated reclaimable: 12.0 KB (high) / 20.5 KB (high+medium)`.
    public static func reclaimableLine(_ r: Reclaimable) -> String {
        "Estimated reclaimable: \(ByteFormatter.string(r.high)) (high) / \(ByteFormatter.string(r.highMedium)) (high+medium)"
    }

    // MARK: - Comparison

    /// Rows by name, in the order of `after` then names only `before` has.
    static func rows(_ before: [(String, Int64)], _ after: [(String, Int64)]) -> [Row] {
        let b = Dictionary(before, uniquingKeysWith: +), a = Dictionary(after, uniquingKeysWith: +)
        var names = after.map(\.0)
        names += before.map(\.0).filter { a[$0] == nil }
        return names.map { Row(name: $0, before: b[$0] ?? 0, after: a[$0] ?? 0) }
    }

    public static func categoryRows(_ before: SizeSnapshot, _ after: SizeSnapshot) -> [Row] {
        rows(before.tree.categories.map { ($0.name, $0.bytes) }, after.tree.categories.map { ($0.name, $0.bytes) })
    }

    public static func moduleRows(_ before: SizeSnapshot, _ after: SizeSnapshot) -> [Row] {
        rows(before.tree.modules.map { ($0.id, $0.bytes) }, after.tree.modules.map { ($0.id, $0.bytes) })
    }

    public static func appRows(_ before: SizeSnapshot, _ after: SizeSnapshot) -> [Row]? {
        guard let b = before.app, let a = after.app else { return nil }
        return rows(b.sections.map { ($0.name, $0.bytes) }, a.sections.map { ($0.name, $0.bytes) })
            + [Row(name: "Total", before: b.total, after: a.total)]
    }

    /// `xcpurge size --compare`: every category, module and (when both have one) app section.
    public static func compare(_ before: SizeSnapshot, _ after: SizeSnapshot, colors: Bool = false) -> String {
        var out = "Size compared with \(before.measuredAt) (before) → now (after)\n\n"
        out += diffTable("Category", categoryRows(before, after) + [Row(name: "Total", before: before.tree.total, after: after.tree.total)],
                         colors: colors)
        out += "\n" + diffTable("Module", moduleRows(before, after), colors: colors)
        if let app = appRows(before, after) { out += "\n" + diffTable("App section", app, colors: colors) }
        out += "\nReclaimable (high+medium): \(reclaimable(before.reclaimable)) → \(reclaimable(after.reclaimable))\n"
        return out
    }

    /// `9.1 KB`, plus the detector categories when they are not all of them: `140 B (assets, duplicates)`.
    static func reclaimable(_ r: Reclaimable) -> String {
        let all = Category.scannable.map(\.rawValue).sorted()
        let scope = r.categories.flatMap { $0 == all ? nil : " (" + $0.joined(separator: ", ") + ")" } ?? ""
        return ByteFormatter.string(r.highMedium) + scope
    }

    /// The compact block after `--delete` / `--prune` (and reversed after `restore`): changed categories and total.
    public static func compact(_ before: SizeSnapshot, _ after: SizeSnapshot, colors: Bool = false) -> String {
        let changed = categoryRows(before, after).filter { $0.delta != 0 }
        let total = Row(name: "Total", before: before.tree.total, after: after.tree.total)
        return "Size before → after:\n" + diffTable("", changed + [total], colors: colors, indent: "  ", header: false)
    }

    static func diffTable(_ title: String, _ rows: [Row], colors: Bool, indent: String = "", header: Bool = true) -> String {
        let body = rows.map { r in [r.name, ByteFormatter.string(r.before), "→", ByteFormatter.string(r.after), change(r)] }
        let text = table(header ? [title, "Before", "", "After", "Change"] : nil, body, indent: indent)
        guard colors else { return text }
        // Color the change column: shrinking is green, growing red.
        var lines = text.components(separatedBy: "\n")
        let offset = header ? 1 : 0
        for (i, r) in rows.enumerated() where r.delta != 0 && i + offset < lines.count {
            let c = change(r)
            if let range = lines[i + offset].range(of: c, options: .backwards) {
                lines[i + offset].replaceSubrange(range, with: (r.delta < 0 ? "\u{1B}[32m" : "\u{1B}[31m") + c + "\u{1B}[0m")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// `-31.9 KB (-15.0%)`, `+2 B (new)`, `no change`.
    public static func change(_ r: Row) -> String {
        guard r.delta != 0 else { return "no change" }
        let sign = r.delta < 0 ? "-" : "+"
        let pct = r.percent.map { String(format: "%@%.1f%%", sign, abs($0)) } ?? "new"
        return "\(sign)\(ByteFormatter.string(abs(r.delta))) (\(pct))"
    }

    // MARK: - Table

    /// Columns padded to their widest cell; the first column is left-aligned, the rest right-aligned.
    static func table(_ header: [String]?, _ rows: [[String]], indent: String = "") -> String {
        let all = (header.map { [$0] } ?? []) + rows
        guard let columns = all.map(\.count).max() else { return "" }
        let widths = (0..<columns).map { c in all.map { c < $0.count ? $0[c].count : 0 }.max() ?? 0 }
        return all.map { row in
            let cells = (0..<columns).map { c -> String in
                let cell = c < row.count ? row[c] : ""
                let pad = String(repeating: " ", count: widths[c] - cell.count)
                return c == 0 ? cell + pad : pad + cell
            }
            return indent + cells.joined(separator: "  ").replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
        }.joined(separator: "\n") + "\n"
    }
}
