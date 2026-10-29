import XCTest
@testable import XcpurgeKit

/// Plan §4.3 unit cases for generated asset-symbol names.
final class AssetSymbolManglerTests: XCTestCase {
    private func first(_ leaf: String, _ type: AssetType = .image) -> String {
        AssetSymbolMangler.symbols(leaf: leaf, type: type).first ?? ""
    }

    func testPlanCases() {
        let cases: [(String, String)] = [
            ("Star", "star"), ("japan-street", "japanStreet"), ("my-icon_2", "myIcon2"), ("2fa", "_2fa"),
            ("default", "default"), ("ABCLogo", "abcLogo"), ("URL", "url"), ("logo.dark", "logoDark"),
            ("a--b", "aB"), ("über_icon", "überIcon"), ("_private", "private"), ("icon 2x", "icon2X"),
            ("IMG_0042", "img0042"),
        ]
        for (name, symbol) in cases {
            XCTAssertEqual(first(name), symbol, name)
        }
    }

    func testKeywordGetsBacktickedTwin() {
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "default"), ["default", "`default`"])
    }

    func testColorAndImageSuffixesAreStripped() {
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "brandColor", type: .color), ["brandColor", "brand"])
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "noImage", type: .image), ["noImage", "no"])
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "LaunchImage", type: .image), ["launchImage", "launch"])
        // Only the matching set type strips, and never down to nothing.
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "brandColor", type: .image), ["brandColor"])
        XCTAssertEqual(AssetSymbolMangler.symbols(leaf: "Color", type: .color), ["color"])
    }

    func testNamespaceChain() {
        let symbols = AssetSymbolMangler.symbols(leaf: "logo", type: .image, namespace: ["Icons", "Settings"])
        XCTAssertEqual(symbols, ["logo", "Icons.Settings.logo"])
        XCTAssertTrue(AssetSymbolMangler.symbols(leaf: "x", namespace: ["my-icons"]).contains("MyIcons.x"))
    }

    func testObjCSymbolsAndFuzzyKey() {
        XCTAssertEqual(AssetSymbolMangler.objcSymbol(leaf: "LaunchImage", type: .image), "ACImageNameLaunchImage")
        XCTAssertEqual(AssetSymbolMangler.objcSymbol(leaf: "brand-tint", type: .color), "ACColorNameBrandTint")
        XCTAssertNil(AssetSymbolMangler.objcSymbol(leaf: "x", type: .data))
        XCTAssertEqual(AssetSymbolMangler.fuzzyKey("brand_mark"), AssetSymbolMangler.fuzzyKey("brandMark"))
    }
}
