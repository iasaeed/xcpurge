/// Set of `RefKind`s used to filter reference lookups.
public struct RefKindMask: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let stringLiteral = RefKindMask(rawValue: 1 << 0)
    public static let memberSymbol = RefKindMask(rawValue: 1 << 1)
    public static let identifier = RefKindMask(rawValue: 1 << 2)
    public static let ibAttribute = RefKindMask(rawValue: 1 << 3)
    public static let plistValue = RefKindMask(rawValue: 1 << 4)
    public static let buildSetting = RefKindMask(rawValue: 1 << 5)
    public static let accessorUse = RefKindMask(rawValue: 1 << 6)
    public static let implicitRawValue = RefKindMask(rawValue: 1 << 7)

    /// Everything that carries a raw name as a string (literals, IB, plist, settings, accessors).
    public static let names: RefKindMask = [.stringLiteral, .ibAttribute, .plistValue, .buildSetting, .accessorUse]
    public static let symbols: RefKindMask = [.memberSymbol, .identifier]
    public static let all = RefKindMask(rawValue: 0xFF)
}
