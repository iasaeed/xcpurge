import ArgumentParser
import Foundation
import XcpurgeKit

/// Options shared by the scanning commands; turns flags plus `xcpurge.json` into a `Config`.
struct CommonOptions: ParsableArguments {
    @Argument(help: "Project root to scan.", completion: .directory)
    var path: String = "."

    @Option(help: "Scan only this .xcodeproj.") var project: String?
    @Option(help: "Scan the projects and packages of this .xcworkspace.") var workspace: String?
    @Option(help: "Scan only this Swift package (directory or Package.swift).") var package: String?
    @Option(parsing: .upToNextOption, help: "Only report findings in these modules.") var targets: [String] = []
    @Option(help: "Output format: text, json, xcode, github, html.") var format: OutputFormat?
    @Option(help: "Write the report to this file (html default: <path>/.xcpurge/report-<timestamp>.html).", completion: .file())
    var output: String?
    @Flag(name: .customLong("open"), help: "Open the HTML report when written.") var openReport = false
    @Option(help: "Application for --open (e.g. \"Google Chrome\"); default browser otherwise.") var browser: String?
    @Option(parsing: .upToNextOption, help: "Exit 1 when findings match: any, assets, strings, files, duplicates, unused-<category>, or a kind (dead-source).")
    var failOn: [String] = []
    @Option(help: "Hide findings below this confidence: low, medium, high.") var minConfidence: Confidence?
    @Option(parsing: .singleValue, help: "Glob of paths to skip (repeatable).") var exclude: [String] = []
    @Option(help: "Config file (default: <path>/xcpurge.json).") var config: String?
    @Option(help: "DerivedData folder to read generated asset symbols from.") var derivedData: String?
    @Option(parsing: .singleValue, help: "Extra localization function name (repeatable).") var localizationMacro: [String] = []
    @Flag(help: "Scan Pods/ too.") var includePods = false
    @Flag(help: "Do not count references from test targets.") var ignoreTestReferences = false
    @Flag(help: "Keep public declarations of libraries (dead-source).") var retainPublic = false
    @Flag(help: "Do not run swift to read Package.swift (text fallback).") var noSwift = false
    @Flag(name: .shortAndLong, help: "More detail (reasons, info diagnostics, per-file attribution).") var verbose = false

    var rootURL: URL { Self.absolute(path) }

    static func absolute(_ p: String) -> URL {
        let expanded = NSString(string: p).expandingTildeInPath
        return URL(fileURLWithPath: expanded, relativeTo: URL(fileURLWithPath: FileManager.default.currentDirectoryPath))
            .standardizedFileURL
    }

    /// `xcpurge.json` (or `--config`), overridden by flags that were given.
    func makeConfig() throws -> Config {
        let configURL = config.map(Self.absolute) ?? rootURL.appendingPathComponent(Config.fileName)
        if config != nil, !FileManager.default.fileExists(atPath: configURL.path) {
            throw XcpurgeError.notFound(configURL.path)
        }
        var c: Config
        do { c = try Config.load(from: configURL) } catch {
            throw XcpurgeError.invalidConfig("\(configURL.path): \(error)")
        }
        if let project { c.project = Self.absolute(project).path }
        if let workspace { c.workspace = Self.absolute(workspace).path }
        if let package { c.package = Self.absolute(package).path }
        if !targets.isEmpty { c.targets = targets.flatMap { $0.split(separator: ",").map(String.init) } }
        if let format { c.format = format.rawValue }
        if !failOn.isEmpty { c.failOn = failOn.flatMap { $0.split(separator: ",").map(String.init) } }
        if let minConfidence { c.minConfidence = minConfidence }
        c.exclude += exclude
        if let derivedData { c.derivedData = Self.absolute(derivedData).path }
        c.localizationMacros += localizationMacro
        c.includePods = c.includePods || includePods
        c.ignoreTestReferences = c.ignoreTestReferences || ignoreTestReferences
        c.retainPublic = c.retainPublic || retainPublic
        c.noSwift = c.noSwift || noSwift
        c.verbose = c.verbose || verbose
        if let f = c.format, OutputFormat(rawValue: f) == nil { throw XcpurgeError.invalidConfig("unknown format \(f)") }
        try FailOn.validate(c.failOn)
        return c
    }
}

extension OutputFormat: ExpressibleByArgument {}
extension Confidence: ExpressibleByArgument {}
