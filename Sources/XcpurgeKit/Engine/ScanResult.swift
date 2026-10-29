/// Findings of one scan plus the context they were computed from.
public struct ScanResult: Sendable {
    public let context: ScanContext
    /// Filtered and sorted in report order.
    public let findings: [Finding]

    public init(context: ScanContext, findings: [Finding]) {
        self.context = context
        self.findings = findings
    }
}
