import XCTest
@testable import XcpurgeKit

final class StringsDetectorTests: XCTestCase {
    static let config = Config()

    func testModularWorkspaceGolden() async throws {
        try await assertFindings(fixture: "ModularWorkspace", category: .strings, config: Self.config)
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
