import Foundation
import XCTest
@testable import XcpurgeKit

/// HTML report: embedded JSON round-trips, script-safe escaping, filled placeholders, size, and the CLI path.
final class HTMLReporterTests: XCTestCase {
    private static let date = Date(timeIntervalSince1970: 1_790_000_000)
    private static let dataOpen = "<script id=\"xcpurge-data\" type=\"application/json\">"

    private func dataBlock(_ html: String) throws -> String {
        let start = try XCTUnwrap(html.range(of: Self.dataOpen), "data block present")
        let end = try XCTUnwrap(html.range(of: "</script>", range: start.upperBound..<html.endIndex))
        return String(html[start.upperBound..<end.lowerBound])
    }

    func testEmbeddedJSONRoundTrips() throws {
        let result = SyntheticResult.make()
        let html = HTMLReporter(date: Self.date).render(result)
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try dataBlock(html).utf8)) as? [String: Any])
        let findings = try XCTUnwrap(object["findings"] as? [[String: Any]])
        XCTAssertEqual(findings.count, 3_000)
        XCTAssertEqual(findings.count, result.findings.count)
        XCTAssertTrue(findings.contains { $0["name"] as? String == SyntheticResult.hostileName }, "hostile name decodes unchanged")
        XCTAssertEqual((object["modules"] as? [Any])?.count, 6)
        XCTAssertEqual(Set(findings.compactMap { $0["kind"] as? String }), Set(FindingKind.allCases.map(\.rawValue)))
    }

    func testDataBlockHasNoScriptTerminators() throws {
        let block = try dataBlock(HTMLReporter(date: Self.date).render(SyntheticResult.make()))
        XCTAssertFalse(block.lowercased().contains("</script"))
        XCTAssertFalse(block.contains("<!--"))
        XCTAssertTrue(block.contains("<\\/script>"), "escaped form present")
    }

    func testPlaceholdersReplacedAndEscaped() throws {
        let html = HTMLReporter(date: Self.date).render(SyntheticResult.make(count: 50))
        XCTAssertNil(html.range(of: #"\{\{[A-Z]+\}\}"#, options: .regularExpression), "no unfilled placeholder")
        XCTAssertTrue(html.contains("Acme &lt;iOS&gt; &amp; &quot;Co&quot;"), "root HTML-escaped")
        XCTAssertTrue(html.contains("<title>xcpurge report · "))
        XCTAssertTrue(html.contains(">\(XcpurgeVersion.current)<"))
        XCTAssertTrue(html.contains("datetime=\"2026-09-21T"), "ISO date filled")
        XCTAssertTrue(html.contains("<dd id=\"s-files\">4812</dd>"))
        XCTAssertFalse(html.contains("http://") || html.contains("https://"), "no network references")
    }

    func testSizeBudget() {
        let bytes = HTMLReporter(date: Self.date).render(SyntheticResult.make()).utf8.count
        XCTAssertLessThan(bytes, 2_000_000, "3,000 findings render to \(bytes) bytes")
    }

    func testRenderFromJSONMatchesRenderFromResult() {
        let result = SyntheticResult.make(count: 200)
        let direct = HTMLReporter(date: Self.date).render(result)
        let fromJSON = HTMLReporter.render(json: JSONReporter().render(result), scannedFiles: 4_812, date: Self.date)
        XCTAssertEqual(direct, fromJSON)
        XCTAssertFalse(HTMLReporter.render(json: "{}", scannedFiles: nil, date: Self.date).contains("{{"))
    }

    func testOpenerArguments() {
        let file = URL(fileURLWithPath: "/tmp/r.html")
        XCTAssertEqual(ReportOpener.arguments(file: file, browser: nil), ["/tmp/r.html"])
        XCTAssertEqual(ReportOpener.arguments(file: file, browser: "Google Chrome"), ["-a", "Google Chrome", "/tmp/r.html"])
        XCTAssertEqual(OutputFormat(rawValue: "html"), .html)
    }

    // MARK: - CLI

    private static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    private func runCLI(_ args: [String]) throws -> (status: Int32, stderr: String) {
        let binary = Self.packageRoot.appendingPathComponent(".build/debug/xcpurge")
        guard FileManager.default.isExecutableFile(atPath: binary.path) else {
            throw XCTSkip("\(binary.path) not built; run `swift build` first")
        }
        let process = Process()
        process.executableURL = binary
        process.arguments = args
        let err = Pipe()
        process.standardError = err
        process.standardOutput = Pipe()
        try process.run()
        let data = err.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self))
    }

    func testCLIWritesHTMLToOutput() throws {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("xcpurge-\(UUID().uuidString)/report.html")
        let fixture = FixtureSupport.fixtureURL("SyncedApp").path
        let run = try runCLI(["scan", fixture, "--format", "html", "--output", out.path, "--no-swift"])
        XCTAssertEqual(run.status, 0, run.stderr)
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(html.contains(Self.dataOpen))
        XCTAssertTrue(run.stderr.contains(out.path))
    }

    func testCLIDefaultsToDotXcpurgeFolder() throws {
        let root = try FixtureSupport.copyToTemp("SyncedApp")
        let run = try runCLI(["assets", root.path, "--format", "html", "--no-swift"])
        XCTAssertEqual(run.status, 0, run.stderr)
        let dir = root.appendingPathComponent(".xcpurge")
        let files = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        XCTAssertEqual(files.count, 1)
        let name = try XCTUnwrap(files.first)
        XCTAssertNotNil(name.range(of: #"^report-\d{8}-\d{6}\.html$"#, options: .regularExpression), name)
        XCTAssertTrue(run.stderr.contains(dir.appendingPathComponent(name).path))
    }

    /// Writes reports for visual checks when `XCPURGE_HTML_OUT` is set (plus `XCPURGE_CORPUS_JSON`, `:`-separated).
    func testWriteVerificationReports() throws {
        let env = ProcessInfo.processInfo.environment
        guard let dir = env["XCPURGE_HTML_OUT"] else { throw XCTSkip("set XCPURGE_HTML_OUT to write sample reports") }
        let out = URL(fileURLWithPath: dir)
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for count in [3_000, 10_000] {
            let html = HTMLReporter(date: Self.date).render(SyntheticResult.make(count: count))
            try Data(html.utf8).write(to: out.appendingPathComponent("synthetic-\(count).html"))
        }
        for path in (env["XCPURGE_CORPUS_JSON"] ?? "").split(separator: ":").map(String.init) {
            let json = try String(contentsOfFile: path, encoding: .utf8)
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            try Data(HTMLReporter.render(json: json, scannedFiles: nil, date: Self.date).utf8)
                .write(to: out.appendingPathComponent("\(name).html"))
        }
    }
}
