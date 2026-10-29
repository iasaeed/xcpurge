/// A detector inspects a `ScanContext` and returns findings for one category. Detectors are pure:
/// they never modify files; actions (trash, prune) consume their findings.
public protocol Detector: Sendable {
    var category: Category { get }
    func run(_ ctx: ScanContext) -> [Finding]
}
