import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge baseline`: writes the current findings to a baseline file that `--baseline` later hides.
struct BaselineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baseline",
        abstract: "Write the current findings to a baseline file (default <root>/.xcpurge-baseline.json).",
        discussion: "Scans every category at --min-confidence (default low) with .xcpurgeignore applied and writes one "
            + "entry per finding identity. The file is regenerated in full: fixed findings drop out; --output chooses the "
            + "file. Later, `xcpurge scan --baseline <file>` hides the listed findings, reports new and fixed ones, and "
            + "--fail-on only sees the new ones.")

    @OptionGroup var options: CommonOptions

    /// The shared options are accepted for scope and config; the report-only ones have no meaning here.
    func validate() throws {
        if options.format != nil || options.openReport || options.browser != nil {
            throw ValidationError("--format, --open and --browser do not apply to `xcpurge baseline`; "
                + "it writes a baseline file (--output chooses where)")
        }
    }

    func run() async throws {
        var config = try options.makeConfig()
        let url = options.output.map(CommonOptions.absolute) ?? options.rootURL.appendingPathComponent(BaselineFile.defaultName)
        // Nothing is hidden while writing; the engine only uses this path to keep the file out of the inventory.
        config.baseline = url.path
        if !options.quiet { ScanRunner.hintIfManyRepositories(options.rootURL) }
        let progress = TerminalProgress(isTTY: StderrTerminal.isTTY, quiet: options.quiet, colors: StderrTerminal.colors,
                                        width: StderrTerminal.width, printsSummary: false)
        let categories = XcpurgeKit.Category.scannable
        let result: ScanResult
        do { result = try await ScanEngine(root: options.rootURL, config: config, progress: progress).run(categories: categories) }
        catch { progress.stop(); throw error }
        progress.stop()

        let root = result.context.root
        let file = BaselineFile.make(findings: result.findings, categories: categories, config: config, root: root)
        let previous = try? BaselineFile.load(url)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try file.write(to: url)

        var line = "Wrote baseline \(url.path): \(Self.count(file.entries.count, "entry", "entries")) "
            + "covering \(Self.count(result.findings.count, "finding", "findings"))"
        if let previous {
            let (added, removed) = Self.diff(from: previous, to: file)
            line += " (+\(added) added, -\(removed) removed)"
        }
        ScanRunner.stderr(line + "\n")
        if !options.quiet { ScanRunner.stderr(ScanSummary(result).line + "\n") }
    }

    /// Findings added and removed between two baselines, counted per key multiplicity.
    static func diff(from old: BaselineFile, to new: BaselineFile) -> (added: Int, removed: Int) {
        var counts: [String: Int] = [:]
        for e in old.entries { counts[e.key, default: 0] -= e.count }
        for e in new.entries { counts[e.key, default: 0] += e.count }
        let added = counts.values.filter { $0 > 0 }.reduce(0, +)
        let removed = -counts.values.filter { $0 < 0 }.reduce(0, +)
        return (added, removed)
    }

    private static func count(_ n: Int, _ singular: String, _ plural: String) -> String {
        "\(n) \(n == 1 ? singular : plural)"
    }
}
