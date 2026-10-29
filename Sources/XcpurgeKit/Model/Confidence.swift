/// How sure xcpurge is that a finding is real; ordered low < medium < high.
public enum Confidence: String, Codable, Comparable, Sendable, CaseIterable {
    case low, medium, high

    private var rank: Int {
        switch self {
        case .low: 0
        case .medium: 1
        case .high: 2
        }
    }

    public static func < (lhs: Confidence, rhs: Confidence) -> Bool { lhs.rank < rhs.rank }
}
