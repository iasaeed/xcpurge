import Foundation

/// The headline metric of a size comparison and the `--fail-if-grows` / `--comment-threshold` decisions.
public enum SizeGate {
    /// What the headline, the comment threshold and the gate measure.
    public struct Metric: Equatable, Sendable {
        public enum Kind: Equatable, Sendable { case app, tree }
        public var kind: Kind
        public var before: Int64
        public var after: Int64
        public var delta: Int64 { after - before }
        public var row: SizeText.Row { SizeText.Row(name: kind == .app ? "App" : "Whole tree", before: before, after: after) }
    }

    /// A `--fail-if-grows` breach.
    public struct Breach: Equatable, Sendable {
        public var metric: Metric
        public var limit: SizeLimit
        /// `size gate: grew +12.0 KB (limit 2%)`, as printed on stderr.
        public var line: String {
            "size gate: grew +\(ByteFormatter.string(metric.delta)) (limit \(limit.description))"
        }
    }

    /// The built app's total when both snapshots have one (install size), else the tree total.
    public static func metric(_ before: SizeSnapshot, _ after: SizeSnapshot) -> Metric {
        if let b = before.app, let a = after.app { return Metric(kind: .app, before: b.total, after: a.total) }
        return Metric(kind: .tree, before: before.tree.total, after: after.tree.total)
    }

    /// nil when the metric did not grow past `limit` (a percent limit is taken of the base).
    public static func check(_ before: SizeSnapshot, _ after: SizeSnapshot, limit: SizeLimit) -> Breach? {
        let m = metric(before, after)
        guard m.delta > 0, m.delta > limit.allowance(base: m.before) else { return nil }
        return Breach(metric: m, limit: limit)
    }

    /// True when `--comment-threshold` says the change is too small to comment on (|delta| below the threshold).
    public static func belowThreshold(_ before: SizeSnapshot, _ after: SizeSnapshot, threshold: Int64) -> Bool {
        abs(metric(before, after).delta) < threshold
    }
}
