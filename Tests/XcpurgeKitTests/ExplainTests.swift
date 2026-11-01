import Foundation
import XCTest
@testable import XcpurgeKit

/// `xcpurge explain`: the four statuses on MixedApp, id/path/name lookup, the JSON shape and the CLI exit codes.
final class ExplainTests: XCTestCase {
    private let root = FixtureSupport.fixtureURL("MixedApp")

    private func explain(_ subject: String, root: URL? = nil, config: Config = Config()) async throws -> ExplainReport {
        try await Explainer.explain(subject: subject, root: root ?? self.root, config: config)
    }

    func testReportedAssetByName() async throws {
        let report = try await explain("legacy_unused")
        XCTAssertEqual(report.matches.count, 1)
        let e = try XCTUnwrap(report.matches.first)
        XCTAssertEqual(e.status, .reported)
        XCTAssertEqual(e.finding?.id, "unused-asset-ab15ed7993")
        XCTAssertEqual(e.owners, ["MixedApp.xcodeproj:MixedApp"])
        XCTAssertEqual(e.modulesChecked, ["unknown", "MixedApp.xcodeproj:MixedApp", "MixedApp.xcodeproj:MixedAppTests"])
        XCTAssertTrue(e.visibilityRule.contains("depends on or embeds"))
        XCTAssertTrue(e.visibilityRule.hasSuffix("Test targets count."))
        XCTAssertTrue(e.referenceSites.isEmpty)
        XCTAssertEqual(e.confidence?.value, "high")
        XCTAssertEqual(e.confidence?.derivation.count, 2)
        XCTAssertTrue(e.confidence?.derivation[1].hasPrefix("no-ref: ") == true)
        XCTAssertTrue(e.toMakeSafe.contains { $0.contains("xcpurge remove") })
        XCTAssertNil(e.suppressedBy)
    }

    func testLookupByIdPathAndFileInsideSet() async throws {
        let byID = try await explain("unused-asset-bdd3de6eeb")
        XCTAssertEqual(byID.matches.first?.finding?.name, "modern_unused")
        let byPath = try await explain("Modern/ModernAssets.xcassets/modern_unused.imageset/")
        XCTAssertEqual(byPath.matches.first?.finding?.id, "unused-asset-bdd3de6eeb")
        let inside = try await explain(root.appendingPathComponent("Modern/ModernAssets.xcassets/modern_unused.imageset/Contents.json").path)
        XCTAssertEqual(inside.matches.first?.finding?.id, "unused-asset-bdd3de6eeb", "absolute path inside the set")
        let byFileName = try await explain("Stray.swift")
        XCTAssertEqual(byFileName.matches.first?.finding?.kind, .orphanFile)
    }

    /// A folder or catalog subject lists every finding under it.
    func testFolderSubjectListsContainedFindings() async throws {
        let catalog = try await explain("Legacy/LegacyAssets.xcassets")
        XCTAssertEqual(catalog.matches.map { $0.finding?.id }, ["unused-asset-ab15ed7993"])
        XCTAssertEqual(catalog.matches.first?.status, .reported)
        let folder = try await explain("./Content/")
        XCTAssertEqual(folder.matches.compactMap { $0.finding?.path }.sorted(), ["Content/a.json", "Content/b.json"])
        let absolute = try await explain(root.appendingPathComponent("Content").path)
        XCTAssertEqual(absolute.matches.count, 2, "absolute folder path inside the root")
        let byFileName = try await explain("Stray.swift")
        XCTAssertEqual(byFileName.matches.count, 1, "a file name is not a folder prefix")
    }

    func testUsedAssetIsNotReportedAndListsSites() async throws {
        let report = try await explain("legacy_used")
        let e = try XCTUnwrap(report.matches.first)
        XCTAssertEqual(e.status, .notReported)
        XCTAssertNil(e.finding)
        XCTAssertEqual(e.owners, ["MixedApp.xcodeproj:MixedApp"], "resolved to its catalog set")
        XCTAssertEqual(e.referenceSites.count, 1)
        let site = try XCTUnwrap(e.referenceSites.first)
        XCTAssertEqual(site.path, "Legacy/Legacy.swift")
        XCTAssertEqual(site.line, 5)
        XCTAssertTrue(site.visible)
        XCTAssertTrue(site.exact)
        XCTAssertEqual(site.kind, "stringLiteral")
        XCTAssertTrue(e.note?.contains("1 visible reference") == true, e.note ?? "")
        XCTAssertNil(e.confidence)
    }

    /// A value found inside a `.json` file has no line to point at: the JSON omits `line` instead of printing 0.
    func testReferenceInJSONFileHasNoLine() async throws {
        let dir = try FixtureSupport.tempTree([
            "Package.swift": """
            // swift-tools-version: 5.9
            import PackageDescription
            let package = Package(name: "Kit", targets: [.target(name: "Kit")])
            """,
            "Sources/Kit/Kit.swift": "public struct Kit {}\nlet name = \"zebra_icon\"\n",
            "Sources/Kit/data.json": #"{ "trackers": [ { "icon": "zebra_icon" } ] }"#,
        ])
        var config = Config()
        config.noSwift = true
        let report = try await explain("zebra_icon", root: dir, config: config)
        let e = try XCTUnwrap(report.matches.first)
        let inJSON = try XCTUnwrap(e.referenceSites.first { $0.path == "Sources/Kit/data.json" })
        XCTAssertNil(inJSON.line)
        XCTAssertEqual(try XCTUnwrap(e.referenceSites.first { $0.path == "Sources/Kit/Kit.swift" }).line, 2)
        let json = Explainer.renderJSON(report)
        XCTAssertFalse(json.contains("\"line\" : 0"), json)
        let decoded = try JSONDecoder().decode(ExplainReport.self, from: Data(json.utf8))
        XCTAssertNil(decoded.matches.first?.referenceSites.first { $0.path == "Sources/Kit/data.json" }?.line)
        let text = Explainer.renderText(report)
        XCTAssertTrue(text.contains("  - Sources/Kit/data.json "), "no :0 in the text report either")
    }

    func testSuppressedByIgnoreFileLine() async throws {
        let copy = try FixtureSupport.copyToTemp("MixedApp")
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        try "# legacy art is loaded by name from the CMS\nasset:legacy_unused\n!asset:nothing\n"
            .write(to: copy.appendingPathComponent(".xcpurgeignore"), atomically: true, encoding: .utf8)
        let report = try await explain("legacy_unused", root: copy)
        let e = try XCTUnwrap(report.matches.first)
        XCTAssertEqual(e.status, .suppressed)
        XCTAssertEqual(e.suppressedBy, ".xcpurgeignore:2 asset:legacy_unused")
        XCTAssertEqual(e.finding?.id, "unused-asset-ab15ed7993")
        // A later negation wins: the rule no longer suppresses, so the finding is reported again.
        try "asset:legacy_*\n!asset:legacy_unused\n".write(to: copy.appendingPathComponent(".xcpurgeignore"), atomically: true, encoding: .utf8)
        let negated = try await explain("legacy_unused", root: copy)
        XCTAssertEqual(negated.matches.first?.status, .reported)
    }

    func testBelowThresholdAndHiddenByTargets() async throws {
        var strict = Config()
        strict.minConfidence = .high
        let low = try await explain("Stray/Stray.swift", config: strict)
        XCTAssertEqual(low.matches.first?.status, .belowThreshold)
        XCTAssertEqual(low.matches.first?.note, "below --min-confidence high")
        XCTAssertEqual(low.matches.first?.confidence?.value, "low")
        var targeted = Config()
        targeted.targets = ["Nope"]
        let hidden = try await explain("legacy_unused", config: targeted)
        XCTAssertEqual(hidden.matches.first?.status, .notReported)
        XCTAssertEqual(hidden.matches.first?.note, "hidden by --targets (module MixedApp)")
        XCTAssertNotNil(hidden.matches.first?.finding)
    }

    func testDynamicPatternAndDerivationOnModularWorkspace() async throws {
        let report = try await explain("icon_1", root: FixtureSupport.fixtureURL("ModularWorkspace"))
        let e = try XCTUnwrap(report.matches.first)
        XCTAssertEqual(e.status, .reported)
        XCTAssertEqual(e.finding?.confidence, .low)
        XCTAssertFalse(e.dynamicPatterns.isEmpty, "the `icon_\\(i)` site builds the name")
        XCTAssertEqual(e.dynamicPatterns.first?.path, "App/App/ContentView.swift")
        XCTAssertTrue(e.dynamicPatterns.first?.visible == true)
        XCTAssertTrue(e.confidence?.derivation.contains { $0.hasPrefix("dyn-pattern: ") } == true)
        XCTAssertTrue(e.toMakeSafe.contains { $0.contains("Do not remove") })
    }

    func testNoMatchThrowsWithSuggestions() async {
        do {
            _ = try await explain("legacy_unusd")
            XCTFail("expected NoMatch")
        } catch let miss as Explainer.NoMatch {
            XCTAssertEqual(miss.suggestions.first, "legacy_unused")
            XCTAssertTrue(miss.description.contains("Did you mean"))
        } catch {
            XCTFail("\(error)")
        }
    }

    func testJSONShapeDecodes() async throws {
        let reported = try await explain("legacy_unused")
        let json = Explainer.renderJSON(reported)
        let decoded = try JSONDecoder().decode(ExplainReport.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.schemaVersion, 1)
        XCTAssertEqual(decoded.matches.first?.finding?.id, "unused-asset-ab15ed7993")
        XCTAssertTrue(json.contains("\"suppressedBy\" : null"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), ["schemaVersion", "tool", "subject", "root", "matches"])
        let match = try XCTUnwrap((object["matches"] as? [[String: Any]])?.first)
        for key in ["status", "finding", "suppressedBy", "owners", "modulesChecked", "visibilityRule", "referenceSites",
                    "dynamicPatterns", "confidence", "toMakeSafe"] {
            XCTAssertNotNil(match[key], key)
        }
        let unreported = Explainer.renderJSON(try await explain("legacy_used"))
        XCTAssertTrue(unreported.contains("\"finding\" : null"))
        XCTAssertEqual(Explainer.renderJSON(reported), json, "deterministic")
    }

    func testTextRendering() async throws {
        let text = Explainer.renderText(try await explain("legacy_unused"))
        XCTAssertTrue(text.hasPrefix("legacy_unused: 1 match\n"))
        XCTAssertTrue(text.contains("## unused-asset-ab15ed7993 · reported · high\n"))
        XCTAssertTrue(text.contains("reference sites (0): none\n"))
        XCTAssertTrue(text.contains("\n  no-ref: no reference by name"))
        XCTAssertTrue(text.contains("to make this safe:\n"))
        XCTAssertFalse(text.contains("authoritative"))
    }

    func testEditDistance() {
        XCTAssertEqual(Explainer.editDistance("kitten", "sitting"), 3)
        XCTAssertEqual(Explainer.editDistance("", "abc"), 3)
        XCTAssertEqual(Explainer.editDistance("same", "same"), 0)
    }

    func testCLI() throws {
        let root = self.root.path
        let ok = try CLISupport.run(["explain", root, "legacy_unused"])
        XCTAssertEqual(ok.status, 0, ok.stderr)
        XCTAssertTrue(ok.stdout.contains("· reported · high"))
        let json = try CLISupport.run(["explain", root, "unused-asset-ab15ed7993", "--format", "json"])
        XCTAssertEqual(json.status, 0, json.stderr)
        XCTAssertNoThrow(try JSONDecoder().decode(ExplainReport.self, from: Data(json.stdout.utf8)))
        let used = try CLISupport.run(["explain", root, "legacy_used"])
        XCTAssertEqual(used.status, 0)
        XCTAssertTrue(used.stdout.contains("· notReported"))
        let miss = try CLISupport.run(["explain", root, "legacy_unusd"])
        XCTAssertEqual(miss.status, 2)
        XCTAssertEqual(miss.stdout, "")
        XCTAssertTrue(miss.stderr.contains("Did you mean: legacy_unused"), miss.stderr)
        let html = try CLISupport.run(["explain", root, "legacy_unused", "--format", "html"])
        XCTAssertEqual(html.status, 2)
        XCTAssertTrue(html.stderr.contains("text or json"), html.stderr)
    }

    /// `"format"` in xcpurge.json is for scan reports; explain ignores it and takes only its own `--format`.
    func testCLIIgnoresConfigFormat() throws {
        let copy = try FixtureSupport.copyToTemp("MixedApp")
        defer { try? FileManager.default.removeItem(at: copy.deletingLastPathComponent()) }
        try "{ \"format\": \"github\" }\n".write(to: copy.appendingPathComponent(Config.fileName), atomically: true, encoding: .utf8)
        let text = try CLISupport.run(["explain", copy.path, "legacy_unused"])
        XCTAssertEqual(text.status, 0, text.stderr)
        XCTAssertTrue(text.stdout.hasPrefix("legacy_unused: 1 match\n"), text.stdout)
        let json = try CLISupport.run(["explain", copy.path, "legacy_unused", "--format", "json"])
        XCTAssertEqual(json.status, 0, json.stderr)
        XCTAssertNoThrow(try JSONDecoder().decode(ExplainReport.self, from: Data(json.stdout.utf8)))
    }
}
