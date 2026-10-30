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

    /// The drawer offers a ready-to-paste `xcpurge remove <root> <path>` command for file-backed findings, with
    /// shell quoting and per-copy commands for duplicates, wired through a delegated `data-cmd` handler.
    func testTemplateHasRemoveCommandSection() {
        let html = HTMLReporter(date: Self.date).render(SyntheticResult.make(count: 50))
        XCTAssertTrue(html.contains("Remove from terminal"))
        XCTAssertTrue(html.contains("'xcpurge remove ' + shArg(D.root || '.') + ' ' + shArg(f.path)"))
        XCTAssertTrue(html.contains("const shq = s => /^[A-Za-z0-9_.\\/@%+=:,-]+$/.test(s) ? s : \"'\" + s.replace(/'/g, \"'\\\\''\") + \"'\";"))
        XCTAssertTrue(html.contains("Each command moves that copy\\'s asset set to .xcpurge-trash"))
        XCTAssertTrue(html.contains("e.target.closest('[data-cmd]')"))
        XCTAssertTrue(html.contains("const shArg = s => shq(s.startsWith('-') ? './' + s : s);"), "a leading dash is not an option")
        XCTAssertFalse(html.contains("Copy all"), "no button that removes every copy of a duplicate")
        for kind in ["unusedAsset", "unusedFont", "orphanFile", "unusedResource", "unusedInterfaceFile", "duplicate", "deadSource", "ghostReference"] {
            XCTAssertTrue(html.contains("'\(kind)'"), "\(kind) is removable")
        }
        XCTAssertFalse(html.contains("'unusedString', 'staleString'"), "string findings have no file to remove")
    }

    /// The module graph has zoom controls and a Pods toggle; the report is light-only (no theme switch).
    func testTemplateHasGraphControlsAndLightThemeOnly() {
        let html = HTMLReporter.template
        for control in [#"id="z-in""#, #"id="z-out""#, #"id="z-reset""#, #"id="z-pct""#, ">+</button>", ">−</button>",
                        ">1:1</button>", #"id="pods-graph""#, "Show Pods", "pods=1"] {
            XCTAssertTrue(html.contains(control), control)
        }
        XCTAssertTrue(html.contains("translate(") && html.contains("scale("), "graph drawn inside a transform group")
        XCTAssertFalse(html.contains("prefers-color-scheme: dark"))
        XCTAssertFalse(html.contains("data-theme"))
        XCTAssertFalse(html.contains("btn-theme"))
    }

    // MARK: - History and baseline (lane B presentation of lane A / C data)

    /// `SyntheticResult` plus git history on two thirds of the findings (dated, shallow, untracked) and a baseline
    /// report with fixed entries and a warning; the result both renders and round-trips.
    static func withHistoryAndBaseline(_ result: ScanResult) -> ScanResult {
        let authors = ["J. Appleseed", "Ada Lovelace", "Grace Hopper", "Linus T."]
        var findings = result.findings
        for i in findings.indices {
            switch i % 3 {
            case 0:
                let days = (i * 37) % 1_500
                let date = ISO8601DateFormatter().string(from: Date(timeIntervalSince1970: 1_790_000_000 - Double(days) * 86_400))
                let commit = FindingHistory.Commit(sha: String(format: "%040x", i * 2_654_435_761), date: date,
                                                   authorName: authors[i % authors.count], authorEmail: "hidden@example.com",
                                                   subject: "Commit touching \(findings[i].name ?? findings[i].path)")
                findings[i].history = FindingHistory(status: .ok, lastCommit: commit, ageDays: days,
                                                     bucket: days < 30 ? .recentlyAdded : .leftover,
                                                     deadSince: i % 9 == 0 ? FindingHistory.Commit(sha: "feedfacecafebeef0000", date: date,
                                                                                                  authorName: authors[(i + 1) % authors.count],
                                                                                                  subject: "Remove last use") : nil)
            case 1:
                findings[i].history = FindingHistory(status: i % 2 == 0 ? .shallow : .untracked,
                                                     note: i % 2 == 0 ? "n/a (shallow clone; use fetch-depth: 0)" : nil)
            default:
                break
            }
        }
        var out = ScanResult(context: result.context, findings: findings, elapsed: result.elapsed)
        out.baseline = BaselineReport(
            file: ".xcpurge-baseline.json", createdAt: "2026-06-01T12:00:00Z", ageDays: 112, toolVersion: "0.4.0",
            baselinedCount: 1_240, newCount: findings.count,
            fixed: [BaselineEntry(key: "unusedAsset|App|old_icon", kind: .unusedAsset, category: .assets, module: "App",
                                  path: "App/Resources/Assets.xcassets/old_icon.imageset", name: "old_icon"),
                    BaselineEntry(key: "deadSource|FeatureKit|FeatureKit/Sources/Gone.swift", kind: .deadSource, category: .files,
                                  module: "FeatureKit", path: "FeatureKit/Sources/Gone.swift", count: 2),
                    BaselineEntry(key: "staleIgnore|.xcpurgeignore|Legacy/**", kind: .staleIgnore, category: .ignores, module: "unknown",
                                  path: ".xcpurgeignore", name: "Legacy/**")],
            warnings: ["baseline is 112 days old; regenerate with xcpurge baseline", "configHash differs: exclude changed"])
        return out
    }

    func testTemplateHasHistoryAndBaselineHooks() {
        let html = HTMLReporter.template
        for hook in ["const CATS = ['assets', 'strings', 'files', 'duplicates', 'ignores'];", "--c-ignores:", ".bg-ignores {", ".f-ignores {",
                     #"id="baseline-card""#, #"id="b-new""#, #"id="b-base""#, #"id="b-fixed""#, #"id="b-fixed-list""#, #"id="b-warnings""#,
                     #"data-sort="age""#, #"data-sort="author""#, "key: 'hist', label: 'History'", "age: { test:", "author: { test:",
                     "bucket: { norm:", "<h4>History</h4>", "heuristic", "Dead since", "'no-hist', !HAS_HIST",
                     "const head = ['id', 'kind', 'category', 'confidence', 'module', 'name', 'path', 'line', 'sizeBytes', 'groupID', 'ageDays', 'author', 'reasons'];"] {
            XCTAssertTrue(html.contains(hook), hook)
        }
        XCTAssertFalse(html.contains("authorEmail"), "email is never read, let alone shown")
        XCTAssertFalse(html.contains("prefers-color-scheme: dark"), "light theme only")
    }

    func testRendersWithHistoryAndBaselineAndWithout() throws {
        let plain = SyntheticResult.make(count: 300)
        let rich = Self.withHistoryAndBaseline(plain)
        let html = HTMLReporter(date: Self.date).render(rich)
        XCTAssertNil(html.range(of: #"\{\{[A-Z]+\}\}"#, options: .regularExpression))
        let object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try dataBlock(html).utf8)) as? [String: Any])
        let baseline = try XCTUnwrap(object["baseline"] as? [String: Any])
        XCTAssertEqual(baseline["baselinedCount"] as? Int, 1_240)
        XCTAssertEqual((baseline["fixed"] as? [Any])?.count, 3)
        let findings = try XCTUnwrap(object["findings"] as? [[String: Any]])
        XCTAssertEqual(findings.filter { $0["history"] != nil }.count, 200)
        XCTAssertTrue(findings.allSatisfy { $0["id"] is String })
        XCTAssertTrue(html.contains("hidden@example.com"), "the JSON carries the email when --git-emails was used...")
        let bytes = html.utf8.count
        XCTAssertLessThan(bytes, 2_000_000)

        // Without history or baseline the same template renders too, and the data block has neither.
        let bare = HTMLReporter(date: Self.date).render(plain)
        let bareObject = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(try dataBlock(bare).utf8)) as? [String: Any])
        XCTAssertNil(bareObject["baseline"])
        XCTAssertFalse(try dataBlock(bare).contains("\"history\""))
    }

    /// Headless Chrome: the baseline card and the Age/Author columns appear only with that data; the drawer's
    /// History section labels heuristics and never prints the email; the `ignores` category gets its own colour class.
    func testBaselineCardAndHistoryColumnsInDOM() throws {
        let rich = Self.withHistoryAndBaseline(SyntheticResult.make(count: 120))
        let dom = try dumpDOM(HTMLReporter(date: Self.date).render(rich))
        XCTAssertTrue(dom.contains(#"id="js-errors" hidden"#), "no JS errors")
        XCTAssertTrue(dom.contains(#"<section class="card" id="baseline-card" aria-labelledby="h-baseline">"#), "card shown")
        XCTAssertTrue(dom.contains(#"<dd id="b-base">1,240</dd>"#), dom.contains("b-base") ? "count filled" : "card missing")
        XCTAssertTrue(dom.contains(#"<dd id="b-fixed" class="warn" title="Regenerate the baseline with xcpurge baseline">3</dd>"#))
        XCTAssertTrue(dom.contains("baseline is 112 days old"))
        XCTAssertTrue(dom.contains("3 fixed entries (no longer found; regenerate with xcpurge baseline)"))
        XCTAssertTrue(dom.contains("<code>old_icon</code>"))
        XCTAssertTrue(dom.contains(#"class="dot bg-ignores""#), "ignores category colour")
        XCTAssertFalse(dom.contains(#"<body class="no-hist">"#), "history columns visible")
        XCTAssertTrue(dom.contains(#"<fieldset class="facet"><h3>History</h3>"#), "History facet")
        XCTAssertTrue(dom.contains("recently added") && dom.contains("leftover") && dom.contains("shallow"))
        XCTAssertNotNil(dom.range(of: #"<td class="num c-hist" title="[^"]*">\d+(d|mo|y)</td><td class="author c-hist" title="[^"]*">[^<]+</td>"#,
                                  options: .regularExpression), "age and author cells")
        XCTAssertTrue(dom.contains(#"<td class="num c-hist" title="n/a (shallow clone; use fetch-depth: 0)"><span class="muted">n/a</span></td>"#))
        XCTAssertFalse(try slice(dom, from: #"<tbody id="rows">"#, to: "</tbody>").contains("hidden@example.com"), "no email in rows")
        XCTAssertTrue(dom.contains(#"colspan="9""#) || !dom.contains("spacer"), "spacers span the extra columns")

        let bare = try dumpDOM(HTMLReporter(date: Self.date).render(SyntheticResult.make(count: 120)))
        XCTAssertTrue(bare.contains(#"id="js-errors" hidden"#))
        XCTAssertTrue(bare.contains(#"<body class="no-hist">"#))
        XCTAssertTrue(bare.contains(#"id="baseline-card" aria-labelledby="h-baseline" hidden"#), "card hidden without a baseline")
        XCTAssertFalse(bare.contains("<h3>History</h3>"), "no History facet without history")
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

    /// Review 2 #5: after `--delete` the undo command is printed before the report is written, so a failing
    /// `--output` still tells the user how to restore.
    func testCLIPrintsSessionBeforeWritingTheReport() throws {
        let root = try FixtureSupport.copyToTemp("AssetsEdgeCases")
        let run = try runCLI(["assets", root.path, "--delete", "--yes", "--no-swift", "--format", "html",
                              "--output", "/dev/null/report.html"])
        XCTAssertNotEqual(run.status, 0, "the report could not be written")
        XCTAssertTrue(run.stderr.contains("Undo with: xcpurge restore --session"), run.stderr)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("Edge/Images/loose_unused.png").path))
        XCTAssertFalse(try TrashStore.sessions(root: root).isEmpty)
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
        let rich = HTMLReporter(date: Self.date).render(Self.withHistoryAndBaseline(SyntheticResult.make(count: 3_000)))
        try Data(rich.utf8).write(to: out.appendingPathComponent("synthetic-history-baseline.html"))
        for path in (env["XCPURGE_CORPUS_JSON"] ?? "").split(separator: ":").map(String.init) {
            let json = try String(contentsOfFile: path, encoding: .utf8)
            let name = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
            try Data(HTMLReporter.render(json: json, scannedFiles: nil, date: Self.date).utf8)
                .write(to: out.appendingPathComponent("\(name).html"))
        }
    }

    // MARK: - Browser

    /// Runs headless Chrome on `html` and returns the DOM after scripts ran; skips when Chrome is missing.
    private func dumpDOM(_ html: String, fragment: String? = nil) throws -> String {
        let chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
        guard FileManager.default.isExecutableFile(atPath: chrome) else { throw XCTSkip("Google Chrome not installed") }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("xcpurge-dom-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let file = dir.appendingPathComponent("report.html")
        try Data(html.utf8).write(to: file)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: chrome)
        process.arguments = ["--headless=new", "--disable-gpu", "--no-first-run", "--no-default-browser-check",
                             "--user-data-dir=\(dir.appendingPathComponent("profile").path)",
                             "--virtual-time-budget=2000", "--dump-dom", file.absoluteString + (fragment.map { "#" + $0 } ?? "")]
        let out = Pipe()
        process.standardOutput = out
        process.standardError = Pipe()
        try process.run()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// Review 2 #3: a module graph without a leaf (App embeds Ext, Ext depends on App) still renders the report.
    func testCyclicModuleGraphStillRendersRows() throws {
        let json = """
        {"schemaVersion":1,"tool":{"name":"xcpurge","version":"0"},"root":"/tmp/cyclic","modules":[
         {"id":{"container":"A.xcodeproj","name":"App"},"kind":"app","dependsOn":[{"container":"A.xcodeproj","name":"Ext"}],
          "embeds":[{"container":"A.xcodeproj","name":"Ext"}]},
         {"id":{"container":"A.xcodeproj","name":"Ext"},"kind":"appExtension","dependsOn":[{"container":"A.xcodeproj","name":"App"}],"embeds":[]}],
         "summary":{"count":1,"bytes":10,"byKind":{"unusedAsset":1}},
         "findings":[{"kind":"unusedAsset","category":"assets","path":"A/x.png","name":"cyclic_marker","module":"App",
          "confidence":"high","reasons":["r"],"sizeBytes":10}],"diagnostics":[]}
        """
        let dom = try dumpDOM(HTMLReporter.render(json: json, scannedFiles: 1, date: Self.date))
        XCTAssertTrue(dom.contains("data-r=\"0\""), "finding rows rendered")
        XCTAssertTrue(dom.contains("cyclic_marker"))
    }

    /// Schema 2 reports carry `size`, shown in the Size card; a schema 1 document hides the card.
    func testSizeCardRendersAndToleratesItsAbsence() async throws {
        var config = Config()
        config.noSwift = true
        let result = try await ScanEngine(root: FixtureSupport.fixtureURL("ModularWorkspace"), config: config).run()
        let json = JSONReporter().render(result)
        let doc = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        let size = try XCTUnwrap(doc["size"] as? [String: Any])
        XCTAssertNotNil((size["tree"] as? [String: Any])?["categories"])
        XCTAssertNil((size["tree"] as? [String: Any])?["assetTypes"], "the report's size object reads no files")
        let dom = try dumpDOM(HTMLReporter.render(json: json, scannedFiles: 1, date: Self.date))
        XCTAssertTrue(dom.contains("<section class=\"card\" id=\"size-card\" aria-labelledby=\"h-size\">"), "card shown")
        XCTAssertFalse(dom.contains("id=\"z-res\">–<"), "resources filled in")
        XCTAssertFalse(dom.contains("id=\"loading\""), "loading placeholder removed after render")
        let v1 = try dumpDOM(HTMLReporter.render(json: #"{"schemaVersion":1,"findings":[]}"#, scannedFiles: nil, date: Self.date))
        XCTAssertTrue(v1.contains("id=\"size-card\" aria-labelledby=\"h-size\" hidden"), "card hidden without size")
    }

    /// The part of `dom` from the first `start` marker to the next `end` marker after it.
    private func slice(_ dom: String, from start: String, to end: String) throws -> String {
        let a = try XCTUnwrap(dom.range(of: start), start)
        let b = try XCTUnwrap(dom.range(of: end, range: a.upperBound..<dom.endIndex), end)
        return String(dom[a.lowerBound..<b.lowerBound])
    }

    /// CocoaPods modules and their findings are hidden until "Show Pods" (`#pods=1`) is on.
    func testPodModulesHiddenByDefaultAndShownWithHash() throws {
        let json = """
        {"schemaVersion":1,"tool":{"name":"xcpurge","version":"0"},"root":"/tmp/pods","modules":[
         {"id":{"container":"App.xcodeproj","name":"App"},"kind":"app","dependsOn":[{"container":"Pods/Pods.xcodeproj","name":"PodKit"}],"embeds":[]},
         {"id":{"container":"Pods/Pods.xcodeproj","name":"PodKit"},"kind":"framework","dependsOn":[],"embeds":[]}],
         "summary":{"count":2,"bytes":20,"byKind":{"unusedAsset":2}},
         "findings":[{"kind":"unusedAsset","category":"assets","path":"App/a.png","name":"app_marker","module":"App",
          "confidence":"high","reasons":["r"],"sizeBytes":10},
          {"kind":"unusedAsset","category":"assets","path":"Pods/PodKit/p.png","name":"pod_marker","module":"PodKit",
          "confidence":"high","reasons":["r"],"sizeBytes":10}],"diagnostics":[]}
        """
        let html = HTMLReporter.render(json: json, scannedFiles: 2, date: Self.date)
        let hidden = try dumpDOM(html)
        XCTAssertTrue(hidden.contains(#"id="js-errors" hidden"#), "no JS errors")
        let rows = try slice(hidden, from: #"<tbody id="rows">"#, to: "</tbody>")
        XCTAssertTrue(rows.contains("app_marker"))
        XCTAssertFalse(rows.contains("pod_marker"), "Pod findings hidden by default")
        let graph = try slice(hidden, from: #"<div id="graph""#, to: "</section>")
        XCTAssertTrue(graph.contains("aria-label=\"App, app"))
        XCTAssertFalse(graph.contains("PodKit"), "Pod node and its edges hidden")
        XCTAssertTrue(hidden.contains(#"<label class="opt" id="pods-graph-opt"><input"#), "toggle shown when Pods exist")
        XCTAssertTrue(hidden.contains("<b>1</b> of 2"))

        let shown = try dumpDOM(html, fragment: "pods=1")
        XCTAssertTrue(shown.contains(#"id="js-errors" hidden"#), "no JS errors")
        XCTAssertTrue(try slice(shown, from: #"<tbody id="rows">"#, to: "</tbody>").contains("pod_marker"), "#pods=1 shows them")
        XCTAssertTrue(try slice(shown, from: #"<div id="graph""#, to: "</section>").contains("aria-label=\"PodKit, framework"))
        XCTAssertTrue(shown.contains("<b>2</b> of 2"))
    }

    /// The real module graph renders inside one zoomable transform group, with its controls; no Pods there, so no toggle.
    func testModuleGraphHasZoomGroupAndControls() async throws {
        var config = Config()
        config.noSwift = true
        let result = try await ScanEngine(root: FixtureSupport.fixtureURL("ModularWorkspace"), config: config).run()
        let dom = try dumpDOM(HTMLReporter(date: Self.date).render(result))
        XCTAssertTrue(dom.contains(#"id="js-errors" hidden"#), "no JS errors")
        let graph = try slice(dom, from: #"<div id="graph""#, to: "</section>")
        XCTAssertNotNil(graph.range(of: #"<g class="vp" transform="translate\([-0-9.]+,[-0-9.]+\) scale\([0-9.]+\)">"#,
                                    options: .regularExpression), "transform group")
        XCTAssertTrue(graph.contains("class=\"node"), "nodes inside the graph")
        XCTAssertTrue(dom.contains(#"<div class="gctl" id="gctl" role="group" aria-label="Graph zoom">"#), "controls visible")
        for id in ["z-in", "z-out", "z-reset"] { XCTAssertTrue(dom.contains("id=\"\(id)\""), id) }
        XCTAssertNotNil(dom.range(of: #"id="z-pct"[^>]*>\d+%<"#, options: .regularExpression), "zoom percentage shown")
        XCTAssertTrue(dom.contains(#"id="pods-graph-opt" hidden"#), "no Pods, no toggle")
    }
}
