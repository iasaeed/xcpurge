import ArgumentParser
import XcpurgeKit

/// `xcpurge files`: orphan, ghost and dead files; `--delete` moves them to the trash.
struct FilesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "files", abstract: "Report orphan, ghost and dead files; optionally move them to the trash.")

    @OptionGroup var options: CommonOptions
    @Flag(help: "Move reported files to .xcpurge-trash and drop their project references.") var delete = false
    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.") var yes = false

    func run() async throws {
        let result = try await ScanRunner.scan(options, categories: [.files])
        ScanRunner.report(result)
        if delete {
            let deletable = result.findings.filter { !$0.kind.isInformational }
            guard !deletable.isEmpty,
                  ConfirmPrompt.confirm("Move \(deletable.count) file(s) to the trash?", assumeYes: yes) else { return }
            let store = try TrashStore.begin(root: result.context.root)
            let report = try Trash(store: store).apply(deletable, context: result.context)
            ScanRunner.printAction(report, verb: "trashed", session: store.sessionID)
            return
        }
        try ScanRunner.exitIfFailOn(result)
    }
}
