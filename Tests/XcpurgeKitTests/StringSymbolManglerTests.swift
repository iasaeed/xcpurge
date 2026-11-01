import Foundation
import XCTest
@testable import XcpurgeKit

/// Expected names were produced by `xcrun xcstringstool generate-symbols` on the same keys, one manual key per
/// catalog (Xcode 26.0.1 and 27.1 beta agree). nil: xcstringstool refuses the key.
final class StringSymbolManglerTests: XCTestCase {
    static let probes: [(key: String, symbol: String?)] = [
        ("don't", "dont"), ("it's OK", "itsOk"), ("\"quoted\"", "quoted"), ("TYPE", "type"), ("SELF", nil),
        ("Self_x", "selfX"), ("Type_", "type"), ("self_", nil), ("Type Name", "typeName"), ("type_name", "typeName"),
        ("Protocol Buffers", "protocolBuffers"), ("Never", "never"), ("Any", "`Any`"), ("Optional", "optional"),
        ("%1$@ and %2$@", "and"), ("%2$@ then %1$@", "then"), ("%lld", nil), ("100%", "_100"), ("Hello %@!", "hello"),
        ("Item #%lld", "item"), ("50% off", "_50Off"), ("$%.2f", "_$"), ("a&b", "aB"), ("a+b", "aB"), ("Q&A", "qA"),
        ("Wi-Fi", "wiFi"), ("E-mail", "eMail"), ("OK", "ok"), ("1st", "_1St"), ("3D", "_3D"),
        ("Rock'n'Roll", "rocknRoll"), ("a—b", "aB"), ("—dash", "dash"), ("a–b", "aB"), ("ABC123", "abc123"),
        ("abc123def", "abc123Def"), ("123", "_123"), ("0", "_0"), ("1.5", "_15"), ("Version 2.0", "version20"),
        ("v1.2.3", "v123"), ("line1\nline2", "line1Line2"), ("Item\ttab", "itemTab"), ("Hello  World", "helloWorld"),
        ("  lead", "lead"), ("Ünïcode Straße", "ünïcodeStraße"), ("ÀÉ", "àé"), ("ǅ", "ǅ"),
        ("İstanbul", "i\u{307}stanbul"), ("ß", "ß"), ("I\u{307}", "i\u{307}"),
        ("Hello %@, you have %lld items", "helloYouHaveItems"), ("%@ items", "items"), ("%1$@ items", "items"),
        ("Hello, %@", "hello"), ("%f", nil), ("%.1f%% done", "done"), ("%ld files", "files"), ("%s", nil),
        ("%c", nil), ("%e", nil), ("%x", nil), ("%u", nil), ("%lu", nil), ("%hd", nil), ("%zd", nil), ("%p", nil),
        ("%a", nil), ("Hello %%", "hello"), ("%%", nil), ("%5d things", "things"), ("%-5d things", "things"),
        ("%*d x", "dX"), ("%1$lld of %2$lld", "of"), ("Total: %1$.2f", "total"), ("%d of %@ (%lld)", "of"),
        ("x %@ y %@", "xY"), ("iPhone", "iPhone"), ("iOS", "iOS"), ("iCloud", "iCloud"), ("eBay", "eBay"),
        ("macOS 14", "macOS14"), ("MacBook Pro", "macBookPro"), ("HTTPS", "https"), ("URLSession", "urlsession"),
        ("myURLSession", "myURLSession"), ("getHTTPResponse", "getHTTPResponse"), ("IBOutlet", "iboutlet"),
        ("ID", "id"), ("Id", "id"), ("id", "id"), ("iD", "iD"), ("XMLHttpRequest", "xmlhttpRequest"), ("a", "a"),
        ("aA", "aA"), ("Aa", "aa"), ("AA", "aa"), ("AAa", "aaa"), ("AAA", "aaa"), ("AAAa", "aaaa"), ("A1", "a1"),
        ("A1B", "a1B"), ("a1B", "a1B"), ("1A", "_1A"), ("1a", "_1A"), ("11", "_11"), ("1_1", "_11"), ("_a", "_A"),
        ("_A", "_A"), ("__", "`_`"), ("_1a", "_1A"), ("$x", "_$X"), ("@x", "x"), ("#x", "x"), ("x$", "x$"),
        ("x@", "x"), ("日本", "日本"), ("日本 語", "日本語"), ("Привет мир", "приветМир"), ("über Cool", "überCool"),
        ("emoji 😀 here", "emoji😀Here"), ("😀😀", "😀😀"), ("😀 smile", "😀Smile"), ("smile 😀", "smile😀"),
        ("e\u{301}", "e\u{301}"), ("é", "é"), ("Éa", "éa"), ("Hello_World", "helloWorld"),
        ("hello_world", "helloWorld"), ("HELLO_WORLD", "helloWorld"), ("Hello-World", "helloWorld"),
        ("hello.world", "helloWorld"), ("hello/world", "helloWorld"), ("hello:world", "helloWorld"),
        ("hello;world", "helloWorld"), ("hello,world", "helloWorld"), ("hello?world", "helloWorld"),
        ("hello!world", "helloWorld"), ("hello(world)", "helloWorld"), ("hello[world]", "helloWorld"),
        ("hello{world}", "helloWorld"), ("hello<world>", "helloWorld"), ("hello=world", "helloWorld"),
        ("hello|world", "helloWorld"), ("hello~world", "helloWorld"), ("hello^world", "helloWorld"),
        ("hello*world", "helloWorld"), ("hello\\world", "helloWorld"), ("hello`world", "helloWorld"),
        ("hello\"world", "helloWorld"), ("hello…world", "helloWorld"), ("it’s", "its"), ("“quoted”", "quoted"),
        ("a b", "aB"), ("a  b", "aB"), ("a\u{A0}b", "aB"), ("welcome_title", "welcomeTitle"),
        ("App.HomeScreen.Title", "appHomeScreenTitle"), ("Hello, world!", "helloWorld"), ("Hello %@", "hello"),
        ("%lld items", "items"), ("Landmarks", "landmarks"), ("%1$(friendsPosts)lld posts", "posts"),
        ("QRCode", "qrcode"), ("default", "`default`"), ("1", "_1"), ("_1", "_1"), ("%@", nil), ("Star", "star"),
        ("japan-street", "japanStreet"), ("my-icon_2", "myIcon2"), ("2fa", "_2Fa"), ("ABCLogo", "abclogo"),
        ("URL", "url"), ("logo.dark", "logoDark"), ("a--b", "aB"), ("über_icon", "überIcon"),
        ("_private", "_Private"), ("icon 2x", "icon2X"), ("IMG_0042", "img0042"), ("HTTPServer", "httpserver"),
        ("userID", "userID"), ("count: %lld", "count"), ("Settings/General", "settingsGeneral"), ("x.y.z", "xYZ"),
        ("HelloWorld", "helloWorld"), ("ABC", "abc"), ("aBC", "aBC"), ("A", "a"), ("Ünter", "ünter"), ("ÄBC", "äbc"),
        ("key with %d and %@ more", "keyWithAndMore"), ("multiple__under", "multipleUnder"),
        ("trailing_", "trailing"), ("e2e_test", "e2ETest"), ("v2", "v2"), ("x2y", "x2Y"), ("a1b2", "a1B2"),
        ("__double", "_Double"), ("_", "`_`"), ("My_URL_Key", "myUrlKey"), ("fooBAR", "fooBAR"),
        ("foo_BAR", "fooBar"), ("iOS_version", "iOSVersion"), ("%lld: %@", nil), ("self", nil), ("Type", nil),
        ("type", "type"), ("protocol", "`protocol`"), ("Protocol", nil), ("async", "async"),
        ("description", "description"), ("init", "`init`"), ("class", "`class`"), ("Self", "`Self`"),
        ("IMAGE_NAME", "imageName"), ("FOO BAR", "fooBar"), ("Image", "image"), ("Color", "color"),
        ("brandColor", "brandColor"), ("noImage", "noImage"), ("HTTP_URL", "httpUrl"), ("NASA", "nasa"), ("😀", "😀"),
        ("日本語", "日本語"), ("café", "café"), ("100%% sure", "_100Sure"), ("%d%%", nil), ("Step %lld of %lld", "stepOf"),
        ("%#@files@", "_1$Files"), ("Done", "done"), ("on", "on"), ("Name", "name"), ("hello world", "helloWorld"),
        ("Hello World", "helloWorld"),
        ("this is a sentence that is quite long: really!", "thisIsASentenceThatIsQuiteLongReally"),
        ("Which one?", "whichOne"), ("Delete \"%@\"?", "delete"), ("can't", "cant"), ("%o x", nil), ("% d x", "dX"),
        ("%+d x", "x"), ("%#x y", "xY"), ("%0d z", "z"), ("%'d w", "dW"), ("%5.2f q", "q"), ("%hhd a", nil),
        ("%qd b", nil), ("%Lf c", nil), ("%jd d", nil), ("%td e", nil), ("%C f", nil), ("%S g", nil), ("%D h", nil),
        ("%U i", nil), ("%O j", nil), ("%F k", nil), ("%E l", nil), ("%G m", nil), ("%A n", nil), ("%X o", nil),
        ("%i p", nil), ("%#@a@ and %#@b@", "_1$AAnd2$B"), ("x %#@files@", "x1$Files"), ("%1$#@files@", "_1$Files"),
        ("%2$#@files@ x", "_2$FilesX"), ("%@ %#@n@", "_2$N"), ("%(name)@ hi", "hi"), ("%1$(n)@ and %2$(m)lld", "and"),
        ("%ls r", "lsR"), ("%hu s", nil), ("%1$*d t", "_1$DT"), ("%-+5d u", "_5DU"), ("%3$@ v", nil), ("a%", "a"),
        ("%", nil), ("%%x", "x"), ("%y w", "yW"), ("%1$ z", "_1$Z"), ("await", "`await`"), ("open", "`open`"),
        ("some", "some"), ("any", "any"), ("actor", "actor"), ("Init", "`init`"), ("CLASS", "`class`"),
        ("Default", "`default`"), ("nil", "`nil`"), ("true", "`true`"), ("inout", "`inout`"),
        ("rethrows", "`rethrows`"), ("associatedtype", "`associatedtype`"), ("precedencegroup", "`precedencegroup`"),
        ("fileprivate", "`fileprivate`"), ("operator", "`operator`"), ("subscript", "`subscript`"),
        ("typealias", "`typealias`"), ("where", "`where`"), ("repeat", "`repeat`"), ("throws", "`throws`"),
        ("super", "`super`"), ("is", "`is`"), ("as", "`as`"), ("in", "`in`"), ("let", "`let`"), ("func", "`func`"),
        ("deinit", "`deinit`"), ("import", "`import`"), ("internal", "`internal`"), ("private", "`private`"),
        ("public", "`public`"), ("static", "`static`"), ("struct", "`struct`"), ("enum", "`enum`"),
        ("case", "`case`"), ("catch", "`catch`"), ("continue", "`continue`"), ("defer", "`defer`"), ("do", "`do`"),
        ("else", "`else`"), ("fallthrough", "`fallthrough`"), ("for", "`for`"), ("guard", "`guard`"), ("if", "`if`"),
        ("return", "`return`"), ("switch", "`switch`"), ("break", "`break`"), ("false", "`false`"), ("Self_", nil),
        ("SELF_X", "selfX"), ("Any_", "any"), ("any_", "any"), ("Protocol_", "`protocol`"),
        ("PROTOCOL", "`protocol`"), ("TYPE_", "type"), ("Type x", "typeX"), ("©x", "x"), ("®x", "x"), ("°x", "x"),
        ("€x", "€X"), ("→x", "x"), ("★x", "x"), ("x©y", "xY"), ("x€y", "x€Y"), ("x→y", "xY"), ("a·b", "a·B"),
        ("x²", "x²"), ("½x", "½X"), ("x½", "x½"), ("Ⅻ", "ⅻ"), ("a'b'", "ab"), ("'quoted'", "quoted"), ("$", "_$"),
        ("$$", "_$$"), ("a$b", "a$B"), ("a$B", "a$B"), ("1$", "_1$"), ("_$", "_$"), ("x_$y", "x$Y"),
        ("don't stop", "dontStop"), ("o’clock", "oclock"), ("a`b", "aB"), ("x@y", "xY"), ("%x a", nil), ("%u a", "a"),
        ("%e a", nil), ("%c a", nil), ("%s a", nil), ("%p a", nil), ("%a a", nil), ("%lu a", "a"), ("%hd a", nil),
        ("%zd a", nil), ("%g a", "a"), ("%ld a", "a"), ("%lf a", "a"), ("%lx a", nil), ("%llu a", "a"),
        ("%llx a", nil), ("%d a", "a"), ("%lli a", nil), ("%qu a", nil), ("%zu a", nil), ("%+05d a", "a"),
        ("%0-5d a", "_05DA"), ("%05d a", "a"), ("%-05d a", "a"), ("%+.2f a", "a"), ("%10.3f a", "a"), ("%.f a", "fA"),
        ("%1$-5d a", "a"), ("%1$(n)@", nil), ("%(n)lld x %(m)@", "x"), ("%1$@ %1$@ x", "x"), ("%2$@ %1$lld y", "y"),
        ("b %#@c@ %@", nil), ("%@ b %1$#@c@", "b"), ("%(a)#@b@", "aB"), ("%#@b", "b"), ("%#@@ q", "q"),
        ("%(a b)@ r", "r"), ("%() s", "s"), ("%(1x)@ t", "t"), ("%(x)  u", "xU"), ("%l@ v", "lV"),
        ("%lld%lld w", "w"), ("%1$lld%2$lld w2", "w2"), ("a%1$@b", "aB"), ("x%@y", "xY"), ("%.2@ z", "z"),
        ("%5@ z2", "z2"), ("%-@ z3", "z3"), ("%+@ z4", "z4"), ("%0@ z5", "z5"), ("%ld%% z6", "z6"),
        ("borrowing", "`borrowing`"), ("consuming", "`consuming`"), ("nonisolated", "`nonisolated`"),
        ("throw", "`throw`"), ("try", "`try`"), ("var", "`var`"), ("while", "`while`"), ("mutating", "mutating"),
        ("get", "get"), ("set", "set"), ("willSet", "willSet"), ("didSet", "didSet"), ("lazy", "lazy"),
        ("weak", "weak"), ("unowned", "unowned"), ("indirect", "indirect"), ("convenience", "convenience"),
        ("dynamic", "dynamic"), ("final", "final"), ("infix", "infix"), ("prefix", "prefix"), ("postfix", "postfix"),
        ("optional", "optional"), ("override", "override"), ("required", "required"), ("package", "package"),
        ("macro", "macro"), ("each", "each"), ("consume", "consume"), ("copy", "copy"), ("discard", "discard"),
        ("sending", "sending"), ("isolated", "isolated"), ("unsafe", "unsafe"), ("left", "left"), ("right", "right"),
        ("none", "none"), ("precedence", "precedence"), ("associativity", "associativity"),
        ("assignment", "assignment"), ("Sendable", "sendable"), ("extension", "`extension`"), ("self.x", "selfX"),
        ("Self x", "selfX"), ("PROTOCOL_X", "protocolX"), ("😀a", "😀A"), ("a😀b", "a😀B"), ("€", "€"), ("·x", "·X"),
        ("x·", "x·"), ("ABC😀def", "abc😀Def"), ("HTTPS2go", "https2Go"), ("ABCdef", "abcdef"), ("ABCDef", "abcdef"),
        ("ǅx", "ǅX"), ("xǅ", "xǅ"), ("aǅb", "aǅB"), ("Ⅻx", "ⅻx"), ("x\u{300}y", "x\u{300}y"),
        ("\u{300}x", "_\u{300}X"), ("ÀBc", "àbc"), ("ß_x", "ßX"), ("x_ß", "xSS"),
        ("%(count)lld landmarks", "landmarks"), ("%lg a", nil), ("%llf a", "llfA"), ("%llg a", "llgA"),
        ("%lc a", "lcA"), ("%1$(n)lld and %2$(m)lld z", "andZ"), ("%#@a@", "_1$A"), ("Item %d%% of %@", "itemOf"),
        ("%2$#@f@ %1$@ q", "_2$FQ"), ("%1$#@c@ b %@", "b"), ("%#@c@ b %1$@", "b"), ("%2$#@c@ %1$@ %2$lld z", "z"),
    ]

    func testEveryProbedKeyMatchesXcstringstool() {
        let mismatches = Self.probes.compactMap { probe -> String? in
            let got = StringSymbolMangler.symbol(forKey: probe.key)
            return got == probe.symbol ? nil : "\(probe.key.debugDescription): \(got ?? "nil") (xcstringstool \(probe.symbol ?? "nil"))"
        }
        XCTAssertEqual(mismatches, [])
        XCTAssertNil(StringSymbolMangler.symbol(forKey: ""))
    }

    func testTableNamespace() {
        XCTAssertEqual(StringSymbolMangler.tableNamespace("Feature-Strings"), "FeatureStrings")
        XCTAssertEqual(StringSymbolMangler.tableNamespace("my_table.name"), "MyTableName")
        XCTAssertEqual(StringSymbolMangler.tableNamespace("HTTPErrors"), "HTTPErrors")
        XCTAssertEqual(StringSymbolMangler.tableNamespace("Discover"), "Discover")
        XCTAssertEqual(StringSymbolMangler.tableNamespace("2fa"), "_2Fa")
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

    // MARK: - Live check against the installed xcstringstool

    /// Runs the installed `xcstringstool generate-symbols` on every probe key (one catalog per key, since colliding
    /// or refused keys are reported per key) and on a few table names, and checks the mangler agrees, so a future
    /// Xcode that changes the rules fails here. Skipped where `xcrun xcstringstool` is unavailable.
    func testManglerAgreesWithInstalledXcstringstool() throws {
        guard let tool = AssetSymbolManglerTests.xcrun(["--find", "xcstringstool"]) else {
            throw XCTSkip("xcrun xcstringstool is not available")
        }
        let root = try FixtureSupport.tempTree([:])
        defer { try? FileManager.default.removeItem(at: root) }
        let probes = Self.probes.map(\.key)
        let tables = ["2fa", "Feature-Strings", "my_table.name", "HTTPErrors", "Discover"]
        let results = Results(count: probes.count + tables.count)
        DispatchQueue.concurrentPerform(iterations: probes.count + tables.count) { n in
            let table = n < probes.count ? "Localizable" : tables[n - probes.count]
            let key = n < probes.count ? probes[n] : "title"
            let dir = root.appendingPathComponent("\(n)")
            results.set(n, Self.generate(tool: tool, key: key, table: table, in: dir))
        }
        var mismatches: [String] = []
        for (n, key) in probes.enumerated() {
            let got = StringSymbolMangler.symbol(forKey: key), want = results.get(n)?.symbol
            if got != want { mismatches.append("\(key.debugDescription): \(got ?? "nil") (xcstringstool \(want ?? "nil"))") }
        }
        for (n, table) in tables.enumerated() {
            let got = StringSymbolMangler.tableNamespace(table), want = results.get(probes.count + n)?.namespace
            if got != want { mismatches.append("table \(table): \(got) (xcstringstool \(want ?? "nil"))") }
        }
        XCTAssertEqual(mismatches, [])
    }

    /// Thread-safe result slots for the concurrent tool runs.
    private final class Results: @unchecked Sendable {
        private var slots: [(symbol: String?, namespace: String?)?]
        private let lock = NSLock()
        init(count: Int) { slots = Array(repeating: nil, count: count) }
        func set(_ n: Int, _ value: (symbol: String?, namespace: String?)) { lock.withLock { slots[n] = value } }
        func get(_ n: Int) -> (symbol: String?, namespace: String?)? { lock.withLock { slots[n] } }
    }

    /// Symbol and namespace enum xcstringstool generates for one manual key in `<table>.xcstrings`.
    private static func generate(tool: String, key: String, table: String, in dir: URL) -> (symbol: String?, namespace: String?) {
        let catalog = dir.appendingPathComponent(table + ".xcstrings")
        let body: [String: Any] = [
            "sourceLanguage": "en", "version": "1.0",
            "strings": [key: ["extractionState": "manual",
                              "localizations": ["en": ["stringUnit": ["state": "translated", "value": key]]]]],
        ]
        guard (try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)) != nil,
              let data = try? JSONSerialization.data(withJSONObject: body), (try? data.write(to: catalog)) != nil else {
            return (nil, nil)
        }
        AssetSymbolManglerTests.run(tool, ["generate-symbols", catalog.path, "-o", dir.path, "-l", "swift"])
        let files = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let swift = files.filter { $0.hasSuffix(".swift") }
            .compactMap { try? String(contentsOf: dir.appendingPathComponent($0), encoding: .utf8) }.joined()
        var symbol: String?, namespace: String?
        for line in swift.split(separator: "\n") {
            let text = line.trimmingCharacters(in: .whitespaces)
            for prefix in ["static var ", "static func "] where text.hasPrefix(prefix) && symbol == nil {
                symbol = String(text.dropFirst(prefix.count).prefix { $0 != ":" && $0 != "(" })
            }
            if text.hasPrefix("enum "), namespace == nil { namespace = String(text.dropFirst(5).prefix { $0 != " " }) }
        }
        return (symbol, namespace)
    }
}
