import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge doctor`: toolchain and project-format report.
struct DoctorCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor", abstract: "Show Xcode/Swift availability and the project formats found.")

    @Argument(help: "Project root.", completion: .directory) var path: String = "."

    func run() async throws {
        let root = CommonOptions.absolute(path).resolvingSymlinksInPath()
        print("xcpurge \(XcpurgeVersion.current)")
        print("Xcode:  \(firstLines(try? ProcessRunner.run("/usr/bin/xcodebuild", ["-version"], timeout: 15), 2) ?? "not found")")
        print("Developer dir: \(firstLines(try? ProcessRunner.run("/usr/bin/xcode-select", ["-p"], timeout: 5), 1) ?? "unknown")")
        print("Swift:  \(firstLines(try? ProcessRunner.run("/usr/bin/env", ["swift", "--version"], timeout: 15), 1) ?? "not available (Package.swift read with text fallback)")")
        let walk = FileWalker().walk(root: root)
        print("Root:   \(root.path)")
        print("Workspaces: \(walk.workspaces.isEmpty ? "none" : walk.workspaces.joined(separator: ", "))")
        for proj in walk.xcodeprojs {
            let url = root.appendingPathComponent(proj)
            let pbx = url.appendingPathComponent("project.pbxproj"), xc = url.appendingPathComponent("project.xcproj")
            var parts: [String] = []
            if let text = try? String(contentsOf: pbx, encoding: .utf8) {
                let version = text.range(of: #"objectVersion = (\d+);"#, options: .regularExpression)
                    .map { String(text[$0]).filter(\.isNumber) } ?? "?"
                parts.append("pbxproj objectVersion \(version)")
            }
            if FileManager.default.fileExists(atPath: xc.path) { parts.append("project.xcproj (Xcode 27.2+ JSON)") }
            let used = ProjectLocator.preferredFormat(xcodeproj: url)?.rawValue ?? "none"
            print("Project: \(proj): \(parts.isEmpty ? "no project file" : parts.joined(separator: " + ")); using \(used)")
        }
        print("Packages: \(walk.packages.isEmpty ? "none" : walk.packages.map { $0.isEmpty ? "." : $0 }.joined(separator: ", "))")
        let names = (walk.workspaces + walk.xcodeprojs).map(RelPath.stem)
        print("DerivedData: \(DerivedDataLocator.locate(names: names, override: nil)?.path ?? "not found")")
    }

    private func firstLines(_ result: ProcessRunner.Result?, _ count: Int) -> String? {
        guard let result, result.status == 0 else { return nil }
        let lines = String(decoding: result.stdout, as: UTF8.self).split(separator: "\n").prefix(count)
        return lines.isEmpty ? nil : lines.joined(separator: ", ")
    }
}
