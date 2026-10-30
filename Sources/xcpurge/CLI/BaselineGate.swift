// LANE: A
import Foundation
import XcpurgeKit

/// Applies `--baseline` to a scan result: hides baselined findings, reports fixed entries and warnings.
enum BaselineGate {
    /// - Parameter categories: what the command scanned; decides which baseline entries may be reported as
    ///   fixed. When the caller does not pass it, it is inferred from the subcommand on the command line.
    static func apply(_ r: ScanResult, options: CommonOptions, categories: Set<XcpurgeKit.Category>? = nil) throws -> ScanResult {
        let config = r.context.config
        guard let configured = config.baseline else { return r }
        // `--baseline` arrives absolute; a value from xcpurge.json is relative to the root.
        let url = configured.hasPrefix("/") ? URL(fileURLWithPath: configured) : r.context.root.appendingPathComponent(configured)
        let file: BaselineFile
        do { file = try BaselineFile.load(url) } catch let error as BaselineError {
            throw XcpurgeError.invalidConfig(error.description)
        }
        let display = options.baselineOptions.baseline ?? configured
        let (kept, report) = BaselineMatcher.apply(findings: r.findings, file: file, filePath: display,
                                                   categories: categories ?? inferCategories(), config: config,
                                                   strict: options.baselineOptions.strictBaseline, root: r.context.root)
        for warning in report.warnings { ScanRunner.stderr("warning: baseline: \(warning)\n") }
        if !options.quiet {
            ScanRunner.stderr("Baseline \(display) (\(report.ageDays) days): \(report.baselinedCount) baselined, "
                + "\(report.newCount) new, \(report.fixed.count) fixed\n")
        }
        if report.strict, !report.fixed.isEmpty {
            ScanRunner.stderr("error: baseline lists \(report.fixed.count) fixed finding(s) (--strict-baseline); "
                + "regenerate with xcpurge baseline\n")
        }
        return ScanResult(context: r.context, findings: kept, elapsed: r.elapsed, baseline: report)
    }

    /// True when `--strict-baseline` is set and the baseline has fixed entries (exit 1).
    static func failsStrict(_ r: ScanResult) -> Bool {
        guard let baseline = r.baseline else { return false }
        return baseline.strict && !baseline.fixed.isEmpty
    }

    /// Fallback for callers that do not pass the categories: the scan-style subcommand decides them.
    private static func inferCategories() -> Set<XcpurgeKit.Category> {
        switch CommandLine.arguments.dropFirst().first(where: { !$0.hasPrefix("-") }) {
        case "assets": [.assets, .duplicates]
        case "strings": [.strings]
        case "files": [.files]
        default: XcpurgeKit.Category.scannable
        }
    }
}
