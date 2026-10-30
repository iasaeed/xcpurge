import Foundation

/// `--format agent`: plain, deterministic stdout data for coding agents (legend, summary, rows grouped by kind
/// and module, capped at `options.agentLimit` per kind). No colour, no progress, relative paths; the only
/// absolute path is the root, repeated in the ready-to-run commands. Every value that comes from the project
/// (path, name, module, ignore entry) goes through `fieldValue`, so a crafted name can never add a line.
public struct AgentReporter: Reporter {
    /// Bumped when a line's shape changes; additions keep it.
    public static let formatVersion = 1

    public let options: ReporterOptions

    public init(options: ReporterOptions = ReporterOptions()) {
        self.options = options
    }

    public func render(_ result: ScanResult) -> String {
        let root = result.context.root.path
        let quotedRoot = Self.shellArgument(root)
        let findings = result.findings.sorted(by: Finding.reportOrder)
        var lines: [String] = []
        lines.append("# xcpurge agent report v\(Self.formatVersion) · \(XcpurgeVersion.name) \(XcpurgeVersion.current) · root: \(root)")
        lines.append("## Legend")
        lines.append("confidence: high = no reference from any module that can see it; remove, then build. "
            + "medium/low = NOT proven unused: run `xcpurge explain <root> <id>` and check runtime/dynamic use first. "
            + "This output is a lead, not a verdict.")
        lines.append("commands: remove `xcpurge remove --yes <root> <path>` · undo `xcpurge restore <root>` · "
            + "explain `xcpurge explain <root> <id>` · ignore: add the line to .xcpurgeignore with a `# reason` comment above it")
        lines.append("values: paths, names and ignore entries with spaces, quotes or control characters are double-quoted "
            + "with \\n \\r \\t \\\" \\\\ \\u{XX} escapes; everything else is literal.")
        lines.append("after removing: build, rescan (removal exposes more), keep removals in their own commit; work on a clean branch.")
        lines.append("reasons: " + ReasonCodes.codes.joined(separator: ", "))
        lines.append("## Summary")
        lines.append(Self.summary(findings, baseline: result.baseline))

        // Kinds in report order (category, then kind), each section grouped by module.
        var kindOrder: [FindingKind] = []
        var byKind: [FindingKind: [Finding]] = [:]
        for f in findings {
            if byKind[f.kind] == nil { kindOrder.append(f.kind) }
            byKind[f.kind, default: []].append(f)
        }
        for kind in kindOrder {
            let all = byKind[kind]!
            lines.append("## \(kind.flagName) (\(all.count))")
            let ranked = all.sorted { a, b in
                if a.confidence != b.confidence { return a.confidence > b.confidence }
                return Finding.reportOrder(a, b)
            }
            let shown = options.agentLimit > 0 ? Array(ranked.prefix(options.agentLimit)) : ranked
            var moduleOrder: [String] = []
            var byModule: [String: [Finding]] = [:]
            for f in shown {
                if byModule[f.module] == nil { moduleOrder.append(f.module) }
                byModule[f.module, default: []].append(f)
            }
            for module in moduleOrder.sorted() {
                lines.append("### \(Self.fieldValue(module))")
                for f in byModule[module]! {
                    lines.append(Self.row(f))
                    if let actions = Self.actions(f, quotedRoot: quotedRoot) { lines.append(actions) }
                }
            }
            let hidden = all.count - shown.count
            if hidden > 0 {
                lines.append("… \(hidden) more \(kind.flagName) not shown: narrow with --targets <module>, "
                    + "--min-confidence high, or --agent-limit 0")
            }
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// `42 findings (10 high, 20 medium, 12 low) · unused-asset 12 · dead-source 5 [· baseline: 140 hidden, 2 fixed]`.
    static func summary(_ findings: [Finding], baseline: BaselineReport?) -> String {
        let counts = Confidence.allCases.reversed().map { c in "\(findings.filter { $0.confidence == c }.count) \(c.rawValue)" }
        var parts = ["\(findings.count) finding\(findings.count == 1 ? "" : "s") (\(counts.joined(separator: ", ")))"]
        var kindOrder: [FindingKind] = [], byKind: [FindingKind: Int] = [:]
        for f in findings {
            if byKind[f.kind] == nil { kindOrder.append(f.kind) }
            byKind[f.kind, default: 0] += 1
        }
        parts += kindOrder.map { "\($0.flagName) \(byKind[$0]!)" }
        if let baseline {
            parts.append("baseline: \(baseline.baselinedCount) hidden, \(baseline.fixed.count) fixed")
        }
        return parts.joined(separator: " · ")
    }

    /// `- id=unused-asset-3f9c0a12bd high App/Assets.xcassets/old.imageset name=old reasons=no-ref`.
    static func row(_ f: Finding) -> String {
        var out = "- id=\(f.id) \(f.confidence.rawValue) \(fieldValue(f.path))"
        if let line = f.line, line > 0 { out += ":\(line)" }
        if let name = f.name, name != f.path { out += " name=\(fieldValue(name))" }
        if let group = f.groupID { out += " group=\(group)" }
        out += " reasons=" + ReasonCodes.codes(for: f).joined(separator: ",")
        return out
    }

    /// The second row line: a `remove:` command for kinds `xcpurge remove` acts on (with `--yes`, because an agent
    /// has no terminal to answer the prompt), and the `.xcpurgeignore` entry that would hide the finding. Nil when
    /// neither applies (dynamic lookups, stale ignores).
    static func actions(_ f: Finding, quotedRoot: String) -> String? {
        var parts: [String] = []
        if Trash.deletableKinds.contains(f.kind) || f.kind == .ghostReference {
            parts.append("remove: xcpurge remove --yes \(quotedRoot) \(shellArgument(f.path))")
        }
        if let entry = ignoreEntry(f) { parts.append("ignore: \(fieldValue(entry))") }
        return parts.isEmpty ? nil : "  " + parts.joined(separator: "   ")
    }

    /// A project-supplied value as one token on one line: literal when it has no space, quote, backslash or
    /// control character; otherwise double-quoted with `\n`, `\r`, `\t`, `\"`, `\\` and `\u{XX}` escapes, so a
    /// newline in an asset name or string key can never forge a `remove:` line.
    public static func fieldValue(_ s: String) -> String {
        let needsQuotes = s.isEmpty || s.unicodeScalars.contains { c in
            c == " " || c == "\"" || c == "\\" || c.value < 0x20 || c.value == 0x7F
        }
        guard needsQuotes else { return s }
        var out = "\""
        for c in s.unicodeScalars {
            switch c {
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            default:
                if c.value < 0x20 || c.value == 0x7F {
                    out += "\\u{" + String(c.value, radix: 16, uppercase: true) + "}"
                } else {
                    out.unicodeScalars.append(c)
                }
            }
        }
        return out + "\""
    }

    /// The same rules as the HTML report's ignore export: `asset:` for named catalog findings, `string:` for
    /// named string findings, otherwise the path. Informational kinds have no entry.
    public static func ignoreEntry(_ f: Finding) -> String? {
        if f.kind.isInformational { return nil }
        if let name = f.name, f.category == .assets, f.kind == .unusedAsset { return "asset:" + name }
        if let name = f.name, f.category == .strings { return "string:" + name }
        return f.path
    }

    /// POSIX shell quoting (the HTML report's `shq`): plain for safe characters, single quotes otherwise.
    /// A leading dash would read as an option, so `./-x` names the same file. A control character (a newline in
    /// a file name) cannot stay literal on a one-line command, so such values use `$'…'` quoting (bash and zsh).
    public static func shellArgument(_ s: String) -> String {
        let value = s.hasPrefix("-") ? "./" + s : s
        let safe = value.unicodeScalars.allSatisfy { c in
            ("A"..."Z").contains(c) || ("a"..."z").contains(c) || ("0"..."9").contains(c) || "_./@%+=:,-".unicodeScalars.contains(c)
        }
        if safe, !value.isEmpty { return value }
        if value.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F }) {
            var out = "$'"
            for c in value.unicodeScalars {
                switch c {
                case "\n": out += "\\n"
                case "\r": out += "\\r"
                case "\t": out += "\\t"
                case "'": out += "\\'"
                case "\\": out += "\\\\"
                default:
                    if c.value < 0x20 || c.value == 0x7F {
                        out += "\\x" + String(format: "%02X", c.value)
                    } else {
                        out.unicodeScalars.append(c)
                    }
                }
            }
            return out + "'"
        }
        return "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
