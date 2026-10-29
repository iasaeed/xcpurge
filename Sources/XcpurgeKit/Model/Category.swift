/// Top-level grouping of findings; each detector owns one category.
public enum Category: String, Codable, Sendable, CaseIterable, Comparable {
    case assets, strings, files, duplicates

    public static func < (lhs: Category, rhs: Category) -> Bool {
        allCases.firstIndex(of: lhs)! < allCases.firstIndex(of: rhs)!
    }
}
