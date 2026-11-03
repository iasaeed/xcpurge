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

    /// The prefix index matches one-, two- and long-prefix patterns alike (keys are up to three characters).
    func testPrefixIndexMatchesShortAndLongPrefixes() async throws {
        let root = try FixtureSupport.tempTree([
            "Assets.xcassets/Contents.json": "{}",
            "Assets.xcassets/x9.imageset/Contents.json": "{}",
            "Assets.xcassets/ab7.imageset/Contents.json": "{}",
            "Assets.xcassets/onboarding_page_2.imageset/Contents.json": "{}",
            "Assets.xcassets/other.imageset/Contents.json": "{}",
            "Art.swift": """
            import UIKit
            func a(_ n: Int) -> UIImage? { UIImage(named: "x\\(n)") }
            func b(_ n: Int) -> UIImage? { UIImage(named: "ab\\(n)") }
            let page = "onboarding_page\\(2)"
            """,
        ])
        let found = AssetsDetector().run(try await ScanEngine(root: root, config: config).makeContext())
        let byName = Dictionary(uniqueKeysWithValues: found.filter { $0.kind == .unusedAsset }.map { ($0.name!, $0.confidence) })
        XCTAssertEqual(byName["x9"], .low)
        XCTAssertEqual(byName["ab7"], .low)
        XCTAssertEqual(byName["onboarding_page_2"], .low)
        XCTAssertEqual(byName["other"], .high)
    }

    /// `NSImage(named: code.lowercased() + "-large")` in a package: the literal suffix builds names in the app's
    /// catalog, but only when the lookup reads the main bundle.
    func testAnchoredSuffixesLowerCatalogsOfOtherModules() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        for name in ["de-large", "plain_other"] { try addImageSet(name, in: root) }
        try write("""
        import AppKit
        public func flag(_ code: String) -> NSImage? { NSImage(named: code.lowercased() + "-large") }
        """, to: "Packages/Core/Sources/Core/Flags.swift", in: root)

        var findings = try await assets(root)
        let flag = try XCTUnwrap(findings.first { $0.name == "de-large" })
        XCTAssertEqual(flag.confidence, .low)
        XCTAssertTrue(flag.reasons.contains { $0.contains("Flags.swift:2") && $0.contains("\"…-large\"") }, "\(flag.reasons)")
        XCTAssertEqual(findings.first { $0.name == "plain_other" }?.confidence, .high)

        try write("""
        import AppKit
        public func flag(_ code: String) -> NSImage? { NSImage(named: code.lowercased() + "-large", in: .module, compatibleWith: nil) }
        """, to: "Packages/Core/Sources/Core/Flags.swift", in: root)
        findings = try await assets(root)
        XCTAssertEqual(findings.first { $0.name == "de-large" }?.confidence, .high, "an explicit .module bundle is not the app's")
    }

    /// A fully interpolated `Image("\(path)\(code)")` in a package reads the app bundle: medium, with a lookup record.
    func testKeylessLookupInADependencyReachesTheAppCatalog() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try addImageSet("flag_de", in: root)
        try write("""
        import SwiftUI
        public func flag(_ folder: String, _ code: String) -> some View {
            let path = folder + code.lowercased()
            return Image("\\(path)\\(code)")
        }
        """, to: "Packages/Core/Sources/Core/Flags.swift", in: root)

        var findings = try await assets(root)
        let flag = try XCTUnwrap(findings.first { $0.name == "flag_de" })
        XCTAssertEqual(flag.confidence, .medium)
        XCTAssertTrue(flag.reasons.contains { $0.contains("Flags.swift:4 (name passed as a variable)") }, "\(flag.reasons)")
        XCTAssertTrue(findings.contains { $0.kind == .dynamicLookup && $0.path.hasSuffix("Flags.swift") })

        try write("""
        import SwiftUI
        public func flag(_ folder: String, _ code: String) -> some View {
            let path = folder + code.lowercased()
            return Image("\\(path)\\(code)", bundle: .module)
        }
        """, to: "Packages/Core/Sources/Core/Flags.swift", in: root)
        findings = try await assets(root)
        XCTAssertEqual(findings.first { $0.name == "flag_de" }?.confidence, .high, "an explicit .module bundle is not the app's")
    }

    /// `"\(iconName)-Preview"` with `case red = "AppIcon-Red"`: the enum's raw value is the dynamic middle.
    func testEnumRawValuesCompleteAffixPatterns() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        for name in ["AppIcon-Red-Preview", "AppIcon-Green-Preview"] { try addImageSet(name, in: root) }
        try write("""
        import UIKit
        public enum AppIconOption: String {
            case blue = "AppIcon-Blue"
            case red = "AppIcon-Red"
        }
        public func preview(_ iconName: String) -> UIImage? { UIImage(named: "\\(iconName)-Preview") }
        """, to: "Packages/Core/Sources/Core/Icons.swift", in: root)

        let findings = try await assets(root)
        XCTAssertNil(findings.first { $0.name == "AppIcon-Red-Preview" }, "built from AppIcon-Red")
        let green = try XCTUnwrap(findings.first { $0.name == "AppIcon-Green-Preview" })
        XCTAssertEqual(green.confidence, .low)
        XCTAssertTrue(green.reasons.contains { $0.contains("Icons.swift:6") && $0.contains("built dynamically") }, "\(green.reasons)")
    }

    /// A suffix on a non-lookup (`print("\(e)_selected")`) says nothing about asset names in another module.
    func testSuffixOnANonLookupStaysModuleLocal() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try addImageSet("tab_selected", in: root)
        try write("""
        public func log(_ e: String) { print("\\(e)_selected") }
        """, to: "Packages/Core/Sources/Core/Log.swift", in: root)

        let findings = try await assets(root)
        XCTAssertEqual(findings.first { $0.name == "tab_selected" }?.confidence, .high, "Core cannot see the app's catalog")
    }

    /// `UIImage(named: "dPad-" + d, in: .module, …)` and `#bundle` lookups never reach the app's catalog; the same
    /// lookup on the main bundle does.
    func testPrefixedAndKeylessLookupsHonourTheBundle() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        for name in ["dPad-Up", "flag_de"] { try addImageSet(name, in: root) }
        func core(_ body: String) throws {
            try write("import SwiftUI\nimport UIKit\n" + body, to: "Packages/Core/Sources/Core/Pad.swift", in: root)
        }
        try core("""
        public func pad(_ d: String) -> UIImage? { UIImage(named: "dPad-" + d, in: .module, compatibleWith: nil) }
        public func flag(_ code: String) -> Image { Image("flag_\\(code)", bundle: #bundle) }
        """)
        var findings = try await assets(root)
        XCTAssertEqual(findings.first { $0.name == "dPad-Up" }?.confidence, .high, ".module stays in Core")
        XCTAssertEqual(findings.first { $0.name == "flag_de" }?.confidence, .high, "#bundle stays in Core")

        try core("""
        public func pad(_ d: String) -> UIImage? { UIImage(named: "dPad-" + d, in: .main, compatibleWith: nil) }
        public func flag(_ code: String) -> Image { Image("flag_\\(code)") }
        """)
        findings = try await assets(root)
        XCTAssertEqual(findings.first { $0.name == "dPad-Up" }?.confidence, .low, "the main bundle is the app's")
        XCTAssertEqual(findings.first { $0.name == "flag_de" }?.confidence, .low)

        try core("""
        public func flag(_ folder: String, _ code: String) -> Image {
            let path = folder + code.lowercased()
            return Image("\\(path)\\(code)", bundle: #bundle)
        }
        """)
        findings = try await assets(root)
        XCTAssertEqual(findings.first { $0.name == "flag_de" }?.confidence, .high, "a keyless #bundle lookup stays in Core")
    }

    /// The real shape: a computed property (no call) `"\(iconName)-Preview"` plus the enum's explicit raw values.
    func testComputedPropertyWithEnumRawValuesIsUsed() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        for name in ["AppIcon-Red-Preview", "AppIcon-Green-Preview"] { try addImageSet(name, in: root) }
        try write("""
        public enum AppIconOption: String {
            case blue = "AppIcon-Blue"
            case red = "AppIcon-Red"
        }
        public struct IconPicker {
            public var iconName = "AppIcon-Blue"
            public var previewImageName: String { "\\(iconName)-Preview" }
        }
        """, to: "Packages/Core/Sources/Core/Icons.swift", in: root)

        let findings = try await assets(root)
        XCTAssertNil(findings.first { $0.name == "AppIcon-Red-Preview" }, "built from AppIcon-Red")
        let green = try XCTUnwrap(findings.first { $0.name == "AppIcon-Green-Preview" })
        XCTAssertEqual(green.confidence, .low, "a bare computed property with a distinctive suffix anchors in any module")
    }

    /// `CodingKeys` raw values are wire keys, not asset names; they must not hide an unused `settings_icon`.
    func testCodingKeysRawValuesDoNotCompleteAffixPatterns() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try addImageSet("settings_icon", in: root)
        try write("""
        import UIKit
        struct Payload: Codable {
            var s: String
            enum CodingKeys: String, CodingKey { case s = "settings" }
        }
        public func icon(_ n: String) -> UIImage? { UIImage(named: "\\(n)_icon") }
        """, to: "Packages/Core/Sources/Core/Payload.swift", in: root)

        let all = try await assets(root)
        let settings = try XCTUnwrap(all.first { $0.name == "settings_icon" })
        XCTAssertEqual(settings.confidence, .low, "reported at low, not dropped: \(settings.reasons)")
    }

    /// An enum a pattern's module cannot see does not complete it (the app declares it; Core cannot use it).
    func testEnumRawValuesFromAnInvisibleModuleDoNotCompletePatterns() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try addImageSet("AppIcon-Red-Preview", in: root)
        try write("""
        enum AppIconOption: String { case red = "AppIcon-Red" }
        """, to: "App/App/AppIcons.swift", in: root)
        try write("""
        import UIKit
        public func preview(_ iconName: String) -> UIImage? { UIImage(named: "\\(iconName)-Preview") }
        """, to: "Packages/Core/Sources/Core/Icons.swift", in: root)

        let all = try await assets(root)
        let red = try XCTUnwrap(all.first { $0.name == "AppIcon-Red-Preview" })
        XCTAssertEqual(red.confidence, .low)
    }

    /// `explain` lists keyless asset lookups only where they can load the asset's catalog: a `.module` lookup in a
    /// package is not one.
    func testExplainListsOnlyReachingKeylessLookups() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        try addImageSet("flag_de", in: root)
        func core(_ lookup: String) throws {
            try write("""
            import SwiftUI
            public func flag(_ folder: String, _ code: String) -> some View {
                let path = folder + code.lowercased()
                return \(lookup)
            }
            """, to: "Packages/Core/Sources/Core/Flags.swift", in: root)
        }
        try core(#"Image("\(path)\(code)", bundle: .module)"#)
        var report = try await Explainer.explain(subject: "flag_de", root: root, config: config)
        XCTAssertEqual(report.matches.first?.dynamicPatterns.count, 0, "\(report.matches.first?.dynamicPatterns ?? [])")

        try core(#"Image("\(path)\(code)")"#)
        report = try await Explainer.explain(subject: "flag_de", root: root, config: config)
        XCTAssertEqual(report.matches.first?.dynamicPatterns.map(\.path), ["Packages/Core/Sources/Core/Flags.swift"])
    }
}
