import Foundation
import XCTest
@testable import XcpurgeKit

/// `xcpurge size`: tree sizes by category and module, built-app sections, before/after comparison.
final class SizeTests: XCTestCase {
    private static var noSwift: Config {
        var c = Config()
        c.noSwift = true
        return c
    }

    /// Bytes of regular files under `dir` whose path matches, walking like the scanner: hidden entries skipped,
    /// bundle folders (`.xcassets`, `.bundle`, ...) measured whole (hidden files inside included), projects and
    /// workspaces not entered.
    private func bytesOnDisk(_ dir: URL, where match: (String) -> Bool) -> Int64 {
        let e = FileManager.default.enumerator(atPath: dir.path)!
        var total: Int64 = 0
        while let rel = e.nextObject() as? String {
            let name = (rel as NSString).lastPathComponent
            let isDir = e.fileAttributes?[.type] as? FileAttributeType == .typeDirectory
            if name.hasPrefix(".") { if isDir { e.skipDescendants() }; continue }
            if isDir {
                if rel.hasSuffix(".xcodeproj") || rel.hasSuffix(".xcworkspace") { e.skipDescendants() }
                if FileKind.bundleExtensions.contains((rel as NSString).pathExtension.lowercased()) {
                    e.skipDescendants()
                    if match(rel) { total += SizeMeasurer.treeStats(dir.path + "/" + rel).bytes }
                }
                continue
            }
            if match(rel) { total += (e.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0 }
        }
        return total
    }

    func testTreeSizesOnModularWorkspace() async throws {
        let root = FixtureSupport.fixtureURL("ModularWorkspace")
        let result = try await ScanEngine(root: root, config: Self.noSwift).run()
        let date = Date(timeIntervalSince1970: 0)
        let s = SizeMeasurer.snapshot(result, categories: Set(XcpurgeKit.Category.allCases), date: date)
        let cat = { (name: String) in s.tree.categories.first { $0.name == name }! }

        XCTAssertEqual(s.tree.categories.map(\.name), SizeMeasurer.categoryNames)
        XCTAssertEqual(cat("Asset catalogs").bytes, bytesOnDisk(root) { $0.hasSuffix(".xcassets") })
        XCTAssertEqual(cat("Asset catalogs").files, 4)
        XCTAssertEqual(cat("Source").bytes, bytesOnDisk(root) { ["swift", "m", "h"].contains(($0 as NSString).pathExtension) && !$0.hasSuffix("Package.swift") })
        XCTAssertEqual(cat("Strings").bytes, bytesOnDisk(root) { ["xcstrings", "strings", "stringsdict"].contains(($0 as NSString).pathExtension) })
        XCTAssertEqual(cat("Interface Builder").bytes, bytesOnDisk(root) { ["storyboard", "xib"].contains(($0 as NSString).pathExtension) })
        XCTAssertEqual(cat("Fonts").bytes, bytesOnDisk(root) { ["ttf", "otf"].contains(($0 as NSString).pathExtension) })
        XCTAssertEqual(s.tree.total, bytesOnDisk(root) { _ in true }, "every walked file is counted once")
        XCTAssertEqual(s.tree.total, s.tree.categories.reduce(0) { $0 + $1.bytes })
        XCTAssertEqual(s.tree.files, s.tree.categories.reduce(0) { $0 + $1.files })
        XCTAssertEqual(s.tree.files, result.context.inventory.files.count)

        // Catalog and asset-type breakdowns add up to the catalog category.
        let catalogs = try XCTUnwrap(s.tree.assetCatalogs)
        XCTAssertEqual(catalogs.map(\.name), ["App/App/Assets.xcassets", "App/AppWidget/Assets.xcassets",
                                              "Packages/Core/Sources/Core/Resources/Core.xcassets",
                                              "Packages/DesignSystem/Sources/DesignSystem/Resources/DesignSystem.xcassets"])
        XCTAssertEqual(catalogs.reduce(0) { $0 + $1.bytes }, cat("Asset catalogs").bytes)
        let types = try XCTUnwrap(s.tree.assetTypes)
        XCTAssertEqual(types.reduce(0) { $0 + $1.bytes }, cat("Asset catalogs").bytes)
        XCTAssertEqual(Set(types.map(\.name)), ["appiconset", "imageset", "colorset", "other"])

        // Modules: each attributed file counts in its modules; unattributed ones in their own row.
        XCTAssertEqual(s.tree.modules.first?.id, "App/App.xcodeproj:App")
        XCTAssertTrue(s.tree.modules.contains { $0.id == "Packages/Core:Core" })
        XCTAssertTrue(s.tree.modules.contains { $0.id == SizeMeasurer.unattributed })

        // Reclaimable is the deduplicated size of high / high+medium findings.
        let unused = result.findings.filter { !$0.kind.isInformational }
        let high = Dictionary(unused.filter { $0.confidence == .high }.map { ($0.path, $0.sizeBytes ?? 0) }, uniquingKeysWith: max)
        XCTAssertEqual(s.reclaimable.high, high.values.reduce(0, +))
        XCTAssertGreaterThan(s.reclaimable.highMedium, s.reclaimable.high)
        XCTAssertEqual(s.reclaimable.categories, ["assets", "duplicates", "files", "strings"])

        // Deterministic: a second scan gives the same snapshot and JSON.
        let again = SizeMeasurer.snapshot(try await ScanEngine(root: root, config: Self.noSwift).run(),
                                          categories: Set(XcpurgeKit.Category.allCases), date: date)
        XCTAssertEqual(s.json(), again.json())
        XCTAssertEqual(try JSONDecoder().decode(SizeSnapshot.self, from: Data(s.json().utf8)), s)

        let text = SizeText.render(s)
        XCTAssertTrue(text.contains("Total "), text)
        XCTAssertTrue(text.hasSuffix(SizeText.reclaimableLine(s.reclaimable) + "\n"), text)
    }

    /// `--targets` keeps only that module's files.
    func testTargetsLimitTheTree() async throws {
        var config = Self.noSwift
        config.targets = ["Core"]
        let result = try await ScanEngine(root: FixtureSupport.fixtureURL("ModularWorkspace"), config: config).run()
        let tree = SizeMeasurer.tree(result.context, targets: ["Core"], assetBreakdown: false)
        XCTAssertEqual(tree.modules.map(\.id), ["Packages/Core:Core"])
        XCTAssertEqual(tree.total, tree.modules[0].bytes)
    }

    // MARK: - App bundle

    private func write(_ url: URL, bytes: Int) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(repeating: 0x41, count: bytes).write(to: url)
    }

    /// A synthetic iOS-style `.app`: executable, Assets.car, two lproj, a framework, a plug-in, other files.
    private func makeApp(in dir: URL) throws -> URL {
        let app = dir.appendingPathComponent("Demo.app")
        let info = try PropertyListSerialization.data(fromPropertyList: ["CFBundleExecutable": "DemoBin"], format: .xml, options: 0)
        try FileManager.default.createDirectory(at: app, withIntermediateDirectories: true)
        try info.write(to: app.appendingPathComponent("Info.plist"))
        try write(app.appendingPathComponent("DemoBin"), bytes: 4_000)
        try write(app.appendingPathComponent("Assets.car"), bytes: 10_000)
        try write(app.appendingPathComponent("en.lproj/Localizable.strings"), bytes: 300)
        try write(app.appendingPathComponent("de.lproj/Localizable.strings"), bytes: 350)
        try write(app.appendingPathComponent("de.lproj/Main.storyboardc/Info.plist"), bytes: 50)
        try write(app.appendingPathComponent("Frameworks/Kit.framework/Kit"), bytes: 2_000)
        try write(app.appendingPathComponent("Frameworks/Kit.framework/Info.plist"), bytes: 100)
        try write(app.appendingPathComponent("PlugIns/Widget.appex/Widget"), bytes: 700)
        try write(app.appendingPathComponent("icon.png"), bytes: 25)
        return app
    }

    func testAppSectionsOnSyntheticBundle() throws {
        let dir = try FixtureSupport.tempTree([:])
        let app = try makeApp(in: dir)
        let size = try AppMeasurer.measure(app)
        let infoBytes = Int64(try Data(contentsOf: app.appendingPathComponent("Info.plist")).count)
        XCTAssertEqual(size.sections, [
            AppSection(name: "Executable", bytes: 4_000),
            AppSection(name: "Assets.car", bytes: 10_000),
            AppSection(name: "de.lproj", bytes: 400),
            AppSection(name: "en.lproj", bytes: 300),
            AppSection(name: "Frameworks/Kit.framework", bytes: 2_100),
            AppSection(name: "PlugIns/Widget.appex", bytes: 700),
            AppSection(name: "Other resources", bytes: 25 + infoBytes),
        ])
        XCTAssertEqual(size.total, 4_000 + 10_000 + 400 + 300 + 2_100 + 700 + 25 + infoBytes)
        XCTAssertEqual(size.path, app.path)

        // The same app zipped as an .ipa (Payload/Demo.app) measures the same.
        let payload = dir.appendingPathComponent("Payload")
        try FileManager.default.createDirectory(at: payload, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: app, to: payload.appendingPathComponent("Demo.app"))
        let ipa = dir.appendingPathComponent("Demo.ipa")
        let zip = Process()
        zip.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        zip.arguments = ["-c", "-k", "--norsrc", "--keepParent", payload.path, ipa.path]
        try zip.run()
        zip.waitUntilExit()
        XCTAssertEqual(zip.terminationStatus, 0)
        let fromIPA = try AppMeasurer.measure(ipa)
        XCTAssertEqual(fromIPA.sections, size.sections)
        XCTAssertEqual(fromIPA.path, ipa.path)
        XCTAssertThrowsError(try AppMeasurer.measure(dir.appendingPathComponent("Missing.app")))
    }

    func testMacAppLayout() {
        XCTAssertEqual(AppMeasurer.section(of: "Contents/MacOS/Demo", isMac: true, executable: "Demo"), "Executable")
        XCTAssertEqual(AppMeasurer.section(of: "Contents/Resources/Assets.car", isMac: true, executable: "Demo"), "Assets.car")
        XCTAssertEqual(AppMeasurer.section(of: "Contents/Resources/fr.lproj/x.strings", isMac: true, executable: "Demo"), "fr.lproj")
        XCTAssertEqual(AppMeasurer.section(of: "Contents/Frameworks/A.framework/Versions/A/A", isMac: true, executable: "Demo"),
                       "Frameworks/A.framework")
        XCTAssertEqual(AppMeasurer.section(of: "Contents/Info.plist", isMac: true, executable: "Demo"), "Other resources")
    }

    // MARK: - Comparison

    private func snapshot(_ categories: [(String, Int64)], modules: [(String, Int64)], app: [AppSection]? = nil) -> SizeSnapshot {
        let cats = SizeMeasurer.categoryNames.map { n in SizeEntry(name: n, files: 1, bytes: categories.first { $0.0 == n }?.1 ?? 0) }
        return SizeSnapshot(
            root: "/r", measuredAt: Date(timeIntervalSince1970: 0),
            tree: TreeSize(total: cats.reduce(0) { $0 + $1.bytes }, files: cats.count, categories: cats,
                           modules: modules.map { ModuleSize(id: $0.0, files: 1, bytes: $0.1) }),
            reclaimable: Reclaimable(high: 100, highMedium: 200, categories: ["assets", "duplicates"]),
            app: app.map { AppSize(path: "/a.app", total: $0.reduce(0) { $0 + $1.bytes }, sections: $0) })
    }

    func testCompareFormatting() {
        let before = snapshot([("Asset catalogs", 204_800), ("Source", 10_240)], modules: [("P:App", 215_040)],
                              app: [AppSection(name: "Assets.car", bytes: 1_048_576)])
        let after = snapshot([("Asset catalogs", 174_080), ("Source", 10_240), ("Fonts", 2)], modules: [("P:App", 184_322)],
                             app: [AppSection(name: "Assets.car", bytes: 943_718)])
        XCTAssertEqual(SizeText.compact(before, after), """
        Size before → after:
          Asset catalogs  200.0 KB  →  170.0 KB  -30.0 KB (-15.0%)
          Fonts                0 B  →       2 B         +2 B (new)
          Total           210.0 KB  →  180.0 KB  -30.0 KB (-14.3%)

        """)
        let full = SizeText.compare(before, after)
        XCTAssertTrue(full.contains("Category             Before        After             Change\n"), full)
        XCTAssertTrue(full.contains("Source              10.0 KB  →   10.0 KB          no change\n"), full)
        XCTAssertTrue(full.contains("P:App   210.0 KB  →  180.0 KB  -30.0 KB (-14.3%)\n"), full)
        XCTAssertTrue(full.contains("Assets.car   1.0 MB  →  921.6 KB  -102.4 KB (-10.0%)\n"), full)
        XCTAssertTrue(full.hasSuffix("Reclaimable (high+medium): 200 B (assets, duplicates) → 200 B (assets, duplicates)\n"), full)
        let colored = SizeText.compact(before, after, colors: true)
        XCTAssertTrue(colored.contains("\u{1B}[32m-30.0 KB (-15.0%)\u{1B}[0m"), colored)
        XCTAssertTrue(colored.contains("\u{1B}[31m+2 B (new)\u{1B}[0m"), colored)
        XCTAssertEqual(SizeText.change(.init(name: "x", before: 5, after: 5)), "no change")
    }

    // MARK: - CLI

    func testSizeCommandSavesAndCompares() throws {
        let fixture = FixtureSupport.fixtureURL("ModularWorkspace").path
        let saved = FileManager.default.temporaryDirectory.appendingPathComponent("xcpurge-size-\(UUID().uuidString).json")
        let first = try CLISupport.run(["size", fixture, "--no-swift", "--format", "json", "--save", saved.path])
        XCTAssertEqual(first.status, 0, first.stderr)
        let printed = try JSONDecoder().decode(SizeSnapshot.self, from: Data(first.stdout.utf8))
        XCTAssertEqual(try SizeSnapshot.load(from: saved), printed)
        let compared = try CLISupport.run(["size", fixture, "--no-swift", "--compare", saved.path])
        XCTAssertEqual(compared.status, 0, compared.stderr)
        XCTAssertTrue(compared.stdout.contains("Total "), compared.stdout)
        XCTAssertTrue(compared.stdout.contains("no change"), compared.stdout)
        XCTAssertFalse(compared.stdout.contains("%)"), "nothing changed between the two runs")
        let html = try CLISupport.run(["size", fixture, "--format", "html"])
        XCTAssertNotEqual(html.status, 0, "size supports text and json only")
    }
}
