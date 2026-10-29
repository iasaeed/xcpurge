/// What a module builds; drives bundle semantics and test-reference handling.
public enum ModuleKind: String, Codable, Sendable {
    case app, appExtension, appClip, watchApp, framework, staticLib,
         packageLibrary, packageExecutable, unitTest, uiTest, macro, plugin, aggregate, unknown

    public var isTest: Bool { self == .unitTest || self == .uiTest }

    /// Maps an Xcode product type (`com.apple.product-type.…` or its abbreviation).
    public init(productType: String) {
        let type = productType.hasPrefix("com.apple.product-type.")
            ? String(productType.dropFirst("com.apple.product-type.".count)) : productType
        switch type {
        case "application.on-demand-install-capable": self = .appClip
        case "application.watchapp", "application.watchapp2": self = .watchApp
        case _ where type.hasPrefix("application"): self = .app
        case "tool": self = .app
        case _ where type.contains("extension"): self = .appExtension
        case "bundle.unit-test": self = .unitTest
        case "bundle.ui-testing": self = .uiTest
        case "library.static": self = .staticLib
        case _ where type.hasPrefix("framework"), "library.dynamic", "bundle", "xpc-service", "xcframework":
            self = .framework
        default: self = .unknown
        }
    }

    /// Maps a SwiftPM target type from `dump-package` (`regular`, `executable`, `test`, ...).
    public init(packageTargetType: String) {
        switch packageTargetType {
        case "executable": self = .packageExecutable
        case "test": self = .unitTest
        case "macro": self = .macro
        case "plugin": self = .plugin
        default: self = .packageLibrary
        }
    }
}
