// LANE: A
/// Unused image/color/data/symbol sets, app icons and fonts (plan §4.3, §5).
/// Handover stub: Lane A implements `run`.
public struct AssetsDetector: Detector {
    public init() {}

    public var category: Category { .assets }

    public func run(_ ctx: ScanContext) -> [Finding] { [] }
}
