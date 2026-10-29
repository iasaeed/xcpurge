import XCTest
@testable import XcpurgeKit

final class ScanEngineTests: XCTestCase {
    private func finding(_ name: String, _ confidence: Confidence, module: String = "App", path: String = "App/A.xcassets") -> Finding {
        Finding(kind: .unusedAsset, category: .assets, path: path, name: name, module: module, confidence: confidence)
    }

    func testEndToEndOnFixturesWithStubbedDetectors() async throws {
        for fixture in ["ModularWorkspace", "SyncedApp"] {
            let result = try await ScanEngine(root: FixtureSupport.fixtureURL(fixture), config: Config()).run()
            XCTAssertEqual(result.findings, [], fixture)
            XCTAssertFalse(result.context.graph.modules.isEmpty, fixture)
            XCTAssertFalse(result.context.diagnostics.entries.contains { $0.level == .warning }, "\(fixture): \(result.context.diagnostics.entries)")
        }
    }

    func testFilterThresholdTargetsExcludesAndOrder() async throws {
        var config = Config()
        config.minConfidence = .medium
        config.targets = ["App"]
        config.exclude = ["Vendor/**"]
        let engine = ScanEngine(root: FixtureSupport.fixtureURL("SyncedApp"), config: config)
        let ctx = try await engine.makeContext()
        let input = [finding("b", .high), finding("a", .medium), finding("low", .low), finding("other", .high, module: "Kit"),
                     finding("vendored", .high, path: "Vendor/x.png"), finding("a", .medium)]
        let out = engine.filter(input, context: ctx)
        XCTAssertEqual(out.map(\.name), ["a", "b"])
    }

    func testReportOrder() {
        let a = Finding(kind: .unusedString, category: .strings, path: "b", name: "x", module: "M", confidence: .high)
        let b = Finding(kind: .unusedAsset, category: .assets, path: "z", name: "y", module: "M", confidence: .high)
        let c = Finding(kind: .unusedAsset, category: .assets, path: "a", line: 3, name: "z", module: "M", confidence: .high)
        XCTAssertEqual([a, b, c].sorted(by: Finding.reportOrder), [c, b, a])
    }

    func testMissingRootThrows() async {
        do {
            _ = try await ScanEngine(root: URL(fileURLWithPath: "/definitely/not/here"), config: Config()).makeContext()
            XCTFail("expected an error")
        } catch {
            XCTAssertTrue(error is XcpurgeError)
        }
    }

    func testDerivedDataLocator() throws {
        let base = try FixtureSupport.tempTree(["App-aaa/info.plist": "", "App-bbb/info.plist": "", "Other-ccc/x": ""])
        let fm = FileManager.default
        try fm.setAttributes([.modificationDate: Date(timeIntervalSince1970: 100)], ofItemAtPath: base.appendingPathComponent("App-aaa").path)
        try fm.setAttributes([.modificationDate: Date()], ofItemAtPath: base.appendingPathComponent("App-bbb").path)
        XCTAssertEqual(DerivedDataLocator.locate(names: ["App"], override: nil, base: base)?.lastPathComponent, "App-bbb")
        XCTAssertNil(DerivedDataLocator.locate(names: ["Nope"], override: nil, base: base))
        XCTAssertEqual(DerivedDataLocator.locate(names: [], override: base.path, base: base)?.path, base.path)
    }

    func testConfigLoadingIsTolerant() throws {
        let dir = try FixtureSupport.tempTree([Config.fileName: """
        { // JSON5 comments allowed
          "minConfidence": "high", "targets": ["App"], "includePods": true, "unknownKey": 1,
        }
        """])
        let c = try Config.load(from: dir.appendingPathComponent(Config.fileName))
        XCTAssertEqual(c.minConfidence, .high)
        XCTAssertEqual(c.targets, ["App"])
        XCTAssertTrue(c.includePods)
        XCTAssertEqual(try Config.load(from: dir.appendingPathComponent("missing.json")), Config())
        let template = try JSONDecoder().decode(Config.self, from: Data(Config.template.utf8))
        XCTAssertEqual(template.minConfidence, .medium)
    }
}
