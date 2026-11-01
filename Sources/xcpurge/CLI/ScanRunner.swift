import ArgumentParser
import Foundation
import XcpurgeKit

/// Shared body of scan-style commands: build config, run the engine, apply the baseline and `--git`, print, apply
/// `--fail-on`.
enum ScanRunner {
    /// Runs the scan with live progress on stderr (terminal only, not under `--quiet`). The summary line is left
    /// behind when the report goes to stdout; a report written to a file prints it with the file's path instead.
    /// - Parameter applyGates: false skips the baseline and `--git` steps (`xcpurge size` measures every finding).
    static func scan(_ options: CommonOptions, categories: Set<XcpurgeKit.Category>, applyGates: Bool = true) async throws -> ScanResult {
        let config = try options.makeConfig()
        let format = config.format.flatMap(OutputFormat.init(rawValue:)) ?? .text
        if !options.quiet { hintIfManyRepositories(options.rootURL) }
        let progress = TerminalProgress(isTTY: StderrTerminal.isTTY, quiet: options.quiet, colors: StderrTerminal.colors,
                                        width: StderrTerminal.width,
                                        printsSummary: outputURL(format: format, root: options.rootURL, options: options) == nil)
        let result: ScanResult
        do { result = try await ScanEngine(root: options.rootURL, config: config, progress: progress).run(categories: categories) }
        catch { progress.stop(); throw error }
        progress.stop()
        guard applyGates else { return result }
        var r = try BaselineGate.apply(result, options: options, categories: categories)
        r = await HistoryStep.enrich(r, options: options.gitOptions, quiet: options.quiet)
        return r
    }

    /// A root holding several unrelated repositories (e.g. `~/Projects`) makes one slow, mixed scan; say so.
    static func hintIfManyRepositories(_ root: URL) {
        let count = RepositorySurvey.independentRepositories(under: root)
        guard count >= 3 else { return }
        stderr("Scanning \(count) independent repositories under \(root.path); results are per-module and may take a while. "
            + "Run xcpurge inside one project for faster, more precise results.\n")
    }

    static func stderr(_ text: String) { FileHandle.standardError.write(Data(text.utf8)) }

    /// ANSI colors for text on stdout: a terminal and no `NO_COLOR`.
    static var stdoutColors: Bool { isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil }

    /// After `--delete` / `--prune`: re-scans the tree, stores `size-before.json` (`before`, measured before the
    /// action) and `size-after.json` in the trash session, and prints the compact before → after table. A failure
    /// here is a warning; the action already happened and can be undone.
    static func recordSizes(before: SizeSnapshot, result: ScanResult, store: TrashStore,
                            categories: Set<XcpurgeKit.Category>, options: CommonOptions) async {
        guard FileManager.default.fileExists(atPath: store.sessionURL.path) else { return }
        do {
            let rescan = try await ScanEngine(root: result.context.root, config: result.context.config).run(categories: categories)
            let after = SizeMeasurer.snapshot(rescan, categories: categories)
            try before.write(to: store.sessionURL.appendingPathComponent(SizeSnapshot.beforeFileName))
            try after.write(to: store.sessionURL.appendingPathComponent(SizeSnapshot.afterFileName))
            if !options.quiet { stderr(SizeText.compact(before, after, colors: StderrTerminal.isTTY && StderrTerminal.colors)) }
        } catch {
            stderr("warning: could not measure the size after the action: \(error)\n")
        }
    }

    /// Findings `--delete` / `--prune` act on: non-informational findings of `category` at or above the explicit
    /// `--min-confidence`, or high only when it is not given. Notes on stderr how many were left in place.
    static func actionable(_ result: ScanResult, category: XcpurgeKit.Category, options: CommonOptions) -> [Finding] {
        let candidates = result.findings.filter { $0.category == category && !$0.kind.isInformational }
        let floor = options.minConfidence ?? .high
        let chosen = candidates.filter { $0.confidence >= floor }
        if chosen.count < candidates.count {
            let note = "Leaving \(candidates.count - chosen.count) finding(s) below \(floor.rawValue) confidence in place"
                + (options.minConfidence == nil ? "; pass --min-confidence medium to include them.\n" : ".\n")
            FileHandle.standardError.write(Data(note.utf8))
        }
        return chosen
    }

    /// Prints the report, or writes it to `--output` (html always goes to a file) and honours `--open`.
    static func report(_ result: ScanResult, _ options: CommonOptions? = nil) throws {
        let config = result.context.config
        let format = config.format.flatMap(OutputFormat.init(rawValue:)) ?? .text
        let file = outputURL(format: format, root: result.context.root, options: options)
        let colors = format == .text && file == nil && isatty(STDOUT_FILENO) != 0
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        let reporterOptions = ReporterOptions(colors: colors, verbose: config.verbose, quiet: options?.quiet == true,
                                              maxWarnings: options?.maxWarnings, agentLimit: options?.agentLimit ?? 30)
        let text = format.reporter(reporterOptions).render(result)
        guard let file else { print(text, terminator: ""); return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        let quiet = options?.quiet == true
        var block = "Wrote \(format.rawValue) report to \(file.path)\n"
        if !quiet { block += ScanSummary(result).line + "\n" }
        if format == .html, options?.openReport == true {
            let outcome = ReportOpener.open(file, browser: options?.browser)
            if case .opened = outcome, quiet {} else { block += outcome.describe(path: file.path) + "\n" }
        } else if format == .html, !quiet {
            block += "Open it with: open \"\(file.path)\"\n"
        }
        stderr(block)
    }

    /// `--output`, else `<root>/.xcpurge/report-<yyyyMMdd-HHmmss>.html` for html; nil means stdout.
    static func outputURL(format: OutputFormat, root: URL, options: CommonOptions?) -> URL? {
        if let output = options?.output { return CommonOptions.absolute(output) }
        guard format == .html else { return nil }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return root.appendingPathComponent(ToolOutput.reportDirectoryName + "/report-\(stamp.string(from: Date())).html")
    }

    /// One confirmation line per finding: `[high] unused-asset App/Assets.xcassets/x.imageset (x)`.
    static func describe(_ f: Finding) -> String {
        "[\(f.confidence.rawValue)] \(f.kind.rawValue) \(f.path)" + (f.name.map { " (\($0))" } ?? "")
    }

    static func exitIfFailOn(_ result: ScanResult) throws {
        if BaselineGate.failsStrict(result) || FailOn.hit(result.context.config.failOn, result.findings) {
            throw XcpurgeExit.failOnHit.exitCode
        }
    }

    static func printAction(_ report: ActionReport, verb: String, session: String) {
        let out = FileHandle.standardError
        let restoring = verb == "restored"
        for p in report.moved { out.write(Data("  \(restoring ? "restored" : "moved") \(p)\n".utf8)) }
        for p in report.rewritten { out.write(Data("  \(restoring ? "restored" : "rewrote") \(p)\n".utf8)) }
        for s in report.skipped { out.write(Data("  skipped \(s.path): \(s.reason)\n".utf8)) }
        let count = report.moved.count + report.rewritten.count
        if count == 0 {
            out.write(Data("Nothing was \(verb).\n".utf8))
        } else if restoring {
            out.write(Data("Restored \(count) item(s) from session \(session).\n".utf8))
        } else {
            out.write(Data("\(verb.capitalized) \(count) item(s). Undo with: xcpurge restore --session \(session)\n".utf8))
        }
    }
}
