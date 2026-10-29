/// String helpers for `/`-separated paths: normalize, join, and make root-relative.
public enum RelPath {
    /// macOS aliases `/tmp`, `/var` and `/etc` to `/private/…`; Foundation reports one form, `swift package` and
    /// `realpath` the other. Absolute paths use the short form so both compare equal.
    static let privateAliases = ["/private/tmp", "/private/var", "/private/etc"]

    /// Collapses `.`, `..` and duplicate separators; keeps a leading `/` and leading `..` components.
    /// Absolute `/private/{tmp,var,etc}` paths become `/{tmp,var,etc}`.
    public static func normalize(_ path: String) -> String {
        let absolute = path.hasPrefix("/")
        var path = path
        if absolute, privateAliases.contains(where: { path == $0 || path.hasPrefix($0 + "/") }) {
            path.removeFirst("/private".count)
        }
        var out: [Substring] = []
        for part in path.split(separator: "/", omittingEmptySubsequences: true) {
            if part == "." { continue }
            if part == "..", let last = out.last, last != ".." { out.removeLast(); continue }
            if part == "..", absolute, out.isEmpty { continue }
            out.append(part)
        }
        let joined = out.joined(separator: "/")
        return absolute ? "/" + joined : joined
    }

    /// Joins `rel` onto `base` unless `rel` is absolute.
    public static func join(_ base: String, _ rel: String) -> String {
        if rel.hasPrefix("/") { return normalize(rel) }
        if base.isEmpty { return normalize(rel) }
        if rel.isEmpty { return normalize(base) }
        return normalize(base + "/" + rel)
    }

    /// Root-relative form of an absolute path (`""` for the root itself, `../x` when outside it).
    public static func relative(_ absolute: String, to root: String) -> String {
        let a = normalize(absolute), r = normalize(root)
        if a == r { return "" }
        if r == "/" { return String(a.dropFirst()) }
        if a.hasPrefix(r + "/") { return String(a.dropFirst(r.count + 1)) }
        let ap = a.split(separator: "/"), rp = r.split(separator: "/")
        var common = 0
        while common < ap.count, common < rp.count, ap[common] == rp[common] { common += 1 }
        let ups = Array(repeating: "..", count: rp.count - common)
        return (ups + ap[common...].map(String.init)).joined(separator: "/")
    }

    /// True when `path` equals `dir` or lies beneath it (`dir == ""` contains everything).
    public static func isUnder(_ path: String, _ dir: String) -> Bool {
        dir.isEmpty || path == dir || path.hasPrefix(dir.hasSuffix("/") ? dir : dir + "/")
    }

    /// `isUnder`, ignoring case when `foldingCase` (paths on a case-insensitive volume).
    public static func isUnder(_ path: String, _ dir: String, foldingCase: Bool) -> Bool {
        foldingCase ? isUnder(path.lowercased(), dir.lowercased()) : isUnder(path, dir)
    }

    public static func lastComponent(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? path
    }

    public static func parent(_ path: String) -> String {
        guard let i = path.lastIndex(of: "/") else { return "" }
        return String(path[..<i])
    }

    /// File name without its last extension (`Brand-Regular.ttf` -> `Brand-Regular`).
    public static func stem(_ path: String) -> String {
        let name = lastComponent(path)
        guard let dot = name.lastIndex(of: "."), dot != name.startIndex else { return name }
        return String(name[..<dot])
    }
}
