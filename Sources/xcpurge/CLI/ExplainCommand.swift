// LANE: D
import ArgumentParser
import XcpurgeKit

/// `xcpurge explain <root> <subject>`: why a finding (by id, path or name) is reported, suppressed or not reported.
struct ExplainCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "explain",
        abstract: "Explain one finding: who could see it, where it is referenced, and how its confidence was derived.")

    @OptionGroup var options: CommonOptions
    @Argument(help: "A finding id (unused-asset-3f9c0a12bd), a root-relative path, or a name.") var subject: String

    func run() async throws {
        throw ValidationError("not implemented in this build")
    }
}
