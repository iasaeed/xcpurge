// LANE: A
/// Byte-identical resources across catalogs and folders.
/// Handover stub: Lane A implements `run`.
public struct DuplicatesDetector: Detector {
    public init() {}

    public var category: Category { .duplicates }

    public func run(_ ctx: ScanContext) -> [Finding] { [] }
}
