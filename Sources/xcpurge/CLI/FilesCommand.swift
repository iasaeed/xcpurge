import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge files`: orphan, ghost and dead files; `--delete` moves them to the trash.
struct FilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files", abstract: "Report orphan, ghost and dead files; optionally move them to the trash.")

    @OptionGroup var options: CommonOptions
    @Flag(help: "Move reported files (high confidence unless --min-confidence is given) to .xcpurge-trash and drop their project references.")
    var delete = false
    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.") var yes = false
    @OptionGroup var verifyOptions: VerifyOptions

    func validate() throws {
        if verifyOptions.enabled, !delete { throw ValidationError("--verify needs --delete") }
    }

    func run() async throws {
        let result = try await ScanRunner.scan(options, categories: [.files])
        if delete {
            let deletable = VerifyStep.dropBlocked(ScanRunner.actionable(result, category: .files, options: options),
                                                   root: result.context.root)
            let answer = deletable.isEmpty ? ConfirmPrompt.Answer.no
                : ConfirmPrompt.confirm("Move \(deletable.count) file(s) to the trash?", details: deletable.map(ScanRunner.describe), assumeYes: yes)
            guard answer == .yes else {
                try ScanRunner.report(result, options)
                return try answer.exitIfNotATerminal()
            }
            try VerifyStep.preflight(verifyOptions, root: result.context.root, quiet: options.quiet)
            let sizeBefore = SizeMeasurer.snapshot(result, categories: [.files])
            let store = try TrashStore.begin(root: result.context.root)
            var report = try Trash(store: store).apply(deletable, context: result.context)
            report = try VerifyStep.verify(verifyOptions, store: store, context: result.context, action: report, quiet: options.quiet)
            // The session ID goes out first: writing or opening the report may still fail.
            ScanRunner.printAction(report, verb: "trashed", session: store.sessionID)
            await ScanRunner.recordSizes(before: sizeBefore, result: result, store: store,
                                         categories: [.files], options: options)
            try ScanRunner.report(result.afterAction(report, acted: deletable), options)
            return
        }
        try ScanRunner.report(result, options)
        try ScanRunner.exitIfFailOn(result)
    }
}
