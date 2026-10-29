import Foundation

/// Measures a built app bundle (iOS flat or macOS `Contents/` layout), or the `.app` inside an `.ipa`.
/// Sections: `Executable`, `Assets.car`, each `*.lproj`, each `Frameworks/*`, `PlugIns/*`, `Extensions/*`,
/// `Watch/*`, `AppClips/*`, and `Other resources`; they add up to `total` (regular files, logical sizes,
/// symlinks not followed).
public enum AppMeasurer {
    static let containerFolders = ["Frameworks", "PlugIns", "Extensions", "Watch", "AppClips"]

    public static func measure(_ url: URL) throws -> AppSize {
        if url.pathExtension.lowercased() == "ipa" { return try measureIPA(url) }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else {
            throw XcpurgeError.notFound(url.path)
        }
        return measureBundle(url, reportedPath: url.path)
    }

    /// Unzips the `.ipa` into a temporary folder, measures `Payload/*.app`, removes the folder.
    static func measureIPA(_ url: URL) throws -> AppSize {
        guard FileManager.default.fileExists(atPath: url.path) else { throw XcpurgeError.notFound(url.path) }
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("xcpurge-ipa-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = ["-x", "-k", url.path, tmp.path]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        let payload = tmp.appendingPathComponent("Payload")
        let app = ((try? FileManager.default.contentsOfDirectory(atPath: payload.path)) ?? []).sorted().first { $0.hasSuffix(".app") }
        guard process.terminationStatus == 0, let app else {
            throw XcpurgeError.invalidConfig("\(url.path): no Payload/*.app inside (is it an .ipa?)")
        }
        return measureBundle(payload.appendingPathComponent(app), reportedPath: url.path)
    }

    static func measureBundle(_ app: URL, reportedPath: String) -> AppSize {
        let fm = FileManager.default
        let isMac = fm.fileExists(atPath: app.appendingPathComponent("Contents/Info.plist").path)
        let plist = app.appendingPathComponent(isMac ? "Contents/Info.plist" : "Info.plist")
        let info = fm.contents(atPath: plist.path)
            .flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }
        let executable = info?["CFBundleExecutable"] as? String ?? app.deletingPathExtension().lastPathComponent
        var sections: [String: Int64] = [:]
        var total: Int64 = 0
        if let e = fm.enumerator(atPath: app.path) {
            while let rel = e.nextObject() as? String {
                guard e.fileAttributes?[.type] as? FileAttributeType == .typeRegular else { continue }
                let size = (e.fileAttributes?[.size] as? NSNumber)?.int64Value ?? 0
                total += size
                sections[section(of: rel, isMac: isMac, executable: executable), default: 0] += size
            }
        }
        let ordered = sections.map { AppSection(name: $0.key, bytes: $0.value) }.sorted { (rank($0.name), $0.name) < (rank($1.name), $1.name) }
        return AppSize(path: reportedPath, total: total, sections: ordered)
    }

    /// Section of a bundle-relative file path.
    static func section(of rel: String, isMac: Bool, executable: String) -> String {
        var p = rel
        if isMac, p.hasPrefix("Contents/") { p.removeFirst("Contents/".count) }
        let parts = p.split(separator: "/").map(String.init)
        if parts.count > 1, containerFolders.contains(parts[0]) { return parts[0] + "/" + parts[1] }
        if p == executable || p == "MacOS/" + executable { return "Executable" }
        if p.hasPrefix("Resources/") { p.removeFirst("Resources/".count) }
        let r = p.split(separator: "/").map(String.init)
        if r.count > 1, r[0].hasSuffix(".lproj") { return r[0] }
        if p == "Assets.car" { return "Assets.car" }
        return "Other resources"
    }

    private static func rank(_ name: String) -> Int {
        if name == "Executable" { return 0 }
        if name == "Assets.car" { return 1 }
        if name.hasSuffix(".lproj") { return 2 }
        if let i = containerFolders.firstIndex(where: { name.hasPrefix($0 + "/") }) { return 3 + i }
        return 10
    }
}
