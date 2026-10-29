import Foundation

/// Excluded from every target by the folder's exception set.
struct LegacyFormatter {
    func format(_ value: Int) -> String { "\(value)" }
}
