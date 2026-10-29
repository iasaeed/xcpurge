import XCTest
@testable import XcpurgeKit

/// Prune on temporary fixture copies: keys leave every `.lproj` variant, originals land in the trash.
final class PruneStringsTests: XCTestCase {
    private let res = "Sources/Feature/Resources"

    private func text(_ root: URL, _ path: String) throws -> String {
        try String(contentsOf: root.appendingPathComponent(path), encoding: .utf8)
    }

    func testPruneEdgeCases() async throws {
        let root = try FixtureSupport.copyToTemp("StringsEdgeCases")
        defer { try? FileManager.default.removeItem(at: root.deletingLastPathComponent()) }
        let before = try await ScanEngine(root: root, config: StringsDetectorTests.config).run(categories: [.strings])
        let prunable = before.findings.filter { !$0.kind.isInformational }
        XCTAssertFalse(prunable.isEmpty)
        let originalCatalog = try Data(contentsOf: root.appendingPathComponent("\(res)/Localizable.xcstrings"))
        let originalFrench = try text(root, "\(res)/fr.lproj/Legacy.strings")

        let store = try TrashStore.begin(root: root)
        let report = try PruneStrings(store: store).apply(prunable, context: before.context)
        XCTAssertTrue(report.skipped.isEmpty, "\(report.skipped)")
        XCTAssertEqual(report.rewritten, report.rewritten.sorted())
        XCTAssertTrue(report.rewritten.contains("\(res)/fr.lproj/Legacy.strings"), "sibling .lproj variant")
        XCTAssertTrue(report.rewritten.contains("\(res)/Settings.bundle/en.lproj/Root.strings"))
        XCTAssertEqual(Set(store.entries.map(\.path)), Set(report.rewritten))
        XCTAssertTrue(store.entries.allSatisfy { $0.action == .rewritten })

        // Backups are the untouched originals.
        let backup = try XCTUnwrap(store.entries.first { $0.path == "\(res)/Localizable.xcstrings" })
        XCTAssertEqual(try Data(contentsOf: store.storedURL(backup)), originalCatalog)
        let frBackup = try XCTUnwrap(store.entries.first { $0.path == "\(res)/fr.lproj/Legacy.strings" })
        XCTAssertEqual(try String(contentsOf: store.storedURL(frBackup), encoding: .utf8), originalFrench)

        // French variant: unused statements and their comments are gone, the used one stays.
        XCTAssertEqual(try text(root, "\(res)/fr.lproj/Legacy.strings"), """
        /* Used with tableName: "Legacy" */
        "table_key" = "Tableau";

        """)
        XCTAssertFalse(try text(root, "\(res)/fr.lproj/Login.strings").contains("zzz-99-zzz"))
        XCTAssertTrue(try text(root, "\(res)/fr.lproj/Login.strings").contains("abc-12-def.text"))

        // The rewritten catalog is still in Xcode's format (its own round trip is identity).
        let catalog = try Data(contentsOf: root.appendingPathComponent("\(res)/Localizable.xcstrings"))
        XCTAssertEqual(try StringCatalogReader.removing([], from: catalog), catalog)
        let keys = Set(try StringCatalogReader.read(catalog).entries.map(\.key))
        XCTAssertFalse(keys.contains("manual_unused"))
        XCTAssertFalse(keys.contains("stale_key"))
        XCTAssertTrue(keys.isSuperset(of: ["module_key", "symbol_used", "items_count", "%lld"]))

        // Rescan: nothing left to prune.
        let after = try await ScanEngine(root: root, config: StringsDetectorTests.config).run(categories: [.strings])
        XCTAssertEqual(after.findings.filter { !$0.kind.isInformational }, [])
    }

    func testPruneSkipsNonStringFindingsAndMissingKeys() async throws {
        let root = try FixtureSupport.tempTree(["en.lproj/A.strings": "\"a\" = \"1\";\n"])
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        let store = try TrashStore.begin(root: root)
        let findings = [
            Finding(kind: .unusedString, category: .strings, path: "en.lproj/A.strings", name: "not_there", module: "unknown", confidence: .high),
            Finding(kind: .dynamicLookup, category: .strings, path: "x.swift", line: 1, module: "unknown", confidence: .low),
            Finding(kind: .unusedAsset, category: .assets, path: "A.xcassets", name: "x", module: "unknown", confidence: .high),
        ]
        let report = try PruneStrings(store: store).apply(findings, context: ctx)
        XCTAssertEqual(report.rewritten, [])
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertEqual(try text(root, "en.lproj/A.strings"), "\"a\" = \"1\";\n")
    }
}
