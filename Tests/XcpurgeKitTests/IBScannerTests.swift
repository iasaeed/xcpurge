import XCTest
@testable import XcpurgeKit

final class IBScannerTests: XCTestCase {
    func testFixtureStoryboard() throws {
        let url = FixtureSupport.fixtureURL("ModularWorkspace/App/App/Main.storyboard")
        let out = IBScanner.scan(try Data(contentsOf: url), file: 3)
        let pairs = Set(out.references.compactMap { r -> String? in
            if case .ibAttribute(let a) = r.kind { return "\(a)=\(r.value)" }
            return nil
        })
        for expected in ["image=storyboard_bg", "customClass=LegacyViewController", "customModule=App",
                         "fontName=Brand-Regular", "fontFamily=Brand", "namedColor=AccentColor", "text=Welcome",
                         "id=vc1"] {
            XCTAssertTrue(pairs.contains(expected), "missing \(expected)")
        }
        XCTAssertTrue(out.references.allSatisfy { $0.file == 3 && $0.line > 0 })
        let image = out.references.first { $0.value == "storyboard_bg" && $0.kind == .ibAttribute("image") }
        XCTAssertEqual(image?.context?.callee, "imageView")
    }

    func testSegueStoryboardReferenceAndStringElements() {
        let xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <document type="com.apple.InterfaceBuilder3.CocoaTouch.Storyboard.XIB" version="3.0">
          <scenes>
            <scene sceneID="s"><objects>
              <viewController id="a"><connections><segue destination="b" kind="show" id="sg"/></connections></viewController>
              <viewControllerPlaceholder storyboardName="Settings" referencedIdentifier="Root" id="p"/>
              <button title="Tap" id="btn"><state key="normal" image="tap_icon"/></button>
              <textView id="tv"><string key="text">Long text</string></textView>
              <view id="v"><userDefinedRuntimeAttributes>
                <userDefinedRuntimeAttribute type="string" keyPath="localizedKey" value="settings.title"/>
              </userDefinedRuntimeAttributes></view>
            </objects></scene>
          </scenes>
        </document>
        """
        let out = IBScanner.scan(Data(xml.utf8), file: 0)
        func has(_ attr: String, _ value: String) -> Bool { out.references.contains { $0.kind == .ibAttribute(attr) && $0.value == value } }
        XCTAssertTrue(has("segue", "b"))
        XCTAssertTrue(has("storyboardName", "Settings"))
        XCTAssertTrue(has("referencedIdentifier", "Root"))
        XCTAssertTrue(has("title", "Tap"))
        XCTAssertTrue(has("image", "tap_icon"))
        XCTAssertTrue(has("text", "Long text"))
        XCTAssertTrue(has("userDefined", "settings.title"))
        XCTAssertEqual(out.references.first { $0.value == "settings.title" }?.context?.label, "localizedKey")
    }

    func testMalformedXMLReturnsPartialResults() {
        let out = IBScanner.scan(Data("<document><imageView image=\"ok\" id=\"1\"/><broken".utf8), file: 0)
        XCTAssertTrue(out.references.contains { $0.value == "ok" })
    }
}
