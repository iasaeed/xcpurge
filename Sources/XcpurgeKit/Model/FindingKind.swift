/// The specific kind of problem a finding reports.
public enum FindingKind: String, Codable, Sendable, CaseIterable, Comparable {
    case unusedAsset, unusedFont, unusedString, staleString, orphanFile, ghostReference,
         deadSource, unusedInterfaceFile, unusedResource, duplicate, dynamicLookup, staleIgnore

    /// Kebab-case spelling used on the command line (`--fail-on dead-source`).
    public var flagName: String {
        rawValue.reduce(into: "") { out, ch in
            if ch.isUppercase { out += "-" + ch.lowercased() } else { out.append(ch) }
        }
    }

    /// Informational kinds never fail a build unless named explicitly.
    public var isInformational: Bool { self == .dynamicLookup || self == .staleIgnore }

    public static func < (lhs: FindingKind, rhs: FindingKind) -> Bool { lhs.rawValue < rhs.rawValue }
}
