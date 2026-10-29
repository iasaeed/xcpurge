import Foundation

/// A JSON / property-list value tree; Codable and Sendable so it can sit in models.
public enum JSONValue: Sendable, Hashable, Codable {
    case string(String)
    case number(Double)
    case bool(Bool)
    case array([JSONValue])
    case object([String: JSONValue])
    case null

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let b = try? c.decode(Bool.self) { self = .bool(b) }
        else if let n = try? c.decode(Double.self) { self = .number(n) }
        else if let s = try? c.decode(String.self) { self = .string(s) }
        else if let a = try? c.decode([JSONValue].self) { self = .array(a) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let s): try c.encode(s)
        case .number(let n): try c.encode(n)
        case .bool(let b): try c.encode(b)
        case .array(let a): try c.encode(a)
        case .object(let o): try c.encode(o)
        case .null: try c.encodeNil()
        }
    }

    /// Converts a `PropertyListSerialization` / `JSONSerialization` result.
    public init(any: Any) {
        switch any {
        case let s as String: self = .string(s)
        case let n as NSNumber:
            self = CFGetTypeID(n) == CFBooleanGetTypeID() ? .bool(n.boolValue) : .number(n.doubleValue)
        case let a as [Any]: self = .array(a.map(JSONValue.init(any:)))
        case let d as [String: Any]: self = .object(d.mapValues(JSONValue.init(any:)))
        case let date as Date: self = .string(ISO8601DateFormatter().string(from: date))
        case let data as Data: self = .string(data.base64EncodedString())
        default: self = .null
        }
    }

    public var stringValue: String? { if case .string(let s) = self { s } else { nil } }
    public var arrayValue: [JSONValue]? { if case .array(let a) = self { a } else { nil } }
    public var objectValue: [String: JSONValue]? { if case .object(let o) = self { o } else { nil } }
    public var boolValue: Bool? { if case .bool(let b) = self { b } else { nil } }

    public subscript(key: String) -> JSONValue? { objectValue?[key] }

    /// All string leaves with the key path that leads to them (`CFBundleIcons.CFBundlePrimaryIcon.CFBundleIconName`).
    public func stringLeaves(path: [String] = []) -> [(path: [String], value: String)] {
        switch self {
        case .string(let s): [(path, s)]
        case .array(let a): a.flatMap { $0.stringLeaves(path: path) }
        case .object(let o): o.keys.sorted().flatMap { o[$0]!.stringLeaves(path: path + [$0]) }
        default: []
        }
    }
}
