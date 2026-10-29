import ArgumentParser
import XcpurgeKit

/// `xcpurge modules`: prints the module graph; `--verbose` adds per-file attribution.
struct ModulesCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "modules", abstract: "Show discovered modules, their dependencies and file attribution.")

    @OptionGroup var options: CommonOptions

    func run() async throws {
        let config = try options.makeConfig()
        let context = try await ScanEngine(root: options.rootURL, config: config).makeContext()
        print(ModulesPrinter.render(context, verbose: config.verbose), terminator: "")
    }
}
