/// `--format` values and the reporter each one selects.
public enum OutputFormat: String, Sendable, CaseIterable, Codable {
    case text, json, xcode, github, html, agent, markdown

    public func reporter(_ options: ReporterOptions) -> any Reporter {
        switch self {
        case .text: TextReporter(colors: options.colors, verbose: options.verbose, quiet: options.quiet)
        case .json: JSONReporter()
        case .xcode: XcodeReporter(maxWarnings: options.maxWarnings)
        case .github: GitHubReporter()
        case .html: HTMLReporter()
        case .agent: AgentReporter(options: options)
        // Only `xcpurge size` renders markdown, from its own snapshot; a scan never reaches this reporter.
        case .markdown: TextReporter(colors: options.colors, verbose: options.verbose, quiet: options.quiet)
        }
    }

    /// - Parameter colors: ANSI colors for text output (only when writing to a terminal).
    public func reporter(colors: Bool = false, verbose: Bool = false) -> any Reporter {
        reporter(ReporterOptions(colors: colors, verbose: verbose))
    }
}
