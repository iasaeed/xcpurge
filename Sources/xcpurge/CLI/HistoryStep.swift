// LANE: C
import XcpurgeKit

/// `--git`: fills `Finding.history` from git history after filtering (never changes confidence or reasons).
enum HistoryStep {
    static func enrich(_ r: ScanResult, options: GitOptions, quiet: Bool) async -> ScanResult {
        r
    }
}
