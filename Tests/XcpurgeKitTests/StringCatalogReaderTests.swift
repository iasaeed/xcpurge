import XCTest
@testable import XcpurgeKit

/// `.xcstrings` / `.strings` / `.stringsdict` readers and the Xcode-format writer.
final class StringCatalogReaderTests: XCTestCase {
    private let edgeResources = "StringsEdgeCases/Sources/Feature/Resources"

    private func data(_ path: String) throws -> Data {
        try Data(contentsOf: FixtureSupport.fixtureURL(path))
    }

    /// The fixture catalog was written by `xcrun xcstringstool sync` (Xcode 26): re-serializing it with zero
    /// removals must reproduce it byte for byte (ordinal key order, `" : "`, empty `{\n\n    }`, no trailing newline).
    func testRoundTripIsByteIdenticalForXcodeOutput() throws {
        let original = try data("\(edgeResources)/Localizable.xcstrings")
        XCTAssertNotEqual(original.last, UInt8(ascii: "\n"), "fixture must be untouched Xcode output")
        XCTAssertEqual(try StringCatalogReader.removing([], from: original), original)
        let object = try JSONSerialization.jsonObject(with: original)
        XCTAssertEqual(StringCatalogReader.serialize(object), original)
    }

    func testRoundTripKeepsTrailingNewline() throws {
        for path in ["ModularWorkspace/App/App/Localizable.xcstrings",
                     "ModularWorkspace/Packages/DesignSystem/Sources/DesignSystem/Resources/Localizable.xcstrings"] {
            let original = try data(path)
            XCTAssertEqual(try StringCatalogReader.removing([], from: original), original, path)
        }
    }

    func testOrdinalKeyOrderMatchesXcode() {
        let keys = StringCatalogReader.sortedKeys(["zeta": 1, "Alpha": 1, "alpha": 1, "_u": 1, "10": 1, "Über": 1, "B": 1, "": 1])
        XCTAssertEqual(keys, ["", "10", "Alpha", "B", "_u", "alpha", "zeta", "Über"])
    }

    func testEntryMetadata() throws {
        let catalog = try StringCatalogReader.read(try data("\(edgeResources)/Localizable.xcstrings"))
        XCTAssertEqual(catalog.sourceLanguage, "en")
        let byKey = Dictionary(uniqueKeysWithValues: catalog.entries.map { ($0.key, $0) })
        XCTAssertNil(byKey["module_key"]?.extractionState)
        XCTAssertEqual(byKey["stale_key"]?.extractionState, "stale")
        XCTAssertEqual(byKey["ewv_unused"]?.extractionState, "extracted_with_value")
        XCTAssertEqual(byKey["no_translate"]?.shouldTranslate, false)
        XCTAssertEqual(byKey["module_key"]?.shouldTranslate, true)
        XCTAssertEqual(byKey["items_count"]?.hasVariations, true)
        XCTAssertEqual(byKey["items_count"]?.hasFormatSpecifiers, true)
        XCTAssertEqual(byKey["device_key"]?.hasVariations, true)
        XCTAssertEqual(byKey["device_key"]?.hasFormatSpecifiers, false)
        XCTAssertEqual(byKey["Hello %@"]?.hasFormatSpecifiers, true)
        XCTAssertEqual(byKey["manual_unused"]?.comment, "Has a / slash and \"quotes\"")
        XCTAssertEqual(byKey["%lld"]?.line, 4)
        XCTAssertEqual(byKey["Hello %@"]?.line, 7)
        XCTAssertNotNil(byKey["Über_key"]?.line)
        XCTAssertEqual(catalog.entries.map(\.key).first, "%lld")
    }

    func testTolerantParseOfMinifiedCatalog() throws {
        let catalog = try StringCatalogReader.read(try data("\(edgeResources)/Feature-Strings.xcstrings"))
        XCTAssertEqual(catalog.entries.map(\.key), ["feature_title", "feature_unused"])
        XCTAssertNil(catalog.entries[0].line)
        XCTAssertThrowsError(try StringCatalogReader.read(Data("{\"version\":\"1.0\"}".utf8)))
        XCTAssertThrowsError(try StringCatalogReader.read(Data("not json".utf8)))
        let extra = Data(#"{"strings":{"k":{"extractionState":"future_state","newField":[1,2]}},"version":"9.9","x":true}"#.utf8)
        XCTAssertEqual(try StringCatalogReader.read(extra).entries.first?.extractionState, "future_state")
    }

    func testRemovingKeysKeepsEverythingElse() throws {
        let original = try data("\(edgeResources)/Localizable.xcstrings")
        let pruned = try StringCatalogReader.removing(["manual_unused", "stale_key"], from: original)
        let keys = try StringCatalogReader.read(pruned).entries.map(\.key)
        XCTAssertFalse(keys.contains("manual_unused"))
        XCTAssertFalse(keys.contains("stale_key"))
        XCTAssertTrue(keys.contains("items_count"))
        // Every remaining line exists in the original: removal deletes blocks, never reformats.
        let originalLines = Set(String(decoding: original, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false))
        for line in String(decoding: pruned, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false) {
            XCTAssertTrue(originalLines.contains(line), "new line: \(line)")
        }
    }

    func testWriterEscapes() throws {
        let out = String(decoding: StringCatalogReader.serialize(["k": "a\"b\\c/d\ne\tf\u{1}é", "n": 2, "b": false, "e": [String]()] as [String: Any]),
                         as: UTF8.self)
        XCTAssertEqual(out, "{\n  \"b\" : false,\n  \"e\" : [\n\n  ],\n  \"k\" : \"a\\\"b\\\\c/d\\ne\\tf\\u0001é\",\n  \"n\" : 2\n}")
    }

    // MARK: - .strings / .stringsdict

    func testStringsFileKeysAndLines() throws {
        let keys = try XCTUnwrap(StringsFileReader.keys(try data("\(edgeResources)/en.lproj/Legacy.strings")))
        XCTAssertEqual(keys["table_key"], 4)
        XCTAssertEqual(keys["legacy_unused"], 7)
        XCTAssertEqual(keys["unquoted_key"], 8)
        XCTAssertEqual(keys["trailing_key"], 9)
        XCTAssertEqual(keys["bare_key"], 10)
        XCTAssertEqual(keys.count, 5)
    }

    func testStringsTokenizerHandlesEscapesAndComments() {
        let text = """
        /* a "quoted" ; comment */
        "k1" = "v \\"x\\" ; y"; // trailing
        // "fake" = "no";
        "k\\"2" = "v";
        """
        let statements = StringsFileReader.statements(in: text)
        XCTAssertEqual(statements.map(\.key), ["k1", "k\"2"])
        XCTAssertEqual(statements.map(\.line), [2, 4])
        XCTAssertNotNil(statements[0].comment)
        XCTAssertNotNil(statements[1].comment, "the line comment directly above")
    }

    func testStringsRemovalDropsStatementAndPrecedingComment() throws {
        let original = try data("\(edgeResources)/en.lproj/Legacy.strings")
        let pruned = try XCTUnwrap(StringsFileReader.removing(["legacy_unused", "trailing_key", "bare_key"], from: original))
        XCTAssertEqual(String(decoding: pruned, as: UTF8.self), """
        /* Legacy table (section header, kept on prune) */

        /* Used with tableName: "Legacy" */
        "table_key" = "Table";

        unquoted_key = "Bare word key";

        """)
        XCTAssertNil(StringsFileReader.removing(["absent"], from: original))
    }

    func testStringsRemovalCollapsesBlankLines() {
        let text = "\"a\" = \"1\";\n\n/* b */\n\"b\" = \"2\";\n\n/* c */\n\"c\" = \"3\";\n"
        let out = StringsFileReader.removing(["b"], from: Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(out, "\"a\" = \"1\";\n\n/* c */\n\"c\" = \"3\";\n")
        let first = StringsFileReader.removing(["a"], from: Data(text.utf8)).map { String(decoding: $0, as: UTF8.self) }
        XCTAssertEqual(first, "/* b */\n\"b\" = \"2\";\n\n/* c */\n\"c\" = \"3\";\n")
    }

    func testUTF16StringsRoundTripEncoding() throws {
        let text = "\"a\" = \"é\";\n\"b\" = \"2\";\n"
        let utf16 = Data([0xFF, 0xFE]) + text.data(using: .utf16LittleEndian)!
        XCTAssertEqual(StringsFileReader.keys(utf16)?["b"], 2)
        let pruned = try XCTUnwrap(StringsFileReader.removing(["b"], from: utf16))
        XCTAssertEqual(pruned, Data([0xFF, 0xFE]) + "\"a\" = \"é\";\n".data(using: .utf16LittleEndian)!)
    }

    func testStringsDictTopLevelKeysOnly() throws {
        let original = try data("\(edgeResources)/en.lproj/Plurals.stringsdict")
        let keys = try XCTUnwrap(StringsDictReader.keys(original))
        XCTAssertEqual(Set(keys.keys), ["plural_unused", "plural_used"])
        XCTAssertEqual(keys["plural_unused"], 5)
        XCTAssertEqual(keys["plural_used"], 21)
        let pruned = try XCTUnwrap(StringsDictReader.removing(["plural_unused"], from: original))
        XCTAssertEqual(Set(try XCTUnwrap(StringsDictReader.keys(pruned)).keys), ["plural_used"])
        XCTAssertTrue(String(decoding: pruned, as: UTF8.self).hasPrefix("<?xml"))
    }
}
