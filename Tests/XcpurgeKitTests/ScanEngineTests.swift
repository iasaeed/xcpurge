import XCTest
@testable import XcpurgeKit

final class ScanEngineTests: XCTestCase {
    private func finding(_ name: String, _ confidence: Confidence, module: String = "App", path: String = "App/A.xcassets") -> Finding {
        Finding(kind: .unusedAsset, category: .assets, path: path, name: name, module: module, confidence: confidence)
    }

    static let allFixtures = ["ModularWorkspace", "SyncedApp", "ClassicApp", "XcprojApp", "AssetsEdgeCases", "StringsEdgeCases", "MixedApp"]

    /// Every fixture runs end-to-end with the real detectors: findings and modules exist, two runs render
    /// byte-identical JSON, and no diagnostic is an error.
    func testEndToEndOnEveryFixtureIsDeterministic() async throws {
        for fixture in Self.allFixtures {
            let first = try await ScanEngine(root: FixtureSupport.fixtureURL(fixture), config: Config()).run()
            let second = try await ScanEngine(root: FixtureSupport.fixtureURL(fixture), config: Config()).run()
            XCTAssertFalse(first.findings.isEmpty, fixture)
            XCTAssertFalse(first.context.graph.modules.isEmpty, fixture)
            XCTAssertEqual(JSONReporter().render(first), JSONReporter().render(second), "\(fixture): output not deterministic")
            let errors = first.context.diagnostics.entries.filter { $0.level == .error }
            XCTAssertEqual(errors, [], fixture)
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

    /// Inline `xcpurge:ignore` markers are applied by the engine for every category, not by one detector.
    func testEngineAppliesInlineMarkersToEveryCategory() async throws {
        let root = try FixtureSupport.tempTree(["A.swift": "let a = 1\n// xcpurge:ignore\nlet b = 2\n"])
        let engine = ScanEngine(root: root, config: Config())
        let ctx = try await engine.makeContext()
        let marked = [Category.assets, .strings, .files, .duplicates].map {
            Finding(kind: .dynamicLookup, category: $0, path: "A.swift", line: 3, name: "x", module: "unknown", confidence: .high)
        }
        let unmarked = Finding(kind: .dynamicLookup, category: .strings, path: "A.swift", line: 1, name: "y",
                               module: "unknown", confidence: .high)
        XCTAssertEqual(engine.filter(marked + [unmarked], context: ctx), [unmarked])
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
        let json5 = JSONDecoder()
        json5.allowsJSON5 = true
        let template = try json5.decode(Config.self, from: Data(Config.template.utf8))
        XCTAssertEqual(template.exclude, ["Vendor/**"], "generated code is never excluded by default")
        XCTAssertEqual(template.minConfidence, .medium)
    }
}
