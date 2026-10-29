import XCTest
@testable import XcpurgeKit

final class PlistScannerTests: XCTestCase {
    func testInfoPlistValuesWithKeyContextAndLines() throws {
        let data = try Data(contentsOf: FixtureSupport.fixtureURL("ModularWorkspace/App/App/Info.plist"))
        let out = PlistScanner.scan(data, file: 7)
        let byValue = Dictionary(out.references.map { ($0.value, $0) }, uniquingKeysWith: { a, _ in a })
        XCTAssertEqual(byValue["Unused-Bold.otf"]?.context?.callee, "UIAppFonts")
        XCTAssertEqual(byValue["DarkIcon"]?.context?.callee, "CFBundleIcons")
        XCTAssertEqual(byValue["DarkIcon"]?.context?.label, "CFBundleIconName")
        XCTAssertEqual(byValue["Brand-Regular.ttf"]?.line, 20)
        XCTAssertTrue(out.references.allSatisfy { $0.kind == .plistValue && $0.file == 7 })
    }

    func testBinaryAndInvalidPlists() throws {
        let binary = try PropertyListSerialization.data(fromPropertyList: ["UILaunchScreen": ["UIImageName": "launch_logo"]],
                                                        format: .binary, options: 0)
        let out = PlistScanner.scan(binary, file: 0)
        XCTAssertEqual(out.references.map(\.value), ["launch_logo"])
        XCTAssertEqual(out.references.first?.line, 0)
        XCTAssertTrue(PlistScanner.scan(Data("not a plist".utf8), file: 0).references.isEmpty)
    }
}
