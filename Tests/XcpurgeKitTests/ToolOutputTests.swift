import Foundation
import XCTest
@testable import XcpurgeKit

/// What xcpurge writes into a scanned tree (trash, `.xcpurge/` reports, `--output` reports, baselines) is never read
/// back as part of the project: a report names every finding and would mark all of them used on the next scan.
final class ToolOutputTests: XCTestCase {
    /// Two Swift packages, each with an unused `cardgift` image set (byte-identical PDFs).
    private func twoModules() throws -> URL {
        var files: [String: String] = [:]
        for m in ["CardsFeature", "WalletFeature"] {
            let catalog = "Features/\(m)/Sources/\(m)/Resources/\(m).xcassets"
            files["Features/\(m)/Package.swift"] = """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(name: "\(m)", targets: [.target(name: "\(m)", resources: [.process("Resources")])])
                """
            files["Features/\(m)/Sources/\(m)/\(m).swift"] = "public struct \(m)View {}\n"
            files["\(catalog)/Contents.json"] = #"{"info":{"author":"xcode","version":1}}"#
            files["\(catalog)/cardgift.imageset/Contents.json"] =
                #"{"images":[{"filename":"cardgift.pdf","idiom":"universal"}],"info":{"author":"xcode","version":1}}"#
            files["\(catalog)/cardgift.imageset/cardgift.pdf"] = "%PDF-1.4\n%%EOF\n"
        }
        return try FixtureSupport.tempTree(files)
    }

    private func set(_ module: String) -> String {
        "Features/\(module)/Sources/\(module)/Resources/\(module).xcassets/cardgift.imageset"
    }

    private func unusedAssets(_ root: URL) async throws -> [String] {
        try await ScanEngine(root: root, config: Config()).run(categories: [.assets])
            .findings.filter { $0.kind == .unusedAsset }.map(\.path).sorted()
    }

    /// The user report: removing one of two same-named unused sets must leave the other module's copy reported.
    func testTrashingOneDuplicateKeepsTheOtherModulesCopyReported() async throws {
        let root = try twoModules()
        let before = try await unusedAssets(root)
        XCTAssertEqual(before, [set("CardsFeature"), set("WalletFeature")])

        let context = try await ScanEngine(root: root, config: Config()).discover()
        let report = try Trash(store: try TrashStore.begin(root: context.root))
            .remove(paths: [set("CardsFeature") + "/cardgift.pdf"], context: context)
        XCTAssertEqual(report.moved, [set("CardsFeature")])
        XCTAssertTrue(FileManager.default.fileExists(atPath: root.appendingPathComponent(TrashStore.directoryName).path))

        let after = try await unusedAssets(root)
        XCTAssertEqual(after, [set("WalletFeature")])
    }

    /// `xcpurge scan . --output report.html` (or a JSON report / baseline saved anywhere in the tree) must not
    /// hide the findings it lists on the next scan.
    func testReportsWrittenIntoTheRootAreNotReferenceSources() async throws {
        let root = try twoModules()
        let result = try await ScanEngine(root: root, config: Config()).run()
        XCTAssertEqual(result.findings.filter { $0.kind == .unusedAsset }.count, 2)
        try Data(HTMLReporter().render(result).utf8).write(to: root.appendingPathComponent("report.html"))
        try Data(JSONReporter().render(result).utf8).write(to: root.appendingPathComponent("Features/report.json"))
        try Data(BaselineFile.make(findings: result.findings, categories: Category.scannable, config: Config(), root: root)
            .render().utf8).write(to: root.appendingPathComponent("my-baseline.json"))
        try FileManager.default.createDirectory(at: root.appendingPathComponent(ToolOutput.reportDirectoryName),
                                                withIntermediateDirectories: true)
        try Data(HTMLReporter().render(result).utf8)
            .write(to: root.appendingPathComponent(ToolOutput.reportDirectoryName + "/report-1.html"))

        let rescanned = try await unusedAssets(root)
        XCTAssertEqual(rescanned, [set("CardsFeature"), set("WalletFeature")])
        let walked = FileWalker().walk(root: root).files.map(\.path)
        XCTAssertFalse(walked.contains { $0.hasSuffix("report.html") || $0.hasSuffix("report.json") || $0 == "my-baseline.json" })
        XCTAssertFalse(walked.contains { $0.hasPrefix(ToolOutput.reportDirectoryName + "/") })
    }

    private func detected(_ root: URL, _ path: String) -> Bool {
        ToolOutput.isGeneratedReport(path: path, absolute: root.appendingPathComponent(path).path)
    }

    /// Ordinary project HTML/JSON stays a reference source; only xcpurge's own output is recognised.
    func testOnlyXcpurgeOutputIsRecognised() throws {
        let root = try FixtureSupport.tempTree([
            "web/index.html": "<!doctype html><title>Help</title><img src=\"cardgift.png\">",
            "data/config.json": #"{"tool": {"name": "swiftlint"}, "image": "cardgift"}"#,
            "data/other.json": "[\"cardgift\"]",
            "data/stats.json": #"{"measuredAt": "today", "image": "cardgift"}"#,
        ])
        for path in ["web/index.html", "data/config.json", "data/other.json", "data/stats.json"] {
            XCTAssertFalse(detected(root, path), path)
        }
    }

    /// `size --save size-base.json` at the root: a current snapshot (with `tool`), a 0.4.0 one (without), and a
    /// `--compare --format json` document all stay out of the reference index; old snapshots still load.
    func testSizeSnapshotsAreRecognised() async throws {
        let root = try twoModules()
        let result = try await ScanEngine(root: root, config: Config()).run()
        let snapshot = SizeMeasurer.snapshot(result, categories: Category.scannable, date: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(snapshot.tool?.name, XcpurgeVersion.name)
        try snapshot.write(to: root.appendingPathComponent("size-base.json"))
        XCTAssertTrue(snapshot.json().contains("cardgift"))

        // 0.4.0 wrote no `tool`: the same document with the key removed.
        var legacy = try JSONSerialization.jsonObject(with: Data(snapshot.json().utf8)) as! [String: Any]
        legacy["tool"] = nil
        let legacyData = try JSONSerialization.data(withJSONObject: legacy, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        XCTAssertFalse(String(decoding: legacyData, as: UTF8.self).contains("\"tool\""))
        try legacyData.write(to: root.appendingPathComponent("Features/size-040.json"))
        XCTAssertNil(try SizeSnapshot.load(from: root.appendingPathComponent("Features/size-040.json")).tool)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(["after": snapshot, "before": snapshot]).write(to: root.appendingPathComponent("compare.json"))

        for path in ["size-base.json", "Features/size-040.json", "compare.json"] { XCTAssertTrue(detected(root, path), path) }
        let rescanned = try await unusedAssets(root)
        XCTAssertEqual(rescanned, [set("CardsFeature"), set("WalletFeature")])
    }

    /// `explain --format json --output x.json` writes `"tool": "xcpurge <version>"` (a string, per its schema).
    func testExplainJSONIsRecognised() throws {
        let root = try FixtureSupport.tempTree([:])
        let json = Explainer.renderJSON(ExplainReport(subject: "cardgift", root: root.path, matches: []))
        XCTAssertTrue(json.contains("\"tool\" : \"\(XcpurgeVersion.name) "))
        try Data(json.utf8).write(to: root.appendingPathComponent("explain.json"))
        XCTAssertTrue(detected(root, "explain.json"))
    }

    /// A leading byte-order mark is skipped; a FIFO (or symlink) named like a report is never opened.
    func testBOMAndNonRegularFiles() async throws {
        let root = try FixtureSupport.tempTree([
            "bom.json": "\u{FEFF}{\n  \"tool\": {\"name\": \"xcpurge\", \"version\": \"0.4.0\"}\n}\n",
            "bom.html": "\u{FEFF}<!doctype html><title>xcpurge report · /r</title>",
        ])
        XCTAssertTrue(detected(root, "bom.json"))
        XCTAssertTrue(detected(root, "bom.html"))
        let fifo = root.appendingPathComponent("pipe.json").path
        XCTAssertEqual(mkfifo(fifo, 0o600), 0)
        XCTAssertFalse(detected(root, "pipe.json"))   // would block forever if opened
        try FileManager.default.createSymbolicLink(atPath: root.appendingPathComponent("link.json").path,
                                                   withDestinationPath: root.appendingPathComponent("bom.json").path)
        XCTAssertFalse(detected(root, "link.json"))
        // The stale-ignore disk walk takes the same path past the FIFO (a full scan would hang otherwise).
        try Data("pipe.json\n".utf8).write(to: root.appendingPathComponent(Ignore.fileName))
        _ = try await ScanEngine(root: root, config: Config()).run()
    }
}
