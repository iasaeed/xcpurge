/// Findings of one scan plus the context they were computed from.
public struct ScanResult: Sendable {
    public let context: ScanContext
    /// Filtered and sorted in report order.
    public let findings: [Finding]

    public init(context: ScanContext, findings: [Finding]) {
        self.context = context
        self.findings = findings
    }

    /// The report after `--delete` / `--prune`: drops findings whose path was moved to the trash, and acted-on
    /// findings whose file was rewritten, so a re-printed report lists only what is still there.
    public func afterAction(_ action: ActionReport, acted: [Finding]) -> ScanResult {
        let actedSet = Set(acted)
        let kept = findings.filter { f in
            if action.moved.contains(where: { RelPath.isUnder(f.path, $0) }) { return false }
            return !(actedSet.contains(f) && action.rewritten.contains(f.path))
        }
        return ScanResult(context: context, findings: kept)
    }
}
