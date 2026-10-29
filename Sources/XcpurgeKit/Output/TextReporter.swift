/// Human-readable report grouped by category, kind and module, with confidence, sizes and totals.
/// ANSI colors only when `colors` is set (the CLI enables it for terminals).
public struct TextReporter: Reporter {
    public let colors: Bool
    public let verbose: Bool

    public init(colors: Bool = false, verbose: Bool = false) {
        self.colors = colors
        self.verbose = verbose
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
        let counts = Confidence.allCases.reversed().map { c in "\(findings.filter { $0.confidence == c }.count) \(c.rawValue)" }
        lines.append(findings.isEmpty ? "No findings."
            : "Total: \(findings.count) findings (\(counts.joined(separator: ", ")))\(total > 0 ? ", " + ByteFormatter.string(total) + " reclaimable" : "")")
        let diagnostics = result.context.diagnostics.entries.filter { verbose || $0.level != .info }
        if !diagnostics.isEmpty {
            lines.append("")
            for d in diagnostics {
                lines.append(paint("\(d.level.rawValue): \(d.path.map { $0 + ": " } ?? "")\(d.message)", d.level == .info ? "2" : "33"))
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
