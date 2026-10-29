import ArgumentParser
import XcpurgeKit

/// `xcpurge strings`: unused and stale localized strings; `--prune` removes them (backed up to the trash).
struct StringsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strings", abstract: "Report unused localized strings; optionally prune them.")

    @OptionGroup var options: CommonOptions
    @Flag(help: "Remove reported keys (high confidence unless --min-confidence is given) from string catalogs and .strings files (backups in .xcpurge-trash).")
    var prune = false
    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.") var yes = false

    func run() async throws {
        let result = try await ScanRunner.scan(options, categories: [.strings])
        if prune {
            let prunable = ScanRunner.actionable(result, category: .strings, options: options)
            guard !prunable.isEmpty,
                  ConfirmPrompt.confirm("Remove \(prunable.count) string key(s)?",
                                        details: prunable.map(ScanRunner.describe), assumeYes: yes)
            else { return try ScanRunner.report(result, options) }
            let sizeBefore = SizeMeasurer.snapshot(result, categories: [.strings])
            let store = try TrashStore.begin(root: result.context.root)
            let report = try PruneStrings(store: store).apply(prunable, context: result.context)
            // The session ID goes out first: writing or opening the report may still fail.
            ScanRunner.printAction(report, verb: "pruned", session: store.sessionID)
            await ScanRunner.recordSizes(before: sizeBefore, result: result, store: store,
                                         categories: [.strings], options: options)
            try ScanRunner.report(result.afterAction(report, acted: prunable), options)
            return
        }
        try ScanRunner.report(result, options)
        try ScanRunner.exitIfFailOn(result)
    }
}
