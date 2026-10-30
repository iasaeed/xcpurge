// LANE: C
import Foundation

/// Maps compiler diagnostics in a failed `--verify` build back to the removal units that caused them, so they
/// can be restored without bisecting: `cannot find 'X' in scope` / `cannot find type 'X'` to the unit declaring
/// `X`; `has no member 'x'` to the asset set whose generated symbol is `x`; `Build input file cannot be found:
/// '/…/File.swift'` and `/…/File.swift:1:2: error:` to the unit holding that path. `no such module` maps to nothing.
public enum DiagnosticAttributor {
    /// Names and paths a unit answers for.
    public struct Signature: Sendable {
        public var unit: RemovalUnit
        public var declaredNames: Set<String>
        public var assetSymbols: Set<String>
    }

    static let nameRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"cannot find '([A-Za-z_][A-Za-z0-9_]*)' in scope"#),
        try! NSRegularExpression(pattern: #"cannot find type '([A-Za-z_][A-Za-z0-9_]*)'"#),
    ]
    static let memberRegex = try! NSRegularExpression(pattern: #"has no member '([A-Za-z_`][A-Za-z0-9_`]*)'"#)
    static let pathRegexes: [NSRegularExpression] = [
        try! NSRegularExpression(pattern: #"Build input file cannot be found: '([^']+)'"#),
        try! NSRegularExpression(pattern: #"^(/[^:\n]+?):\d+:\d+: error:"#, options: [.anchorsMatchLines]),
    ]

    /// Signatures for `units`; source files are read from their trash copy (`storedURL`) when given.
    public static func signatures(for units: [RemovalUnit], context: ScanContext, storedURL: (String) -> URL?) -> [Signature] {
        units.map { unit in
            var names = Set<String>(), symbols = Set<String>()
            for path in unit.paths {
                if RemovalUnits.isSource(path) {
                    names.formUnion(RemovalUnits.declaredNames(of: path, context: context, at: storedURL(path)))
                }
                symbols.formUnion(assetSymbols(for: path))
            }
            return Signature(unit: unit, declaredNames: names, assetSymbols: symbols)
        }
    }

    /// Swift and ObjC symbols Xcode would generate for an asset set path (empty for anything else).
    static func assetSymbols(for path: String) -> Set<String> {
        let parts = path.split(separator: "/").map(String.init)
        guard let last = parts.last, parts.dropLast().contains(where: { $0.lowercased().hasSuffix(".xcassets") }) else { return [] }
        let ext = (last as NSString).pathExtension.lowercased()
        guard let type = AssetType.byExtension[ext] else { return [] }
        let leaf = (last as NSString).deletingPathExtension
        var out = Set(AssetSymbolMangler.symbols(leaf: leaf, type: type))
        if let objc = AssetSymbolMangler.objcSymbol(leaf: leaf, type: type) { out.insert(objc) }
        return out
    }

    /// Unit id -> the first diagnostic line that named it.
    public static func attribute(output: String, signatures: [Signature]) -> [String: String] {
        var out: [String: String] = [:]
        func hit(_ sig: Signature, _ line: String) { if out[sig.unit.id] == nil { out[sig.unit.id] = line } }
        for rawLine in output.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(rawLine)
            let range = NSRange(line.startIndex..., in: line)
            for regex in nameRegexes {
                for m in regex.matches(in: line, range: range) {
                    guard let r = Range(m.range(at: 1), in: line) else { continue }
                    let name = String(line[r])
                    for sig in signatures where sig.declaredNames.contains(name) { hit(sig, line) }
                }
            }
            for m in memberRegex.matches(in: line, range: range) {
                guard let r = Range(m.range(at: 1), in: line) else { continue }
                let member = String(line[r])
                for sig in signatures where sig.assetSymbols.contains(member) || sig.declaredNames.contains(member) { hit(sig, line) }
            }
            for regex in pathRegexes {
                for m in regex.matches(in: line, range: range) {
                    guard let r = Range(m.range(at: 1), in: line) else { continue }
                    let path = RelPath.normalize(String(line[r]))
                    for sig in signatures where sig.unit.paths.contains(where: { path == $0 || path.hasSuffix("/" + $0) }) {
                        hit(sig, line)
                    }
                }
            }
        }
        return out
    }

    /// The first line that looks like a compiler error, for the bisect report.
    public static func firstErrorLine(in output: String) -> String? {
        output.split(separator: "\n").map(String.init).first { $0.contains("error:") || $0.contains("error ") }
    }
}
