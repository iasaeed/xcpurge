import XCTest
@testable import XcpurgeKit

/// Expected names were produced by `xcrun xcstringstool generate-symbols` (Xcode 26) on the same keys.
final class StringSymbolManglerTests: XCTestCase {
    func testSymbolsMatchXcstringstool() {
        let cases: [(String, String?)] = [
            ("Star", "star"), ("japan-street", "japanStreet"), ("my-icon_2", "myIcon2"), ("2fa", "_2Fa"),
            ("default", "default"), ("ABCLogo", "abclogo"), ("URL", "url"), ("logo.dark", "logoDark"), ("a--b", "aB"),
            ("über_icon", "überIcon"), ("_private", "_Private"), ("icon 2x", "icon2X"), ("IMG_0042", "img0042"),
            ("onboarding.step.title", "onboardingStepTitle"), ("Hello %@", "hello"), ("welcome_title", "welcomeTitle"),
            ("HTTPServer", "httpserver"), ("userID", "userID"), ("Hello, world!", "helloWorld"),
            ("count: %lld", "count"), ("Settings/General", "settingsGeneral"), ("x.y.z", "xYZ"),
            ("HelloWorld", "helloWorld"), ("MyKey", "myKey"), ("ABC", "abc"), ("aBC", "aBC"), ("A", "a"),
            ("Ünter", "ünter"), ("ÄBC", "äbc"), ("key with %d and %@ more", "keyWithAndMore"),
            ("multiple__under", "multipleUnder"), ("trailing_", "trailing"), ("e2e_test", "e2ETest"), ("v2", "v2"),
            ("x2y", "x2Y"), ("a1b2", "a1B2"), ("__double", "_Double"), ("_", "_"), ("My_URL_Key", "myUrlKey"),
            ("fooBAR", "fooBAR"), ("foo_BAR", "fooBar"), ("Zoo.Bar", "zooBar"), ("iOS_version", "iOSVersion"),
            ("%lld items", "items"), ("Ok", "ok"), ("already_Camel", "alreadyCamel"), ("camelCase", "camelCase"),
            ("%@", nil), ("self", nil), ("Type", nil), ("", nil),
        ]
        for (key, expected) in cases {
            XCTAssertEqual(StringSymbolMangler.symbol(forKey: key), expected, key)
        }
    }

    func testTableNamespace() {
        XCTAssertEqual(StringSymbolMangler.tableNamespace("Feature-Strings"), "FeatureStrings")
        XCTAssertEqual(StringSymbolMangler.tableNamespace("my_table.name"), "MyTableName")
        XCTAssertEqual(StringSymbolMangler.tableNamespace("HTTPErrors"), "HTTPErrors")
    }

    func testFormatSpecifiers() {
        XCTAssertTrue(StringSymbolMangler.hasFormatSpecifiers("Step %lld"))
        XCTAssertTrue(StringSymbolMangler.hasFormatSpecifiers("%1$@ and %2$@"))
        XCTAssertTrue(StringSymbolMangler.hasFormatSpecifiers("%.2f%%"))
        XCTAssertTrue(StringSymbolMangler.hasFormatSpecifiers("%#@files@"))
        XCTAssertFalse(StringSymbolMangler.hasFormatSpecifiers("100%% sure"))
        XCTAssertFalse(StringSymbolMangler.hasFormatSpecifiers("plain"))
        XCTAssertTrue(StringSymbolMangler.isFormatOnly("%@"))
        XCTAssertTrue(StringSymbolMangler.isFormatOnly("%lld: %@"))
        XCTAssertFalse(StringSymbolMangler.isFormatOnly("Hello %@"))
        XCTAssertFalse(StringSymbolMangler.isFormatOnly("plain"))
        XCTAssertEqual(StringSymbolMangler.formatAffixes("Hello %@!")?.prefix, "Hello ")
        XCTAssertEqual(StringSymbolMangler.formatAffixes("%lld of %lld items")?.suffix, " items")
        XCTAssertNil(StringSymbolMangler.formatAffixes("plain"))
    }
}
