import ArgumentParser
import XcpurgeKit

/// `xcpurge strings`: unused and stale localized strings; `--prune` removes them (backed up to the trash).
struct StringsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "strings", abstract: "Report unused localized strings; optionally prune them.")

    @OptionGroup var options: CommonOptions
    @Flag(help: "Remove reported keys from string catalogs and .strings files (backups in .xcpurge-trash).") var prune = false
    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.") var yes = false

    func run() async throws {
        let result = try await ScanRunner.scan(options, categories: [.strings])
        ScanRunner.report(result)
        if prune {
            let prunable = result.findings.filter { $0.category == .strings && !$0.kind.isInformational }
            guard !prunable.isEmpty,
                  ConfirmPrompt.confirm("Remove \(prunable.count) string key(s)?", assumeYes: yes) else { return }
            let store = try TrashStore.begin(root: result.context.root)
            let report = try PruneStrings(store: store).apply(prunable, context: result.context)
            ScanRunner.printAction(report, verb: "pruned", session: store.sessionID)
            return
        }
        try ScanRunner.exitIfFailOn(result)
    }
}
