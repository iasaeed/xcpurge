// LANE: C
/// Files on disk inside a project's source roots that no target builds (plan §4.1 step 8): synchronized-folder
/// members excluded from every target, classic-group files missing from every build phase, and files a
/// `Package.swift` `exclude:` keeps out of a target. Settings files (Info.plist, entitlements, xcconfig, bridging
/// and prefix headers) and imported headers are never orphans.
enum OrphanFinder {
    /// Kinds that would be compiled or copied if a target had them.
    static let kinds: Set<FileKind> = [
        .swift, .objc, .header, .c, .cpp, .metal, .storyboard, .xib, .assetCatalog, .stringCatalog, .strings,
        .stringsdict, .plist, .json, .html, .css, .js, .image, .font, .audio, .video, .dataModel, .sceneAssets,
        .intentDefinition, .iconComposer,
    ]

    /// Path-valued build settings whose files are consumed by the build, not by a build phase.
    static let pathSettings = [
        "INFOPLIST_FILE", "CODE_SIGN_ENTITLEMENTS", "SWIFT_OBJC_BRIDGING_HEADER", "GCC_PREFIX_HEADER",
        "MODULEMAP_FILE", "APPLICATION_EXTENSION_API_ONLY_HEADER", "STRINGS_FILE_INFOPLIST_RENAME",
    ]

    static func find(_ ctx: ScanContext) -> [Finding] {
        let consumed = consumedFiles(ctx)
        // Untrusted membership (unknown xcproj capability) and `DEVELOPMENT_ASSET_PATHS` (preview content) folders.
        let skippedDirs = ctx.projects.filter(\.membershipUnknown).map(\.directory) + developmentAssetDirs(ctx)
        let synced = ctx.projects.flatMap { p in p.syncedGroups.map { (group: $0, container: p.container) } }
        var out: [Finding] = []

        for file in ctx.inventory.files where file.modules.isEmpty && file.inSourceRoot && kinds.contains(file.kind) {
            guard !consumed.contains(file.path), !FilesDetector.isInsideOpaqueFolder(file.path),
                  !skippedDirs.contains(where: { RelPath.isUnder(file.path, $0) }) else { continue }
            if file.kind == .header, !file.projectRefs.isEmpty || isImported(file, ctx) { continue }
            let module: String
            let reason: String
            if let s = synced.first(where: { RelPath.isUnder(file.path, $0.group.path) }) {
                module = s.group.owners.sorted().first ?? ModuleID.unknown.name
                reason = "in synchronized folder \(s.group.path) of \(s.container) but excluded from every target"
            } else if let container = file.projectRefs.sorted().first {
                module = ModuleID.unknown.name
                reason = "referenced by \(container) but not a member of any target"
            } else {
                module = ModuleID.unknown.name
                reason = "inside a project group folder but not referenced by any project"
            }
            out.append(Finding(kind: .orphanFile, category: .files, path: file.path, module: module, confidence: .medium,
                               reasons: [reason, "Xcode may exclude it on purpose"], sizeBytes: file.size))
        }

        // SwiftPM: everything under a target directory builds, except `exclude:` entries.
        for package in ctx.projects where package.format == .package {
            for target in package.targets {
                guard let dir = target.sourceDir, !target.excludes.isEmpty else { continue }
                for file in ctx.inventory.files(under: dir) where file.modules.isEmpty && kinds.contains(file.kind) {
                    guard let exclude = target.excludes.first(where: { RelPath.isUnder(file.path, $0) }) else { continue }
                    out.append(Finding(kind: .orphanFile, category: .files, path: file.path, module: target.name,
                                       confidence: .low,
                                       reasons: ["excluded from target \(target.name) by Package.swift (\(exclude))"],
                                       sizeBytes: file.size))
                }
            }
        }
        return out
    }

    /// Files the build reads through settings rather than build phases, root-relative.
    static func consumedFiles(_ ctx: ScanContext) -> Set<String> {
        var out = FilesDetector.settingsFiles(ctx)
        let rootPath = ctx.root.path
        for project in ctx.projects where project.format != .package {
            let projectDir = RelPath.join(rootPath, project.directory)
            for target in project.targets {
                out.formUnion(target.settingsFiles)
                for config in target.settings.configurationNames {
                    for key in pathSettings {
                        guard let value = target.settings.value(key, configuration: config), !value.isEmpty else { continue }
                        out.insert(RelPath.relative(RelPath.join(projectDir, value), to: rootPath))
                    }
                }
            }
        }
        return out
    }

    /// Root-relative `DEVELOPMENT_ASSET_PATHS` folders of every target.
    static func developmentAssetDirs(_ ctx: ScanContext) -> [String] {
        let rootPath = ctx.root.path
        return ctx.projects.filter { $0.format != .package }.flatMap { project in
            let projectDir = RelPath.join(rootPath, project.directory)
            return project.targets.flatMap { $0.settings.values("DEVELOPMENT_ASSET_PATHS") }.map {
                RelPath.relative(RelPath.join(projectDir, $0), to: rootPath)
            }
        }
    }

    /// True when some file `#import`s / `#include`s the header by name.
    static func isImported(_ file: SourceFile, _ ctx: ScanContext) -> Bool {
        !ctx.refs.sites(file.fileName, kinds: .identifier).isEmpty
    }
}
