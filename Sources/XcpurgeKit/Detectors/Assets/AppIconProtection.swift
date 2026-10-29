/// Asset names a target uses through build settings or its Info.plist rather than code: app icons
/// (primary, alternate, include-all), accent and widget colors, complications, launch images and the
/// `UILaunchScreen` image / color.
public struct AppIconProtection: Sendable {
    /// Build settings whose values are asset names.
    public static let settingKeys = [
        "ASSETCATALOG_COMPILER_APPICON_NAME", "ASSETCATALOG_COMPILER_ALTERNATE_APPICON_NAMES",
        "ASSETCATALOG_COMPILER_GLOBAL_ACCENT_COLOR_NAME", "ASSETCATALOG_COMPILER_WIDGET_BACKGROUND_COLOR_NAME",
        "ASSETCATALOG_COMPILER_COMPLICATION_NAME", "ASSETCATALOG_COMPILER_LAUNCHIMAGE_NAME",
    ]
    public static let includeAllKey = "ASSETCATALOG_COMPILER_INCLUDE_ALL_APPICON_ASSETS"
    /// Info.plist top-level keys whose string leaves (and alternate-icon dictionary keys) name assets.
    static let plistKeyPrefixes = ["CFBundleIcons", "UILaunchScreen", "UILaunchImages", "CFBundleIconFile", "CFBundleIconName"]

    /// (module, name, reason) rows.
    private var entries: [ModuleID: [String: String]] = [:]
    private var includeAll: Set<ModuleID> = []

    public init(graph: ModuleGraph) {
        for module in graph.sorted {
            for key in Self.settingKeys {
                for value in module.settings.values(key) {
                    add(module.id, value, "named by \(key) in \(module.id.name)")
                }
            }
            if module.settings.isEnabled(Self.includeAllKey) { includeAll.insert(module.id) }
            for key in module.infoPlist.keys.sorted() where Self.plistKeyPrefixes.contains(where: key.hasPrefix) {
                let value = module.infoPlist[key]!
                for leaf in value.stringLeaves() { add(module.id, leaf.value, "named by Info.plist \(key) in \(module.id.name)") }
                for alternate in Self.alternateIconKeys(value) {
                    add(module.id, alternate, "named by Info.plist CFBundleAlternateIcons in \(module.id.name)")
                }
            }
        }
    }

    private mutating func add(_ module: ModuleID, _ name: String, _ reason: String) {
        guard !name.isEmpty else { return }
        if entries[module, default: [:]][name] == nil { entries[module, default: [:]][name] = reason }
    }

    /// Dictionary keys under any `CFBundleAlternateIcons` object.
    static func alternateIconKeys(_ value: JSONValue) -> [String] {
        guard case .object(let dict) = value else { return [] }
        var out: [String] = []
        for key in dict.keys.sorted() {
            if key == "CFBundleAlternateIcons", case .object(let icons)? = dict[key] { out += icons.keys.sorted() }
            out += alternateIconKeys(dict[key]!)
        }
        return out
    }

    /// Why `names` are kept, when a module in `consumers` names one of them (case-insensitively).
    /// - Parameter includeAllApplies: true for app-icon sets, which `INCLUDE_ALL_APPICON_ASSETS` keeps.
    public func reason(for names: [String], consumers: Set<ModuleID>, includeAllApplies: Bool = false) -> String? {
        let lowered = Set(names.map { $0.lowercased() })
        for module in consumers.sorted() {
            guard let named = entries[module] else { continue }
            for (name, reason) in named.sorted(by: { $0.key < $1.key }) where lowered.contains(name.lowercased())
                || lowered.contains(RelPath.stem(name).lowercased()) {
                return reason
            }
        }
        if includeAllApplies, let module = consumers.sorted().first(where: includeAll.contains) {
            return "\(Self.includeAllKey) is set in \(module.name)"
        }
        return nil
    }
}
