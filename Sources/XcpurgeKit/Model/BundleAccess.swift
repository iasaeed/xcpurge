/// Which bundle a module's resources end up in at runtime.
public enum BundleAccess: String, Codable, Sendable {
    /// `Bundle.main` (apps, extensions).
    case main
    /// `Bundle.module` (SwiftPM targets with resources).
    case module
    /// The framework or test bundle (`Bundle(for:)`, `#bundle`).
    case framework

    public init(kind: ModuleKind) {
        switch kind {
        case .app, .appExtension, .appClip, .watchApp, .aggregate, .unknown: self = .main
        case .packageLibrary, .packageExecutable, .macro, .plugin: self = .module
        case .framework, .staticLib, .unitTest, .uiTest: self = .framework
        }
    }
}
