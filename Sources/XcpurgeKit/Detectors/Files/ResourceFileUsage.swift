// LANE: C
import Foundation

/// Loose bundle resources (plist, json, media, Core ML, Core Data, scenes, documents, databases) that no visible
/// file names by stem, `stem.ext` or a path ending in either. Folder loads (`urls(forResourcesWithExtension:)`,
/// blue folder references, `Package.swift` `.copy`) and dynamic name patterns downgrade to low instead of clearing.
enum ResourceFileUsage {
    static let kinds: Set<FileKind> = [.plist, .json, .html, .css, .js, .audio, .video, .dataModel, .sceneAssets]
    static let extensions: Set<String> = [
        "txt", "mlmodel", "gpx", "rtf", "scn", "usdz", "reality", "lottie", "pdf", "sqlite", "db", "csv",
    ]
    /// Call labels that load every resource with a given extension.
    static let folderLoadLabels: Set<String> = [
        "forResourcesWithExtension", "forResourcesOfType", "pathsForResourcesOfType", "URLsForResourcesWithExtension",
    ]
    /// Plists SDKs read by convention, never by a name in app code.
    static let conventionalPlists: Set<String> = ["Info", "GoogleService-Info", "Root", "PrivacyInfo"]

    static func find(_ ctx: ScanContext, skipping orphans: Set<String>) -> [Finding] {
        let consumed = OrphanFinder.consumedFiles(ctx)
        let folderRefs = ctx.projects.flatMap(\.fileRefs).filter(\.isFolder).map(\.path)
        let copied = ctx.projects.flatMap(\.targets).flatMap(\.resources).filter { $0.rule == .copy }.map(\.path)
        let tails = pathTails(ctx.refs)
        let isUser = FilesDetector.userFilter(ctx, orphans: orphans)
        var out: [Finding] = []
        for (i, file) in ctx.inventory.files.enumerated() where isCandidate(file) {
            guard !file.modules.isEmpty, !orphans.contains(file.path), !consumed.contains(file.path),
                  !FilesDetector.isInsideOpaqueFolder(file.path) else { continue }
            let stem = RelPath.stem(file.path)
            if file.kind == .plist, conventionalPlists.contains(stem) || stem.hasSuffix("-Info") { continue }
            let visible = FilesDetector.visibility(of: file, in: ctx)
            let canSee = { (source: Int32) in source != Int32(i) && isUser(source) && ctx.refs.isVisible(source, visible) }
            let kinds: RefKindMask = file.fileName.hasSuffix(".mlmodel") ? [.names, .symbols] : .names   // model class
            let names = [stem, file.fileName]
            if names.contains(where: { name in
                ctx.refs.sites(name, kinds: kinds, caseInsensitive: true).contains { !isUserText($0) && canSee($0.file) }
                    || (tails[name.lowercased()] ?? []).contains { canSee($0.file) }
            }) { continue }

            let ext = (file.fileName as NSString).pathExtension.lowercased()
            let low: String?
            if let folder = folderRefs.first(where: { RelPath.isUnder(file.path, $0) }) {
                low = "inside folder reference \(folder); copied as a whole"
            } else if let copy = copied.first(where: { RelPath.isUnder(file.path, $0) }) {
                low = "copied by Package.swift .copy(\"\(RelPath.lastComponent(copy))\")"
            } else if let site = folderLoad(ext, ctx, canSee: canSee) {
                low = "every .\(ext) resource is loaded at \(site)"
            } else {
                low = dynamicMatch(stem, domains: [.resource, .any], ctx, canSee: canSee)
                    .map { "may be built dynamically at \($0)" }
            }
            var reasons = ["no reference to '\(stem)' or '\(file.fileName)' from a visible file"]
            var confidence = Confidence.high
            if let low {
                confidence = .low
                reasons.append(low)
            } else if file.kind == .plist {
                confidence = .medium
                reasons.append("plists are sometimes read by SDKs by convention")
            }
            out.append(Finding(kind: .unusedResource, category: .files, path: file.path,
                               module: ctx.moduleName(for: file.path), confidence: confidence, reasons: reasons,
                               sizeBytes: file.size))
        }
        return out
    }

    static func isCandidate(_ file: SourceFile) -> Bool {
        kinds.contains(file.kind) || extensions.contains((file.fileName as NSString).pathExtension.lowercased())
    }

    /// Literals that look like paths (`"Tables/rates.csv"`), keyed by lowercased last component and its stem.
    static func pathTails(_ refs: ReferenceIndex) -> [String: [Reference]] {
        var out: [String: [Reference]] = [:]
        for r in refs.references where r.kind == .stringLiteral && r.value.contains("/") && r.value.count < 512 {
            let last = RelPath.lastComponent(r.value).lowercased()
            out[last, default: []].append(r)
            let stem = RelPath.stem(last)
            if stem != last { out[stem, default: []].append(r) }
        }
        return out
    }

    /// IB labels and titles are user-visible text, not resource names.
    static func isUserText(_ r: Reference) -> Bool {
        if case .ibAttribute(let attribute) = r.kind { return IBScanner.textAttributes.contains(attribute) }
        return false
    }

    /// `file:line` of a call loading every resource with this extension, from a source `canSee` accepts.
    static func folderLoad(_ ext: String, _ ctx: ScanContext, canSee: (Int32) -> Bool) -> String? {
        ctx.refs.sites(ext, kinds: .stringLiteral, caseInsensitive: true).first {
            folderLoadLabels.contains($0.context?.label ?? "") && canSee($0.file)
        }.map { "\(ctx.refs.path(of: $0.file)):\($0.line)" }
    }

    /// `file:line` of a dynamic pattern (`"intro_\(n)"`) that could produce `name` (plan §4.7 step 3).
    static func dynamicMatch(_ name: String, domains: Set<DynamicPattern.Domain>, _ ctx: ScanContext,
                             canSee: (Int32) -> Bool) -> String? {
        ctx.refs.dynamicPatterns.first { p in
            guard domains.contains(p.domain), !p.isKeyless, name.count > p.prefix.count + p.suffix.count,
                  name.hasPrefix(p.prefix), name.hasSuffix(p.suffix) else { return false }
            let literal = p.prefix.count + p.suffix.count
            return (p.domain == .any ? literal >= 3 : literal >= 1) && canSee(p.file)
        }.map { "\(ctx.refs.path(of: $0.file)):\($0.line)" }
    }
}
