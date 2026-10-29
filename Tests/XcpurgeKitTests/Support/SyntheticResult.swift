import Foundation
@testable import XcpurgeKit

/// Deterministic, realistic `ScanResult` for reporter tests: six modules with dependency and embed edges,
/// every `FindingKind`, every confidence, dynamic-lookup reasons, duplicate groups and hostile strings.
enum SyntheticResult {
    static let root = URL(fileURLWithPath: "/Users/dev/Acme <iOS> & \"Co\"")

    /// Name containing `</script>` and `<!--` to exercise data-block escaping.
    static let hostileName = "</script><!--<script>alert(1)</script>"

    static func make(count: Int = 3_000) -> ScanResult {
        var rng = LCG(seed: 42)
        let modules = Self.modules
        let names = modules.map(\.id.name)
        var findings: [Finding] = []
        let dynamicSites = (1...24).map { i in
            (file: "\(names[i % 3])/Sources/Dynamic/IconProvider\(i).swift", line: 10 + i * 3, module: names[i % 3])
        }
        for site in dynamicSites {
            findings.append(Finding(kind: .dynamicLookup, category: site.line % 2 == 0 ? .assets : .strings, path: site.file,
                                    line: site.line, name: "icon_\\(\(site.line % 5 == 0 ? "index" : "name"))*",
                                    module: site.module, confidence: .low,
                                    reasons: ["name built at runtime: UIImage(named: \"icon_\\(…)\")"]))
        }
        let weights: [(FindingKind, XcpurgeKit.Category, Int)] = [
            (.unusedAsset, .assets, 30), (.unusedFont, .assets, 3), (.unusedString, .strings, 28), (.staleString, .strings, 6),
            (.orphanFile, .files, 8), (.ghostReference, .files, 3), (.deadSource, .files, 9), (.unusedInterfaceFile, .files, 2),
            (.unusedResource, .files, 5), (.duplicate, .duplicates, 6),
        ]
        let totalWeight = weights.reduce(0) { $0 + $1.2 }
        var n = 0
        while findings.count < count - 1 {
            n += 1
            var pick = Int(rng.next() % UInt64(totalWeight))
            var chosen = weights[0]
            for w in weights { if pick < w.2 { chosen = w; break }; pick -= w.2 }
            let module = names[Int(rng.next() % UInt64(names.count))]
            let roll = rng.next() % 100
            let confidence: Confidence = roll < 55 ? .high : roll < 82 ? .medium : .low
            var reasons: [String]
            switch confidence {
            case .high: reasons = ["no reference by name, generated symbol or accessor visible to \(module)"]
            case .medium: reasons = ["only a case-insensitive match in \(module)/Sources/Legacy/Mapper.swift:\(rng.next() % 400)",
                                     "referenced from a comment"]
            case .low:
                let site = dynamicSites[Int(rng.next() % UInt64(dynamicSites.count))]
                reasons = ["may be built dynamically at \(site.file):\(site.line)",
                           "prefix \"icon_\" matches"]
            }
            let (kind, category, _) = chosen
            var f: Finding
            switch kind {
            case .unusedAsset:
                let name = "\(["icon", "illustration", "bg", "color"][n % 4])_\(module.lowercased())_\(n)"
                f = Finding(kind: kind, category: category, path: "\(module)/Resources/Assets.xcassets/\(name).imageset",
                            name: name, module: module, confidence: confidence, reasons: reasons,
                            sizeBytes: Int64(500 + rng.next() % 400_000))
            case .unusedFont:
                f = Finding(kind: kind, category: category, path: "\(module)/Resources/Fonts/Brand-\(n).ttf", name: "Brand-\(n).ttf",
                            module: module, confidence: confidence, reasons: reasons, sizeBytes: Int64(20_000 + rng.next() % 300_000))
            case .unusedString, .staleString:
                let key = "\(module.lowercased()).screen\(n % 40).\(["title", "subtitle", "cta", "error.message"][n % 4])_\(n)"
                f = Finding(kind: kind, category: category, path: "\(module)/Resources/Localizable.xcstrings", line: Int(rng.next() % 9000),
                            name: key, module: module, confidence: confidence,
                            reasons: kind == .staleString ? ["marked stale in the catalog"] + reasons : reasons)
            case .duplicate:
                let group = "dup-\(n / 2)"
                f = Finding(kind: kind, category: category, path: "\(module)/Resources/Images/hero_\(n / 2)\(n % 2 == 0 ? "" : "_copy").png",
                            module: module, confidence: confidence, reasons: ["identical content (sha256 \(String(rng.next(), radix: 16).prefix(12)))"],
                            sizeBytes: Int64(1_000 + rng.next() % 90_000), groupID: group)
            case .deadSource:
                f = Finding(kind: kind, category: category, path: "\(module)/Sources/Feature\(n % 30)/Helper\(n).swift", line: 1,
                            name: "Helper\(n)", module: module, confidence: confidence, reasons: reasons,
                            sizeBytes: Int64(300 + rng.next() % 20_000))
            default:
                let ext = kind == .unusedInterfaceFile ? "xib" : kind == .unusedResource ? "json" : "swift"
                f = Finding(kind: kind, category: category, path: "\(module)/Sources/Old/File\(n).\(ext)", module: module,
                            confidence: confidence, reasons: reasons, sizeBytes: Int64(100 + rng.next() % 50_000))
            }
            findings.append(f)
        }
        findings.append(Finding(kind: .unusedString, category: .strings, path: "App/Resources/Localizable.xcstrings", line: 7,
                                name: hostileName, module: "App", confidence: .high, reasons: ["contains </script> and <!-- on purpose"]))

        let diagnostics = Diagnostics()
        diagnostics.warn("package product SnapshotTesting not found in Packages/Vendor", path: "App.xcodeproj")
        diagnostics.info("read 1,204 generated asset symbols from DerivedData")
        diagnostics.warn("skipped file larger than 5 MB", path: "App/Resources/huge.json")
        let files = (0..<4_812).map { SourceFile(path: "src/f\($0).swift", kind: .swift, size: 1_000) }
        let refs = ReferenceIndex(references: [], dynamicPatterns: [], ignoredLines: [], accessors: [:], generatedFiles: [],
                                  sourcePaths: [], sourceModules: [])
        let context = ScanContext(root: root, config: Config(), inventory: FileInventory(files: files),
                                  graph: ModuleGraph(modules: modules), refs: refs, projects: [], derivedData: nil,
                                  diagnostics: diagnostics, ignore: Ignore())
        return ScanResult(context: context, findings: findings.sorted(by: Finding.reportOrder))
    }

    static var modules: [Module] {
        let proj = "App.xcodeproj"
        func id(_ c: String, _ n: String) -> ModuleID { ModuleID(container: c, name: n) }
        let app = id(proj, "App"), widget = id(proj, "AppWidget"), tests = id(proj, "AppTests")
        let feature = id("Packages/FeatureKit", "FeatureKit"), design = id("Packages/DesignSystem", "DesignSystem")
        let net = id("Packages/Networking", "Networking")
        return [
            Module(id: app, kind: .app, productName: "App", moduleName: "App", dependsOn: [feature, design, net], embeds: [widget]),
            Module(id: widget, kind: .appExtension, productName: "AppWidget", moduleName: "AppWidget", dependsOn: [design]),
            Module(id: tests, kind: .unitTest, productName: "AppTests", moduleName: "AppTests", dependsOn: [app]),
            Module(id: feature, kind: .packageLibrary, productName: "FeatureKit", moduleName: "FeatureKit", dependsOn: [design, net]),
            Module(id: design, kind: .packageLibrary, productName: "DesignSystem", moduleName: "DesignSystem"),
            Module(id: net, kind: .packageLibrary, productName: "Networking", moduleName: "Networking"),
        ]
    }

    /// Tiny deterministic generator (no Foundation randomness, so output is stable).
    struct LCG {
        var state: UInt64
        init(seed: UInt64) { state = seed }
        mutating func next() -> UInt64 {
            state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
            return state >> 33
        }
    }
}
