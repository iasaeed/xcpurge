/// A buildable unit (Xcode target or SwiftPM target) with its dependencies and settings.
public struct Module: Sendable {
    public var id: ModuleID
    public var kind: ModuleKind
    public var productName: String
    /// Swift module name (`PRODUCT_MODULE_NAME`, or the package target name).
    public var moduleName: String
    public var dependsOn: Set<ModuleID>
    /// Modules this one embeds (app extensions, watch apps, embedded frameworks).
    public var embeds: Set<ModuleID>
    public var settings: BuildSettings
    /// Effective Info.plist: physical `INFOPLIST_FILE` merged with `INFOPLIST_KEY_*` settings.
    public var infoPlist: [String: JSONValue]
    public var resourceBundleAccess: BundleAccess
    /// Root-relative directories that make up the module (synced folders, package target dir).
    public var rootPaths: [String]
    /// Root-relative files the build settings point at (Info.plist, entitlements, xcconfigs).
    public var settingsFiles: [String]

    public init(id: ModuleID, kind: ModuleKind, productName: String, moduleName: String,
                dependsOn: Set<ModuleID> = [], embeds: Set<ModuleID> = [], settings: BuildSettings = BuildSettings(),
                infoPlist: [String: JSONValue] = [:], resourceBundleAccess: BundleAccess? = nil,
                rootPaths: [String] = [], settingsFiles: [String] = []) {
        self.id = id
        self.kind = kind
        self.productName = productName
        self.moduleName = moduleName
        self.dependsOn = dependsOn
        self.embeds = embeds
        self.settings = settings
        self.infoPlist = infoPlist
        self.resourceBundleAccess = resourceBundleAccess ?? BundleAccess(kind: kind)
        self.rootPaths = rootPaths
        self.settingsFiles = settingsFiles
    }
}
