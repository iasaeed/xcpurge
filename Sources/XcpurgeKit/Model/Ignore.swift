// LANE: C
import Foundation

/// `.xcpurgeignore` rules: path globs plus `asset:`, `string:` and `module:` name entries.
/// Handover stub: Lane C implements parsing and matching.
public struct Ignore: Sendable {
    public static let fileName = ".xcpurgeignore"

    /// Starter `.xcpurgeignore` written by `xcpurge init`.
    public static let template = """
    # xcpurge ignore rules (one per line)
    # Path globs:          Vendor/**
    # Asset names:         asset:server_driven_*
    # String keys:         string:push.*
    # Whole modules:       module:LegacyKit

    """

    public init() {}

    /// Parses ignore-file text.
    public init(contents: String) {}

    /// Loads `<root>/.xcpurgeignore`, or an empty rule set when absent.
    public static func load(root: URL) throws -> Ignore { Ignore() }

    /// True when a rule suppresses this finding.
    public func suppresses(_ finding: Finding) -> Bool { false }
}
