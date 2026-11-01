import XCTest
@testable import XcpurgeKit

/// OSS scan #3: names built at runtime. In `ModularWorkspace`, App depends on Core, so Core cannot see App's resources;
/// these rules apply whatever module the site is in.
final class RuntimeNameTests: XCTestCase {
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

    private func assets(_ root: URL) async throws -> [Finding] {
        try await ScanEngine(root: root, config: config).run(categories: [.assets]).findings
    }

    /// Signal-iOS `"avatar_\(rawValue)"` and vlc-ios `generateAnimation(with: "pause-animation-", …)`, both in a module
    /// that cannot see the catalog.
    func testConstantPrefixesMarkMatchingNamesLowInAnyModule() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        for name in ["avatar_heart", "pause-animation-3", "pause-animation-", "plain_other"] { try addImageSet(name, in: root) }
        try write("""
        public enum AvatarIcon: String {
            case heart
            public var imageName: String { "avatar_\\(rawValue)" }
        }
        public func animate() { generateAnimation(with: "pause-animation-", count: 4) }
        func generateAnimation(with prefix: String, count: Int) {}
        """, to: "Packages/Core/Sources/Core/Avatars.swift", in: root)

        let findings = try await assets(root)
        let avatar = try XCTUnwrap(findings.first { $0.name == "avatar_heart" })
        XCTAssertEqual(avatar.confidence, .low)
        XCTAssertTrue(avatar.reasons.contains { $0.contains("Avatars.swift:3") && $0.contains("built dynamically") }, "\(avatar.reasons)")
        let frame = try XCTUnwrap(findings.first { $0.name == "pause-animation-3" })
        XCTAssertEqual(frame.confidence, .low)
        XCTAssertTrue(frame.reasons.contains { $0.contains("\"pause-animation-…\"") }, "\(frame.reasons)")
        XCTAssertNotEqual(findings.first { $0.name == "pause-animation-" }?.confidence, .low, "only a proper prefix counts")
        XCTAssertEqual(findings.first { $0.name == "plain_other" }?.confidence, .high)
        let lookups = Set(findings.filter { $0.kind == .dynamicLookup }.compactMap(\.name))
        XCTAssertTrue(lookups.isSuperset(of: ["avatar_*", "pause-animation-*"]), "\(lookups)")
    }

    func testSeparatorPrefixNeedsTwoAlphanumerics() {
        XCTAssertTrue(ReferenceIndex.isSeparatorPrefix("pause-animation-"))
        XCTAssertTrue(ReferenceIndex.isSeparatorPrefix("ic_"))
        XCTAssertFalse(ReferenceIndex.isSeparatorPrefix("_"))
        XCTAssertFalse(ReferenceIndex.isSeparatorPrefix("a."))
        XCTAssertFalse(ReferenceIndex.isSeparatorPrefix("Loading..."), "contains no separator-final name start")
        XCTAssertFalse(ReferenceIndex.isSeparatorPrefix("an error -"))
        XCTAssertFalse(ReferenceIndex.isSeparatorPrefix("pause-animation"))
    }

    func testStringEnumCasesAreImplicitRawValues() {
        let tokens = SwiftTokenizer.tokenize("""
        enum SoundEffect: String, CaseIterable {
            case pull, refresh
            case tootSent = "toot", boost
            case `default`
            func url() -> URL? {
                switch self { case .pull: return nil; default: return nil }
            }
        }
        enum Plain { case notRaw }
        enum Associated: String { case a }
        """)
        let out = TokenReferenceExtractor.extract(tokens, file: 0, dialect: .swift, localizationMacros: [])
        let raw = out.references.filter { if case .implicitRawValue = $0.kind { return true } else { return false } }
        XCTAssertEqual(raw.map(\.value), ["pull", "refresh", "boost", "default", "a"])
        XCTAssertEqual(raw.first?.kind, .implicitRawValue("SoundEffect"))
    }

    /// IceCubesApp: `Bundle.main.url(forResource: effect.rawValue, withExtension: "wav")` with `case pull, refresh`.
    func testImplicitRawValueCapsResourceAtMedium() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try write("pull", to: "App/App/Data/pull.json", in: root)
        try write("""
        import Foundation
        public enum SoundEffect: String { case pull, refresh }
        public func url(for effect: SoundEffect) -> URL? { Bundle.main.url(forResource: effect.rawValue, withExtension: "json") }
        """, to: "Packages/Core/Sources/Core/Sounds.swift", in: root)

        let findings = try await ScanEngine(root: root, config: config).run(categories: [.files]).findings
        let pull = try XCTUnwrap(findings.first { $0.path.hasSuffix("pull.json") })
        XCTAssertEqual(pull.confidence, .medium)
        XCTAssertEqual(ReasonCodes.codes(for: pull), ["no-ref", "enum-raw-value"], "\(pull.reasons)")
        XCTAssertEqual(findings.first { $0.path.hasSuffix("unused.json") }?.confidence, .high)
    }

    /// mastodon-ios: `UIImage(named: "Athens")` behind `#if SNAPSHOT`; xcpurge never evaluates compilation conditions.
    func testReferencesInInactiveConditionalBlocksCount() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try addImageSet("Athens", in: root)
        try write("""
        import UIKit
        func preview() {
            #if SNAPSHOT
            let image = UIImage(named: "Athens")
            #endif
        }
        """, to: "App/App/Snapshot.swift", in: root)
        let findings = try await assets(root)
        XCTAssertNil(findings.first { $0.name == "Athens" })
    }

    /// A locally computed asset name lowers that module's catalogs to medium; a forwarded parameter
    /// (duckduckgo-ios `UIImage(named: entityName, …)` inside `func load(for entityName:)`) does not.
    func testLocallyComputedAssetNameLowersSameModuleCatalogsToMedium() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try addImageSet("tracker_logo", in: root)
        try write("""
        import UIKit
        func logo(for entityName: String) -> UIImage? {
            UIImage(named: entityName, in: nil, compatibleWith: nil)
        }
        """, to: "App/App/TrackerImages.swift", in: root)
        let forwarded = try await assets(root)
        XCTAssertEqual(forwarded.first { $0.name == "tracker_logo" }?.confidence, .high, "a forwarding wrapper is no lookup")

        try write("""
        import UIKit
        func logo(for entity: Entity) -> UIImage? {
            let entityName = entity.displayName.lowercased()
            return UIImage(named: entityName, in: nil, compatibleWith: nil)
        }
        """, to: "App/App/TrackerImages.swift", in: root)
        let computed = try await assets(root)
        let logo = try XCTUnwrap(computed.first { $0.name == "tracker_logo" })
        XCTAssertEqual(logo.confidence, .medium)
        XCTAssertTrue(logo.reasons.contains { $0.contains("TrackerImages.swift:4 (name passed as a variable)") }, "\(logo.reasons)")
        XCTAssertTrue(computed.contains { $0.kind == .dynamicLookup && $0.path == "App/App/TrackerImages.swift" })
    }

    func testKeylessLookupNeedsALocallyComputedName() {
        let tokens = SwiftTokenizer.tokenize("""
        struct Cell {
            var iconName: String
            func forwarded(_ name: String) -> UIImage? { UIImage(named: name) }
            func shadowed(_ image: String) -> UIImage? { let image = UIImage(named: image); return image }
            func property() -> UIImage? { UIImage(named: iconName) }
            func computed(_ model: Model) {
                let picked = model.icon()
                _ = UIImage(named: picked)
                _ = UIImage(named: picked.lowercased())
                let themeName = "theme_" + mode
                _ = UIImage(named: themeName)
                let saved = isSaved ? "save-filled" : "save"
                _ = UIImage(named: saved)
                _ = UIImage(named: "flag_\\(picked)")
                _ = UIImage(systemName: picked)
                for each in model.names { _ = Image(each) }
                for fixed in ["a", "b"] { _ = Image(fixed) }
                items.forEach { item in _ = UIImage(named: item) }
                if let unwrapped = model.iconName, let other = model.alt { _ = UIImage(named: unwrapped) }
                _ = UIImage(named: picked.iconName)
                let switched: String = {
                    switch mode { case .a: return "group"; case .b: return "lock" }
                }()
                _ = UIImage(named: switched)
                let fromHelper = statusIcon(for: mode)
                _ = UIImage(named: fromHelper)
            }
            func statusIcon(for mode: Mode) -> String { mode == .a ? "status_a" : "status_b" }
            func other() -> UIImage? { UIImage(named: picked) }
        }
        """)
        let out = TokenReferenceExtractor.extract(tokens, file: 0, dialect: .swift, localizationMacros: [])
        XCTAssertEqual(out.patterns.filter(\.isKeyless).map(\.line), [8, 9, 16],
                       "computed locals and loop variables only; not parameters, properties or literal-bound names")
    }

    /// A helper call bound in one function must not hide a loop variable of the same name in another.
    func testLocalCalleeDoesNotLeakAcrossFunctions() {
        let tokens = SwiftTokenizer.tokenize("""
        struct Icons {
            func a() { let name = helper() }
            func helper() -> String { "x" }
            func b(_ names: [String]) { for name in names.sorted() { _ = UIImage(named: name) } }
            func c(_ model: Model) {
                let name = helper()
                for name in model.names() { _ = UIImage(named: name) }
            }
        }
        """)
        let out = TokenReferenceExtractor.extract(tokens, file: 0, dialect: .swift, localizationMacros: [])
        XCTAssertEqual(out.patterns.filter(\.isKeyless).map(\.line), [4, 7])
    }

    func testNestedStringEnumKeepsOuterCases() {
        let tokens = SwiftTokenizer.tokenize("""
        enum Outer: String {
            case first
            enum Inner: String { case nested }
            case second, third
        }
        """)
        let out = TokenReferenceExtractor.extract(tokens, file: 0, dialect: .swift, localizationMacros: [])
        let raw = out.references.compactMap { r -> String? in
            if case .implicitRawValue(let type) = r.kind { return "\(type).\(r.value)" } else { return nil }
        }
        XCTAssertEqual(raw, ["Outer.first", "Inner.nested", "Outer.second", "Outer.third"])
    }
}
