import XCTest
@testable import XcpurgeKit

/// False-positive classes from the second scan of open-source apps (rescan/REPORT2.md).
final class RescanFalsePositiveTests: XCTestCase {
    private var config: Config {
        var c = Config()
        c.noSwift = true
        return c
    }

    /// ios-oss: `localizedString(key:count:)` appends `"." + suffix` to the base key at runtime.
    func testPluralFamilyFollowsItsBaseKeyOrSibling() async throws {
        let root = try FixtureSupport.tempTree([
            "en.lproj/Localizable.strings": """
            "dates.hours.one" = "1 hour";
            "dates.hours.few" = "%d hours";
            "unused.count.one" = "1";
            "unused.count.few" = "%d";
            "greeting.one" = "Hi";
            "greeting.many" = "Hi all";
            "plain.one" = "x";
            """,
            "Strings.swift": """
            enum Strings {
                static func dates_hours(count: Int) -> String { localizedString(key: "dates.hours", count: count) }
                static func unused_count(count: Int) -> String { localizedString(key: "unused.count", count: count) }
            }
            """,
            "Use.swift": """
            let hours = Strings.dates_hours(count: 2)
            let hi = NSLocalizedString("greeting.one", comment: "")
            """,
        ])
        let findings = try await ScanEngine(root: root, config: config).run(categories: [.strings]).findings
        func finding(_ key: String) -> Finding? { findings.first { $0.name == key } }
        for key in ["dates.hours.one", "dates.hours.few", "greeting.many"] {
            let f = try XCTUnwrap(finding(key), key)
            XCTAssertEqual(f.confidence, .medium, key)
            XCTAssertTrue(ReasonCodes.codes(for: f).contains("plural-family"), "\(key): \(f.reasons)")
        }
        XCTAssertNil(finding("greeting.one"))
        XCTAssertEqual(finding("unused.count.one")?.confidence, .high, "the base accessor is never called")
        XCTAssertEqual(finding("plain.one")?.confidence, .high)
        XCTAssertEqual(StringsDetector.Evaluator.pluralBase("dates.hours.other"), "dates.hours")
        XCTAssertNil(StringsDetector.Evaluator.pluralBase("dates.hours.single"))
    }

    /// Signal `#imageLiteral(resourceName: "clock-12.pdf")`, vlc `imageName = @"NowPlaying@2x.png";`.
    func testAssetNamesWrittenWithAFileExtensionMatch() async throws {
        let root = try FixtureSupport.tempTree([
            "Assets.xcassets/Contents.json": "{}",
            "Assets.xcassets/clock-12.imageset/Contents.json": "{}",
            "Assets.xcassets/NowPlaying.imageset/Contents.json": "{}",
            "Assets.xcassets/config.dataset/Contents.json": "{}",
            "Assets.xcassets/unused_art.imageset/Contents.json": "{}",
            "Sticker.swift": """
            import UIKit
            let clock = #imageLiteral(resourceName: "clock-12.pdf")
            let data = NSDataAsset(name: "config.dataset")
            """,
            "Bar.m": """
            #import <UIKit/UIKit.h>
            void setup(UIButton *b) { NSString *imageName = @"NowPlaying@2x.png"; }
            """,
        ])
        let findings = AssetsDetector().run(try await ScanEngine(root: root, config: config).makeContext())
        let names = Set(findings.filter { $0.kind == .unusedAsset }.compactMap(\.name))
        XCTAssertEqual(names, ["unused_art"])
        XCTAssertEqual(ReferenceIndex.strippingImageExtension("clock-12.pdf"), "clock-12")
        XCTAssertEqual(ReferenceIndex.strippingImageExtension("NowPlaying@3x.PNG"), "NowPlaying")
        XCTAssertNil(ReferenceIndex.strippingImageExtension("report.txt"))
        XCTAssertNil(ReferenceIndex.strippingImageExtension("Images/icon.png"), "paths are matched by their tail elsewhere")
    }

    /// nextcloud `custom.person.3.circle.fill`: the dotted name with a digit component matches; the only use in that
    /// app sits inside a `/* … */` block, so the symbol set is rightly reported there.
    func testDottedNameWithDigitComponentMatchesOutsideComments() async throws {
        let root = try FixtureSupport.tempTree([
            "Assets.xcassets/Contents.json": "{}",
            "Assets.xcassets/custom.person.3.circle.fill.symbolset/Contents.json": "{}",
            "Assets.xcassets/custom.person.2.circle.fill.symbolset/Contents.json": "{}",
            "Cell.swift": """
            import UIKit
            let team = UIImage(named: "custom.person.3.circle.fill")
            /*
            let pair = UIImage(named: "custom.person.2.circle.fill")
            */
            """,
        ])
        let findings = AssetsDetector().run(try await ScanEngine(root: root, config: config).makeContext())
        let names = Set(findings.filter { $0.kind == .unusedAsset }.compactMap(\.name))
        XCTAssertEqual(names, ["custom.person.2.circle.fill"])
    }
}
