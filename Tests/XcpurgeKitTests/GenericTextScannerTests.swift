import XCTest
@testable import XcpurgeKit

final class GenericTextScannerTests: XCTestCase {
    private func values(_ text: String, _ kind: FileKind) -> Set<String> {
        Set(GenericTextScanner.scan(Data(text.utf8), file: 0, kind: kind).references.map(\.value))
    }

    func testJSONStringLeaves() {
        let v = values(#"{"icon": "images/hero.png", "n": 3, "list": ["a"]}"#, .json)
        XCTAssertTrue(v.isSuperset(of: ["images/hero.png", "hero.png", "hero", "a"]))
    }

    func testCSSAndHTML() {
        let css = values("body { background: url(img/bg.jpg); font-family: \"Brand\", Helvetica; }", .css)
        XCTAssertTrue(css.isSuperset(of: ["img/bg.jpg", "bg", "Brand", "Helvetica"]))
        let html = values(#"<img src="logo.svg"><link href='style.css'>"#, .html)
        XCTAssertTrue(html.isSuperset(of: ["logo.svg", "logo", "style.css", "style"]))
    }

    func testXCConfigValues() {
        let v = values("ASSETCATALOG_COMPILER_APPICON_NAME = AppIcon Beta\n// comment = Nope\n", .xcconfig)
        XCTAssertTrue(v.isSuperset(of: ["AppIcon", "Beta"]))
        XCTAssertFalse(v.contains("Nope"))
    }

    /// Review 2 #2: streamed scanning matches whole-file scanning on line-oriented text, line numbers included.
    func testStreamingMatchesWholeFileScan() throws {
        let text = (1...200).map { "{\"icon\": \"img_\($0).png\"} // line \($0)" }.joined(separator: "\n") + "\n// xcpurge:ignore"
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("stream-\(UUID().uuidString).html")
        try Data(text.utf8).write(to: url)
        let whole = GenericTextScanner.scan(Data(text.utf8), file: 0, kind: .html)
        let streamed = try XCTUnwrap(GenericTextScanner.scanStreaming(url, file: 0, kind: .html, chunkSize: 64))
        XCTAssertEqual(streamed.references, whole.references)
        XCTAssertEqual(streamed.ignoredLines, [201])
        XCTAssertNil(GenericTextScanner.scanStreaming(url.appendingPathExtension("missing"), file: 0, kind: .html))
    }
}
