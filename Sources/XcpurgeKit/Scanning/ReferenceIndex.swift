import Foundation

/// Every reference in the scan, built once (concurrently, deterministically) and read-only afterwards.
/// Sources are inventory files (same indices as `FileInventory.files`) followed by one synthetic
/// "build settings" source per module.
public struct ReferenceIndex: Sendable {
    public let references: [Reference]
    public let dynamicPatterns: [DynamicPattern]
    public let ignoredLines: Set<FileLine>
    /// Identifiers and member symbols seen per source file (for dead-code analysis).
    public let identifiersByFile: [Int32: Set<String>]
    /// Accessor path -> raw name, from SwiftGen / R.swift generated files.
    public let accessors: [String: String]
    /// Inventory indices of generated accessor files (not reference sources).
    public let generatedFiles: Set<Int32>
    public let sourcePaths: [String]
    public let sourceModules: [Set<ModuleID>]
    private let byValue: [String: [Int32]]
    private let byLowercased: [String: [Int32]]

    /// Max bytes read per file; larger files are skipped with a diagnostic.
    public static let maxFileSize: Int64 = 5 * 1024 * 1024

    /// Build settings whose values name resources (app icons, accent colors, storyboards).
    static let resourceSettingKeys = [
        "ASSETCATALOG_COMPILER_APPICON_NAME", "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME",
        "ASSETCATALOG_COMPILER_LAUNCHIMAGE_NAME", "ASSETCATALOG_COMPILER_COMPLICATION_NAME",
        "ASSETCATALOG_COMPILER_LEADERBOARD_IDENTIFIER_PREFIX", "ASSETCATALOG_COMPILER_STICKER_PACK_IDENTIFIER_PREFIX",
    ]

    init(references: [Reference], dynamicPatterns: [DynamicPattern], ignoredLines: Set<FileLine>,
         accessors: [String: String], generatedFiles: Set<Int32>, sourcePaths: [String], sourceModules: [Set<ModuleID>]) {
        self.references = references
        self.dynamicPatterns = dynamicPatterns
        self.ignoredLines = ignoredLines
        self.accessors = accessors
        self.generatedFiles = generatedFiles
        self.sourcePaths = sourcePaths
        self.sourceModules = sourceModules
        var byValue: [String: [Int32]] = [:], byLower: [String: [Int32]] = [:], idents: [Int32: Set<String>] = [:]
        for (i, r) in references.enumerated() {
            byValue[r.value, default: []].append(Int32(i))
            byLower[r.value.lowercased(), default: []].append(Int32(i))
            if r.kind == .identifier || r.kind == .memberSymbol { idents[r.file, default: []].insert(r.value) }
        }
        self.byValue = byValue
        self.byLowercased = byLower
        self.identifiersByFile = idents
    }

    // MARK: - Queries

    /// Reference sites whose value equals `value` (or matches ignoring case), filtered by kind.
    public func sites(_ value: String, kinds: RefKindMask = .all, caseInsensitive: Bool = false) -> [Reference] {
        let hits = caseInsensitive ? byLowercased[value.lowercased()] : byValue[value]
        return (hits ?? []).map { references[Int($0)] }.filter { kinds.contains($0.kind.mask) }
    }

    /// Evidence that `value` is referenced from a module in `visible` (usually `graph.consumers(of:)`):
    /// `.high` for an exact match, `.medium` for a case-insensitive-only match, nil for none.
    public func referenced(_ value: String, kinds: RefKindMask, from visible: Set<ModuleID>) -> Confidence? {
        if sites(value, kinds: kinds).contains(where: { isVisible($0.file, visible) }) { return .high }
        if sites(value, kinds: kinds, caseInsensitive: true).contains(where: { isVisible($0.file, visible) }) { return .medium }
        return nil
    }

    public func isVisible(_ file: Int32, _ visible: Set<ModuleID>) -> Bool {
        !modules(of: file).isDisjoint(with: visible)
    }

    public func path(of file: Int32) -> String { sourcePaths.indices.contains(Int(file)) ? sourcePaths[Int(file)] : "" }

    public func modules(of file: Int32) -> Set<ModuleID> {
        sourceModules.indices.contains(Int(file)) ? sourceModules[Int(file)] : [.unknown]
    }

    public func isIgnored(file: Int32, line: Int32) -> Bool { ignoredLines.contains(FileLine(file: file, line: line)) }

    // MARK: - Build

    public static func build(inventory: FileInventory, graph: ModuleGraph, rootPath: String,
                             localizationMacros: [String] = [], diagnostics: Diagnostics) async -> ReferenceIndex {
        let files = inventory.files
        let candidates = files.indices.filter { files[$0].kind.isReferenceSource && !files[$0].isUnit }
        let chunkCount = max(1, min(candidates.count, ProcessInfo.processInfo.activeProcessorCount * 4))
        let chunks = (0..<chunkCount).map { c in stride(from: c, to: candidates.count, by: chunkCount).map { candidates[$0] } }

        let outputs: [(Int, ScanOutput)] = await withTaskGroup(of: [(Int, ScanOutput)].self) { group in
            for chunk in chunks {
                group.addTask {
                    chunk.compactMap { i in
                        scanFile(files[i], index: Int32(i), rootPath: rootPath, macros: localizationMacros,
                                 diagnostics: diagnostics).map { (i, $0) }
                    }
                }
            }
            var all: [(Int, ScanOutput)] = []
            for await part in group { all += part }
            return all.sorted { $0.0 < $1.0 }
        }

        var references: [Reference] = [], patterns: [DynamicPattern] = [], ignored = Set<FileLine>()
        var accessors: [String: String] = [:], generated = Set<Int32>()
        for (i, out) in outputs {
            if out.isGenerated {
                generated.insert(Int32(i))
                for (k, v) in out.accessors.sorted(by: { $0.key < $1.key }) where accessors[k] == nil { accessors[k] = v }
                continue
            }
            references += out.references
            patterns += out.patterns
            for line in out.ignoredLines { ignored.insert(FileLine(file: Int32(i), line: line)) }
        }

        // Generated accessor uses: `Asset.Colors.brand`, `R.image.settingsIcon`, `L10n.welcomeTitle`.
        if !accessors.isEmpty {
            var uses: [Reference] = []
            for r in references where r.kind == .memberSymbol {
                let qualifier = r.context?.qualifier ?? ""
                let chain = qualifier.isEmpty ? r.value : qualifier + "." + r.value
                let short = (qualifier.split(separator: ".").last.map { String($0) + "." } ?? "") + r.value
                if let raw = accessors[chain] ?? accessors[short] {
                    uses.append(Reference(kind: .accessorUse(chain), value: raw, file: r.file, line: r.line, context: r.context))
                }
            }
            references += uses
        }

        var sourcePaths = files.map(\.path)
        var sourceModules = files.map(\.effectiveModules)
        for module in graph.sorted {
            let source = Int32(sourcePaths.count)
            sourcePaths.append("\(module.id.description) (build settings)")
            sourceModules.append([module.id])
            let config = module.settings.preferredConfiguration.flatMap { module.settings.configurations[$0] } ?? [:]
            let keys = resourceSettingKeys + config.keys.filter { $0.hasPrefix("INFOPLIST_KEY_") }.sorted()
            for key in keys {
                for value in module.settings.values(key) {
                    references.append(Reference(kind: .buildSetting(key), value: value, file: source, line: 0,
                                                context: CallContext(callee: module.id.name, label: key)))
                }
            }
        }
        return ReferenceIndex(references: references, dynamicPatterns: patterns, ignoredLines: ignored,
                              accessors: accessors, generatedFiles: generated, sourcePaths: sourcePaths,
                              sourceModules: sourceModules)
    }

    static func scanFile(_ file: SourceFile, index: Int32, rootPath: String, macros: [String],
                         diagnostics: Diagnostics) -> ScanOutput? {
        guard file.size <= maxFileSize else {
            diagnostics.info("skipped (larger than 5 MB)", path: file.path)
            return nil
        }
        let url = URL(fileURLWithPath: RelPath.join(rootPath, file.path))
        guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
            diagnostics.warn("cannot read file", path: file.path)
            return nil
        }
        switch file.kind {
        case .swift: return SwiftScanner.scan(data, file: index, localizationMacros: macros)
        case .objc, .header, .c, .cpp, .metal: return ObjCScanner.scan(data, file: index, localizationMacros: macros)
        case .storyboard, .xib: return IBScanner.scan(data, file: index)
        case .plist, .entitlements, .intentDefinition: return PlistScanner.scan(data, file: index)
        case .json, .html, .css, .js, .xcconfig: return GenericTextScanner.scan(data, file: index, kind: file.kind)
        default: return nil
        }
    }
}
