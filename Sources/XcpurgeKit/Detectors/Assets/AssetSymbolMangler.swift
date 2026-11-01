/// Predicts the Swift / ObjC symbols Xcode generates for an asset-catalog name (plan §4.3). There is no
/// official spec; the rules reproduce `actool --generate-swift-asset-symbols` / `--generate-objc-asset-symbols`
/// output (Xcode 26 and 27, checked name by name) and are only used when no `GeneratedAssetSymbols-Index.plist`
/// is available.
///
/// Words split on every non-letter, non-digit character, at letter/digit boundaries and at camel humps
/// (`HTTPServer` -> `HTTP` `Server`). Trailing `Color` / `Image` words are dropped (any case, any set type) while
/// more than one word remains. A name with no lowercase letters keeps its words verbatim joined by `_`
/// (`IMG_0042`, `A1` -> `A_1`); otherwise the first word is lowercased and the rest capitalized. A leading digit
/// gets an `_` prefix. Image and symbol sets produce `ImageResource` symbols, color sets `ColorResource` symbols;
/// other set types produce none.
public enum AssetSymbolMangler {
    /// Leaf symbols actool wraps in backticks (`async`, `await`, `open`, `type`, `any` are left bare).
    static let swiftKeywords: Set<String> = [
        "associatedtype", "class", "deinit", "enum", "extension", "fileprivate", "func", "import", "init", "inout",
        "internal", "let", "operator", "private", "precedencegroup", "protocol", "public", "rethrows", "static",
        "struct", "subscript", "typealias", "var", "break", "case", "catch", "continue", "default", "defer", "do",
        "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return", "throw", "switch", "where", "while",
        "as", "false", "is", "nil", "self", "super", "throws", "true", "try",
    ]

    /// Namespace enum names actool wraps in backticks.
    static let namespaceKeywords: Set<String> = ["Any", "Protocol", "Self", "Type"]

    /// The generated symbols an asset owns once collisions in its catalog group are settled.
    public struct OwnedSymbols: Sendable, Hashable {
        /// Qualified Swift symbol (`Icons.MyTabs.home`), nil when none is generated or another asset owns it.
        public var swift: String?
        /// ObjC constant (`ACImageNameIconsMyTabsHome`), nil when none is generated or another asset owns it.
        public var objc: String?
        /// The asset would generate a Swift symbol, but an earlier asset or namespace took it.
        public var lostSwift = false
        /// A namespace folder on the asset's chain mangles to the same enum as a sibling folder. Which folder keeps
        /// the enum then depends on how the catalog was written to disk, not on the names (probed: the same two
        /// folders flip with creation order), so `swift` / `lostSwift` are a guess.
        public var orderDependent = false

        public init(swift: String? = nil, objc: String? = nil, lostSwift: Bool = false, orderDependent: Bool = false) {
            self.swift = swift
            self.objc = objc
            self.lostSwift = lostSwift
            self.orderDependent = orderDependent
        }
    }

    /// True for set types that get generated symbols (image, symbol and color sets).
    public static func generatesSymbols(_ type: AssetType) -> Bool {
        type == .image || type == .symbol || type == .color
    }

    /// Swift symbol candidates for one asset: the leaf symbol, plus the namespace-qualified one
    /// (`Icons.Settings.logo`) when the asset sits in provides-namespace folders. Collisions are not considered.
    /// - Parameters:
    ///   - leaf: asset leaf name (folder name without extension).
    ///   - type: set type; only image, symbol and color sets generate symbols.
    ///   - namespace: provides-namespace folder chain, outermost first.
    public static func symbols(leaf: String, type: AssetType = .image, namespace: [String] = []) -> [String] {
        guard generatesSymbols(type), let leafSymbol = leafSymbol(leaf) else { return [] }
        guard !namespace.isEmpty else { return [leafSymbol] }
        let chain = namespace.compactMap(namespaceSymbol)
        guard chain.count == namespace.count else { return [leafSymbol] }
        return [leafSymbol, (chain + [leafSymbol]).joined(separator: ".")]
    }

    /// Qualified Swift symbol (`Icons.MyTabs.home`), ignoring collisions; nil for set types without symbols
    /// and names without letters or digits.
    public static func swiftSymbol(leaf: String, type: AssetType = .image, namespace: [String] = []) -> String? {
        guard generatesSymbols(type), let leafSymbol = leafSymbol(leaf) else { return nil }
        let chain = namespace.compactMap(namespaceSymbol)
        guard chain.count == namespace.count else { return nil }
        return (chain + [leafSymbol]).joined(separator: ".")
    }

    /// ObjC constant Xcode emits in `GeneratedAssetSymbols.h` (`ACImageNameHero`, `ACColorNameBrandColor`,
    /// `ACImageName_IMG_0042`, `ACImageNameIconsMyTabsHome`). Non-ASCII letters are dropped from camel-cased names.
    public static func objcSymbol(leaf: String, type: AssetType, namespace: [String] = []) -> String? {
        let prefix: String
        switch type {
        case .image, .symbol: prefix = "ACImageName"
        case .color: prefix = "ACColorName"
        default: return nil
        }
        let parts = (namespace + [leaf]).flatMap(words)
        guard let first = parts.first else { return nil }
        let body: String
        if isAllCaps(parts) {
            body = parts.count > 1 ? "_" + parts.joined(separator: "_") : first
        } else {
            body = String(parts.map(upperFirst).joined().filter(\.isASCII))
        }
        return body.isEmpty ? nil : prefix + body
    }

    /// Settles collisions the way actool does for one target's catalogs: within a resource kind (images and symbol
    /// sets, or colors) and namespace scope, the asset whose name sorts first (byte order) owns a symbol and later
    /// ones get none (sets with the very same name share it); an asset named exactly like a namespace folder of its
    /// kind gets none; a namespace folder that mangles like an earlier sibling takes its whole subtree with it (see
    /// `OwnedSymbols.orderDependent`). ObjC constants are settled the same way, across the whole group. Returns every
    /// asset's symbols, keyed by `CatalogAsset.path`.
    public static func ownedSymbols(in assets: [CatalogAsset]) -> [String: OwnedSymbols] {
        let ordered = assets.sorted { byteOrder($0.name, $1.name) || ($0.name == $1.name && $0.path < $1.path) }
        var out: [String: OwnedSymbols] = [:]
        // Symbol -> owning asset name. Sets with the very same name (in several catalogs or folders) share it.
        var ownerObjC: [String: String] = [:]
        for asset in ordered {
            var owned = OwnedSymbols()
            if let objc = objcSymbol(leaf: asset.leaf, type: asset.type, namespace: asset.namespace),
               ownerObjC[objc, default: asset.name] == asset.name {
                ownerObjC[objc] = asset.name
                owned.objc = objc
            }
            out[asset.path] = owned
        }
        for isColor in [false, true] {
            let group = ordered.filter { generatesSymbols($0.type) && ($0.type == .color) == isColor }
            let (scopes, contested) = namespaceScopes(group)
            var owner: [String: String] = [:]
            for asset in group {
                guard let leafSymbol = leafSymbol(asset.leaf) else { continue }
                let chain = asset.namespace.joined(separator: "/")
                out[asset.path]?.orderDependent = contested.contains(chain)
                guard let scope = scopes[chain] ?? nil, scopes[asset.name] == nil,
                      case let symbol = scope.isEmpty ? leafSymbol : scope + "." + leafSymbol,
                      owner[symbol, default: asset.name] == asset.name else {
                    out[asset.path]?.lostSwift = true
                    continue
                }
                owner[symbol] = asset.name
                out[asset.path]?.swift = symbol
            }
        }
        return out
    }

    /// Raw namespace chain (`Icons/my-tabs`, `""` for the root) -> qualified enum path (`Icons.MyTabs`), or nil
    /// when the chain or one of its ancestors lost its enum to a sibling folder (byte order decides here); plus the
    /// chains at or under a folder whose enum a sibling folder also produces.
    private static func namespaceScopes(_ assets: [CatalogAsset]) -> (scopes: [String: String?], contested: Set<String>) {
        var chains = Set<[String]>()
        for asset in assets {
            for depth in asset.namespace.indices { chains.insert(Array(asset.namespace.prefix(depth + 1))) }
        }
        var siblings: [String: Int] = [:]
        for chain in chains {
            if let symbol = namespaceSymbol(chain.last!) {
                siblings[chain.dropLast().joined(separator: "/") + "|" + symbol, default: 0] += 1
            }
        }
        var scopes: [String: String?] = ["": ""]
        var contested = Set<String>()
        var takenInParent: [String: Set<String>] = [:]
        let ordered = chains.sorted {
            $0.count != $1.count ? $0.count < $1.count : byteOrder($0.joined(separator: "/"), $1.joined(separator: "/"))
        }
        for chain in ordered {
            let parent = chain.dropLast().joined(separator: "/")
            let key = chain.joined(separator: "/")
            let symbol = namespaceSymbol(chain.last!)
            if contested.contains(parent) || symbol.map({ siblings[parent + "|" + $0, default: 0] > 1 }) == true {
                contested.insert(key)
            }
            guard let parentScope = scopes[parent] ?? nil, let symbol,
                  takenInParent[parent, default: []].insert(symbol).inserted else {
                scopes[key] = .some(nil)
                continue
            }
            scopes[key] = parentScope.isEmpty ? symbol : parentScope + "." + symbol
        }
        return (scopes, contested)
    }

    // MARK: - Name rules

    /// Unqualified Swift symbol for an asset leaf (`japan-street` -> `japanStreet`, `2fa` -> `_2Fa`,
    /// `IMG_0042` -> `IMG_0042`, `brandColor` -> `brand`, `default` -> `` `default` ``), nil when empty.
    public static func leafSymbol(_ leaf: String) -> String? {
        let parts = strippingSuffixes(words(leaf))
        guard let first = parts.first else { return nil }
        var out = isAllCaps(parts)
            ? parts.joined(separator: "_")
            : first.lowercased() + parts.dropFirst().map(upperFirst).joined()
        if out.first.map(isASCIIDigit) == true { out = "_" + out }
        return swiftKeywords.contains(out) ? "`\(out)`" : out
    }

    /// Namespace enum for a provides-namespace folder (`my-tabs` -> `MyTabs`, `hero_image` -> `Hero`,
    /// `IMG_0042` -> `IMG_0042`, `self` -> `` `Self` ``), nil when empty.
    public static func namespaceSymbol(_ folder: String) -> String? {
        let parts = strippingSuffixes(words(folder))
        guard !parts.isEmpty else { return nil }
        var out = isAllCaps(parts) ? parts.joined(separator: "_") : parts.map(upperFirst).joined()
        if out.first.map(isASCIIDigit) == true { out = "_" + out }
        return namespaceKeywords.contains(out) ? "`\(out)`" : out
    }

    /// Words of a name: runs of letters and digits, split at letter/digit boundaries, before an uppercase letter
    /// that follows a lowercase one, and before the last capital of an uppercase run followed by a lowercase letter.
    static func words(_ name: String) -> [String] {
        let chars = Array(name)
        var out: [String] = [], current: [Character] = []
        for (i, c) in chars.enumerated() {
            guard c.isLetter || c.isNumber else {
                if !current.isEmpty { out.append(String(current)); current = [] }
                continue
            }
            if let p = current.last {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                let boundary = (p.isNumber && c.isLetter) || (p.isLetter && c.isNumber)
                    || (p.isLowercase && c.isUppercase)
                    || (p.isUppercase && c.isUppercase && next?.isLowercase == true)
                if boundary { out.append(String(current)); current = [] }
            }
            current.append(c)
        }
        if !current.isEmpty { out.append(String(current)) }
        return out
    }

    /// Drops trailing `Color` / `Image` words (any case) while more than one word remains.
    static func strippingSuffixes(_ words: [String]) -> [String] {
        var words = words
        while words.count > 1, let last = words.last?.lowercased(), last == "color" || last == "image" {
            words.removeLast()
        }
        return words
    }

    /// No lowercase or caseless letters: every character is an uppercase or titlecase letter or a decimal digit.
    static func isAllCaps(_ words: [String]) -> Bool {
        words.allSatisfy { word in
            word.unicodeScalars.allSatisfy {
                switch $0.properties.generalCategory {
                case .uppercaseLetter, .titlecaseLetter, .decimalNumber: true
                default: false
                }
            }
        }
    }

    static func upperFirst(_ word: String) -> String {
        guard let c = word.first else { return word }
        return c.uppercased() + word.dropFirst()
    }

    private static func isASCIIDigit(_ c: Character) -> Bool { c.isASCII && c.isNumber }

    /// Byte (UTF-8) order, the order actool settles collisions in (`Ic Wallet` < `ic-wallet` < `ic_wallet`).
    static func byteOrder(_ a: String, _ b: String) -> Bool { a.utf8.lexicographicallyPrecedes(b.utf8) }

    /// Loose comparison key: lowercased letters and digits only (`brand_mark`, `brandMark` -> `brandmark`).
    public static func fuzzyKey(_ name: String) -> String {
        String(name.lowercased().filter { $0.isLetter || $0.isNumber })
    }
}
