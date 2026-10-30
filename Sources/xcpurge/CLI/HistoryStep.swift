import Foundation
import XcpurgeKit

/// `--git`: fills `Finding.history` from git history after filtering (never changes confidence or reasons).
enum HistoryStep {
    static func enrich(_ r: ScanResult, options: GitOptions, quiet: Bool) async -> ScanResult {
        guard options.git else { return r }
        let settings = GitHistory.Settings(emails: options.gitEmails, deadSince: options.gitDeadSince,
                                           recentDays: options.gitRecentDays)
        let (findings, diagnostics, stats) = await GitHistory.annotateDetailed(r.findings, root: r.context.root, settings: settings)
        for d in diagnostics { r.context.diagnostics.add(d.level, d.message, path: d.path) }
        if !quiet {
            var note = "git history: \(stats.annotated) of \(findings.count) finding(s) annotated"
            if stats.untracked > 0 { note += ", \(stats.untracked) not committed" }
            if stats.repositories > 1 { note += ", \(stats.repositories) repositories" }
            for d in diagnostics { note += "\n\(d.level.rawValue): \(d.message)" }
            ScanRunner.stderr(note + "\n")
        }
        return ScanResult(context: r.context, findings: findings, elapsed: r.elapsed, baseline: r.baseline)
    }
}
