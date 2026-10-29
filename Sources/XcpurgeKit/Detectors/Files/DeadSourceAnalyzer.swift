// LANE: C
import Foundation

/// Whole-file dead-code check (plan §4.5): a `.swift`/`.m`/`.mm` file is dead when none of its declared names is
/// used, by identifier or member symbol, from another file the owning modules are visible to. Roots
/// (`RootRules`), files with `xcpurge:ignore` markers and generated accessor files are skipped.
///
/// Confidence: high when the file declares a nominal type; medium for functions/variables only; low for
/// extension-only or category-only files, preview-only files, public API of a library without an in-repo
/// consumer (skipped with `--retain-public`), and names that appear as a string literal (`NSClassFromString`).
enum DeadSourceAnalyzer {
    static func find(_ ctx: ScanContext, skipping orphans: Set<String>) -> [Finding] {
        let files = ctx.inventory.files
        let hasProjects = !ctx.projects.isEmpty
        let isUser = FilesDetector.userFilter(ctx, orphans: orphans)
        let usage = usageIndex(ctx.refs, isUser: isUser)
        let instantiated = RootRules.instantiatedClassNames(ctx.refs)
        let hasDataModel = files.contains { $0.kind == .dataModel }
        let markedFiles = Set(ctx.refs.ignoredLines.map(\.file))

        // Declarations of other files, tokenized on demand (nested-type checks only).
        var declsCache: [Int32: DeclarationCollector.Result] = [:]
        func declarations(of g: Int32) -> DeclarationCollector.Result? {
            if let cached = declsCache[g] { return cached }
            let other = files.indices.contains(Int(g)) ? files[Int(g)] : nil
            guard let other, other.kind == .swift,
                  let data = try? Data(contentsOf: ctx.url(for: other.path), options: .alwaysMapped) else { return nil }
            let result = DeclarationCollector.collect(SwiftTokenizer.tokenize(data, dialect: .swift).tokens, dialect: .swift)
            declsCache[g] = result
            return result
        }

        var out: [Finding] = []
        for (i, file) in files.enumerated() {
            let index = Int32(i)
            guard isCandidate(file, ctx, hasProjects: hasProjects), !orphans.contains(file.path),
                  !ctx.refs.generatedFiles.contains(index), !markedFiles.contains(index),
                  let data = try? Data(contentsOf: ctx.url(for: file.path), options: .alwaysMapped),
                  !data.starts(with: Array("#!".utf8)) else { continue }
            let dialect: SwiftTokenizer.Dialect = file.kind == .swift ? .swift : .objc
            let tokens = SwiftTokenizer.tokenize(data, dialect: dialect).tokens
            let decls = DeclarationCollector.collect(tokens, dialect: dialect)
            if RootRules.rootReason(decls, fileName: file.fileName, instantiated: instantiated,
                                    hasDataModel: hasDataModel) != nil { continue }
            let names = decls.allNames + decls.categories
            guard !names.isEmpty || !decls.nestedTypes.isEmpty else { continue }
            let nominalOrMember = !decls.types.isEmpty || !decls.nestedTypes.isEmpty || !decls.members.isEmpty
            if !nominalOrMember, decls.hasOpaqueExtension { continue }

            let visible = FilesDetector.visibility(of: file, in: ctx)
            let header = RelPath.join(RelPath.parent(file.path), RelPath.stem(file.path) + ".h")
            let companion = dialect == .objc ? ctx.inventory.index(of: header) : nil
            func usedElsewhere(_ name: String) -> Bool {
                (usage[name] ?? []).contains { g in g != index && Int(g) != companion && ctx.refs.isVisible(g, visible) }
            }
            func spelledElsewhere(_ name: String, _ kinds: RefKindMask) -> Bool {
                ctx.refs.sites(name, kinds: kinds).contains {
                    $0.file != index && isUser($0.file) && ctx.refs.isVisible($0.file, visible)
                }
            }
            if names.contains(where: usedElsewhere) { continue }
            // Nested types are generic names (`Coordinator`, `Style`); only a qualified `.Name` use counts, or an
            // unqualified one from a file that declares or extends the outer type (`Bar()` inside `struct Foo`).
            if decls.nestedTypes.contains(where: { spelledElsewhere($0, .memberSymbol) }) { continue }
            let outer = Set(decls.types + decls.extendedTypes)
            if !outer.isEmpty, dialect == .swift, decls.nestedTypes.contains(where: { nested in
                (usage[nested] ?? []).contains { g in
                    g != index && ctx.refs.isVisible(g, visible)
                        && declarations(of: g).map { !outer.isDisjoint(with: $0.types + $0.extendedTypes) } == true
                }
            }) { continue }
            if dialect == .objc, usedElsewhere(RelPath.stem(file.path) + ".h") { continue }

            var confidence: Confidence = !decls.types.isEmpty ? .high : (nominalOrMember ? .medium : .low)
            var reasons = ["declares \(Self.summary(names + decls.nestedTypes)); not referenced from another visible file"]
            if !nominalOrMember {
                reasons.append(decls.categories.isEmpty ? "extension-only file" : "category-only file")
            }
            if decls.macros.contains("#Preview") || decls.supertypes.contains("PreviewProvider") {
                confidence = .low
                reasons.append("only used from SwiftUI previews")
            }
            if decls.hasPublic, isLibrary(file, ctx) {
                if ctx.config.retainPublic { continue }
                confidence = .low
                reasons.append("public API of a library with no in-repo consumer")
            }
            if let literal = decls.types.first(where: { spelledElsewhere($0, .stringLiteral) }) {
                confidence = .low
                reasons.append("'\(literal)' appears as a string literal (NSClassFromString?)")
            }
            out.append(Finding(kind: .deadSource, category: .files, path: file.path,
                               module: ctx.moduleName(for: file.path), confidence: confidence, reasons: reasons,
                               sizeBytes: file.size))
        }
        return out
    }

    /// Swift and ObjC implementation files built by a non-test module; with no project at all, every such file.
    static func isCandidate(_ file: SourceFile, _ ctx: ScanContext, hasProjects: Bool) -> Bool {
        guard file.kind == .swift || file.kind == .objc else { return false }
        guard hasProjects else { return true }
        // ponytail: unattributed files in a project-backed scan are orphans or tooling scripts, never dead code.
        return file.modules.contains { ctx.graph.module($0).map { !$0.kind.isTest } ?? false }
    }

    /// Identifier / member-symbol name -> files using it; `@Wrapper` and `#Macro` also count as `Wrapper`/`Macro`.
    static func usageIndex(_ refs: ReferenceIndex, isUser: (Int32) -> Bool) -> [String: [Int32]] {
        var out: [String: [Int32]] = [:]
        for (file, names) in refs.identifiersByFile where isUser(file) {
            for name in names {
                out[name, default: []].append(file)
                if name.hasPrefix("@") || name.hasPrefix("#") { out[String(name.dropFirst()), default: []].append(file) }
            }
        }
        return out
    }

    static func isLibrary(_ file: SourceFile, _ ctx: ScanContext) -> Bool {
        file.modules.contains { id in
            switch ctx.graph.module(id)?.kind {
            case .packageLibrary, .framework, .staticLib: true
            default: false
            }
        }
    }

    static func summary(_ names: [String]) -> String {
        let unique = Array(NSOrderedSet(array: names)) as? [String] ?? names
        return unique.prefix(3).joined(separator: ", ") + (unique.count > 3 ? " and \(unique.count - 3) more" : "")
    }
}

