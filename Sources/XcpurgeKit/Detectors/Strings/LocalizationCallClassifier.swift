/// Decides whether a reference site is a localization lookup and which bundle and table it targets
/// (plan §4.6 step 4, §4.2 step 5).
public enum LocalizationCallClassifier {
    /// SwiftUI modifiers taking a `LocalizedStringKey` as first argument, beyond `CallContext.localizedViews`.
    static let extraCallees: Set<String> = [
        "accessibilityLabel", "accessibilityHint", "accessibilityValue", "navigationSubtitle", "badge",
        "ControlGroup", "GroupBox", "LabeledContent", "Gauge", "ShareLink", "ContentUnavailableView",
        "accessibilityInputLabels",
    ]

    /// Which bundle a localization call reads from.
    public enum BundleArg: Sendable, Equatable {
        /// No `bundle:` argument: `Bundle.main` at runtime.
        case none
        /// `.module`, `Bundle.module`, `#bundle`: the calling module's own bundle.
        case module
        /// `.main`, `Bundle.main`.
        case main
        /// Anything else (a variable, `Bundle(for:)`, a receiver): unknown, no narrowing.
        case other
    }

    /// True when a literal (or member symbol) at this site is a localization key.
    public static func isLocalization(_ ctx: CallContext?, extraMacros: [String] = []) -> Bool {
        guard let ctx else { return false }
        if ctx.isLocalization(extraMacros: extraMacros) { return true }
        if ctx.label == "localizedStringForKey" { return true }
        guard let callee = ctx.callee else { return false }
        if callee.hasPrefix("NSLocalizedString") || callee == "CFCopyLocalizedString" { return ctx.argIndex == 0 }
        if callee == "LocalizationValue" || callee == "LocalizedStringResource" || callee == "LocalizedStringKey" {
            return ctx.argIndex == 0 && (ctx.label == nil || ctx.label == "stringLiteral")
        }
        return extraCallees.contains(callee) && ctx.label == nil && ctx.argIndex == 0
    }

    public static func bundle(_ ctx: CallContext) -> BundleArg {
        // `bundle.localizedString(forKey:value:table:)`: the receiver is the bundle; FromTableInBundle passes it positionally.
        if ctx.callee == "localizedString" || ctx.callee == "localizedStringForKey" || ctx.label == "localizedStringForKey"
            || ctx.callee?.hasSuffix("InBundle") == true || ctx.callee == "CFCopyLocalizedStringFromTableInBundle" {
            return .other
        }
        guard let raw = ctx.bundle else { return .none }
        switch raw {
        case ".module", "Bundle.module", "#bundle", "Foundation.Bundle.module": return .module
        case ".main", "Bundle.main", "Foundation.Bundle.main": return .main
        default: return .other
        }
    }
}
