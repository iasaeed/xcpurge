/// Syntactic context of a reference: the call it sits in and the argument label, plus call-level
/// `tableName:`/`bundle:` arguments and, for member symbols, the dotted qualifier before it.
public struct CallContext: Sendable, Hashable {
    /// Function or type being called (`UIImage`, `Text`, `url`, `NSLocalizedString`); IB element; plist top-level key.
    public var callee: String?
    /// Argument label (`named`, `forResource`, `localized`); IB attribute; plist key.
    public var label: String?
    /// Zero-based argument position within the call.
    public var argIndex: Int
    /// Literal `tableName:` / `table:` argument of the same call.
    public var table: String?
    /// Source text of the `bundle:` argument of the same call (`.module`, `#bundle`, `Bundle.main`).
    public var bundle: String?
    /// Dotted chain before a member symbol (`Asset.Colors` for `Asset.Colors.brand`, `""` for `.brand`).
    public var qualifier: String?

    public init(callee: String? = nil, label: String? = nil, argIndex: Int = 0, table: String? = nil,
                bundle: String? = nil, qualifier: String? = nil) {
        self.callee = callee
        self.label = label
        self.argIndex = argIndex
        self.table = table
        self.bundle = bundle
        self.qualifier = qualifier
    }

    static let localizedViews: Set<String> = [
        "Text", "Button", "Label", "Toggle", "NavigationLink", "Section", "Picker", "LocalizedStringKey",
        "LocalizedStringResource", "navigationTitle", "Menu", "Link", "TextField", "SecureField", "Stepper",
        "Tab", "DatePicker", "ProgressView", "Slider", "alert", "confirmationDialog", "help",
    ]
    static let assetCallees: Set<String> = [
        "UIImage", "Image", "Color", "UIColor", "NSImage", "NSColor", "NSDataAsset", "ImageResource",
        "ColorResource", "setAlternateIconName", "imageNamed", "colorNamed",
    ]

    /// True when a string literal at this position is a localization key.
    public func isLocalization(extraMacros: [String] = []) -> Bool {
        guard let callee else { return false }
        if extraMacros.contains(callee) { return argIndex == 0 }
        if callee.hasPrefix("NSLocalizedString") { return argIndex == 0 }
        if callee == "String" { return label == "localized" }
        if callee == "localizedString" || callee == "localizedStringForKey" {
            return label == "forKey" || label == "localizedStringForKey"
        }
        return Self.localizedViews.contains(callee) && label == nil && argIndex == 0
    }

    /// True when this call loads an asset by name.
    public var isAssetLookup: Bool {
        guard let callee else { return false }
        return Self.assetCallees.contains(callee) || label == "imageNamed" || label == "colorNamed"
    }

    /// True when this call loads a bundle resource by name.
    public var isResourceLookup: Bool {
        label == "forResource" || label == "pathForResource" || label == "URLForResource"
    }
}
