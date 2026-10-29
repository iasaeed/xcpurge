// LANE: C
/// Orphan and ghost files, dead sources, unused interface files and resources (plan §4.1, §4.5).
/// Handover stub: Lane C implements `run`.
public struct FilesDetector: Detector {
    public init() {}

    public var category: Category { .files }

    public func run(_ ctx: ScanContext) -> [Finding] { [] }
}
