import Foundation
import XCTest
@testable import XcpurgeKit

/// Scan progress: engine phase order, the terminal renderer, the summary line, and that progress never
/// reaches stdout.
final class ProgressTests: XCTestCase {
    private final class Recorder: ProgressSink, @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [ScanProgress] = []
        var events: [ScanProgress] { lock.withLock { stored } }
        func report(_ event: ScanProgress) { lock.withLock { stored.append(event) } }
    }

    private final class Buffer: @unchecked Sendable {
        private let lock = NSLock()
        private var stored = ""
        var text: String { lock.withLock { stored } }
        func append(_ s: String) { lock.withLock { stored += s } }
    }

    private static var noSwift: Config {
        var c = Config()
        c.noSwift = true
        return c
    }

    func testEngineReportsPhasesInOrder() async throws {
        let recorder = Recorder()
        let result = try await ScanEngine(root: FixtureSupport.fixtureURL("ModularWorkspace"), config: Self.noSwift,
                                          progress: recorder).run()
        let events = recorder.events
        var phases: [Int] = []
        for e in events where phases.last != e.phase { phases.append(e.phase) }
        XCTAssertEqual(phases, [0, 1, 2, 3, 4, 5])
        XCTAssertEqual(events.last, .finished(ScanSummary(result)))
        XCTAssertTrue(events.contains(.walking(files: result.context.inventory.files.count)))
        let indexing = events.compactMap { e -> (Int, Int)? in if case .indexing(let d, let t) = e { (d, t) } else { nil } }
        XCTAssertEqual(indexing.first?.0, 0)
        XCTAssertEqual(indexing.map(\.0).max(), indexing.first?.1)
        guard case .detecting(let states) = events[events.count - 2] else { return XCTFail("no detector event") }
        XCTAssertEqual(states.map(\.name), ["assets", "duplicates", "strings", "files"])
        XCTAssertTrue(states.allSatisfy(\.done))
        XCTAssertGreaterThan(result.elapsed, 0)
    }

    func testSummaryLineFormat() {
        XCTAssertEqual(ScanSummary(files: 12_480, modules: 9, seconds: 2.34, high: 8, medium: 30, low: 0).line,
                       "Scanned 12,480 files in 9 modules in 2.3s — 38 findings (8 high, 30 medium, 0 low)")
        XCTAssertEqual(ScanSummary(files: 1, modules: 1, seconds: 0.04, high: 0, medium: 0, low: 0).line,
                       "Scanned 1 file in 1 module in 0.0s — No findings.")
        XCTAssertEqual(ScanSummary(files: 3, modules: 2, seconds: 65, high: 0, medium: 0, low: 1).line,
                       "Scanned 3 files in 2 modules in 1m 05s — 1 finding (0 high, 0 medium, 1 low)")
        XCTAssertEqual(ScanSummary.grouped(1_234_567), "1,234,567")
        XCTAssertEqual(ScanSummary.grouped(999), "999")
    }

    private func feed(_ sink: TerminalProgress) -> ScanSummary {
        let summary = ScanSummary(files: 12_480, modules: 9, seconds: 2.3, high: 8, medium: 30, low: 0)
        sink.report(.walking(files: 12_480))
        sink.report(.discovering(projects: 3, packages: 2))
        sink.report(.attributing(modules: 9))
        sink.report(.indexing(done: 1_204, total: 1_430))
        sink.report(.detecting([.init(name: "assets", done: true), .init(name: "files", done: false)]))
        sink.report(.finished(summary))
        return summary
    }

    func testTerminalProgressDrawsPhasesInPlaceAndLeavesTheSummary() {
        let out = Buffer()
        let summary = feed(TerminalProgress(isTTY: true, colors: false, width: 200, write: out.append))
        let text = out.text
        let labels = ["Walking files… 12,480 files", "Discovering projects… (3 projects, 2 packages)",
                      "Attributing to modules… 9 modules", "Indexing references… 1,204/1,430 files",
                      "Running detectors: assets ✓ files …"]
        var cursor = text.startIndex
        for label in labels {
            guard let r = text.range(of: "\r" + label, range: cursor..<text.endIndex) else {
                return XCTFail("missing or out of order: \(label) in \(text.debugDescription)")
            }
            cursor = r.upperBound
        }
        XCTAssertTrue(text.contains("\u{1B}[K"))
        XCTAssertFalse(text.contains("\u{1B}[2m"), "NO_COLOR-style output has no SGR styling")
        XCTAssertTrue(text.hasSuffix("\r\u{1B}[K" + summary.line + "\n"), text.debugDescription)
        XCTAssertEqual(text.components(separatedBy: "\n").count, 2, "only the summary line is persistent")
    }

    func testTerminalProgressIsSilentWithoutTTYOrWhenQuiet() {
        for (tty, quiet) in [(false, false), (true, true), (false, true)] {
            let out = Buffer()
            let sink = TerminalProgress(isTTY: tty, quiet: quiet, write: out.append)
            _ = feed(sink)
            sink.stop()
            XCTAssertEqual(out.text, "", "tty \(tty) quiet \(quiet)")
            XCTAssertFalse(sink.isActive)
        }
    }

    func testTerminalProgressWithoutSummaryOnlyClears() {
        let out = Buffer()
        _ = feed(TerminalProgress(isTTY: true, width: 30, printsSummary: false, write: out.append))
        XCTAssertTrue(out.text.hasSuffix("\r\u{1B}[K"))
        XCTAssertFalse(out.text.contains("Scanned"))
        for line in out.text.components(separatedBy: "\r") {
            XCTAssertLessThan(TerminalProgress.visibleLength(line.replacingOccurrences(of: "\u{1B}[K", with: "")), 30, line)
        }
    }

    // MARK: - CLI

    private static let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()

    /// The `xcpurge` built next to this test bundle (whatever the scratch path), else `.build/debug`.
    private static var binary: URL {
        for bundle in Bundle.allBundles where bundle.bundlePath.hasSuffix(".xctest") {
            let candidate = bundle.bundleURL.deletingLastPathComponent().appendingPathComponent("xcpurge")
            if FileManager.default.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        return packageRoot.appendingPathComponent(".build/debug/xcpurge")
    }

    /// Runs the CLI with stdout on a pipe and stderr on a pseudo-terminal (or a pipe), returning both.
    private func run(_ args: [String], stderrTTY: Bool) throws -> (status: Int32, stdout: Data, stderr: String) {
        guard FileManager.default.isExecutableFile(atPath: Self.binary.path) else {
            throw XCTSkip("\(Self.binary.path) not built; run `swift build` first")
        }
        let process = Process()
        process.executableURL = Self.binary
        process.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = "xterm-256color"
        env["NO_COLOR"] = nil
        process.environment = env
        let out = Pipe()
        process.standardOutput = out
        var master: Int32 = -1, slave: Int32 = -1
        let errPipe = Pipe()
        if stderrTTY {
            guard openpty(&master, &slave, nil, nil, nil) == 0 else { throw XCTSkip("openpty failed") }
            process.standardError = FileHandle(fileDescriptor: slave, closeOnDealloc: false)
        } else {
            process.standardError = errPipe
        }
        let errBuffer = Buffer()
        let drained = DispatchSemaphore(value: 0)
        if stderrTTY {
            DispatchQueue.global().async { [master] in
                var bytes = [UInt8](repeating: 0, count: 4096)
                var data = Data()
                while true {
                    let n = read(master, &bytes, bytes.count)
                    if n <= 0 { break }
                    data.append(contentsOf: bytes[0..<n])
                }
                errBuffer.append(String(decoding: data, as: UTF8.self))
                drained.signal()
            }
        }
        try process.run()
        if stderrTTY { close(slave) }
        let stdout = out.fileHandleForReading.readDataToEndOfFile()
        if !stderrTTY { errBuffer.append(String(decoding: errPipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)) }
        process.waitUntilExit()
        if stderrTTY {
            drained.wait()
            close(master)
        }
        return (process.terminationStatus, stdout, errBuffer.text)
    }

    /// Progress goes to stderr only: JSON on stdout is byte-identical with a terminal on stderr, without one,
    /// and under `--quiet`.
    func testProgressNeverTouchesStdout() throws {
        let fixture = FixtureSupport.fixtureURL("ModularWorkspace").path
        let args = ["scan", fixture, "--format", "json", "--no-swift"]
        let tty = try run(args, stderrTTY: true)
        let piped = try run(args, stderrTTY: false)
        let quiet = try run(args + ["--quiet"], stderrTTY: true)
        XCTAssertEqual(tty.status, 0, tty.stderr)
        XCTAssertFalse(tty.stdout.isEmpty)
        XCTAssertEqual(tty.stdout, piped.stdout)
        XCTAssertEqual(tty.stdout, quiet.stdout)
        XCTAssertTrue(tty.stderr.contains("Indexing references…"), tty.stderr.debugDescription)
        XCTAssertTrue(tty.stderr.contains("Scanned "), tty.stderr.debugDescription)
        XCTAssertEqual(piped.stderr, "", "no progress when stderr is not a terminal")
        XCTAssertEqual(quiet.stderr, "", "no progress under --quiet")
    }

    /// An html report prints its path and the summary; with no findings it says so and still writes the page.
    func testHTMLCompletionBlockWithZeroFindings() throws {
        let root = try FixtureSupport.tempTree(["notes.txt": "hi\n"])
        let out = root.appendingPathComponent("out/report.html")
        let r = try run(["scan", root.path, "--format", "html", "--output", out.path, "--no-swift"], stderrTTY: false)
        XCTAssertEqual(r.status, 0, r.stderr)
        XCTAssertTrue(r.stderr.contains("Wrote html report to \(out.path)\n"), r.stderr)
        XCTAssertTrue(r.stderr.contains("— No findings.\n"), r.stderr)
        XCTAssertTrue(r.stderr.contains("Open it with: open \"\(out.path)\""), r.stderr)
        let html = try String(contentsOf: out, encoding: .utf8)
        XCTAssertTrue(html.contains("Loading 0 findings…"))
    }

    // MARK: - Opener

    /// A `--browser` that does not exist is reported and the default browser is used instead; nothing throws.
    func testOpenerFallsBackWhenBrowserIsMissing() {
        let file = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("xcpurge-open-\(UUID().uuidString).html")
        FileManager.default.createFile(atPath: file.path, contents: Data("<p>x</p>".utf8))
        let calls = Buffer()
        // Only the named-app call runs the real `open`; it fails without launching anything. The default-browser
        // call is faked so the test opens no window.
        let outcome = ReportOpener.open(file, browser: "Xcpurge Bogus Browser 9000") { args in
            calls.append(args.joined(separator: " ") + "\n")
            return args.first == "-a" ? ReportOpener.runOpen(args) : (0, "")
        }
        guard case .fellBack(let app, let reason) = outcome else { return XCTFail("\(outcome)") }
        XCTAssertEqual(app, "Xcpurge Bogus Browser 9000")
        XCTAssertTrue(reason.contains("Unable to find application"), reason)
        XCTAssertEqual(outcome.describe(path: file.path),
                       "WARNING: Xcpurge Bogus Browser 9000 not found; opened in default browser instead")
        XCTAssertEqual(calls.text, "-a Xcpurge Bogus Browser 9000 \(file.path)\n\(file.path)\n")
    }

    func testOpenerReportsFailureWithManualCommand() {
        let file = URL(fileURLWithPath: "/tmp/r.html")
        let failed = ReportOpener.open(file, browser: nil) { _ in (1, "LSOpenURLsWithRole() failed\n") }
        XCTAssertEqual(failed, .failed(message: "LSOpenURLsWithRole() failed (open exited 1)"))
        XCTAssertEqual(failed.describe(path: file.path),
                       "WARNING: could not open the report: LSOpenURLsWithRole() failed (open exited 1)\n  Open it manually: open \"/tmp/r.html\"")
        XCTAssertEqual(ReportOpener.open(file, browser: "Safari") { _ in (0, "") }, .opened(app: "Safari"))
        XCTAssertEqual(ReportOpener.open(file, browser: nil) { _ in (0, "") }.describe(path: file.path), "Opened in default browser")
        XCTAssertEqual(ReportOpener.open(file, browser: "Google Chrome") { _ in (0, "") }.describe(path: file.path),
                       "Opened in Google Chrome")
    }

    // MARK: - Many repositories

    func testRepositorySurvey() throws {
        let folder = try FixtureSupport.tempTree([
            "a/.git/HEAD": "", "b/.git/HEAD": "", "c/C.xcodeproj/project.pbxproj": "", "d/Package.swift": "",
            "notes/readme.md": "",
        ])
        XCTAssertEqual(RepositorySurvey.independentRepositories(under: folder), 4)
        let repo = try FixtureSupport.tempTree([
            ".git/HEAD": "", "Core/Package.swift": "", "UI/Package.swift": "", "Feature/Package.swift": "",
        ])
        XCTAssertEqual(RepositorySurvey.independentRepositories(under: repo), 0, "packages of one repository")
        XCTAssertEqual(RepositorySurvey.independentRepositories(under: FixtureSupport.fixtureURL("ModularWorkspace")), 0)
    }
}
