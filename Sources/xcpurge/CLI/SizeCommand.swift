import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge size`: bytes by category and module, what the findings would reclaim, optionally a built app;
/// `--save` / `--compare` snapshot and diff.
struct SizeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "size", abstract: "Measure the project (and a built .app or .ipa) and estimate what a purge reclaims.")

    @OptionGroup var options: CommonOptions
    @Option(help: "Built .app bundle or .ipa to measure as well (nothing is built).", completion: .file())
    var app: String?
    @Option(help: "Write the JSON snapshot to this file.", completion: .file()) var save: String?
    @Option(help: "Compare with a saved snapshot (e.g. .xcpurge-trash/<session>/size-before.json).", completion: .file())
    var compare: String?

    func validate() throws {
        if let f = options.format, f != .text, f != .json { throw ValidationError("size supports --format text or json") }
    }

    func run() async throws {
        // Read inputs first so a bad path fails before the scan.
        let before = try compare.map { try SizeSnapshot.load(from: CommonOptions.absolute($0)) }
        let appSize = try app.map { try AppMeasurer.measure(CommonOptions.absolute($0)) }
        var opts = options
        opts.format = options.format ?? .text
        opts.output = nil
        let result = try await ScanRunner.scan(opts, categories: Set(XcpurgeKit.Category.allCases))
        let snapshot = SizeMeasurer.snapshot(result, categories: Set(XcpurgeKit.Category.allCases), app: appSize)
        if let save {
            let url = CommonOptions.absolute(save)
            try snapshot.write(to: url)
            if !options.quiet { ScanRunner.stderr("Saved size snapshot to \(url.path)\n") }
        }
        let text: String
        if let before {
            text = opts.format == .json ? Self.json(["before": before, "after": snapshot])
                : SizeText.compare(before, snapshot, colors: ScanRunner.stdoutColors)
        } else {
            text = opts.format == .json ? snapshot.json() : SizeText.render(snapshot)
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

    static func json(_ value: [String: SizeSnapshot]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(value)) ?? Data("{}".utf8), as: UTF8.self) + "\n"
    }
}
