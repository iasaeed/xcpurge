import XCTest
@testable import XcpurgeKit

final class SwiftScannerTests: XCTestCase {
    private func literal(_ out: ScanOutput, _ value: String) -> Reference? {
        out.references.first { $0.kind == .stringLiteral && $0.value == value }
    }

    func testCallContextForAssetAndResourceCalls() {
        let out = SwiftScanner.scan("""
        let a = UIImage(named: "hero")
        let b = Image("logo", bundle: .module)
        let c = Bundle.main.url(forResource: "config", withExtension: "json")
        """)
        XCTAssertEqual(literal(out, "hero")?.context?.callee, "UIImage")
        XCTAssertEqual(literal(out, "hero")?.context?.label, "named")
        XCTAssertEqual(literal(out, "logo")?.context?.callee, "Image")
        XCTAssertEqual(literal(out, "logo")?.context?.bundle, ".module")
        XCTAssertEqual(literal(out, "config")?.context?.callee, "url")
        XCTAssertEqual(literal(out, "config")?.context?.label, "forResource")
        XCTAssertEqual(literal(out, "json")?.context?.label, "withExtension")
        XCTAssertEqual(literal(out, "json")?.context?.argIndex, 1)
    }

    func testLocalizationContextAndTableBackfill() {
        let out = SwiftScanner.scan("""
        Text("welcome")
        let s = String(localized: "key", table: "Settings", bundle: #bundle)
        let l = NSLocalizedString("legacy", tableName: "Legacy", comment: "c")
        let v = Text(verbatim: "raw")
        """)
        XCTAssertEqual(literal(out, "welcome")?.context?.isLocalization(), true)
        XCTAssertEqual(literal(out, "key")?.context?.isLocalization(), true)
        XCTAssertEqual(literal(out, "key")?.context?.table, "Settings")
        XCTAssertEqual(literal(out, "key")?.context?.bundle, "#bundle")
        XCTAssertEqual(literal(out, "legacy")?.context?.table, "Legacy")
        XCTAssertEqual(literal(out, "legacy")?.context?.isLocalization(), true)
        XCTAssertEqual(literal(out, "c")?.context?.isLocalization(), false)
        XCTAssertEqual(literal(out, "raw")?.context?.isLocalization(), false)
    }

    func testNestedCallsKeepTheirOwnContext() {
        let out = SwiftScanner.scan(#"Text(String(localized: "inner")).font(.custom("Brand-Regular", size: 14))"#)
        XCTAssertEqual(literal(out, "inner")?.context?.callee, "String")
        XCTAssertEqual(literal(out, "Brand-Regular")?.context?.callee, "custom")
    }

    func testMemberSymbolsCarryQualifier() {
        let out = SwiftScanner.scan("Image(.Brand.brandMark); let c = Asset.Colors.brand.color; let r = ImageResource.logo")
        let members = out.references.filter { $0.kind == .memberSymbol }
        XCTAssertEqual(members.first { $0.value == "brandMark" }?.context?.qualifier, "Brand")
        XCTAssertEqual(members.first { $0.value == "brandMark" }?.context?.callee, "Image")
        XCTAssertEqual(members.first { $0.value == "Brand" }?.context?.qualifier, "")
        XCTAssertEqual(members.first { $0.value == "brand" }?.context?.qualifier, "Asset.Colors")
        XCTAssertEqual(members.first { $0.value == "logo" }?.context?.qualifier, "ImageResource")
    }

    func testDynamicPatterns() {
        let out = SwiftScanner.scan("""
        Image("icon_\\(i)")
        let a = UIImage(named: "flag_" + code)
        let b = prefix + "_dark"
        let c = String(format: "img%02d@2x", n)
        let d = String(localized: "error_\\(code)")
        let e = Text(LocalizedStringKey(key))
        let f = "plain"
        """)
        let p = out.patterns
        XCTAssertTrue(p.contains { $0.prefix == "icon_" && $0.suffix == "" && $0.domain == .asset && $0.line == 1 })
        XCTAssertTrue(p.contains { $0.prefix == "flag_" && $0.domain == .asset })
        XCTAssertTrue(p.contains { $0.prefix == "" && $0.suffix == "_dark" && $0.domain == .any })
        XCTAssertTrue(p.contains { $0.prefix == "img" && $0.suffix == "@2x" })
        XCTAssertTrue(p.contains { $0.prefix == "error_" && $0.domain == .string })
        XCTAssertTrue(p.contains { $0.isKeyless && $0.domain == .string && $0.line == 6 })
        XCTAssertFalse(p.contains { $0.prefix == "plain" })
        XCTAssertNil(literal(out, "icon_"), "interpolated strings are patterns, not literals")
    }

    func testKeylessOnlyForVariableKeys() {
        let out = SwiftScanner.scan("Text(.welcomeTitle); Text(\"x\"); Button(title) {}")
        XCTAssertEqual(out.patterns.filter(\.isKeyless).count, 1)
        let typed = SwiftScanner.scan("Text(String(localized: \"k\")); Text(Date(), style: .date); Text(L10n.title)")
        XCTAssertEqual(typed.patterns.filter(\.isKeyless).count, 0, "arguments starting with a type name are not variable keys")
    }

    func testFormatParts() {
        XCTAssertEqual(TokenReferenceExtractor.formatParts("img%d")?.0, "img")
        XCTAssertEqual(TokenReferenceExtractor.formatParts("a%@b%lldc")?.1, "c")
        XCTAssertNil(TokenReferenceExtractor.formatParts("100%% sure"))
    }

    func testIdentifiersAndAttributes() {
        let out = SwiftScanner.scan("@objc final class Foo: Bar { #Preview {} }")
        let idents = Set(out.references.filter { $0.kind == .identifier }.map(\.value))
        XCTAssertTrue(idents.isSuperset(of: ["@objc", "Foo", "Bar", "#Preview", "class"]))
    }

    func testGeneratedFileIsNotAReferenceSource() {
        let out = SwiftScanner.scan("""
        // swiftlint:disable all
        // Generated using SwiftGen — https://github.com/SwiftGen/SwiftGen
        internal enum Asset {
          internal static let hero = ImageAsset(name: "hero")
        }
        """)
        XCTAssertTrue(out.isGenerated)
        XCTAssertTrue(out.references.isEmpty)
        XCTAssertEqual(out.accessors["Asset.hero"], "hero")
    }
}
