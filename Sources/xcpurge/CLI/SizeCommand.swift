import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge size`: bytes by category and module, what the findings would reclaim, optionally a built app;
/// `--save` / `--compare` snapshot and diff; with `--compare`, a PR comment (`--format markdown|github`) and a
/// growth gate (`--fail-if-grows`).
struct SizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "size", abstract: "Measure the project (and a built .app or .ipa) and estimate what a purge reclaims.")

    @OptionGroup var options: CommonOptions
    @Option(help: "Built .app bundle or .ipa to measure as well (nothing is built).", completion: .file())
    var app: String?
    @Option(help: "Write the JSON snapshot to this file.", completion: .file()) var save: String?
    @Option(help: "Compare with a saved snapshot (e.g. .xcpurge-trash/<session>/size-before.json).", completion: .file())
    var compare: String?
    @Option(help: ArgumentHelp("Exit 1 when the total grew by more than this: bytes (100KB, 2MB) or a share of the base (2%).",
                               valueName: "limit"))
    var failIfGrows: String?
    @Option(help: ArgumentHelp("markdown/github: print nothing (and write no --output) when |change| is below this (e.g. 100KB).",
                               valueName: "bytes"))
    var commentThreshold: String?
    @Option(help: "markdown/github: paths listed under Top changes; the rest fold away.") var top: Int = 20
    @Option(help: ArgumentHelp("markdown/github: hide paths whose |change| is below this many bytes.", valueName: "bytes"))
    var minPathDelta: Int64 = 500
    @Flag(help: "A missing --compare file is a note, not an error: no comparison, exit 0.") var allowMissingCompare = false

    var limit: SizeLimit? { failIfGrows.flatMap(SizeLimit.init) }
    var threshold: Int64? { commentThreshold.flatMap(ByteSize.parse) }

    func validate() throws {
        if let f = options.format, ![.text, .json, .markdown, .github].contains(f) {
            throw ValidationError("size supports --format text, json, markdown or github")
        }
        if compare == nil {
            if let f = options.format, f == .markdown || f == .github {
                throw ValidationError("--format \(f.rawValue) needs --compare <base snapshot>")
            }
            for (flag, given) in [("--fail-if-grows", failIfGrows != nil), ("--comment-threshold", commentThreshold != nil),
                                  ("--allow-missing-compare", allowMissingCompare)] where given {
                throw ValidationError("\(flag) needs --compare <base snapshot>")
            }
        }
        if let failIfGrows, limit == nil { throw ValidationError("--fail-if-grows: expected bytes (100KB, 2MB) or a percentage (2%), got \(failIfGrows)") }
        if let commentThreshold, threshold == nil { throw ValidationError("--comment-threshold: expected bytes (100KB), got \(commentThreshold)") }
        if top < 0 { throw ValidationError("--top must be 0 or more") }
        if minPathDelta < 0 { throw ValidationError("--min-path-delta must be 0 or more") }
    }

    func run() async throws {
        // Read inputs first so a bad path fails before the scan.
        let before = try loadBase()
        let appSize = try app.map { try AppMeasurer.measure(CommonOptions.absolute($0)) }
        let format = options.format ?? .text
        var opts = options
        opts.format = .text
        opts.output = nil
        // No baseline or git step: reclaimable counts every finding, and a missing baseline file is not size's concern.
        let result = try await ScanRunner.scan(opts, categories: XcpurgeKit.Category.scannable, applyGates: false)
        let snapshot = SizeMeasurer.snapshot(result, categories: XcpurgeKit.Category.scannable, app: appSize)
        if let save {
            let url = CommonOptions.absolute(save)
            try snapshot.write(to: url)
            if !options.quiet { ScanRunner.stderr("Saved size snapshot to \(url.path)\n") }
        }
        if let text = render(before: before, after: snapshot, format: format) {
            try emit(text, format: format)
        }
        if let before, let limit, let breach = SizeGate.check(before, snapshot, limit: limit) {
            ScanRunner.stderr(breach.line + "\n")
            throw XcpurgeExit.failOnHit.exitCode
        }
    }

    /// The `--compare` snapshot; nil without the flag, or when the file is missing and `--allow-missing-compare`.
    func loadBase() throws -> SizeSnapshot? {
        guard let compare else { return nil }
        let url = CommonOptions.absolute(compare)
        if allowMissingCompare, !FileManager.default.fileExists(atPath: url.path) {
            ScanRunner.stderr("note: no base snapshot at \(url.path); nothing to compare (--allow-missing-compare)\n")
            return nil
        }
        return try SizeSnapshot.load(from: url)
    }

    /// nil means print nothing and write no file (markdown/github under the threshold, or with no base).
    func render(before: SizeSnapshot?, after: SizeSnapshot, format: OutputFormat) -> String? {
        switch format {
        case .markdown, .github:
            guard let before else { return nil }
            if let threshold, SizeGate.belowThreshold(before, after, threshold: threshold) {
                if !options.quiet {
                    ScanRunner.stderr("size: \(SizeText.change(SizeGate.metric(before, after).row)) is below the comment threshold "
                        + "(\(ByteSize.format(threshold))); no comment\n")
                }
                return nil
            }
            return SizeMarkdown.render(before: before, after: after,
                                       options: SizeMarkdown.Options(top: top, minPathDelta: minPathDelta))
        case .json:
            return before.map { Self.json(["before": $0, "after": after]) } ?? after.json()
        default:
            return before.map { SizeText.compare($0, after, colors: ScanRunner.stdoutColors && options.output == nil) }
                ?? SizeText.render(after)
        }
    }

    /// Prints or writes `--output`; `github` also appends the body to `$GITHUB_STEP_SUMMARY` when set.
    func emit(_ text: String, format: OutputFormat) throws {
        if format == .github, let summary = ProcessInfo.processInfo.environment["GITHUB_STEP_SUMMARY"], !summary.isEmpty {
            let handle = try FileHandle(forWritingTo: Self.createIfMissing(URL(fileURLWithPath: summary)))
            defer { try? handle.close() }
            try handle.seekToEnd()
            try handle.write(contentsOf: Data((text + "\n").utf8))
        }
        if let output = options.output {
            let url = CommonOptions.absolute(output)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url, options: .atomic)
            ScanRunner.stderr("Wrote size report to \(url.path)\n")
        } else {
            print(text, terminator: "")
        }
    }

    static func createIfMissing(_ url: URL) throws -> URL {
        if !FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data().write(to: url)
        }
        return url
    }

    static func json(_ value: [String: SizeSnapshot]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self) + "\n"
    }
}
