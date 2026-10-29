/// One exception set on a synchronized folder.
public struct SyncedException: Sendable, Hashable {
    public enum Sense: String, Sendable, Hashable {
        /// pbxproj semantics: exclusion for an owning target, inclusion for any other target.
        case byOwnership
        case exclusions
        case inclusions
    }

    public var target: String
    public var sense: Sense
    /// True for build-phase exception sets (always inclusions into that phase's target).
    public var isBuildPhase: Bool
    /// Folder-relative paths.
    public var paths: [String]
    public var publicHeaders: [String]
    public var privateHeaders: [String]

    public init(target: String, sense: Sense, isBuildPhase: Bool = false, paths: [String],
                publicHeaders: [String] = [], privateHeaders: [String] = []) {
        self.target = target
        self.sense = sense
        self.isBuildPhase = isBuildPhase
        self.paths = paths
        self.publicHeaders = publicHeaders
        self.privateHeaders = privateHeaders
    }
}
