import XCTest
@testable import XcpurgeKit

final class StringsDetectorTests: XCTestCase {
    static let config = Config()

    func testModularWorkspaceGolden() async throws {
        try await assertFindings(fixture: "ModularWorkspace", category: .strings, config: Self.config)
    }

    /// Classic group, synchronized folder and blue folder reference in one project.
    func testMixedAppGolden() async throws {
        try await assertFindings(fixture: "MixedApp", category: .strings, config: Self.config)
    }

    func testSyncedAppGolden() async throws {
        try await assertFindings(fixture: "SyncedApp", category: .strings, config: Self.config)
    }

    func testStringsEdgeCasesGolden() async throws {
        try await assertFindings(fixture: "StringsEdgeCases", category: .strings, config: Self.config)
    }

    private func findings(_ fixture: String) async throws -> [String: Finding] {
        let ctx = try await FixtureSupport.context(fixture, config: Self.config)
        let all = StringsDetector().run(ctx).filter { $0.kind != .dynamicLookup }
        return Dictionary(all.map { ("\($0.module)/\($0.name ?? $0.path)", $0) }, uniquingKeysWith: { a, _ in a })
    }

    /// §4.2 step 5 narrowing on the ModularWorkspace: bundle and table arguments decide which table a literal hits.
    func testBundleNarrowingReasons() async throws {
        let f = try await findings("ModularWorkspace")
        XCTAssertNil(f["DesignSystem/ds_title"], "bundle: .module inside DesignSystem")
        XCTAssertNil(f["App/shared_key"], "App literal without bundle: hits the app's own table")
        XCTAssertTrue(f["DesignSystem/shared_key"]?.reasons.first?.contains("main bundle") == true)
        XCTAssertTrue(f["DesignSystem/ds_no_bundle"]?.reasons.first?.contains("likely wrong bundle") == true)
        XCTAssertNil(f["App/legacy_greeting"], "tableName: \"Legacy\"")
        XCTAssertNil(f["App/legacy_items"], "stringsdict key via tableName:")
        XCTAssertNil(f["App/onboarding.step.title"], "generated symbol .onboardingStepTitle")
        XCTAssertNil(f["App/NSCameraUsageDescription"])
        XCTAssertNil(f["App/Group"], "Settings.bundle title")
        XCTAssertEqual(f["App/old_banner"]?.line, 49)
    }

    func testEdgeCaseEvidence() async throws {
        let f = try await findings("StringsEdgeCases")
        for used in ["module_key", "hash_bundle_key", "symbol_used", "items_count", "feature_title", "table_key",
                     "Hello %@", "plural_used", "swiftgen_used", "rswift_used", "receiver_key", "nav_title",
                     "CFBundleDisplayName", "NSPhotoLibraryUsageDescription", "abc-12-def.text", "Shown",
                     "Open ${applicationName}", "%lld"] {
            XCTAssertNil(f["Feature/\(used)"], used)
        }
        XCTAssertEqual(f["Feature/stale_found"]?.kind, .staleString)
        XCTAssertEqual(f["Feature/stale_found"]?.confidence, .medium)
        XCTAssertEqual(f["Feature/zzz-99-zzz.normalTitle"]?.confidence, .high)
        XCTAssertEqual(f["Feature/status_ok"]?.confidence, .low)
        XCTAssertEqual(f["Feature/legacy_unused"]?.path, "Sources/Feature/Resources/en.lproj/Legacy.strings", "en preferred over fr")
    }

    /// Review #1: a storyboard over 5 MB is still scanned, so its object IDs keep `Main.strings` keys alive.
    func testLargeStoryboardIsScannedNotSkipped() async throws {
        let pad = String(repeating: "<!-- padding padding padding padding padding padding padding -->\n", count: 90_000)
        let root = try FixtureSupport.tempTree([
            "Base.lproj/Main.storyboard": "<?xml version=\"1.0\"?><document><objects><label id=\"abc-12-def\" text=\"Hi\"/>"
                + "</objects>\(pad)</document>",
            "fr.lproj/Main.strings": "\"abc-12-def.text\" = \"Salut\";\n\"zzz-99-zzz.text\" = \"Gone\";\n",
        ])
        var config = Config()
        config.noSwift = true
        let result = try await ScanEngine(root: root, config: config).run(categories: [.strings])
        XCTAssertGreaterThan(try FileManager.default.attributesOfItem(atPath: root.appendingPathComponent("Base.lproj/Main.storyboard").path)[.size] as? Int ?? 0,
                             Int(ReferenceIndex.maxFileSize))
        XCTAssertFalse(result.findings.contains { $0.name == "abc-12-def.text" }, "object ID exists in the large storyboard")
        XCTAssertEqual(result.findings.first { $0.name == "zzz-99-zzz.text" }?.confidence, .high)
        XCTAssertTrue(result.context.refs.skippedSources.isEmpty)
    }

    func testLargeTextIsStreamedNotSkipped() async throws {
        // Review 2 #2: a >5 MB JSON is scanned in chunks; its literals count and nothing is capped.
        let big = "[\"" + String(repeating: "x", count: Int(ReferenceIndex.maxFileSize)) + "\",\n \"keep_key\"]"
        let root = try FixtureSupport.tempTree([
            "en.lproj/Localizable.strings": "\"keep_key\" = \"A\";\n\"gone_key\" = \"B\";\n",
            "Big.json": big,
            "Vendor/Locked.json": "[\"x\"]",
        ])
        var config = Config()
        config.noSwift = true
        config.exclude = ["Vendor/**"]
        let locked = root.appendingPathComponent("Vendor/Locked.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
        let result = try await ScanEngine(root: root, config: config).run(categories: [.strings])
        XCTAssertEqual(result.context.refs.skippedSources.map(\.path), ["Vendor/Locked.json"], "only the unreadable file")
        XCTAssertTrue(result.context.refs.sites("keep_key").contains { result.context.refs.path(of: $0.file) == "Big.json" })
        XCTAssertEqual(result.findings.first { $0.name == "gone_key" }?.confidence, .high,
                       "an unreadable file under --exclude does not cap findings")
        XCTAssertNotEqual(result.findings.first { $0.name == "keep_key" }?.confidence, .high)
    }

    /// Review #1: an unreadable reference source caps findings at medium (it may hold the only use).
    func testUnreadableSourceCapsFindingsAtMedium() async throws {
        let root = try FixtureSupport.tempTree([
            "en.lproj/Localizable.strings": "\"maybe_key\" = \"A\";\n",
            "Locked.json": "[\"maybe_key\"]",
        ])
        let locked = root.appendingPathComponent("Locked.json").path
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: locked) }
        var config = Config()
        config.noSwift = true
        let result = try await ScanEngine(root: root, config: config).run(categories: [.strings])
        let finding = try XCTUnwrap(result.findings.first { $0.name == "maybe_key" })
        XCTAssertEqual(finding.confidence, .medium)
        XCTAssertTrue(finding.reasons.contains { $0.contains("source Locked.json skipped (unreadable)") }, "\(finding.reasons)")
    }

    /// Review #2: keys that start and end with an interpolation match by their middle segments; unmatched
    /// format keys are never high.
    func testInterpolationSegmentsMatchFormatKeys() async throws {
        let catalog = """
        {"sourceLanguage":"en","version":"1.0","strings":{
         "%lld of %lld":{"localizations":{"de":{"stringUnit":{"state":"translated","value":"%lld von %lld"}}}},
         "%1$@ and %2$@":{}, "Hello %@":{}, "%lld items left":{}, "100%% of %@":{}, "plain_unused":{}}}
        """
        let root = try FixtureSupport.tempTree([
            "Localizable.xcstrings": catalog,
            "V.swift": """
            import SwiftUI
            struct V: View { var body: some View { VStack {
                Text("\\(a) of \\(b)"); Text("\\(x) and \\(y)"); Text("Hello \\(name)"); Text("100% of \\(p)")
            } } }
            """,
        ])
        var config = Config()
        config.noSwift = true
        let result = try await ScanEngine(root: root, config: config).run(categories: [.strings])
        let byName = Dictionary(result.findings.map { ($0.name ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        for used in ["%lld of %lld", "%1$@ and %2$@", "Hello %@", "100%% of %@"] { XCTAssertNil(byName[used], used) }
        XCTAssertEqual(byName["%lld items left"]?.confidence, .medium, "format key without a match is never high")
        XCTAssertEqual(byName["plain_unused"]?.confidence, .high)
        XCTAssertFalse(result.findings.contains { $0.kind == .dynamicLookup }, "matched interpolations are not dynamic lookups")
    }

    /// Review #6: a dotted code key in a table named like a xib is not an object ID; code evidence decides.
    func testCodeKeysInInterfaceNamedTable() async throws {
        let root = try FixtureSupport.tempTree([
            "Onboarding.xib": "<?xml version=\"1.0\"?><document><objects><view id=\"aaa-bb-ccc\"/></objects></document>",
            "en.lproj/Onboarding.strings": "\"onboarding.title\" = \"Welcome\";\n\"onboarding.unused\" = \"x\";\n"
                + "\"aaa-bb-ccc.text\" = \"Hi\";\n\"zzz-99-zzz.text\" = \"Gone\";\n\"42.title\" = \"Old\";\n",
            "O.swift": "let t = NSLocalizedString(\"onboarding.title\", tableName: \"Onboarding\", comment: \"\")\n",
        ])
        var config = Config()
        config.noSwift = true
        let result = try await ScanEngine(root: root, config: config).run(categories: [.strings])
        let byName = Dictionary(result.findings.map { ($0.name ?? "", $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertNil(byName["onboarding.title"], "used from code via tableName:")
        XCTAssertNil(byName["aaa-bb-ccc.text"])
        XCTAssertEqual(byName["onboarding.unused"]?.reasons, ["no reference found"])
        XCTAssertTrue(byName["zzz-99-zzz.text"]?.reasons.first?.contains("object ID") == true)
        XCTAssertTrue(byName["42.title"]?.reasons.first?.contains("object ID") == true, "numeric IDs of old xibs")
        XCTAssertNil(IBStringsResolver.split("onboarding.title"))
        XCTAssertNotNil(IBStringsResolver.split("UIa-b2-C3d.normalTitle"))
    }

    /// Review #7: `--exclude` hides findings in excluded files but they still count as references.
    func testExcludedGeneratedCodeStillReferencesKeys() async throws {
        let generated = """
        // Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen
        internal enum L10n {
          internal static let welcomeTitle = L10n.tr("Localizable", "welcome_title", fallback: "Welcome")
          internal static let unusedTitle = L10n.tr("Localizable", "unused_title", fallback: "Unused")
        }
        """
        let root = try FixtureSupport.tempTree([
            "en.lproj/Localizable.strings": "\"welcome_title\" = \"Welcome\";\n\"unused_title\" = \"U\";\n",
            "Sources/Generated/Strings.swift": generated,
            "Sources/V.swift": "let t = L10n.welcomeTitle\n",
            "Sources/Generated/en.lproj/Extra.strings": "\"extra_unused\" = \"E\";\n",
        ])
        for exclude in [[String](), ["**/Generated/**"]] {
            var config = Config()
            config.noSwift = true
            config.exclude = exclude
            let names = try await ScanEngine(root: root, config: config).run(categories: [.strings]).findings.compactMap(\.name)
            XCTAssertFalse(names.contains("welcome_title"), "\(exclude)")
            XCTAssertTrue(names.contains("unused_title"), "\(exclude)")
            XCTAssertEqual(names.contains("extra_unused"), exclude.isEmpty, "findings inside excluded paths are hidden")
        }
    }

    /// Review #9: a bundle-less `NSLocalizedString` in DesignSystem (App depends on it) reads App's table.
    func testBundlelessLocalizationInDependencyReachesAppTable() async throws {
        let root = try FixtureSupport.copyToTemp("ModularWorkspace")
        let legacy = root.appendingPathComponent("App/App/en.lproj/Legacy.strings")
        let text = try String(contentsOf: legacy, encoding: .utf8)
        try Data((text + "\n\"ds_reads_app\" = \"From DS\";\n\"nobody_reads\" = \"x\";\n").utf8).write(to: legacy)
        try Data("""
        import Foundation
        let fromApp = NSLocalizedString("ds_reads_app", tableName: "Legacy", comment: "")
        let explicit = NSLocalizedString("nobody_reads", tableName: "Legacy", bundle: .module, comment: "")
        """.utf8).write(to: root.appendingPathComponent("Packages/DesignSystem/Sources/DesignSystem/ReadsApp.swift"))
        var config = Config()
        config.noSwift = true
        let findings = try await ScanEngine(root: root, config: config).run(categories: [.strings]).findings
        let key = try XCTUnwrap(findings.first { $0.name == "ds_reads_app" })
        XCTAssertEqual(key.confidence, .medium)
        XCTAssertTrue(key.reasons.contains { $0.contains("referenced from DesignSystem without a bundle") }, "\(key.reasons)")
        XCTAssertEqual(findings.first { $0.name == "nobody_reads" }?.confidence, .high)
    }

    func testDynamicLookupInfoFindings() async throws {
        let ctx = try await FixtureSupport.context("StringsEdgeCases", config: Self.config)
        let lookups = StringsDetector().run(ctx).filter { $0.kind == .dynamicLookup }
        // `"status_\(code)"` builds keys; `Text(title)` has no literal key; `Text("Hello \(name)")` is the existing
        // format key "Hello %@"; `Text(Date(), …)` and `Text(L10n.x)` start with a type name.
        XCTAssertEqual(Set(lookups.map { "\($0.line ?? 0):\($0.name ?? "-")" }), ["17:status_*", "24:-"])
    }

    func testInfoPlistAndIBHelpers() {
        XCTAssertTrue(SystemStringKeys.isSystemKey("NSCameraUsageDescription"))
        XCTAssertTrue(SystemStringKeys.isSystemKey("CFBundleDisplayName"))
        XCTAssertTrue(SystemStringKeys.isSystemKey("NFCReaderUsageDescription"))
        XCTAssertTrue(SystemStringKeys.isSystemKey("UIApplicationShortcutItemTitle"))
        XCTAssertFalse(SystemStringKeys.isSystemKey("RandomKey"))
        let terms = SystemStringKeys.infoPlistTerms(["NSLocationTemporaryUsageDescriptionDictionary": .object(["Purpose": .string("x")]),
                                                    "UIApplicationShortcutItems": .array([.object(["UIApplicationShortcutItemTitle": .string("Search")])])])
        XCTAssertTrue(terms.isSuperset(of: ["Purpose", "Search"]))
        XCTAssertEqual(IBStringsResolver.split("abc-12-def.normalTitle")?.id, "abc-12-def")
        XCTAssertNil(IBStringsResolver.split("welcome_title"))
        XCTAssertNil(IBStringsResolver.split("onboarding.1"))
    }

    func testLocalizationCallClassifier() {
        typealias C = LocalizationCallClassifier
        XCTAssertTrue(C.isLocalization(CallContext(callee: "Text")))
        XCTAssertFalse(C.isLocalization(CallContext(callee: "Text", label: "verbatim")))
        XCTAssertTrue(C.isLocalization(CallContext(callee: "String", label: "localized")))
        XCTAssertTrue(C.isLocalization(CallContext(callee: "NSLocalizedStringFromTableInBundle")))
        XCTAssertTrue(C.isLocalization(CallContext(callee: "accessibilityLabel")))
        XCTAssertTrue(C.isLocalization(CallContext(callee: "bundle", label: "localizedStringForKey")))
        XCTAssertTrue(C.isLocalization(CallContext(callee: "tr"), extraMacros: ["tr"]))
        XCTAssertFalse(C.isLocalization(CallContext(callee: "UIImage", label: "named")))
        XCTAssertFalse(C.isLocalization(nil))
        XCTAssertEqual(C.bundle(CallContext(callee: "Text", bundle: ".module")), .module)
        XCTAssertEqual(C.bundle(CallContext(callee: "String", bundle: "#bundle")), .module)
        XCTAssertEqual(C.bundle(CallContext(callee: "String", bundle: "Bundle.main")), .main)
        XCTAssertEqual(C.bundle(CallContext(callee: "String")), .none)
        XCTAssertEqual(C.bundle(CallContext(callee: "String", bundle: "Bundle(for:")), .other)
        XCTAssertEqual(C.bundle(CallContext(callee: "localizedString", label: "forKey")), .other)
    }

    /// Unattributed loose files: everything is `.unknown`, main bundle, no narrowing.
    func testUnattributedTree() async throws {
        let root = try FixtureSupport.tempTree([
            "Localizable.xcstrings": #"{"sourceLanguage":"en","strings":{"used":{},"unused":{"extractionState":"manual"},"%@":{}},"version":"1.0"}"#,
            "en.lproj/Other.strings": "\"o_used\" = \"x\";\n\"o_loose\" = \"y\";\n",
            "View.swift": """
            let a = NSLocalizedString("used", comment: "")
            let b = NSLocalizedString("o_used", tableName: "Other", comment: "")
            let c = NSLocalizedString("o_loose", comment: "")
            """,
        ])
        defer { try? FileManager.default.removeItem(at: root) }
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        let rows = Set(StringsDetector().run(ctx).map { "\($0.name ?? "-") \($0.confidence.rawValue)" })
        XCTAssertEqual(rows, ["unused high", "o_loose medium"])
    }
}
