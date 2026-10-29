/// Names under which a loose (non-catalog) image file can be loaded: `icon@2x~ipad.png` is found by
/// `UIImage(named: "icon")`, `"icon.png"`, or its full file name.
public enum LooseImageNormalizer {
    /// Device / scale / appearance suffixes stripped from the stem, outermost first.
    static let suffixes = ["~ipad", "~iphone", "~mac", "~tv", "~watch", "~car", "-dark", "_dark", "@1x", "@2x", "@3x"]

    /// Base name with every suffix removed (`icon@2x~ipad.png` -> `icon`).
    public static func baseName(_ fileName: String) -> String {
        var base = RelPath.stem(fileName)
        var changed = true
        while changed {
            changed = false
            for suffix in suffixes where base.count > suffix.count && base.lowercased().hasSuffix(suffix) {
                base = String(base.dropLast(suffix.count))
                changed = true
            }
        }
        return base
    }

    /// Every lookup name for the file, most specific first, without duplicates.
    public static func candidates(_ fileName: String) -> [String] {
        let stem = RelPath.stem(fileName)
        let ext = fileName.count > stem.count ? String(fileName.dropFirst(stem.count)) : ""
        let base = baseName(fileName)
        var seen = Set<String>()
        return [fileName, stem, base, base + ext].filter { !$0.isEmpty && seen.insert($0).inserted }
    }
}
