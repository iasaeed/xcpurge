import ArgumentParser
import XcpurgeKit

/// `xcpurge files`: orphan, ghost and dead files; `--delete` moves them to the trash.
struct FilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files", abstract: "Report orphan, ghost and dead files; optionally move them to the trash.")

    @OptionGroup var options: CommonOptions
    @Flag(help: "Move reported files (high confidence unless --min-confidence is given) to .xcpurge-trash and drop their project references.")
    var delete = false
    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.") var yes = false

    func run() async throws {
        let result = try await ScanRunner.scan(options, categories: [.files])
        if delete {
            let deletable = ScanRunner.actionable(result, category: .files, options: options)
            guard !deletable.isEmpty,
                  ConfirmPrompt.confirm("Move \(deletable.count) file(s) to the trash?", details: deletable.map(ScanRunner.describe), assumeYes: yes)
            else { return try ScanRunner.report(result, options) }
            let store = try TrashStore.begin(root: result.context.root)
            let report = try Trash(store: store).apply(deletable, context: result.context)
            // The session ID goes out first: writing or opening the report may still fail.
            ScanRunner.printAction(report, verb: "trashed", session: store.sessionID)
            try ScanRunner.report(result.afterAction(report, acted: deletable), options)
            return
        }
        try ScanRunner.report(result, options)
        try ScanRunner.exitIfFailOn(result)
    }
}
