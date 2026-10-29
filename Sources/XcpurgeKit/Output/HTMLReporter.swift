import Foundation

/// Single-file interactive HTML report: the `JSONReporter` document embedded in the `Resources/report.html` template
/// (inline CSS and JS, no network). Accepts any JSONReporter output, so a saved `.json` can be re-rendered.
public struct HTMLReporter: Reporter {
    /// Scan date shown in the header; injectable for deterministic tests.
    public let date: Date

    public init(date: Date = Date()) {
        self.date = date
    }

    public func render(_ result: ScanResult) -> String {
        Self.render(json: JSONReporter().render(result), scannedFiles: result.context.inventory.files.count, date: date)
    }

    /// Fills the template from a JSONReporter document (`schemaVersion` 1).
    public static func render(json: String, scannedFiles: Int?, date: Date) -> String {
        let doc = (try? JSONSerialization.jsonObject(with: Data(json.utf8))) as? [String: Any] ?? [:]
        let tool = doc["tool"] as? [String: Any]
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let values: [String: String] = [
            "TOOL": escapeHTML(tool?["name"] as? String ?? XcpurgeVersion.name),
            "VERSION": escapeHTML(tool?["version"] as? String ?? XcpurgeVersion.current),
            "ROOT": escapeHTML(doc["root"] as? String ?? ""),
            "DATE": formatter.string(from: date),
            "FILES": scannedFiles.map(String.init) ?? "",
            "COUNT": ScanSummary.count((doc["findings"] as? [Any])?.count ?? 0, "finding"),
        ]
        var html = template
        for (key, value) in values { html = html.replacingOccurrences(of: "{{\(key)}}", with: value) }
        // Data last, so placeholder-looking text inside findings is never substituted.
        return html.replacingOccurrences(of: "{{DATA}}", with: escapeScriptData(json))
    }

    /// Makes JSON safe inside `<script type="application/json">`: `<` only occurs inside JSON strings,
    /// where `<\/` and `<` decode to the same text.
    static func escapeScriptData(_ json: String) -> String {
        json.replacingOccurrences(of: "</", with: "<\\/").replacingOccurrences(of: "<!--", with: "\\u003c!--")
    }

    static func escapeHTML(_ s: String) -> String {
        s.replacingOccurrences(of: "&", with: "&amp;").replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;").replacingOccurrences(of: "\"", with: "&quot;")
    }

    /// `Resources/report.html`, compiled in via `ReportTemplate` so a copied-out binary needs no resource bundle.
    static var template: String { ReportTemplate.html }
}
