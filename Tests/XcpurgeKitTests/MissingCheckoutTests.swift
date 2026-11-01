import XCTest
@testable import XcpurgeKit

/// Uninitialised git submodules and missing CocoaPods output: their dangling references are noted once, and the
/// warnings about their paths are dropped. Diagnostic paths are root-relative.
final class MissingCheckoutTests: XCTestCase {
    /// `ClassicApp` with its ghost file moved to `ghostPath` and a base xcconfig at `xcconfigPath` that does not exist.
    private func project(ghostPath: String, xcconfigPath: String? = nil) throws -> URL {
        let root = try FixtureSupport.copyToTemp("ClassicApp")
        let pbxproj = root.appendingPathComponent("ClassicApp.xcodeproj/project.pbxproj")
        var text = try String(contentsOf: pbxproj, encoding: .utf8).replacingOccurrences(
            of: "path = Ghost.swift; sourceTree = \"<group>\";", with: "path = \"\(ghostPath)\"; sourceTree = SOURCE_ROOT;")
        if let xcconfigPath {
            text = text.replacingOccurrences(
                of: "/* Begin PBXFileReference section */\n",
                with: "/* Begin PBXFileReference section */\n\t\tCC00000000000000000000A1 /* base.xcconfig */ = {isa = PBXFileReference; lastKnownFileType = text.xcconfig; path = \"\(xcconfigPath)\"; sourceTree = SOURCE_ROOT; };\n")
                .replacingOccurrences(of: "\t\t\tbuildSettings = {\n\t\t\t\tINFOPLIST_FILE = ClassicApp/Info.plist;",
                                      with: "\t\t\tbaseConfigurationReference = CC00000000000000000000A1;\n\t\t\tbuildSettings = {\n\t\t\t\tINFOPLIST_FILE = ClassicApp/Info.plist;")
        }
        try text.write(to: pbxproj, atomically: true, encoding: .utf8)
        return root
    }

    private func scan(_ root: URL) async throws -> ScanResult {
        var config = Config()
        config.noSwift = true
        return try await ScanEngine(root: root, config: config).run()
    }

    private func ghosts(_ r: ScanResult) -> [String] { r.findings.filter { $0.kind == .ghostReference }.map(\.path) }

    func testGhostIsReportedWithoutSubmoduleInfo() async throws {
        let r = try await scan(project(ghostPath: "Deps/Sub/Ghost.swift"))
        XCTAssertEqual(ghosts(r), ["Deps/Sub/Ghost.swift"])
        XCTAssertTrue(r.context.missingCheckouts.isEmpty)
    }

    func testMissingSubmoduleSuppressesGhostsAndNotesOnce() async throws {
        let root = try project(ghostPath: "Deps/Sub/Ghost.swift")
        try Data("[submodule \"Sub\"]\n\tpath = Deps/Sub\n\turl = https://example.com/sub.git\n".utf8)
            .write(to: root.appendingPathComponent(".gitmodules"))
        let r = try await scan(root)
        XCTAssertEqual(ghosts(r), [])
        let notes = r.context.diagnostics.entries.filter { $0.message.contains("uninitialised git submodule") }
        XCTAssertEqual(notes.map(\.message), ["uninitialised git submodule Deps/Sub; run git submodule update --init"])
        XCTAssertEqual(notes.first?.level, .info)
    }

    func testEmptySubmoduleDirectoryCountsAsUninitialised() async throws {
        let root = try project(ghostPath: "Deps/Sub/Ghost.swift")
        try FileManager.default.createDirectory(at: root.appendingPathComponent("Deps/Sub"), withIntermediateDirectories: true)
        try Data("[submodule \"Sub\"]\n\tpath = Deps/Sub\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
        let r = try await scan(root)
        XCTAssertEqual(ghosts(r), [])
    }

    func testInitialisedSubmoduleKeepsItsGhosts() async throws {
        let root = try project(ghostPath: "Deps/Sub/Ghost.swift")
        let sub = root.appendingPathComponent("Deps/Sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: sub.appendingPathComponent("README.md"))
        try Data("[submodule \"Sub\"]\n\tpath = Deps/Sub\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
        let r = try await scan(root)
        XCTAssertEqual(ghosts(r), ["Deps/Sub/Ghost.swift"])
        XCTAssertFalse(r.context.diagnostics.entries.contains { $0.message.contains("uninitialised") })
    }

    func testMissingPodsSuppressesGhostsAndXcconfigWarnings() async throws {
        let root = try project(ghostPath: "Pods/Foo/Ghost.swift", xcconfigPath: "Pods/Target Support Files/App/App.debug.xcconfig")
        try Data("target 'App' do\nend\n".utf8).write(to: root.appendingPathComponent("Podfile"))
        let r = try await scan(root)
        XCTAssertEqual(ghosts(r), [])
        let entries = r.context.diagnostics.entries
        XCTAssertEqual(entries.filter { $0.message == "CocoaPods output missing; run pod install" }.count, 1)
        XCTAssertFalse(entries.contains { $0.message.contains("cannot read xcconfig") }, "\(entries)")
    }

    func testPodsWithoutPodfileOrWithProjectAreNotMissing() async throws {
        let noPodfile = try await scan(project(ghostPath: "Pods/Foo/Ghost.swift"))
        XCTAssertEqual(ghosts(noPodfile), ["Pods/Foo/Ghost.swift"], "no Podfile: not CocoaPods output")
        let root = try project(ghostPath: "Pods/Foo/Ghost.swift")
        try Data("target 'App' do\nend\n".utf8).write(to: root.appendingPathComponent("Podfile"))
        let pods = root.appendingPathComponent("Pods/Pods.xcodeproj")
        try FileManager.default.createDirectory(at: pods, withIntermediateDirectories: true)
        let installed = try await scan(root)
        XCTAssertTrue(installed.context.missingCheckouts.isEmpty)
        XCTAssertEqual(ghosts(installed), ["Pods/Foo/Ghost.swift"])
    }

    func testPodsInsideAnUninitialisedSubmoduleGetOneNote() async throws {
        let root = try project(ghostPath: "Pods/Foo/Ghost.swift")
        try Data("target 'App' do\nend\n".utf8).write(to: root.appendingPathComponent("Podfile"))
        try Data("[submodule \"Pods\"]\n\tpath = Pods\n".utf8).write(to: root.appendingPathComponent(".gitmodules"))
        let r = try await scan(root)
        XCTAssertEqual(r.context.missingCheckouts.map(\.kind), [.submodule])
        XCTAssertFalse(r.context.diagnostics.entries.contains { $0.message.contains("CocoaPods") })
    }

    func testMissingXcconfigWarningIsRootRelative() async throws {
        let r = try await scan(project(ghostPath: "Ghost.swift", xcconfigPath: "Config/Debug.xcconfig"))
        let warning = try XCTUnwrap(r.context.diagnostics.entries.first { $0.message == "cannot read xcconfig" })
        XCTAssertEqual(warning.path, "Config/Debug.xcconfig")
    }

    func testDiagnosticsRelativizeAbsolutePathsUnderTheRoot() {
        let d = Diagnostics(rootPath: "/tmp/proj")
        d.warn("a", path: "/tmp/proj/X/y.xcconfig")
        d.warn("b", path: "/private/tmp/proj/z")
        d.warn("c", path: "/elsewhere/q")
        d.warn("d", path: "rel/p")
        XCTAssertEqual(Set(d.entries.map { $0.path ?? "" }), ["X/y.xcconfig", "z", "/elsewhere/q", "rel/p"])
        d.suppressWarnings(under: ["rel"])
        d.warn("e", path: "rel/other")
        d.info("f", path: "rel/other")
        XCTAssertEqual(d.entries.filter { $0.path == "rel/other" }.map(\.message), ["f"], "notes survive, warnings do not")
    }

    func testEmptyStringsFilesGetTheirOwnWarning() async throws {
        let root = try FixtureSupport.tempTree([
            "A/hy.lproj/Empty.strings": "", "A/Empty.xcstrings": "", "A/Broken.strings": "\"unterminated",
            "A/ok.lproj/Ok.strings": "\"a\" = \"b\";\n",
        ])
        let ctx = try await ScanEngine(root: root, config: Config()).makeContext()
        _ = StringsDetector().run(ctx)
        let warnings = ctx.diagnostics.entries.filter { $0.level == .warning }
        XCTAssertEqual(warnings.filter { $0.message == "empty strings file" }.compactMap(\.path).sorted(),
                       ["A/Empty.xcstrings", "A/hy.lproj/Empty.strings"])
        XCTAssertFalse(warnings.contains { $0.message == "cannot parse strings file" && $0.path?.contains("Empty") == true })
        XCTAssertTrue(warnings.contains { $0.message == "cannot parse strings file" && $0.path == "A/Broken.strings" },
                      "a malformed file keeps the parse warning")
    }
}
