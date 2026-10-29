import XCTest
@testable import XcpurgeKit

final class ObjCScannerTests: XCTestCase {
    func testMessageSendContextAndLiterals() {
        let out = ObjCScanner.scan("""
        #import "Legacy.h"
        UIImage *i = [UIImage imageNamed:@"legacy_icon"];
        NSString *s = NSLocalizedString(@"objc_key", nil);
        NSString *f = [NSString stringWithFormat:@"tile_%d", n];
        /* [UIImage imageNamed:@"commented"] */
        """)
        let lit = { (v: String) in out.references.first { $0.kind == .stringLiteral && $0.value == v } }
        XCTAssertEqual(lit("legacy_icon")?.context?.callee, "UIImage")
        XCTAssertEqual(lit("legacy_icon")?.context?.label, "imageNamed")
        XCTAssertEqual(lit("legacy_icon")?.line, 2)
        XCTAssertEqual(lit("objc_key")?.context?.isLocalization(), true)
        XCTAssertNil(lit("commented"))
        XCTAssertTrue(out.references.contains { $0.kind == .identifier && $0.value == "Legacy.h" })
        XCTAssertTrue(out.patterns.contains { $0.prefix == "tile_" })
        XCTAssertEqual(out.patterns.first { $0.prefix == "tile_" }?.domain, .any)
        XCTAssertTrue(out.patterns.isEmpty == false)
    }

    func testAssetDomainForImageNamed() {
        let out = ObjCScanner.scan("[UIImage imageNamed:[NSString stringWithFormat:@\"flag_%@\", code]];")
        XCTAssertTrue(out.patterns.contains { $0.prefix == "flag_" })
    }

    func testNoNestedCommentsInObjC() {
        let out = ObjCScanner.scan("/* a /* b */ id x = @\"visible\";")
        XCTAssertTrue(out.references.contains { $0.value == "visible" })
    }

    func testCharLiteralDoesNotOpenString() {
        let out = ObjCScanner.scan("char q = '\"'; NSString *s = @\"after\";")
        XCTAssertEqual(out.references.filter { $0.kind == .stringLiteral }.map(\.value), ["after"])
    }
}
