import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge init`: writes starter `xcpurge.json` and `.xcpurgeignore`.
struct InitCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "init", abstract: "Write starter xcpurge.json and .xcpurgeignore files.")

    @Argument(help: "Project root.", completion: .directory) var path: String = "."
    @Flag(help: "Overwrite existing files.") var force = false

    func run() async throws {
        let root = CommonOptions.absolute(path)
        for (name, text) in [(Config.fileName, Config.template), (Ignore.fileName, Ignore.template)] {
            let url = root.appendingPathComponent(name)
            if FileManager.default.fileExists(atPath: url.path), !force {
                print("exists: \(name) (use --force to overwrite)")
                continue
            }
            try Data(text.utf8).write(to: url, options: .atomic)
            print("wrote: \(name)")
        }
    }
}
