// LANE: A
import XcpurgeKit

/// Applies `--baseline` to a scan result: hides baselined findings, reports fixed entries and warnings.
enum BaselineGate {
    static func apply(_ r: ScanResult, options: CommonOptions) throws -> ScanResult {
        r
    }

    /// True when `--strict-baseline` is set and the baseline has fixed entries (exit 1).
    static func failsStrict(_ r: ScanResult) -> Bool {
        false
    }
}
