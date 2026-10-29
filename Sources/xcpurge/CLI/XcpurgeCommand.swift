import ArgumentParser
import Foundation
import XcpurgeKit

/// Root command: subcommands, version, and exit-code mapping (0 ok, 1 fail-on hit, 2 usage/config, 3 internal).
@main
struct XcpurgeCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "xcpurge",
        abstract: "Find unused assets, localized strings and files in Xcode projects and Swift packages.",
        version: XcpurgeVersion.current,
        subcommands: [ScanCommand.self, AssetsCommand.self, StringsCommand.self, FilesCommand.self,
                      RestoreCommand.self, ModulesCommand.self, InitCommand.self, DoctorCommand.self],
        defaultSubcommand: ScanCommand.self)

    static func main() async {
        do {
            var command = try parseAsRoot()
            if var async = command as? AsyncParsableCommand {
                try await async.run()
            } else {
                try command.run()
            }
        } catch {
            exit(withError: error)
        }
    }

    /// Maps errors onto xcpurge's exit codes before handing them to ArgumentParser for printing.
    static func exit(withError error: Error) -> Never {
        if let code = error as? ArgumentParser.ExitCode { Foundation.exit(code.rawValue) }
        if let xc = error as? XcpurgeError {
            FileHandle.standardError.write(Data("error: \(xc)\n".utf8))
            Foundation.exit(XcpurgeExit.usage.rawValue)
        }
        let code = exitCode(for: error)
        if code == .success { Self.exit(withError: error as Error?) }
        FileHandle.standardError.write(Data((fullMessage(for: error) + "\n").utf8))
        Foundation.exit(code == .validationFailure ? XcpurgeExit.usage.rawValue : XcpurgeExit.internalError.rawValue)
    }
}
