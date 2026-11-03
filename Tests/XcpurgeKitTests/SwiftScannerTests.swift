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

    func testNamedWrapperIsAnAssetLookupButResourceLoadersAreNot() {
        let out = SwiftScanner.scan("""
        let a = utility.loadImage(named: "a")
        let b = SCNScene(named: "level.scn")
        let c = NSSound(named: "ping")
        """)
        XCTAssertEqual(literal(out, "a")?.context?.isAssetLookup, true)
        XCTAssertEqual(literal(out, "a")?.context?.isResourceLookup, false)
        XCTAssertEqual(literal(out, "level.scn")?.context?.isAssetLookup, false)
        XCTAssertEqual(literal(out, "level.scn")?.context?.isResourceLookup, true)
        XCTAssertEqual(literal(out, "ping")?.context?.isResourceLookup, true)
        XCTAssertEqual(DynamicPattern.domain(for: literal(out, "a")?.context), .asset)
        XCTAssertEqual(DynamicPattern.domain(for: literal(out, "level.scn")?.context), .resource)
        let patterns = SwiftScanner.scan(#"let a = SCNScene(named: "lvl_\(n)"); let b = wrap(named: "img_\(n)")"#).patterns
        XCTAssertEqual(patterns.first { $0.prefix == "lvl_" }?.domain, .resource)
        XCTAssertEqual(patterns.first { $0.prefix == "img_" }?.domain, .asset)
    }

    func testLiteralConcatenationIsFolded() {
        let out = SwiftScanner.scan("""
        let a = UIImage(named: "more" + "-20")
        let b = UIImage(named: "a" + "b" + "c")
        let c = UIImage(named: "pre" + "fix_" + kind)
        let d = UIImage(named: kind + "_x" + "yz")
        """)
        let folded = literal(out, "more-20")
        XCTAssertEqual(folded?.context?.callee, "UIImage")
        XCTAssertEqual(folded?.context?.label, "named")
        XCTAssertEqual(folded?.context?.isAssetLookup, true)
        XCTAssertNotNil(literal(out, "abc"))
        XCTAssertNil(literal(out, "ab"), "only the whole chain is folded")
        XCTAssertTrue(out.patterns.contains { $0.prefix == "prefix_" && $0.domain == .asset })
        XCTAssertFalse(out.patterns.contains { $0.prefix == "fix_" }, "the folded chain, not its last literal, is the prefix")
        XCTAssertTrue(out.patterns.contains { $0.suffix == "_xyz" })
        XCTAssertFalse(out.patterns.contains { $0.suffix == "_x" })
    }

    func testChainIntoInterpolationFoldsIntoThePrefix() {
        let out = SwiftScanner.scan(#"""
        let a = UIImage(named: "a" + "b" + "\(k)")
        let b = UIImage(named: "x" + "\(k)")
        """#)
        XCTAssertNil(literal(out, "ab"), "the chain is not the constant `ab`")
        XCTAssertNil(literal(out, "xy"))
        let a = out.patterns.filter { $0.line == 1 }
        XCTAssertEqual(a.map(\.prefix), ["ab"], "one pattern, the whole chain as its prefix")
        XCTAssertEqual(a.first?.domain, .asset)
        XCTAssertEqual(a.first?.segments, ["ab", ""])
        XCTAssertEqual(out.patterns.filter { $0.line == 2 }.map(\.prefix), ["x"])
    }

    func testResourceNameWithNestedCallLiteralsStillMakesAPattern() {
        let out = SwiftScanner.scan("""
        let a = Bundle.main.url(forResource: name.replacingOccurrences(of: " ", with: "-"), withExtension: "mp4")
        let b = Bundle.main.url(forResource: flag ? "on" : "off", withExtension: "mp4")
        """)
        let resource = out.patterns.filter { $0.domain == .resource }
        XCTAssertEqual(resource.first { $0.line == 1 }?.suffix, ".mp4")
        XCTAssertTrue(resource.filter { $0.line == 2 }.isEmpty, "literals of the argument itself are indexed instead")
    }

    func testSelfPropertyIsAResourceName() {
        let out = SwiftScanner.scan("""
        let a = Bundle.main.url(forResource: self.video, withExtension: "mp4")
        let b = Bundle.main.url(forResource: self, withExtension: "mp4")
        """)
        let resource = out.patterns.filter { $0.domain == .resource }
        XCTAssertEqual(resource.first { $0.line == 1 }?.suffix, ".mp4")
        XCTAssertTrue(resource.filter { $0.line == 2 }.isEmpty, "a bare `self` is not a name")
    }

    func testVariableResourceNameGetsTheCallsExtensionAsSuffix() {
        let out = SwiftScanner.scan("""
        let a = Bundle.main.url(forResource: title.bundleName, withExtension: "mp4")
        let b = Bundle.main.path(forResource: name, ofType: ".json", inDirectory: "Data")
        let c = Bundle.main.url(forResource: "\\(page)", withExtension: "html")
        let d = Bundle.main.url(forResource: other, withExtension: ext)
        let e = Bundle.main.url(forResource: "fixed", withExtension: "txt")
        let f = Bundle.main.url(forResource: "\\(chapter).html", withExtension: nil)
        """)
        let resource = out.patterns.filter { $0.domain == .resource }
        let mp4 = resource.first { $0.line == 1 }
        XCTAssertEqual(mp4?.suffix, ".mp4")
        XCTAssertEqual(mp4?.prefix, "")
        XCTAssertEqual(mp4?.segments, ["", ".mp4"])
        XCTAssertEqual(mp4?.hasAnchoredSuffix, false)
        XCTAssertEqual(mp4?.context?.label, "forResource")
        XCTAssertEqual(resource.first { $0.line == 2 }?.suffix, ".json")
        XCTAssertEqual(resource.first { $0.line == 3 }?.suffix, ".html")
        XCTAssertTrue(resource.filter { $0.line == 4 }.isEmpty, "a call without a literal extension makes no pattern")
        XCTAssertTrue(resource.filter { $0.line == 5 }.isEmpty)
        XCTAssertFalse(resource.contains { $0.isKeyless })
        let interpolated = resource.first { $0.line == 6 }
        XCTAssertEqual(interpolated?.suffix, ".html")
        XCTAssertTrue(interpolated?.couldBuild("intro.html") == true)
    }

    func testPlainNameBoundToLiteralsMakesNoResourcePattern() {
        let out = SwiftScanner.scan("""
        let name = "data"
        let a = Bundle.main.url(forResource: name, withExtension: "json")
        """)
        XCTAssertTrue(out.patterns.isEmpty)
    }

    func testExplicitRawValueLiteralCarriesTheEnumContext() {
        let out = SwiftScanner.scan("""
        enum Icon: String {
            case blue = "AppIcon-Blue"
            case red, green = "AppIcon-Green"
            case plain
        }
        let x = UIImage(named: "AppIcon-Blue")
        """)
        let tagged = out.references.filter { $0.kind == .stringLiteral && $0.value == "AppIcon-Blue" }
        XCTAssertEqual(tagged.count, 2)
        XCTAssertEqual(tagged.first?.context?.callee, "enum Icon")
        XCTAssertEqual(tagged.first?.context?.label, "rawValue")
        XCTAssertEqual(tagged.first?.context?.isAssetLookup, false)
        XCTAssertEqual(tagged.first?.context?.isLocalization(), false)
        XCTAssertEqual(tagged.last?.context?.callee, "UIImage")
        XCTAssertEqual(literal(out, "AppIcon-Green")?.context?.callee, "enum Icon")
        XCTAssertTrue(out.references.contains { $0.kind == .implicitRawValue("Icon") && $0.value == "plain" })
    }

    func testHasAnchoredSuffix() {
        func anchored(_ suffix: String) -> Bool { DynamicPattern(prefix: "", suffix: suffix, file: 0, line: 0, domain: .any).hasAnchoredSuffix }
        XCTAssertTrue(anchored("-large"))
        XCTAssertTrue(anchored("-Preview"))
        XCTAssertTrue(anchored("@2x"))
        XCTAssertTrue(anchored("-20.png"), "core `-20` has three characters")
        XCTAssertFalse(anchored(".mp4"))
        XCTAssertFalse(anchored(".html"))
        XCTAssertFalse(anchored("_x"))
        XCTAssertFalse(anchored("_x.png"))
        XCTAssertFalse(anchored(""))
    }

    func testNamedLabelOfTestHelpersIsNotAnAssetLookup() {
        let out = SwiftScanner.scan("""
        XCTContext.runActivity(named: "act") { _ in }
        assertSnapshot(of: v, as: .image, named: "snap")
        let a = UIImage(named: "hero")
        """)
        XCTAssertEqual(literal(out, "act")?.context?.isAssetLookup, false)
        XCTAssertEqual(literal(out, "snap")?.context?.isAssetLookup, false)
        XCTAssertEqual(literal(out, "hero")?.context?.isAssetLookup, true)
        XCTAssertFalse(CallContext(callee: "XCTContext.runActivity", label: "named").isAssetLookup)
        XCTAssertTrue(CallContext(callee: "loadImage", label: "named").isAssetLookup)
    }
}
