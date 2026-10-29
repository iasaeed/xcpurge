// LANE: C
/// Entry points that make a source file live without any by-name reference (plan §4.5 step 3): attributes the
/// runtime or compiler consumes, system-instantiated conformances, and class names Interface Builder or an
/// Info.plist instantiates.
enum RootRules {
    /// Attributes that make the whole file a root.
    static let attributes: Set<String> = [
        "@main", "@UIApplicationMain", "@NSApplicationMain", "@objc", "@objcMembers", "@IBAction", "@IBOutlet",
        "@IBDesignable", "@IBInspectable", "@IBSegueAction", "@_cdecl", "@_exported", "@dynamicMemberLookup",
        "@Test", "@Suite",
    ]

    /// Supertypes / conformances the system instantiates (tests, app entry points, App Intents).
    static let supertypes: Set<String> = [
        "XCTestCase", "QuickSpec", "AsyncSpec", "App", "WidgetBundle", "AppIntent", "AppShortcutsProvider",
        "AppEntity", "AppEnum", "AppIntentsPackage", "LiveActivityIntent", "WidgetConfigurationIntent",
        "ControlConfigurationIntent", "AudioPlaybackIntent", "ForegroundContinuableIntent", "OpenIntent",
        "SetValueIntent", "TransientAppEntity", "IndexedEntity",
    ]

    /// Info.plist keys whose values name a class.
    static let classKeys: Set<String> = [
        "NSExtensionPrincipalClass", "UISceneDelegateClassName", "UISceneClassName", "NSPrincipalClass",
        "UIApplicationDelegateClassName", "WKExtensionDelegateClassName", "WKApplicationDelegateClassName",
        "CLKComplicationPrincipalClass",
    ]

    /// Class names instantiated by name: IB `customClass`, Info.plist class keys (`$(PRODUCT_MODULE_NAME).X` -> `X`).
    static func instantiatedClassNames(_ refs: ReferenceIndex) -> Set<String> {
        var out = Set<String>()
        for r in refs.references {
            switch r.kind {
            case .ibAttribute("customClass"):
                out.insert(r.value)
            case .plistValue, .buildSetting:
                guard let label = r.context?.label else { continue }
                let key = label.hasPrefix("INFOPLIST_KEY_") ? String(label.dropFirst("INFOPLIST_KEY_".count)) : label
                guard classKeys.contains(key) else { continue }
                out.insert(r.value.split(separator: ".").last.map(String.init) ?? r.value)
            default:
                continue
            }
        }
        return out
    }

    /// Why the file is a root, or nil when it is not.
    static func rootReason(_ d: DeclarationCollector.Result, fileName: String, instantiated: Set<String>,
                           hasDataModel: Bool) -> String? {
        if fileName == "main.swift" || fileName == "main.m" || fileName == "main.mm" { return "program entry point" }
        if let a = d.attributes.intersection(attributes).sorted().first { return "uses \(a)" }
        if hasDataModel, d.attributes.contains("@NSManaged") { return "Core Data managed object" }
        if let s = d.supertypes.intersection(supertypes).sorted().first { return "conforms to \(s)" }
        if let c = Set(d.types).intersection(instantiated).sorted().first { return "\(c) is instantiated by name" }
        return nil
    }
}
