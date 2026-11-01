/// Human-readable report grouped by category, kind and module, with confidence, sizes and totals. A baseline
/// (`--baseline`) adds a header line; git history (`--git`) adds `· age, author` after each finding. Warnings
/// close the report; info diagnostics follow as dimmed `note:` lines (at most `noteLimit`, else a count) unless
/// `quiet`. ANSI colors only when `colors` is set (the CLI enables it for terminals).
public struct TextReporter: Reporter {
    /// More info diagnostics than this collapse into one `N notes (use --format json to see them)` line.
    public static let noteLimit = 3

    public let colors: Bool
    public let verbose: Bool
    public let quiet: Bool

    public init(colors: Bool = false, verbose: Bool = false, quiet: Bool = false) {
        self.colors = colors
        self.verbose = verbose
        self.quiet = quiet
    }

    private func paint(_ s: String, _ code: String) -> String { colors ? "\u{1B}[\(code)m\(s)\u{1B}[0m" : s }

    private func badge(_ c: Confidence) -> String {
        switch c {
        case .high: paint("[high]  ", "31")
        case .medium: paint("[medium]", "33")
        case .low: paint("[low]   ", "2")
        }
    }

    public func render(_ result: ScanResult) -> String {
        var lines: [String] = []
        let findings = result.findings
        if let b = result.baseline {
            lines.append(paint(Self.baselineLine(b), "1"))
            for w in b.warnings { lines.append("  " + paint("warning: " + w, "33")) }
            if verbose, !b.fixed.isEmpty {
                lines.append("  Fixed baseline entries (regenerate with xcpurge baseline):")
                for e in b.fixed.sorted() { lines.append("    \(e.kind.flagName) \(e.module) \(e.name ?? e.path)\(e.count > 1 ? " ×\(e.count)" : "")") }
            }
            lines.append("")
        }
        let byCategory = Dictionary(grouping: findings, by: \.category)
        for category in Category.allCases {
            guard let items = byCategory[category], !items.isEmpty else { continue }
            let bytes = items.compactMap(\.sizeBytes).reduce(0, +)
            lines.append(paint("\(category.rawValue.capitalized) (\(items.count)\(bytes > 0 ? ", " + ByteFormatter.string(bytes) : ""))", "1"))
            let byKind = Dictionary(grouping: items, by: \.kind)
            for kind in byKind.keys.sorted() {
                lines.append("  \(kind.flagName)")
                let byModule = Dictionary(grouping: byKind[kind]!, by: \.module)
                for module in byModule.keys.sorted() {
                    lines.append("    \(paint(module, "36"))")
                    for f in byModule[module]!.sorted(by: Finding.reportOrder) {
                        var line = "      \(badge(f.confidence)) \(f.path)\(f.line.map { ":\($0)" } ?? "")"
                        if let name = f.name, name != f.path { line += "  \(name)" }
                        if let size = f.sizeBytes { line += "  (\(ByteFormatter.string(size)))" }
                        if let group = f.groupID { line += "  group \(group)" }
                        if let h = f.history { line += "  · " + paint(Self.historySuffix(h), "2") }
                        lines.append(line)
                        if verbose || f.confidence != .high {
                            for reason in f.reasons { lines.append("          " + paint(reason, "2")) }
                        }
                    }
                }
            }
            lines.append("")
        }
        let total = findings.compactMap(\.sizeBytes).reduce(0, +)
        // Dynamic lookups and duplicate sets are reported beside the total, not inside it.
        let tally = FindingTally(findings)
        let info = tally.informationalText.map { " + " + $0 } ?? ""
        let size = total > 0 ? ", " + ByteFormatter.string(total) + " reclaimable" : ""
        lines.append(findings.isEmpty ? "No findings."
            : tally.actionable == 0 ? "No findings\(info)."
            : "Total: \(tally.headline)\(size)\(info)")
        let entries = result.context.diagnostics.entries
        let diagnostics = entries.filter { verbose || $0.level != .info }
        // `--verbose` lists info entries above as `info:`; otherwise they become notes, dropped under `--quiet`.
        let notes = verbose || quiet ? [] : entries.filter { $0.level == .info }
        if !diagnostics.isEmpty || !notes.isEmpty { lines.append("") }
        for d in diagnostics {
            lines.append(paint("\(d.level.rawValue): \(d.path.map { $0 + ": " } ?? "")\(d.message)", d.level == .info ? "2" : "33"))
        }
        if notes.count > Self.noteLimit {
            lines.append(paint("\(notes.count) notes (use --format json to see them)", "2"))
        } else {
            for n in notes { lines.append(paint("note: \(n.path.map { $0 + ": " } ?? "")\(n.message)", "2")) }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `Baseline: 140 baselined, 3 new, 2 fixed (12 days old)`.
    public static func baselineLine(_ b: BaselineReport) -> String {
        "Baseline: \(b.baselinedCount) baselined, \(b.newCount) new, \(b.fixed.count) fixed (\(b.ageDays) day\(b.ageDays == 1 ? "" : "s") old)"
    }

    /// `3y, J. Appleseed`; `n/a (shallow)` when git could not say.
    public static func historySuffix(_ h: FindingHistory) -> String {
        guard h.status == .ok, let c = h.lastCommit else { return "n/a (\(h.status.rawValue))" }
        var parts: [String] = []
        if let days = h.ageDays { parts.append(Self.age(days: days)) }
        parts.append(c.authorName)
        return parts.joined(separator: ", ")
    }

    /// Compact age: `12d`, `5mo`, `3y`.
    public static func age(days: Int) -> String {
        if days < 30 { return "\(max(0, days))d" }
        if days < 365 { return "\(days / 30)mo" }
        return "\(days / 365)y"
    }
}
