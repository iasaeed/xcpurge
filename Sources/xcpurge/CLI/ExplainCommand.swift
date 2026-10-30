import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge explain <root> <subject>`: why a finding (by id, path or name) is reported, suppressed or not reported.
struct ExplainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Explain one finding: who could see it, where it is referenced, and how its confidence was derived.",
        discussion: """
            The subject is a finding id from any report (unused-asset-3f9c0a12bd), a path relative to the root (or \
            absolute, inside it; a file inside an asset set names the set), or a name (asset, string key, file). \
            Statuses: reported, suppressed (which .xcpurgeignore line or inline marker), belowThreshold, \
            notReported (a used subject lists where it is referenced). --format text (default) or json. \
            Exit 2 when nothing matches, with the closest names.
            """)

    @OptionGroup var options: CommonOptions
    @Argument(help: "A finding id (unused-asset-3f9c0a12bd), a root-relative path, or a name.") var subject: String

    func validate() throws {
        if let format = options.format, format != .text, format != .json {
            throw ValidationError("explain supports --format text or json")
        }
    }

    func run() async throws {
        let config = try options.makeConfig()
        // Only the flag chooses the format: a `"format": "github"` in xcpurge.json is for scan reports, not explain.
        let format = options.format ?? .text
        let report: ExplainReport
        do {
            report = try await Explainer.explain(subject: subject, root: options.rootURL, config: config)
        } catch let miss as Explainer.NoMatch {
            ScanRunner.stderr("error: \(miss)\n")
            throw XcpurgeExit.usage.exitCode
        }
        let text = format == .json ? Explainer.renderJSON(report) : Explainer.renderText(report)
        if let output = options.output {
            let file = CommonOptions.absolute(output)
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: file, options: .atomic)
            ScanRunner.stderr("Wrote \(format.rawValue) explanation to \(file.path)\n")
        } else {
            print(text, terminator: "")
        }
    }
}
