/// Headline numbers of a report. Only actionable findings (something to delete, fix or look at) are counted in
/// the totals; `dynamicLookup` records (how a name is built at runtime) and `duplicate` members (copies that
/// belong to a set) are reported beside them, never inside them.
public struct FindingTally: Sendable, Equatable {
    public var high = 0
    public var medium = 0
    public var low = 0
    /// `dynamicLookup` records.
    public var dynamicLookups = 0
    /// Distinct duplicate sets (members that share a `groupID`; a member without one counts as its own set).
    public var duplicateSets = 0

    public init() {}

    public init(_ findings: [Finding]) {
        var groups = Set<String>()
        for f in findings {
            switch f.kind {
            case .dynamicLookup: dynamicLookups += 1
            case .duplicate: if !groups.insert(f.groupID ?? "\(f.path)\u{0}\(f.name ?? "")").inserted { continue }; duplicateSets += 1
            default:
                switch f.confidence {
                case .high: high += 1
                case .medium: medium += 1
                case .low: low += 1
                }
            }
        }
    }

    public init(high: Int, medium: Int, low: Int, dynamicLookups: Int = 0, duplicateSets: Int = 0) {
        self.high = high
        self.medium = medium
        self.low = low
        self.dynamicLookups = dynamicLookups
        self.duplicateSets = duplicateSets
    }

    /// Actionable findings: the number the headline shows.
    public var actionable: Int { high + medium + low }

    /// `392 dynamic lookups, 88 duplicate sets`; nil when there are none of either.
    public var informationalText: String? {
        var parts: [String] = []
        if dynamicLookups > 0 { parts.append("\(dynamicLookups) dynamic lookup\(dynamicLookups == 1 ? "" : "s")") }
        if duplicateSets > 0 { parts.append("\(duplicateSets) duplicate set\(duplicateSets == 1 ? "" : "s")") }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    /// `38 findings (8 high, 30 medium, 0 low)`.
    public var headline: String {
        "\(actionable) finding\(actionable == 1 ? "" : "s") (\(high) high, \(medium) medium, \(low) low)"
    }
}

extension FindingKind {
    /// False for records that describe the code rather than a problem in it (`dynamicLookup`, `duplicate`).
    public var isActionable: Bool { self != .dynamicLookup && self != .duplicate }
}
