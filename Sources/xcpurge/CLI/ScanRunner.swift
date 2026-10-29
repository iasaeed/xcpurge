import ArgumentParser
import Foundation
import XcpurgeKit

/// Shared body of scan-style commands: build config, run the engine, print, apply `--fail-on`.
enum ScanRunner {
    static func scan(_ options: CommonOptions, categories: Set<XcpurgeKit.Category>) async throws -> ScanResult {
        let config = try options.makeConfig()
        return try await ScanEngine(root: options.rootURL, config: config).run(categories: categories)
    }

    /// Prints the report, or writes it to `--output` (html always goes to a file) and honours `--open`.
    static func report(_ result: ScanResult, _ options: CommonOptions? = nil) throws {
        let config = result.context.config
        let format = config.format.flatMap(OutputFormat.init(rawValue:)) ?? .text
        let file = outputURL(format: format, root: result.context.root, options: options)
        let colors = format == .text && file == nil && isatty(STDOUT_FILENO) != 0
            && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        let text = format.reporter(colors: colors, verbose: config.verbose).render(result)
        guard let file else { print(text, terminator: ""); return }
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: file, options: .atomic)
        FileHandle.standardError.write(Data("Wrote \(format.rawValue) report to \(file.path)\n".utf8))
        if format == .html, options?.openReport == true { try ReportOpener.open(file, browser: options?.browser) }
    }

    /// `--output`, else `<root>/.xcpurge/report-<yyyyMMdd-HHmmss>.html` for html; nil means stdout.
    static func outputURL(format: OutputFormat, root: URL, options: CommonOptions?) -> URL? {
        if let output = options?.output { return CommonOptions.absolute(output) }
        guard format == .html else { return nil }
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return root.appendingPathComponent(".xcpurge/report-\(stamp.string(from: Date())).html")
    }

    static func exitIfFailOn(_ result: ScanResult) throws {
        if FailOn.hit(result.context.config.failOn, result.findings) { throw XcpurgeExit.failOnHit.exitCode }
    }

    static func printAction(_ report: ActionReport, verb: String, session: String) {
        let out = FileHandle.standardError
        for p in report.moved { out.write(Data("  moved \(p)\n".utf8)) }
        for p in report.rewritten { out.write(Data("  rewrote \(p)\n".utf8)) }
        for s in report.skipped { out.write(Data("  skipped \(s.path): \(s.reason)\n".utf8)) }
        if report.moved.isEmpty && report.rewritten.isEmpty {
            out.write(Data("Nothing was \(verb).\n".utf8))
        } else {
            out.write(Data("\(verb.capitalized) \(report.moved.count + report.rewritten.count) item(s). Undo with: xcpurge restore --session \(session)\n".utf8))
        }
    }
}
