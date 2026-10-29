import ArgumentParser
import Foundation
import XcpurgeKit

/// Shared body of scan-style commands: build config, run the engine, print, apply `--fail-on`.
enum ScanRunner {
    static func scan(_ options: CommonOptions, categories: Set<XcpurgeKit.Category>) async throws -> ScanResult {
        let config = try options.makeConfig()
        return try await ScanEngine(root: options.rootURL, config: config).run(categories: categories)
    }

    static func report(_ result: ScanResult) {
        let config = result.context.config
        let format = config.format.flatMap(OutputFormat.init(rawValue:)) ?? .text
        let colors = format == .text && isatty(STDOUT_FILENO) != 0 && ProcessInfo.processInfo.environment["NO_COLOR"] == nil
        print(format.reporter(colors: colors, verbose: config.verbose).render(result), terminator: "")
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
