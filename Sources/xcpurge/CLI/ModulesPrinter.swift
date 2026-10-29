import XcpurgeKit

/// Text rendering of the module graph for `xcpurge modules`.
enum ModulesPrinter {
    static func render(_ ctx: ScanContext, verbose: Bool) -> String {
        var lines: [String] = []
        let files = ctx.inventory.files
        var counts: [ModuleID: Int] = [:]
        for f in files { for m in f.effectiveModules { counts[m, default: 0] += 1 } }
        let names = Dictionary(grouping: ctx.graph.sorted, by: \.id.name)
        func label(_ id: ModuleID) -> String { (names[id.name]?.count ?? 0) > 1 ? id.description : id.name }

        lines.append("Root: \(ctx.root.path)")
        for p in ctx.projects {
            let version = p.objectVersion.map { ", objectVersion \($0)" } ?? ""
            lines.append("Container: \(p.container) [\(p.format.rawValue)\(version)] \(p.targets.count) target(s)")
        }
        lines.append("")
        lines.append("Modules (\(ctx.graph.modules.count))")
        for m in ctx.graph.sorted {
            lines.append("  \(label(m.id))  [\(m.kind.rawValue)]  \(m.id.container)  files: \(counts[m.id] ?? 0)")
            if !m.dependsOn.isEmpty { lines.append("    depends on: \(m.dependsOn.sorted().map(label).joined(separator: ", "))") }
            if !m.embeds.isEmpty { lines.append("    embeds: \(m.embeds.sorted().map(label).joined(separator: ", "))") }
            let consumers = ctx.graph.consumers(of: m.id).subtracting([m.id, .unknown])
            if !consumers.isEmpty { lines.append("    visible to: \(consumers.sorted().map(label).joined(separator: ", "))") }
            if !m.rootPaths.isEmpty { lines.append("    roots: \(m.rootPaths.joined(separator: ", "))") }
        }
        let unattributed = files.filter { $0.modules.isEmpty }
        lines.append("")
        lines.append("Files: \(files.count) (\(unattributed.count) unattributed, \(unattributed.filter(\.inSourceRoot).count) of them in a source root)")
        if verbose {
            lines.append("")
            lines.append("Attribution")
            for f in files {
                let mods = f.modules.isEmpty ? "-" : f.modules.sorted().map(label).joined(separator: ", ")
                let note = f.modules.isEmpty && !f.inSourceRoot ? "  (outside source roots)" : ""
                lines.append("  \(f.path) -> \(mods)\(note)")
            }
        }
        let diagnostics = ctx.diagnostics.entries.filter { verbose || $0.level != .info }
        if !diagnostics.isEmpty {
            lines.append("")
            for d in diagnostics { lines.append("\(d.level.rawValue): \(d.path.map { $0 + ": " } ?? "")\(d.message)") }
        }
        return lines.joined(separator: "\n") + "\n"
    }
}
