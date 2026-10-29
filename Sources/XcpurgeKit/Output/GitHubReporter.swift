// LANE: C
import Foundation

/// GitHub Actions workflow commands: one `::warning file=<rel>,line=<n>,title=xcpurge <kind>::<msg>` per finding
/// (`::notice` for informational kinds), then a `::notice::` summary line. Deterministic report order.
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
        out += "::notice::\(Self.escapeData("xcpurge: \(result.findings.count) findings (\(counts.joined(separator: ", ")))"))\n"
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
