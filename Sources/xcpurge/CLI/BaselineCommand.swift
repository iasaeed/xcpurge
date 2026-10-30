// LANE: A
import ArgumentParser
import XcpurgeKit

/// `xcpurge baseline`: writes the current findings to a baseline file that `--baseline` later hides.
struct BaselineCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "baseline",
        abstract: "Write the current findings to a baseline file (default <root>/.xcpurge-baseline.json).")

    @OptionGroup var options: CommonOptions

    func run() async throws {
        throw ValidationError("not implemented in this build")
    }
}
