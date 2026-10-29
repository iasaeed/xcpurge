import Foundation

/// Excluded from App by the folder's membership exceptions, and from nothing else: an orphan.
struct OldLegacyFormatter {
    func format(_ value: Int) -> String { String(value) }
}
