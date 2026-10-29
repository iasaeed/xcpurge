/// Where a reference token came from.
public enum RefKind: Sendable, Hashable {
    /// A string literal in code (`"hero"`).
    case stringLiteral
    /// An identifier after `.` (`.hero`, `ImageResource.hero`).
    case memberSymbol
    /// A bare identifier (`DeadHelper`), attribute (`@main`) or macro (`#Preview`).
    case identifier
    /// An Interface Builder attribute; associated value is the attribute name (`image`, `customClass`).
    case ibAttribute(String)
    /// A string value in a property list.
    case plistValue
    /// A build-setting value; associated value is the setting key.
    case buildSetting(String)
    /// A generated accessor use (SwiftGen/R.swift); associated value is the accessor path. `value` is the raw name.
    case accessorUse(String)

    public var mask: RefKindMask {
        switch self {
        case .stringLiteral: .stringLiteral
        case .memberSymbol: .memberSymbol
        case .identifier: .identifier
        case .ibAttribute: .ibAttribute
        case .plistValue: .plistValue
        case .buildSetting: .buildSetting
        case .accessorUse: .accessorUse
        }
    }
}
