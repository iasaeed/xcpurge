import XCTest
@testable import XcpurgeKit

final class FontInspectorTests: XCTestCase {
    static let arial = URL(fileURLWithPath: "/System/Library/Fonts/Supplemental/Arial.ttf")

    private func requireArial() throws {
        try XCTSkipUnless(FileManager.default.fileExists(atPath: Self.arial.path), "system font Arial.ttf not installed")
    }

    func testSystemFontNames() throws {
        try requireArial()
        let names = FontInspector.names(of: Self.arial)
        XCTAssertEqual(names.postScript, ["ArialMT"])
        XCTAssertEqual(names.family, ["Arial"])
        XCTAssertTrue(FontInspector.lookupNames(of: Self.arial).starts(with: ["Arial.ttf", "Arial", "ArialMT"]))
    }

    func testPlaceholderFileYieldsFileNamesOnly() throws {
        let root = try FixtureSupport.tempTree(["Brand-Regular.ttf": "not a font"])
        let url = root.appendingPathComponent("Brand-Regular.ttf")
        XCTAssertEqual(FontInspector.names(of: url), FontInspector.Names())
        XCTAssertEqual(FontInspector.lookupNames(of: url), ["Brand-Regular.ttf", "Brand-Regular"])
    }

    /// A font whose file name differs from its PostScript name is used when code names the PostScript name.
    func testFontUsedByPostScriptName() async throws {
        try requireArial()
        for (literal, expectUsed) in [("ArialMT", true), ("Helvetica", false)] {
            let root = try FixtureSupport.tempTree([
                "Package.swift": """
                // swift-tools-version: 5.9
                import PackageDescription
                let package = Package(name: "Kit", targets: [.target(name: "Kit", resources: [.process("Resources")])])
                """,
                "Sources/Kit/Use.swift": "import UIKit\nlet font = UIFont(name: \"\(literal)\", size: 12)\n",
            ])
            // Bytes only: copyItem would carry the system file's `restricted` flag and fail.
            let font = root.appendingPathComponent("Sources/Kit/Resources/Body.ttf")
            try FileManager.default.createDirectory(at: font.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data(contentsOf: Self.arial).write(to: font)
            var config = Config()
            config.noSwift = true
            let ctx = try await ScanEngine(root: root, config: config).makeContext()
            let fonts = AssetsDetector().run(ctx).filter { $0.kind == .unusedFont }
            XCTAssertEqual(fonts.isEmpty, expectUsed, literal)
            if !expectUsed { XCTAssertEqual(fonts.first?.confidence, .high) }
        }
    }
}
