// LANE: D
/// `--format agent`: plain, deterministic stdout data for coding agents (legend, summary, rows grouped by kind
/// and module, capped at `options.agentLimit` per kind).
public struct AgentReporter: Reporter {
    public let options: ReporterOptions

    public init(options: ReporterOptions = ReporterOptions()) {
        self.options = options
    }

    public func render(_ result: ScanResult) -> String {
        ""
    }
}
