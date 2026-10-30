/// Stable identity of a finding across runs: a `key` that survives line shifts and locale copies (what baselines
/// match on) and a short `id` for the command line (`xcpurge explain <root> <id>`).
public enum FindingIdentity {
    /// Fields joined with `|`; never a line number, paths are root-relative as reported:
    /// - `unusedAsset` with a name: `kind|module|name`
    /// - `unusedString` / `staleString`: `kind|module|<table stem>|name` (locales collapse; counts handle multiples)
    /// - `dynamicLookup`: `kind|module|path|name`
    /// - `staleIgnore`: `kind|path|name`, where `name` is the `.xcpurgeignore` rule text or, for an inline marker,
    ///   `xcpurge:ignore` plus its ordinal among the file's markers (`xcpurge:ignore #2`), so several stale markers
    ///   in one file stay distinct without a line number
    /// - everything else (file kinds, `unusedFont`, `duplicate`): `kind|module|path`
    public static func key(_ f: Finding) -> String {
        let kind = f.kind.rawValue
        switch f.kind {
        case .unusedAsset where f.name != nil:
            return "\(kind)|\(f.module)|\(f.name!)"
        case .unusedString, .staleString:
            return "\(kind)|\(f.module)|\(RelPath.stem(f.path))|\(f.name ?? "")"
        case .dynamicLookup:
            return "\(kind)|\(f.module)|\(f.path)|\(f.name ?? "")"
        case .staleIgnore:
            return "\(kind)|\(f.path)|\(f.name ?? "")"
        default:
            return "\(kind)|\(f.module)|\(f.path)"
        }
    }

    /// `<kind flag>-<10 hex>`: the kind's kebab-case name plus the first 10 hex digits of FNV-1a-64 over
    /// `key|path`. Two findings share an id only when they are identical dynamic lookups in one file.
    public static func id(_ f: Finding) -> String {
        f.kind.flagName + "-" + hex10(fnv1a64(key(f) + "|" + f.path))
    }

    static func fnv1a64(_ s: String) -> UInt64 {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in s.utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x0000_0100_0000_01b3
        }
        return hash
    }

    static func hex10(_ value: UInt64) -> String {
        let hex = String(value, radix: 16)
        return String(String(repeating: "0", count: max(0, 16 - hex.count)) + hex).prefix(10).description
    }
}
