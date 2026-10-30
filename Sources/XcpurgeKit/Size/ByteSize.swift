import Foundation

/// Parses human byte counts the way `ByteFormatter` prints them (base 1024): `500`, `500B`, `100KB`, `1.5 MB`, `2GB`.
public enum ByteSize {
    static let units: [String: Int64] = ["B": 1, "KB": 1 << 10, "MB": 1 << 20, "GB": 1 << 30]

    /// `ByteFormatter.string` for callers outside the module (`1.2 MB`).
    public static func format(_ bytes: Int64) -> String { ByteFormatter.string(bytes) }

    /// nil when the text is not a non-negative size with an optional unit, or does not fit in an Int64.
    public static func parse(_ text: String) -> Int64? {
        let trimmed = text.trimmingCharacters(in: .whitespaces).uppercased()
        guard let match = trimmed.range(of: #"^(\d+(?:\.\d+)?)\s*(B|KB|MB|GB)?$"#, options: .regularExpression),
              match == trimmed.startIndex..<trimmed.endIndex else { return nil }
        let unitStart = trimmed.firstIndex { $0.isLetter } ?? trimmed.endIndex
        let number = trimmed[..<unitStart].trimmingCharacters(in: .whitespaces)
        let unit = String(trimmed[unitStart...])
        guard let value = Double(number), let factor = unit.isEmpty ? 1 : units[unit] else { return nil }
        let bytes = (value * Double(factor)).rounded()
        guard fitsInt64(bytes) else { return nil }
        return Int64(bytes)
    }

    /// `Double(Int64.max)` rounds up to 2^63, which `Int64(_:)` traps on; finite values below it convert.
    static func fitsInt64(_ value: Double) -> Bool { value.isFinite && value >= 0 && value < Double(Int64.max) }
}

/// A growth limit for `--fail-if-grows`: absolute bytes (`100KB`) or a share of the base (`2%`).
public enum SizeLimit: Equatable, Sendable {
    case bytes(Int64)
    case percent(Double)

    public init?(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        if trimmed.hasSuffix("%") {
            guard let value = Double(trimmed.dropLast().trimmingCharacters(in: .whitespaces)), ByteSize.fitsInt64(value) else { return nil }
            self = .percent(value)
        } else if let bytes = ByteSize.parse(trimmed) {
            self = .bytes(bytes)
        } else {
            return nil
        }
    }

    /// Bytes this limit allows on top of `base`; a share that exceeds Int64 allows everything.
    public func allowance(base: Int64) -> Int64 {
        switch self {
        case .bytes(let b): return b
        case .percent(let p):
            let bytes = (Double(base) * p / 100).rounded(.down)
            return ByteSize.fitsInt64(bytes) ? Int64(bytes) : Int64.max
        }
    }

    /// `100.0 KB` or `2%`.
    public var description: String {
        switch self {
        case .bytes(let b): ByteFormatter.string(b)
        case .percent(let p): p == p.rounded() ? "\(Int(p))%" : "\(p)%"
        }
    }
}
