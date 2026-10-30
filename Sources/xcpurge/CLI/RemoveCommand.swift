import ArgumentParser
import Foundation
import XcpurgeKit

/// `xcpurge remove`: move the given files or asset sets to the trash and drop their project references, without
/// a scan deciding for you (the command the HTML report's drawer offers per finding).
struct RemoveCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "remove",
        abstract: "Move the given files or asset sets to .xcpurge-trash and drop their project references.",
        discussion: """
            Paths are absolute (under the root) or relative to the root. A path inside an asset-catalog set \
            (x.imageset, x.colorset, ...) removes that set. A path that is missing on disk still loses its \
            project.pbxproj references (a ghost reference). Plain folders are refused: pass the files inside. \
            Undo with `xcpurge restore`.
            """)

    @Argument(help: "Project root.", completion: .directory) var root: String
    @Argument(parsing: .remaining, help: "Files or asset sets to remove.", completion: .file()) var paths: [String]
    @Flag(name: .shortAndLong, help: "Do not ask for confirmation.") var yes = false
    @Flag(name: .shortAndLong, help: "No progress or hints on stderr.") var quiet = false
    @OptionGroup var verifyOptions: VerifyOptions

    func validate() throws {
        if paths.isEmpty { throw ValidationError("Give at least one path to remove: xcpurge remove <root> <path> ...") }
    }

    func run() async throws {
        let rootURL = CommonOptions.absolute(root)
        let config: Config
        do { config = try Config.load(from: rootURL.appendingPathComponent(Config.fileName)) } catch {
            throw XcpurgeError.invalidConfig("\(rootURL.appendingPathComponent(Config.fileName).path): \(error)")
        }
        let progress = quiet ? nil : TerminalProgress(isTTY: StderrTerminal.isTTY, colors: StderrTerminal.colors,
                                                      width: StderrTerminal.width, printsSummary: false)
        let context: ScanContext
        do {
            // --verify groups dead source files by their references and reads compiler diagnostics against
            // declared names, so it needs the reference index; plain removal only needs discovery.
            let engine = ScanEngine(root: rootURL, config: config, progress: progress)
            context = try await verifyOptions.enabled ? engine.makeContext() : engine.discover()
        } catch {
            progress?.stop()
            throw error
        }
        progress?.stop()

        // Resolve every path before touching anything: one outside the root (or in the trash) fails the command.
        let rootPath = context.root.path
        var resolved: [String] = []
        for raw in paths {
            let rel: String
            if raw.hasPrefix("/") || raw.hasPrefix("~") {
                // Resolve the folder, not the file: a symlink is moved itself, never its target.
                let abs = CommonOptions.absolute(raw)
                let dir = abs.deletingLastPathComponent().resolvingSymlinksInPath().path
                rel = RelPath.relative(RelPath.join(dir, abs.lastPathComponent), to: rootPath)
            } else {
                rel = RelPath.normalize(raw)
            }
            guard !rel.isEmpty, !rel.hasPrefix("/"), rel != "..", !rel.hasPrefix("../") else {
                throw ValidationError("\(raw) is not inside \(rootPath)")
            }
            guard !RelPath.isUnder(rel, TrashStore.directoryName, foldingCase: true) else {
                throw ValidationError("\(raw) is inside \(TrashStore.directoryName); use `xcpurge restore` instead")
            }
            resolved.append(rel)
        }
        let targets: [String]
        do { targets = try Trash.targets(for: resolved, context: context) } catch XcpurgeError.notFound(let path) {
            throw ValidationError("\(path) is not inside \(rootPath)")
        }
        for raw in resolved {
            if let set = Trash.assetSet(containing: raw) {
                ScanRunner.stderr("removing asset set \(RelPath.lastComponent(set)) (asset sets are removed whole)\n")
            }
        }

        // What the confirmation lists: paths to move, ghosts whose references go, pbxproj files that change,
        // and what `remove` will skip anyway (plain folders, missing files nothing references).
        let fm = FileManager.default
        var acting: [String] = [], ghosts: [String] = [], skips: [String] = []
        for path in targets {
            var isDir: ObjCBool = false
            let exists = fm.fileExists(atPath: context.url(for: path).path, isDirectory: &isDir)
            let inCatalog = path.split(separator: "/").dropLast().contains { $0.lowercased().hasSuffix(".xcassets") }
            if exists, isDir.boolValue, !Trash.isRemovableFolder(path, context: context) {
                skips.append("will be skipped: \(path) (\(Trash.folderReason))")
            } else if !exists, inCatalog || !Trash.isReferenced(path, context: context) {
                skips.append("will be skipped: \(path) (no longer exists)")
            } else {
                acting.append(path)
                if !exists { ghosts.append(path) }
            }
        }
        let folding = context.inventory.isCaseInsensitive
        let fold = { (p: String) in folding ? p.lowercased() : p }
        var details = acting.map { ghosts.contains($0) ? "\($0)  (missing on disk; references only)" : $0 }
        for project in context.projects where project.format == .pbxproj
            && project.fileRefs.contains(where: { ref in acting.contains { fold($0) == fold(ref.path) } }) {
            details.append("edit \(RelPath.join(project.container, "project.pbxproj"))")
        }
        details += skips
        if !acting.isEmpty {
            var question = ["Move \(acting.count - ghosts.count) path(s) to \(TrashStore.directoryName)"]
            if !ghosts.isEmpty { question.append("drop \(ghosts.count) reference(s) to missing file(s)") }
            guard ConfirmPrompt.confirm(question.joined(separator: " and ") + "?", details: details, assumeYes: yes) else { return }
        }

        VerifyStep.warnBlocked(acting, root: context.root)
        try VerifyStep.preflight(verifyOptions, root: context.root, quiet: quiet)
        let store = try TrashStore.begin(root: context.root)
        var report = try Trash(store: store).remove(paths: targets, context: context)
        report = try VerifyStep.verify(verifyOptions, store: store, context: context, action: report, quiet: quiet)
        ScanRunner.printAction(report, verb: "removed", session: store.sessionID)
    }
}
