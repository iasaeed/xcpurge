import XCTest
@testable import XcpurgeKit

/// Whole-file dead-code analysis (plan §4.5): declarations, roots, cross-file use, confidence tiers, and the
/// false-positive / false-negative classes found on real projects.
final class DeadSourceTests: XCTestCase {
    /// A two-target package: library `Kit` and executable `Tool` (depends on Kit).
    private static let manifest = """
    // swift-tools-version: 5.9
    import PackageDescription

    let package = Package(
        name: "Kit",
        products: [.library(name: "Kit", targets: ["Kit"])],
        targets: [
            .target(name: "Kit"),
            .executableTarget(name: "Tool", dependencies: ["Kit"]),
        ]
    )
    """

    /// Dead-source findings for a package tree (`Sources/Tool/main.swift` is added when missing).
    private func dead(_ files: [String: String], retainPublic: Bool = false) async throws -> [String: Finding] {
        var tree = files
        tree["Package.swift"] = Self.manifest
        if tree["Sources/Tool/main.swift"] == nil { tree["Sources/Tool/main.swift"] = "print(1)\n" }
        var config = Config()
        config.noSwift = true
        config.retainPublic = retainPublic
        let root = try FixtureSupport.tempTree(tree)
        let result = try await ScanEngine(root: root, config: config).run(categories: [.files])
        return Dictionary(uniqueKeysWithValues: result.findings.filter { $0.kind == .deadSource }.map { ($0.path, $0) })
    }

    // MARK: - Confidence tiers

    func testUnusedNominalTypeIsHighAndUsedTypeIsNot() async throws {
        let d = try await dead([
            "Sources/Kit/Dead.swift": "struct DeadThing { func run() {} }\n",
            "Sources/Kit/Used.swift": "struct UsedThing {}\n",
            "Sources/Tool/main.swift": "import Kit\nlet u = UsedThing()\n",
        ])
        XCTAssertEqual(d["Sources/Kit/Dead.swift"]?.confidence, .high)
        XCTAssertEqual(d["Sources/Kit/Dead.swift"]?.module, "Kit")
        XCTAssertNil(d["Sources/Kit/Used.swift"])
        XCTAssertNil(d["Sources/Tool/main.swift"], "main.swift is a root")
    }

    func testFunctionsOnlyIsMediumAndExtensionOnlyIsLow() async throws {
        let d = try await dead([
            "Sources/Kit/Funcs.swift": "func helperNobodyCalls() -> Int { 1 }\nlet unusedConstant = 2\n",
            "Sources/Kit/Ext.swift": "extension String {\n    var shoutedNever: String { uppercased() }\n}\n",
            "Sources/Kit/ExtUsed.swift": "extension String {\n    var whispered: String { lowercased() }\n}\n",
            "Sources/Kit/Conformance.swift": "extension Int: CustomDebugStringConvertible {}\n",
            "Sources/Kit/Generic.swift": "extension Array where Element: Equatable {\n    func uniqueNever() -> Self { self }\n}\n",
            "Sources/Kit/Caller.swift": "func caller() -> String { \"a\".whispered }\n",
            "Sources/Tool/main.swift": "import Kit\ncaller()\n",
        ])
        XCTAssertEqual(d["Sources/Kit/Funcs.swift"]?.confidence, .medium)
        XCTAssertEqual(d["Sources/Kit/Ext.swift"]?.confidence, .low)
        XCTAssertNil(d["Sources/Kit/ExtUsed.swift"], "extension member used elsewhere")
        XCTAssertNil(d["Sources/Kit/Conformance.swift"], "conformance extensions are used invisibly")
        XCTAssertEqual(d["Sources/Kit/Generic.swift"]?.confidence, .low, "a where clause is not a conformance")
        XCTAssertNil(d["Sources/Kit/Caller.swift"])
    }

    func testPreviewOnlyIsLow() async throws {
        let d = try await dead([
            "Sources/Kit/Badge.swift": "import SwiftUI\nstruct Badge: View {\n    var body: some View { Text(\"b\") }\n}\n#Preview { Badge() }\n",
        ])
        XCTAssertEqual(d["Sources/Kit/Badge.swift"]?.confidence, .low)
        XCTAssertTrue(d["Sources/Kit/Badge.swift"]?.reasons.contains { $0.contains("previews") } == true)
    }

    func testPublicLibraryAPIIsLowOrRetained() async throws {
        let files = ["Sources/Kit/API.swift": "public enum PublicAPI { public static func go() {} }\n"]
        let d = try await dead(files)
        XCTAssertEqual(d["Sources/Kit/API.swift"]?.confidence, .low)
        let retained = try await dead(files, retainPublic: true)
        XCTAssertNil(retained["Sources/Kit/API.swift"], "--retain-public keeps public API")
    }

    func testStringLiteralOfClassNameIsLow() async throws {
        let d = try await dead([
            "Sources/Kit/Plugin.swift": "final class LoadedByName: NSObject {}\n",
            "Sources/Kit/Loader.swift": "func load() -> AnyClass? { NSClassFromString(\"LoadedByName\") }\n",
            "Sources/Tool/main.swift": "import Kit\n_ = load()\n",
        ])
        XCTAssertEqual(d["Sources/Kit/Plugin.swift"]?.confidence, .low)
    }

    // MARK: - Roots

    func testRootsAreSkipped() async throws {
        let d = try await dead([
            "Sources/Kit/ObjC.swift": "final class Target: NSObject {\n    @objc func tap() {}\n}\n",
            "Sources/Kit/Case.swift": "import XCTest\nfinal class HelperCase: XCTestCase {}\n",
            "Sources/Kit/Intent.swift": "import AppIntents\nstruct OpenThing: AppIntent {\n    static let title: LocalizedStringResource = \"Open\"\n}\n",
            "Sources/Kit/Entry.swift": "@main\nstruct Entry { static func main() {} }\n",
            "Sources/Kit/Swifty.swift": "import Testing\n@Test func works() {}\n",
            "Sources/Kit/Marked.swift": "// xcpurge:ignore\nstruct KeptOnPurpose {}\n",
            "Sources/Kit/IB.swift": "final class CellFromNib: UIView {}\n",
            "Sources/Kit/Cell.xib": "<document><objects><view id=\"1\" customClass=\"CellFromNib\"/></objects></document>\n",
            "Sources/Kit/Ext.swift": "final class ShareHandler: NSObject {}\n",
            "Sources/Kit/Info.plist": """
            <?xml version="1.0" encoding="UTF-8"?>
            <plist version="1.0"><dict><key>NSExtension</key><dict><key>NSExtensionPrincipalClass</key>\
            <string>$(PRODUCT_MODULE_NAME).ShareHandler</string></dict></dict></plist>
            """,
            "Sources/Kit/Script.swift": "#!/usr/bin/swift\nstruct ScriptOnly {}\n",
        ])
        for path in ["ObjC", "Case", "Intent", "Entry", "Swifty", "Marked", "IB", "Ext", "Script"] {
            XCTAssertNil(d["Sources/Kit/\(path).swift"], path)
        }
    }

    // MARK: - Regressions from real projects

    /// Property wrappers and macros are used as `@Name` / `#Name`, which the index stores with the sigil.
    func testPropertyWrapperAndMacroUsesCount() async throws {
        let d = try await dead([
            "Sources/Kit/Clamped.swift": "@propertyWrapper\nstruct Clamped { var wrappedValue: Int }\n",
            "Sources/Kit/Model.swift": "struct Model { @Clamped var level: Int }\nlet model = Model(level: .init(wrappedValue: 1))\n",
            "Sources/Tool/main.swift": "import Kit\nprint(model)\n",
        ])
        XCTAssertNil(d["Sources/Kit/Clamped.swift"])
    }

    /// A nested type with a common name (`Coordinator`) must not keep its file alive through unrelated uses.
    func testNestedTypeNamesNeedQualifiedUse() async throws {
        let d = try await dead([
            "Sources/Kit/Picker.swift": "struct PickerView {\n    final class Coordinator {}\n}\n",
            "Sources/Kit/Other.swift": "struct OtherView {\n    final class Coordinator {}\n    func make() -> Coordinator { Coordinator() }\n}\n",
            "Sources/Kit/Sheet.swift": "struct SheetView {\n    struct Style {}\n}\n",
            "Sources/Kit/Uses.swift": "func style() -> Any { SheetView.Style() }\n",
            "Sources/Tool/main.swift": "import Kit\nprint(OtherView(), style())\n",
        ])
        XCTAssertEqual(d["Sources/Kit/Picker.swift"]?.confidence, .high)
        XCTAssertNil(d["Sources/Kit/Sheet.swift"], "qualified .Style use counts (and SheetView is named too)")
    }

    /// Plan §3 step 6: a file no target compiles is visible everywhere, so its uses keep code alive (conservative).
    func testUnattributedFilesCountAsUsers() async throws {
        let d = try await dead([
            "Sources/Kit/Layer.swift": "final class RasterLayer {}\n",
            "Sources/Kit/Unused.swift": "final class NobodyUsesThis {}\n",
            "Scripts/tool.swift": "let l = RasterLayer()\n",
        ])
        XCTAssertNil(d["Sources/Kit/Layer.swift"], "used from an unattributed script")
        XCTAssertEqual(d["Sources/Kit/Unused.swift"]?.confidence, .high)
        XCTAssertNil(d["Scripts/tool.swift"], "unattributed files are not candidates when a project exists")
    }

    // MARK: - Objective-C and fixtures

    func testClassicAppObjC() async throws {
        let result = try await ScanEngine(root: FixtureSupport.fixtureURL("ClassicApp"), config: Config()).run(categories: [.files])
        let dead = result.findings.filter { $0.kind == .deadSource }.map(\.path)
        XCTAssertEqual(dead, ["ClassicApp/DeadObjC.m"], "Legacy.m is used from Swift and imported by the bridging header")
    }

    func testObjCCategoryOnlyIsLow() async throws {
        let d = try await dead([
            "Sources/Kit/NSString+Shout.m": "#import \"NSString+Shout.h\"\n@implementation NSString (Shout)\n- (NSString *)shout { return self; }\n@end\n",
            "Sources/Kit/NSString+Shout.h": "@interface NSString (Shout)\n- (NSString *)shout;\n@end\n",
        ])
        XCTAssertEqual(d["Sources/Kit/NSString+Shout.m"]?.confidence, .low)
    }

    func testModularWorkspaceTiers() async throws {
        let result = try await ScanEngine(root: FixtureSupport.fixtureURL("ModularWorkspace"), config: Config()).run(categories: [.files])
        let tiers = Dictionary(uniqueKeysWithValues: result.findings.filter { $0.kind == .deadSource }.map { ($0.path, $0.confidence) })
        XCTAssertEqual(tiers["App/App/Dead/DeadHelper.swift"], .high)
        XCTAssertEqual(tiers["App/App/PreviewOnly.swift"], .low)
        XCTAssertEqual(tiers["App/App/ExtensionOnly.swift"], .low)
        XCTAssertNil(tiers["App/App/LegacyViewController.swift"], "storyboard customClass")
        XCTAssertNil(tiers["App/AppWidget/AppWidgetBundle.swift"], "@main widget bundle")
        XCTAssertNil(tiers["App/App/ContentView.swift"])
    }

    // MARK: - Collector

    func testDeclarationCollector() {
        let swift = """
        import struct Foundation.Date
        public final class Outer<T: Equatable>: NSObject, Codable where T: Hashable {
            class func make() -> Outer { fatalError() }
            enum Inner { case a }
        }
        extension Outer.Inner { func describe() {} }
        func freeFunction() {}
        let (a, b) = (1, 2)
        """
        let r = DeclarationCollector.collect(SwiftTokenizer.tokenize(swift).tokens, dialect: .swift)
        XCTAssertEqual(r.types, ["Outer"])
        XCTAssertEqual(r.nestedTypes, ["Inner"])
        XCTAssertEqual(r.members, ["freeFunction"])
        XCTAssertEqual(r.extensionMembers, ["describe"])
        XCTAssertTrue(r.supertypes.isSuperset(of: ["NSObject", "Codable"]))
        XCTAssertFalse(r.supertypes.contains("Hashable"), "where clause is not inheritance")
        XCTAssertTrue(r.hasPublic)
        XCTAssertFalse(r.hasOpaqueExtension)
        XCTAssertEqual(r.firstLine, 2)

        let objc = "@class Fwd;\n@protocol Delegate;\n@interface Shown : UIView\n@end\n@implementation Shown (Extra)\n@end\n"
        let o = DeclarationCollector.collect(SwiftTokenizer.tokenize(objc, dialect: .objc).tokens, dialect: .objc)
        XCTAssertEqual(o.types, ["Shown"])
        XCTAssertEqual(o.categories, ["Shown"])
        XCTAssertEqual(o.supertypes, ["UIView"])
    }
}
