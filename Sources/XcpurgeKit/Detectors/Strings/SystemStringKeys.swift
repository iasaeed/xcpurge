/// Keys of `InfoPlist.strings` / `InfoPlist.xcstrings` that the system reads, plus tables the system owns.
/// Such keys are never referenced from code, so they count as used.
public enum SystemStringKeys {
    static let exact: Set<String> = [
        "NSHumanReadableCopyright", "NSLocationTemporaryUsageDescriptionDictionary", "INAlternativeAppNames",
        "NSUbiquitousContainerName", "UTTypeDescription", "NSAccessoryTrackingUsageDescription",
        "NSUserActivityTypes", "UIApplicationShortcutItems", "NSExtension",
    ]
    static let prefixes = ["CFBundle", "UIApplicationShortcutItem", "NSLocation", "NSSiri", "INIntent", "UTType"]
    static let suffixes = ["UsageDescription", "UsageDescriptionDictionary", "DisplayName", "Description"]

    /// Tables the system loads by itself: every key counts as used.
    public static let systemTables: Set<String> = ["AppShortcuts"]

    /// Info.plist-related table names.
    public static func isInfoPlistTable(_ stem: String) -> Bool { stem == "InfoPlist" }

    /// True for keys the system reads out of an `InfoPlist` table.
    public static func isSystemKey(_ key: String) -> Bool {
        exact.contains(key) || prefixes.contains { key.hasPrefix($0) }
            || (key.hasPrefix("NS") || key.hasPrefix("NFC") || key.hasPrefix("OS")) && suffixes.contains { key.hasSuffix($0) }
    }

    /// Every key (at any depth) and every string value of an Info.plist: `InfoPlist.strings` localizes keys
    /// such as `NSCameraUsageDescription` and values such as shortcut item titles and document type names.
    public static func infoPlistTerms(_ plist: [String: JSONValue]) -> Set<String> {
        var terms = Set<String>()
        func walk(_ v: JSONValue) {
            switch v {
            case .string(let s): terms.insert(s)
            case .array(let a): a.forEach(walk)
            case .object(let o):
                for (k, child) in o { terms.insert(k); walk(child) }
            default: break
            }
        }
        walk(.object(plist))
        return terms
    }
}
