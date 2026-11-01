import Foundation

/// Machine-readable report: `schemaVersion` 2 (adds `size` to 1; 0.4 adds the optional `id`, `history` and
/// `baseline` fields, and `summary.actionable` / `summary.informational` appear without a bump), stable key order
/// and finding order.
public struct JSONReporter: Reporter {
    public static let schemaVersion = 2

    public init() {}

    struct Document: Encodable {
        struct Tool: Encodable { let name: String; let version: String }
        struct ModuleEntry: Encodable {
            let id: ModuleID
            let kind: ModuleKind
            let dependsOn: [ModuleID]
            let embeds: [ModuleID]
        }
        struct Informational: Encodable { let dynamicLookups: Int; let duplicateSets: Int }
        /// `count` stays the number of all findings (the schema's version policy: no change of meaning within v2);
        /// `actionable` is the one the text headline and the HTML report show.
        struct Summary: Encodable {
            let actionable: Int
            let byKind: [String: Int]
            let bytes: Int64
            let count: Int
            let informational: Informational
        }

        let schemaVersion: Int
        let tool: Tool
        let root: String
        let modules: [ModuleEntry]
        let summary: Summary
        let size: SizeReport
        let findings: [Finding]
        let diagnostics: [Diagnostics.Entry]
        /// Present only when `--baseline` was applied.
        let baseline: BaselineReport?
    }

    public func render(_ result: ScanResult) -> String {
        let findings = result.findings.sorted(by: Finding.reportOrder)
        let modules = result.context.graph.sorted.map {
            Document.ModuleEntry(id: $0.id, kind: $0.kind, dependsOn: $0.dependsOn.sorted(), embeds: $0.embeds.sorted())
        }
        let byKind = Dictionary(grouping: findings, by: \.kind.rawValue).mapValues(\.count)
        let tally = FindingTally(findings)
        let doc = Document(
            schemaVersion: Self.schemaVersion,
            tool: .init(name: XcpurgeVersion.name, version: XcpurgeVersion.current),
            root: result.context.root.path,
            modules: modules,
            summary: .init(actionable: tally.actionable, byKind: byKind,
                           bytes: findings.compactMap(\.sizeBytes).reduce(0, +), count: findings.count,
                           informational: .init(dynamicLookups: tally.dynamicLookups, duplicateSets: tally.duplicateSets)),
            size: SizeMeasurer.report(result),
            findings: findings,
            diagnostics: result.context.diagnostics.entries,
            baseline: result.baseline)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(doc)) ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self) + "\n"
    }
}
