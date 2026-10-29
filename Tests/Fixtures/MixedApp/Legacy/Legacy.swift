import UIKit

/// Classic-group source, compiled through an explicit PBXBuildFile.
final class LegacyBanner {
    func image() -> UIImage? { UIImage(named: "legacy_used") }
    func title() -> String { NSLocalizedString("greeting", comment: "") }
}
