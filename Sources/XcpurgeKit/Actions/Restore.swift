// LANE: A
import Foundation

/// Restores a trash session: moves `moved` entries back and copies `rewritten` originals over the current files.
/// Handover stub: Lane A implements `run`.
public enum Restore {
    /// - Parameter sessionID: session to restore; nil means the newest session.
    public static func run(root: URL, sessionID: String?) throws -> ActionReport { ActionReport() }
}
