import Foundation

/// Finds the DerivedData folder for a workspace/project: `--derived-data` wins, else the newest
/// `~/Library/Developer/Xcode/DerivedData/<Name>-*`.
public enum DerivedDataLocator {
    public static let defaultBase = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Developer/Xcode/DerivedData")

    public static func locate(names: [String], override: String?, base: URL = defaultBase) -> URL? {
        let fm = FileManager.default
        if let override {
            let url = URL(fileURLWithPath: NSString(string: override).expandingTildeInPath)
            return fm.fileExists(atPath: url.path) ? url : nil
        }
        guard let entries = try? fm.contentsOfDirectory(at: base, includingPropertiesForKeys: [.contentModificationDateKey])
        else { return nil }
        var best: (URL, Date)?
        for name in names {
            for entry in entries where entry.lastPathComponent.hasPrefix(name + "-") {
                let date = (try? entry.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate ?? .distantPast
                if best == nil || date > best!.1 { best = (entry, date) }
            }
            if best != nil { break }
        }
        return best?.0
    }
}
