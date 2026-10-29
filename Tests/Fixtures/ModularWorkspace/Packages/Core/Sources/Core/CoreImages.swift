import UIKit

public enum CoreImages {
    public static func duplicate() -> UIImage? {
        UIImage(named: "core_dup", in: .module, compatibleWith: nil)
    }

    /// Core does not depend on DesignSystem, so this name cannot resolve to DesignSystem's `ds_isolated`.
    public static func isolated() -> UIImage? {
        UIImage(named: "ds_isolated", in: .module, compatibleWith: nil)
    }
}
