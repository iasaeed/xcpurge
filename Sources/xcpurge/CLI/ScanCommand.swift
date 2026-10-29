import ArgumentParser
import XcpurgeKit

/// `xcpurge scan`: every detector, report only.
struct ScanCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "scan", abstract: "Report unused assets, strings and files (read-only).")

    @OptionGroup var options: CommonOptions

    func run() async throws {
        let result = try await ScanRunner.scan(options, categories: Set(XcpurgeKit.Category.allCases))
        ScanRunner.report(result)
        try ScanRunner.exitIfFailOn(result)
    }
}
