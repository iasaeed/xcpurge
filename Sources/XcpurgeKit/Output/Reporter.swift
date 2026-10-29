/// Renders a scan result for one output format.
public protocol Reporter: Sendable {
    func render(_ result: ScanResult) -> String
}
