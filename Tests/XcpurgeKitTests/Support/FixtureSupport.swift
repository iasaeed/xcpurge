import Foundation
import XCTest
@testable import XcpurgeKit

/// Locates fixtures (via `#filePath`), copies them for mutating tests, and compares findings with goldens.
enum FixtureSupport {
    static let fixturesURL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Fixtures")

    static func fixtureURL(_ name: String) -> URL { fixturesURL.appendingPathComponent(name) }

    /// Copies a fixture into a fresh temporary directory and returns the copy's URL.
    static func copyToTemp(_ name: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcpurge-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let copy = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: fixtureURL(name), to: copy)
        return copy.resolvingSymlinksInPath()
    }

    /// Empty temporary directory, populated by `files` (relative path -> contents).
    static func tempTree(_ files: [String: String]) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("xcpurge-tests-\(UUID().uuidString)").resolvingSymlinksInPath()
        for (path, text) in files {
            let url = dir.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(text.utf8).write(to: url)
        }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    static func context(_ name: String, config: Config = Config()) async throws -> ScanContext {
        try await ScanEngine(root: fixtureURL(name), config: config).makeContext()
    }

    /// One comparable row of a golden file.
    struct Row: Codable, Hashable, Comparable, CustomStringConvertible {
        var kind: String
        var module: String
        var name: String
        var confidence: String

        init(_ f: Finding) {
            kind = f.kind.rawValue
            module = f.module
            name = f.name ?? f.path
            confidence = f.confidence.rawValue
        }

        static func < (a: Row, b: Row) -> Bool {
            (a.kind, a.module, a.name, a.confidence) < (b.kind, b.module, b.name, b.confidence)
        }

        var description: String { "\(kind) \(module) \(name) \(confidence)" }
    }
}

/// Runs the scan for one category on a fixture and compares (kind, module, name ?? path, confidence) with
/// `<fixture>/expected-<category>.json`. `XCPURGE_UPDATE_EXPECTED=1` rewrites the golden instead.
func assertFindings(fixture: String, category: XcpurgeKit.Category, config: Config = Config(),
                    file: StaticString = #filePath, line: UInt = #line) async throws {
    let result = try await ScanEngine(root: FixtureSupport.fixtureURL(fixture), config: config).run(categories: [category])
    let actual = Set(result.findings.map(FixtureSupport.Row.init)).sorted()
    let golden = FixtureSupport.fixtureURL(fixture).appendingPathComponent("expected-\(category.rawValue).json")
    if ProcessInfo.processInfo.environment["XCPURGE_UPDATE_EXPECTED"] == "1" {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try (encoder.encode(actual) + Data("\n".utf8)).write(to: golden)
        return
    }
    guard let data = FileManager.default.contents(atPath: golden.path) else {
        XCTFail("missing golden \(golden.path); run with XCPURGE_UPDATE_EXPECTED=1", file: file, line: line)
        return
    }
    let expected = Set(try JSONDecoder().decode([FixtureSupport.Row].self, from: data))
    let missing = expected.subtracting(actual).sorted(), extra = Set(actual).subtracting(expected).sorted()
    XCTAssertTrue(missing.isEmpty && extra.isEmpty,
                  "findings differ from \(golden.lastPathComponent)\n  missing: \(missing)\n  unexpected: \(extra)",
                  file: file, line: line)
}
