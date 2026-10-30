/// Presentation switches shared by every reporter; each one reads what it needs.
public struct ReporterOptions: Sendable {
    /// ANSI colors for text output (only when writing to a terminal).
    public var colors = false
    public var verbose = false
    /// `--format xcode`: at most this many warning lines, then a summary.
    public var maxWarnings: Int?
    /// `--format agent`: rows per kind; 0 means all.
    public var agentLimit = 30

    public init(colors: Bool = false, verbose: Bool = false, maxWarnings: Int? = nil, agentLimit: Int = 30) {
        self.colors = colors
        self.verbose = verbose
        self.maxWarnings = maxWarnings
        self.agentLimit = agentLimit
    }
}
