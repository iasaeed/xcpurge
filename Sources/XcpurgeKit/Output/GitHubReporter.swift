import Foundation

/// GitHub Actions workflow commands: one `::warning file=<rel>,line=<n>,title=xcpurge <kind>::<msg>` per finding
/// (`::notice` for informational kinds), a `::notice::` for fixed baseline entries, then a `::notice::` summary line
/// (with the baseline counts when one was applied). Deterministic report order.
/// `file=` is relative to the repository checkout (`$GITHUB_WORKSPACE`, else the working directory) so annotations
/// land on the right file when the scan root is a subfolder; folder findings point at their `Contents.json`.
public struct GitHubReporter: Reporter {
    /// Directory `file=` paths are relative to; nil means `$GITHUB_WORKSPACE` or the working directory.
    let base: String?

    public init(base: String? = nil) {
        self.base = base
    }

    public func render(_ result: ScanResult) -> String {
        let root = result.context.root.path
        let base = RelPath.normalize(self.base ?? ProcessInfo.processInfo.environment["GITHUB_WORKSPACE"]
            ?? FileManager.default.currentDirectoryPath)
        var out = ""
        for f in result.findings {
            let command = f.kind.isInformational ? "notice" : "warning"
            let title = Self.escapeProperty("xcpurge \(f.kind.flagName)")
            let message = Self.escapeData(XcodeReporter.message(f) + " (\(f.confidence.rawValue))")
            let (absolute, line) = XcodeReporter.location(f, root: root)
            let file = RelPath.isUnder(absolute, base) ? RelPath.relative(absolute, to: base) : absolute
            out += "::\(command) file=\(Self.escapeProperty(file)),line=\(line),title=\(title)::\(message)\n"
        }
        let counts = Confidence.allCases.reversed().map { c in
            "\(result.findings.filter { $0.confidence == c }.count) \(c.rawValue)"
        }
        var summary = "xcpurge: \(result.findings.count) findings (\(counts.joined(separator: ", ")))"
        if let b = result.baseline {
            if !b.fixed.isEmpty {
                let list = b.fixed.sorted().map { "\($0.kind.flagName) \($0.module) \($0.name ?? $0.path)" }.joined(separator: "; ")
                out += "::notice title=\(Self.escapeProperty("xcpurge baseline"))::"
                    + Self.escapeData("\(b.fixed.count) fixed baseline entr\(b.fixed.count == 1 ? "y" : "ies") (regenerate with xcpurge baseline): \(list)") + "\n"
            }
            summary += "; baseline: \(b.baselinedCount) baselined, \(b.newCount) new, \(b.fixed.count) fixed"
        }
        out += "::notice::\(Self.escapeData(summary))\n"
        return out
    }

    /// Message escaping per the workflow-command spec.
    static func escapeData(_ s: String) -> String {
        s.replacingOccurrences(of: "%", with: "%25").replacingOccurrences(of: "\r", with: "%0D")
            .replacingOccurrences(of: "\n", with: "%0A")
    }

    /// Property escaping: the message rules plus `:` and `,`.
    static func escapeProperty(_ s: String) -> String {
        escapeData(s).replacingOccurrences(of: ":", with: "%3A").replacingOccurrences(of: ",", with: "%2C")
    }
}
