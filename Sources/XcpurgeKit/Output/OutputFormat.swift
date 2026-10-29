/// `--format` values and the reporter each one selects.
public enum OutputFormat: String, Sendable, CaseIterable, Codable {
    case text, json, xcode, github, html

    /// - Parameter colors: ANSI colors for text output (only when writing to a terminal).
    public func reporter(colors: Bool = false, verbose: Bool = false) -> any Reporter {
        switch self {
        case .text: TextReporter(colors: colors, verbose: verbose)
        case .json: JSONReporter()
        case .xcode: XcodeReporter()
        case .github: GitHubReporter()
        case .html: HTMLReporter()
        }
    }
}
