import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge assets`: unused and duplicate assets; `--delete` moves unused ones to the trash.
struct AssetsCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "assets", abstract: "Report unused and duplicate assets; optionally move them to the trash.")

    @OptionGroup var options: CommonOptions
    @Flag(help: "Move reported unused assets (high confidence unless --min-confidence is given) to .xcpurge-trash (undo with `xcpurge restore`).")
    var delete = false
    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.") var yes = false
    @OptionGroup var verifyOptions: VerifyOptions

    func validate() throws {
        if verifyOptions.enabled, !delete { throw ValidationError("--verify needs --delete") }
    }

    func run() async throws {
        let result = try await ScanRunner.scan(options, categories: [.assets, .duplicates])
        if delete {
            let deletable = VerifyStep.dropBlocked(ScanRunner.actionable(result, category: .assets, options: options),
                                                   root: result.context.root)
            let bytes = deletable.compactMap(\.sizeBytes).reduce(0, +)
            guard !deletable.isEmpty,
                  ConfirmPrompt.confirm("Move \(deletable.count) asset(s) (\(bytes) bytes) to \(TrashStore.directoryName)?",
                                        details: deletable.map(ScanRunner.describe), assumeYes: yes)
            else { return try ScanRunner.report(result, options) }
            try VerifyStep.preflight(verifyOptions, root: result.context.root, quiet: options.quiet)
            let sizeBefore = SizeMeasurer.snapshot(result, categories: [.assets, .duplicates])
            let store = try TrashStore.begin(root: result.context.root)
            var report = try Trash(store: store).apply(deletable, context: result.context)
            report = try VerifyStep.verify(verifyOptions, store: store, context: result.context, action: report, quiet: options.quiet)
            // The session ID goes out first: writing or opening the report may still fail.
            ScanRunner.printAction(report, verb: "trashed", session: store.sessionID)
            await ScanRunner.recordSizes(before: sizeBefore, result: result, store: store,
                                         categories: [.assets, .duplicates], options: options)
            try ScanRunner.report(result.afterAction(report, acted: deletable), options)
            return
        }
        try ScanRunner.report(result, options)
        try ScanRunner.exitIfFailOn(result)
    }
}
