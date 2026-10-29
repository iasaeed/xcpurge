import Foundation

/// Builds a target's effective Info.plist: the physical `INFOPLIST_FILE` plus `INFOPLIST_KEY_*` settings when
/// `GENERATE_INFOPLIST_FILE = YES` (physical values win).
public enum InfoPlistReader {
    /// - Parameter projectDir: absolute `SRCROOT`.
    /// - Returns: the merged plist and the absolute path of the physical file, if any.
    public static func read(settings: BuildSettings, projectDir: String) -> (plist: [String: JSONValue], file: String?) {
        var plist: [String: JSONValue] = [:]
        if settings.isEnabled("GENERATE_INFOPLIST_FILE"), let config = settings.preferredConfiguration {
            for (key, value) in settings.configurations[config] ?? [:] where key.hasPrefix("INFOPLIST_KEY_") {
                plist[String(key.dropFirst("INFOPLIST_KEY_".count))] = .string(value)
            }
        }
        guard let infoFile = settings.value("INFOPLIST_FILE"), !infoFile.isEmpty else { return (plist, nil) }
        let path = RelPath.join(projectDir, infoFile)
        if let data = FileManager.default.contents(atPath: path),
           let dict = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] {
            for (key, value) in dict { plist[key] = JSONValue(any: value) }
        }
        return (plist, path)
    }
}
