import XCTest
@testable import XcpurgeKit

/// OSS scan #1: exact references in modules the visibility rule does not count. In `ModularWorkspace`, App depends on
/// Core, so Core cannot see App's resources, yet Core's main-bundle lookups read App's bundle at runtime.
final class UnseenReferenceTests: XCTestCase {
    private var config: Config {
        var c = Config()
        c.noSwift = true
        return c
    }

    private func write(_ text: String, to path: String, in root: URL) throws {
        let url = root.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
    }

    private func addImageSet(_ name: String, in root: URL) throws {
        let dir = "App/App/Assets.xcassets/\(name).imageset"
        try write(#"{"images":[{"filename":"\#(name).png","idiom":"universal"}],"info":{"author":"xcode","version":1}}"#,
                  to: "\(dir)/Contents.json", in: root)
        try write("\(name)-bytes", to: "\(dir)/\(name).png", in: root)
    }

    private func appendLegacyKeys(_ keys: [String], in root: URL) throws {
        let legacy = root.appendingPathComponent("App/App/en.lproj/Legacy.strings")
        let text = try String(contentsOf: legacy, encoding: .utf8)
        try Data((text + keys.map { "\n\"\($0)\" = \"x\";" }.joined() + "\n").utf8).write(to: legacy)
    }

    func testExactAssetNameOutsideVisibleModulesCapsConfidence() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        for name in ["plain_art", "looked_up_art", "module_art", "lonely_art"] { try addImageSet(name, in: root) }
        try write("""
        import UIKit
        public enum CoreArt {
            public static let names = ["plain_art"]
            public static func image() -> UIImage? { UIImage(named: "looked_up_art") }
            public static func own() -> UIImage? { UIImage(named: "module_art", in: .module, compatibleWith: nil) }
        }
        """, to: "Packages/Core/Sources/Core/CoreArt.swift", in: root)

        let findings = try await ScanEngine(root: root, config: config).run(categories: [.assets]).findings
        let plain = try XCTUnwrap(findings.first { $0.name == "plain_art" })
        XCTAssertEqual(plain.confidence, .medium)
        XCTAssertEqual(ReasonCodes.codes(for: plain), ["no-ref", "not-visible"], "\(plain.reasons)")
        XCTAssertTrue(plain.reasons.contains { $0.contains("CoreArt.swift:3 in Core, a module that cannot see App") })
        let lookup = try XCTUnwrap(findings.first { $0.name == "looked_up_art" })
        XCTAssertEqual(lookup.confidence, .low)
        XCTAssertEqual(ReasonCodes.codes(for: lookup), ["no-ref", "main-bundle-lookup"], "\(lookup.reasons)")
        XCTAssertEqual(findings.first { $0.name == "module_art" }?.confidence, .high,
                       "a lookup in Core's own bundle never finds App's asset")
        XCTAssertEqual(findings.first { $0.name == "lonely_art" }?.confidence, .high)
    }

    /// Signal-iOS: `CommonStrings.attachmentTypeAnimated` is used in the app; its body in a framework holds the key.
    func testAccessorChainAcrossModulesCountsAsUse() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        for name in ["chained_art", "unchained_art"] { try addImageSet(name, in: root) }
        try appendLegacyKeys(["CHAINED_KEY", "UNCHAINED_KEY"], in: root)
        try write("""
        public func CoreLocalized(_ key: String, comment: String) -> String { key }
        public enum CoreStrings {
            public static var chainedLabel: String {
                CoreLocalized("CHAINED_KEY", comment: "")
            }
            public static var unchainedLabel: String { CoreLocalized("UNCHAINED_KEY", comment: "") }
            public static let bannerArtName = "chained_art"
            public static let otherArtName = "unchained_art"
        }
        """, to: "Packages/Core/Sources/Core/CoreStrings.swift", in: root)
        try write("""
        import Core
        let label = CoreStrings.chainedLabel
        let art = CoreStrings.bannerArtName
        """, to: "App/App/UsesCore.swift", in: root)

        let findings = try await ScanEngine(root: root, config: config).run(categories: [.assets, .strings]).findings
        let names = Set(findings.compactMap(\.name))
        XCTAssertFalse(names.contains("CHAINED_KEY"), "a visible accessor whose body holds the key is a use")
        XCTAssertFalse(names.contains("chained_art"))
        XCTAssertEqual(findings.first { $0.name == "UNCHAINED_KEY" }?.confidence, .medium)
        XCTAssertEqual(findings.first { $0.name == "unchained_art" }?.confidence, .medium)
    }

    func testAccessorChainNeedsAUniqueDeclarationName() throws {
        let tokens = SwiftTokenizer.tokenize("""
        enum Large { static let folder = "folderLarge" }
        enum Small { static let folder = "folderSmall" }
        func make() -> String {
            let local = "inner"
            return local
        }
        if let x = Optional("cond") { print(x) }
        """)
        let out = TokenReferenceExtractor.extract(tokens, file: 0, dialect: .swift, localizationMacros: [])
        let byValue = Dictionary(uniqueKeysWithValues: out.references.enumerated().filter { $0.element.kind == .stringLiteral }
            .map { ($0.element.value, out.enclosingDeclarations[$0.offset]) })
        XCTAssertEqual(byValue["folderLarge"], "folder")
        XCTAssertEqual(byValue["folderSmall"], "folder")
        XCTAssertEqual(byValue["inner"], "make", "nested declarations count for the outermost one")
        XCTAssertEqual(byValue["cond"] ?? nil, nil, "`if let` is a condition, not a declaration")
        XCTAssertEqual(out.declarationCounts["folder"], 2)
    }

    func testExactStringKeyOutsideVisibleModulesCapsConfidence() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try appendLegacyKeys(["core_plain", "core_lookup", "core_module", "core_other_table", "core_lonely"], in: root)
        try write("""
        import Foundation
        let keys = ["core_plain"]
        let a = NSLocalizedString("core_lookup", tableName: "Legacy", comment: "")
        let b = NSLocalizedString("core_module", tableName: "Legacy", bundle: .module, comment: "")
        let c = NSLocalizedString("core_other_table", tableName: "Other", comment: "")
        """, to: "Packages/Core/Sources/Core/CoreKeys.swift", in: root)

        let findings = try await ScanEngine(root: root, config: config).run(categories: [.strings]).findings
        func confidence(_ key: String) -> Confidence? { findings.first { $0.name == key }?.confidence }
        XCTAssertEqual(confidence("core_plain"), .medium)
        XCTAssertEqual(confidence("core_lookup"), .low)
        XCTAssertEqual(confidence("core_module"), .high, "Core's own bundle is not App's table")
        XCTAssertEqual(confidence("core_other_table"), .high, "another table is not this key")
        XCTAssertEqual(confidence("core_lonely"), .high)
        let plain = try XCTUnwrap(findings.first { $0.name == "core_plain" })
        XCTAssertTrue(ReasonCodes.codes(for: plain).contains("not-visible"), "\(plain.reasons)")
    }

    func testExactResourceNameOutsideVisibleModulesCapsConfidence() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try write("chime", to: "App/App/Data/chime.json", in: root)
        try write("ding", to: "App/App/Data/ding.json", in: root)
        try write("""
        import Foundation
        let chime = Bundle.main.url(forResource: "chime", withExtension: "json")
        let names = ["ding"]
        """, to: "Packages/Core/Sources/Core/CoreSounds.swift", in: root)

        let findings = try await ScanEngine(root: root, config: config).run(categories: [.files]).findings
            .filter { $0.kind == .unusedResource }
        XCTAssertEqual(findings.first { $0.path.hasSuffix("chime.json") }?.confidence, .low)
        XCTAssertEqual(findings.first { $0.path.hasSuffix("ding.json") }?.confidence, .medium)
        XCTAssertEqual(findings.first { $0.path.hasSuffix("unused.json") }?.confidence, .high)
    }

    /// `--ignore-test-references` puts test targets outside the visible modules on purpose; a name used only in tests
    /// must stay high instead of counting as an exact match elsewhere.
    func testIgnoredTestReferencesDoNotCountAsUnseenMatches() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try addImageSet("test_only_art", in: root)
        try appendLegacyKeys(["test_only_key"], in: root)
        try write("""
        import UIKit
        let art = UIImage(named: "test_only_art")
        let key = NSLocalizedString("test_only_key", tableName: "Legacy", comment: "")
        """, to: "App/AppTests/TestOnlyUse.swift", in: root)

        var ignoring = config
        ignoring.ignoreTestReferences = true
        let findings = try await ScanEngine(root: root, config: ignoring).run(categories: [.assets, .strings]).findings
        XCTAssertEqual(findings.first { $0.name == "test_only_art" }?.confidence, .high)
        XCTAssertEqual(findings.first { $0.name == "test_only_key" }?.confidence, .high)
        let counted = try await ScanEngine(root: root, config: config).run(categories: [.assets, .strings]).findings
        XCTAssertNil(counted.first { $0.name == "test_only_art" }, "tests count by default")
    }
}
