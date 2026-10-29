import Foundation

public enum DSStrings {
    public static let title = String(localized: "ds_title", bundle: .module)
    /// Missing `bundle: .module`: resolves against the app's main bundle at runtime.
    public static let noBundle = String(localized: "ds_no_bundle")
}
