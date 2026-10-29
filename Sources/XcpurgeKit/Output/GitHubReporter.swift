// LANE: C
import Foundation

/// GitHub Actions workflow commands: one `::warning file=<rel>,line=<n>,title=xcpurge <kind>::<msg>` per finding
/// (`::notice` for informational kinds), then a `::notice::` summary line. Deterministic report order.
public struct GitHubReporter: Reporter {
    public init() {}

    public func render(_ result: ScanResult) -> String {
        var out = ""
        for f in result.findings {
            let command = f.kind.isInformational ? "notice" : "warning"
            let title = Self.escapeProperty("xcpurge \(f.kind.flagName)")
            let message = Self.escapeData(XcodeReporter.message(f) + " (\(f.confidence.rawValue))")
            out += "::\(command) file=\(Self.escapeProperty(f.path)),line=\(f.line ?? 1),title=\(title)::\(message)\n"
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
