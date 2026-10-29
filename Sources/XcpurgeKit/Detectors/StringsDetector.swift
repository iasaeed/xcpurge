// LANE: B
/// Unused and stale localized strings in .xcstrings/.strings/.stringsdict (plan §4.6, §4.7).
/// Handover stub: Lane B implements `run`.
public struct StringsDetector: Detector {
    public init() {}

    public var category: Category { .strings }

    public func run(_ ctx: ScanContext) -> [Finding] { [] }
}
