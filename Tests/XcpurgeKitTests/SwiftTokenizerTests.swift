import XCTest
@testable import XcpurgeKit

final class SwiftTokenizerTests: XCTestCase {
    private func tokens(_ s: String) -> [SwiftToken] { SwiftTokenizer.tokenize(s).tokens }
    private func strings(_ s: String) -> [String] { tokens(s).filter { $0.kind == .string }.map(\.text) }
    private func names(_ s: String) -> [String] { tokens(s).filter(\.isName).map(\.text) }

    func testNestedBlockCommentsAreSkipped() {
        let src = """
        /* outer /* inner "not a string" */ still comment UIImage */
        let a = "real"
        """
        XCTAssertEqual(strings(src), ["real"])
        XCTAssertEqual(names(src), ["let", "a"])
    }

    func testLineCommentHidesCode() {
        XCTAssertEqual(strings("// Image(\"hidden\")\nImage(\"shown\")"), ["shown"])
    }

    func testMultilineString() {
        let src = "let s = \"\"\"\n    first \"quoted\" line\n    second\n    \"\"\"\nlet t = \"after\""
        let s = strings(src)
        XCTAssertEqual(s.count, 2)
        XCTAssertTrue(s[0].contains("first \"quoted\" line"))
        XCTAssertEqual(s[1], "after")
        XCTAssertEqual(tokens(src).first { $0.text == "t" }?.line, 5)
    }

    func testRawStrings() {
        XCTAssertEqual(strings(##"let r = #"raw "quoted" \n"#"##), [#"raw "quoted" \n"#])
        XCTAssertEqual(strings(###"let r = ##"a "# b"##"###), [##"a "# b"##])
    }

    func testRawStringInterpolation() {
        let t = tokens(##"let r = #"icon_\#(index)_dark"#"##).first { $0.kind == .string }
        XCTAssertEqual(t?.interpolated, true)
        XCTAssertEqual(t?.text, "icon_")
        XCTAssertEqual(t?.suffix, "_dark")
        // `\(` inside a raw string is literal text.
        let literal = tokens(##"let r = #"a\(b)"#"##).first { $0.kind == .string }
        XCTAssertEqual(literal?.interpolated, false)
        XCTAssertEqual(literal?.text, #"a\(b)"#)
    }

    func testInterpolationPrefixSuffixAndInnerCode() {
        let all = tokens(#"Image("icon_\(item.name)_\(size)px")"#)
        let s = all.first { $0.kind == .string }
        XCTAssertEqual(s?.text, "icon_")
        XCTAssertEqual(s?.suffix, "px")
        XCTAssertTrue(all.contains { $0.kind == .member && $0.text == "name" })
        XCTAssertTrue(all.contains { $0.kind == .identifier && $0.text == "size" })
    }

    func testNestedStringsInsideInterpolation() {
        let src = #"let x = "outer \(dict["inner"] ?? "fallback") end""#
        let all = tokens(src)
        let literals = all.filter { $0.kind == .string }
        XCTAssertEqual(literals.map(\.text), ["inner", "fallback", "outer "])
        XCTAssertEqual(literals.last?.suffix, " end")
        XCTAssertEqual(literals.last?.interpolated, true)
    }

    func testInterpolationWithParentheses() {
        let s = tokens(#"let x = "a\(f(g(1), (2)))b""#).first { $0.kind == .string && $0.interpolated }
        XCTAssertEqual(s?.text, "a")
        XCTAssertEqual(s?.suffix, "b")
    }

    func testEscapes() {
        XCTAssertEqual(strings(#"let x = "a\"b\\c\u{41}""#), ["a\"b\\cA"])
    }

    func testRegexLiterals() {
        XCTAssertEqual(strings(#"let r = /"not a string"/"#), [])
        XCTAssertEqual(strings("let r = #/ \"x\" /\"y\"/ /#\nlet s = \"after\""), ["after"])
        XCTAssertEqual(strings("let r = ##/a/#b/##\nlet s = \"z\""), ["z"])
        // Division is not a regex.
        let div = tokens("let q = a / b / c")
        XCTAssertFalse(div.contains { $0.kind == .regex })
        XCTAssertEqual(div.filter(\.isName).map(\.text), ["let", "q", "a", "b", "c"])
    }

    func testBackticksAndMembers() {
        let all = tokens("let `default` = Color.`default`; let x = .hero; foo?.bar")
        XCTAssertEqual(all.filter { $0.kind == .identifier }.map(\.text), ["let", "default", "Color", "let", "x", "foo"])
        XCTAssertEqual(all.filter { $0.kind == .member }.map(\.text), ["default", "hero", "bar"])
    }

    func testRangeOperatorIsNotMemberAccess() {
        let all = tokens("for i in 0..<count { } ; a...end")
        XCTAssertFalse(all.contains { $0.kind == .member })
    }

    func testAttributesAndMacros() {
        let all = tokens("@main struct A {}\n#Preview { A() }\nlet b = #bundle")
        XCTAssertEqual(all.filter { $0.kind == .attribute }.map(\.text), ["@main"])
        XCTAssertEqual(all.filter { $0.kind == .macro }.map(\.text), ["#Preview", "#bundle"])
    }

    func testLineNumbers() {
        let src = "let a = 1\n/* two\nthree */\nlet b = \"\"\"\nx\n\"\"\"\nlet c = 2"
        let all = tokens(src)
        XCTAssertEqual(all.first { $0.text == "a" }?.line, 1)
        XCTAssertEqual(all.first { $0.text == "b" }?.line, 4)
        XCTAssertEqual(all.first { $0.kind == .string }?.line, 4)
        XCTAssertEqual(all.first { $0.text == "c" }?.line, 7)
    }

    func testIgnoreMarkerTrailingAndStandalone() {
        let src = """
        let a = UIImage(named: "x") // xcpurge:ignore
        // xcpurge:ignore
        struct Kept {}
        /* xcpurge:ignore */ let c = 1
        let d = 2
        """
        let out = SwiftTokenizer.tokenize(src)
        XCTAssertEqual(Set(out.ignoredLines), [1, 2, 3, 4])
    }

    func testNumbersAndTupleAccess() {
        let all = tokens("let v = 1.5e3 + pair.0 + 0xFF")
        XCTAssertEqual(all.filter { $0.kind == .number }.map(\.text), ["1.5e3", "0", "0xFF"])
    }

    func testUnterminatedStringDoesNotSwallowFile() {
        let all = tokens("let a = \"oops\nlet b = \"ok\"")
        XCTAssertTrue(all.contains { $0.kind == .identifier && $0.text == "b" })
    }

    func testObjCDialect() {
        let out = SwiftTokenizer.tokenize("#import \"Legacy.h\"\n#import <UIKit/UIKit.h>\nNSString *s = @\"key\"; char c = '\"';", dialect: .objc)
        XCTAssertTrue(out.tokens.contains { $0.kind == .identifier && $0.text == "Legacy.h" })
        XCTAssertFalse(out.tokens.contains { $0.text == "UIKit" })
        XCTAssertEqual(out.tokens.filter { $0.kind == .string }.map(\.text), ["key"])
    }

    /// Review #2: every literal segment of an interpolation is kept, not just prefix and suffix.
    func testInterpolationKeepsAllSegments() {
        let t = tokens("Text(\"\\(a) of \\(b)\")\nText(\"Hi \\(n), \\(m)!\")").filter { $0.kind == .string }
        XCTAssertEqual(t.map(\.segments), [["", " of ", ""], ["Hi ", ", ", "!"]])
        XCTAssertEqual(t.map(\.text), ["", "Hi "])
        XCTAssertEqual(t.map(\.suffix), ["", "!"])
        XCTAssertEqual(tokens("let s = \"plain\"").first { $0.kind == .string }?.segments, [])
        let pattern = SwiftScanner.scan(Data("let s = NSLocalizedString(\"\\(a) of \\(b)\", comment: \"\")".utf8), file: 0,
                                        fileName: "A.swift").patterns.first { $0.hasLiteralText }
        XCTAssertEqual(pattern?.segments, ["", " of ", ""])
        XCTAssertEqual(pattern?.couldBuild("3 of 5"), true)
        XCTAssertEqual(pattern?.couldBuild("3 von 5"), false)
    }

    /// Review #13: an unterminated single-line string counts its newline once.
    func testUnterminatedStringCountsNewlineOnce() {
        XCTAssertEqual(tokens("let s = \"unterminated\nlet z = 1\nlet y = 2").first { $0.text == "y" }?.line, 3)
    }
}
