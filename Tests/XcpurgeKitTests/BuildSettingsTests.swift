import XCTest
@testable import XcpurgeKit

final class BuildSettingsTests: XCTestCase {
    func testLayeringInheritedAndExpansion() {
        let resolved = BuildSettings.resolve(
            layers: [["FLAGS": "-a", "NAME": "Base"], ["FLAGS": "$(inherited) -b", "TITLE": "${NAME} App"],
                     ["FLAGS": "$(inherited) -c", "PRODUCT_NAME": "My-App 2"]],
            builtins: ["TARGET_NAME": "T", "PRODUCT_MODULE_NAME": "$(PRODUCT_NAME:c99extidentifier)"])
        XCTAssertEqual(resolved["FLAGS"], "-a -b -c")
        XCTAssertEqual(resolved["TITLE"], "Base App")
        XCTAssertEqual(resolved["PRODUCT_MODULE_NAME"], "My_App_2")
    }

    func testConditionalKeysOnlyFillGaps() {
        let r = BuildSettings.resolve(layers: [["A[sdk=iphoneos*]": "cond", "B": "plain", "B[sdk=macosx*]": "mac"]], builtins: [:])
        XCTAssertEqual(r["A"], "cond")
        XCTAssertEqual(r["B"], "plain")
    }

    func testOperatorsAndUnknownVariables() {
        let s = ["N": "Hello World", "EMPTY": ""]
        XCTAssertEqual(BuildSettings.expand("$(N:lower)", in: s), "hello world")
        XCTAssertEqual(BuildSettings.expand("$(N:rfc1034identifier)", in: s), "Hello-World")
        XCTAssertEqual(BuildSettings.expand("x$(MISSING)y", in: s), "xy")
        XCTAssertEqual(BuildSettings.expand("$(EMPTY:default=fallback)", in: s), "fallback")
        XCTAssertEqual(BuildSettings.expand("$(LOOP)", in: ["LOOP": "$(LOOP)"]), "", "self-reference terminates")
        XCTAssertEqual(BuildSettings.c99Identifier("2fa-app"), "_2fa_app")
    }

    func testListValuesUnionAcrossConfigurations() {
        let s = BuildSettings(configurations: [
            "Debug": ["ICONS": "AppIcon \"Beta Icon\"", "GEN": "NO"],
            "Release": ["ICONS": "AppIcon Holiday", "GEN": "YES"],
        ])
        XCTAssertEqual(s.values("ICONS"), ["AppIcon", "Beta Icon", "Holiday"])
        XCTAssertTrue(s.isEnabled("GEN"))
        XCTAssertEqual(s.preferredConfiguration, "Release")
        XCTAssertEqual(s.value("ICONS"), "AppIcon Holiday")
    }

    func testXCConfigIncludesAndInherited() throws {
        let dir = try FixtureSupport.tempTree([
            "Base.xcconfig": "#include \"Common.xcconfig\"\n#include? \"Missing.xcconfig\"\nFLAGS = $(inherited) -base // comment\n",
            "Common.xcconfig": "FLAGS = -common\nSWIFT_VERSION = 6.0;\n#include \"Base.xcconfig\"\n",
        ])
        let diagnostics = Diagnostics()
        let parsed = XCConfigParser.parse(url: dir.appendingPathComponent("Base.xcconfig"), diagnostics: diagnostics)
        XCTAssertEqual(parsed.settings["FLAGS"], "-common -base")
        XCTAssertEqual(parsed.settings["SWIFT_VERSION"], "6.0")
        XCTAssertEqual(parsed.files.map(\.lastPathComponent), ["Base.xcconfig", "Common.xcconfig"])
        XCTAssertTrue(diagnostics.entries.isEmpty, "optional include and include cycle are silent: \(diagnostics.entries)")
        XCTAssertEqual(XCConfigParser.parse(text: "A = $(inherited) x")["A"], "$(inherited) x")
    }

    func testInfoPlistReaderRequiresGenerateForKeys() {
        let off = BuildSettings(configurations: ["Release": ["INFOPLIST_KEY_UILaunchStoryboardName": "Launch"]])
        XCTAssertTrue(InfoPlistReader.read(settings: off, projectDir: "/nowhere").plist.isEmpty)
        let on = BuildSettings(configurations: ["Release": ["INFOPLIST_KEY_UILaunchStoryboardName": "Launch",
                                                             "GENERATE_INFOPLIST_FILE": "YES"]])
        XCTAssertEqual(InfoPlistReader.read(settings: on, projectDir: "/nowhere").plist["UILaunchStoryboardName"], .string("Launch"))
    }
}
