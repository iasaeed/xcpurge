/// Predicts the Swift / ObjC symbols Xcode generates for an asset-catalog name (plan §4.3). There is no
/// official spec; the rules mirror observed Xcode output and are only used when no
/// `GeneratedAssetSymbols-Index.plist` is available.
public enum AssetSymbolMangler {
    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "open", "operator", "private", "precedencegroup", "protocol", "public", "rethrows",
        "static", "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default",
        "defer", "do", "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch",
        "where", "while", "Any", "as", "await", "false", "is", "nil", "self", "Self", "super", "throws", "true",
        "try", "Type", "Protocol",
    ]

    /// Swift symbol candidates for one asset: the leaf symbol (with a backticked twin for keywords and a
    /// `Color`/`Image`-stripped twin), plus the same prefixed by the namespace chain (`Icons.Settings.logo`).
    /// - Parameters:
    ///   - leaf: asset leaf name (folder name without extension).
    ///   - type: set type; colorsets drop a trailing `Color`, imagesets a trailing `Image`.
    ///   - namespace: provides-namespace folder chain, outermost first.
    public static func symbols(leaf: String, type: AssetType = .image, namespace: [String] = []) -> [String] {
        var leaves = [lowerCamel(leaf)]
        let strip = type == .color ? "Color" : type == .image ? "Image" : nil
        if let strip, let base = leaves.first, base.hasSuffix(strip), base.count > strip.count {
            leaves.append(String(base.dropLast(strip.count)))
        }
        leaves += leaves.filter { swiftKeywords.contains($0) }.map { "`\($0)`" }
        guard !namespace.isEmpty else { return leaves }
        let prefix = namespace.map(upperCamel).joined(separator: ".")
        return leaves + leaves.map { prefix + "." + $0 }
    }

    /// ObjC constant Xcode emits in `GeneratedAssetSymbols.h` (`ACImageNameHero`, `ACColorNameBrandColor`).
    public static func objcSymbol(leaf: String, type: AssetType) -> String? {
        let prefix: String
        switch type {
        case .image: prefix = "ACImageName"
        case .color: prefix = "ACColorName"
        default: return nil
        }
        return prefix + upperFirst(lowerCamel(leaf).trimmingLeadingUnderscore)
    }

    /// Words of a name: split on every non-letter, non-digit character; existing camel humps are kept.
    static func words(_ name: String) -> [String] {
        name.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
    }

    /// `japan-street` -> `japanStreet`, `ABCLogo` -> `abcLogo`, `2fa` -> `_2fa`, `IMG_0042` -> `img0042`.
    public static func lowerCamel(_ name: String) -> String {
        let parts = words(name)
        guard let first = parts.first else { return "" }
        var out = lowerLeadingRun(first) + parts.dropFirst().map(upperFirstLetter).joined()
        if let c = out.first, c.isNumber { out = "_" + out }
        return out
    }

    /// Namespace folder form: every word upper-camel (`my-icons` -> `MyIcons`).
    static func upperCamel(_ name: String) -> String {
        let out = words(name).map(upperFirstLetter).joined()
        if let c = out.first, c.isNumber { return "_" + out }
        return out
    }

    /// Lowercases the leading uppercase run; a run longer than one letter that is followed by a lowercase
    /// letter keeps its last letter (the start of the next hump) uppercase.
    static func lowerLeadingRun(_ word: String) -> String {
        let chars = Array(word)
        var run = 0
        while run < chars.count, chars[run].isUppercase { run += 1 }
        guard run > 0 else { return word }
        let followedByLower = run < chars.count && chars[run].isLowercase
        let lowered = run > 1 && followedByLower ? run - 1 : run
        return String(chars[..<lowered]).lowercased() + String(chars[lowered...])
    }

    /// Uppercases the first letter, skipping leading digits (`2x` -> `2X`, `0042` stays).
    static func upperFirstLetter(_ word: String) -> String {
        guard let i = word.firstIndex(where: \.isLetter) else { return word }
        return String(word[..<i]) + word[i].uppercased() + String(word[word.index(after: i)...])
    }

    static func upperFirst(_ word: String) -> String {
        guard let c = word.first else { return word }
        return c.uppercased() + word.dropFirst()
    }

    /// Loose comparison key: lowercased letters and digits only (`brand_mark`, `brandMark` -> `brandmark`).
    public static func fuzzyKey(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}

private extension String {
    var trimmingLeadingUnderscore: String { hasPrefix("_") ? String(dropFirst()) : self }
}
