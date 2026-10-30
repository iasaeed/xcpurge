/// Findings of one scan plus the context they were computed from.
public struct ScanResult: Sendable {
    public let context: ScanContext
    /// Filtered and sorted in report order.
    public let findings: [Finding]
    /// Wall-clock seconds the scan took (0 when unknown).
    public let elapsed: Double
    /// What `--baseline` hid and found fixed; nil when no baseline was applied.
    public var baseline: BaselineReport?

    public init(context: ScanContext, findings: [Finding], elapsed: Double = 0, baseline: BaselineReport? = nil) {
        self.context = context
        self.findings = findings
        self.elapsed = elapsed
        self.baseline = baseline
    }

    /// The report after `--delete` / `--prune`: drops findings whose path was moved to the trash, and acted-on
    /// findings whose file was rewritten, so a re-printed report lists only what is still there.
    public func afterAction(_ action: ActionReport, acted: [Finding]) -> ScanResult {
        let actedSet = Set(acted)
        let kept = findings.filter { f in
            if action.moved.contains(where: { RelPath.isUnder(f.path, $0) }) { return false }
            return !(actedSet.contains(f) && action.rewritten.contains(f.path))
        }
        return ScanResult(context: context, findings: kept, elapsed: elapsed, baseline: baseline)
    }
}
