import Foundation


/// Resolved build settings per configuration, with `$(VAR)` / `$(inherited)` expansion.
public struct BuildSettings: Sendable, Hashable {
    /// Configuration name -> fully expanded settings.
    public private(set) var configurations: [String: [String: String]]

    public init(configurations: [String: [String: String]] = [:]) {
        self.configurations = configurations
    }

    public var configurationNames: [String] { configurations.keys.sorted() }

    /// `Release` when present, else the first configuration by name.
    public var preferredConfiguration: String? {
        configurations["Release"] != nil ? "Release" : configurationNames.first
    }

    public func value(_ key: String, configuration: String? = nil) -> String? {
        guard let config = configuration ?? preferredConfiguration else { return nil }
        return configurations[config]?[key]
    }

    /// Union across all configurations of the whitespace-separated (quote-aware) list items.
    public func values(_ key: String) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for config in configurationNames {
            for item in Self.splitList(configurations[config]?[key] ?? "") where seen.insert(item).inserted {
                out.append(item)
            }
        }
        return out
    }

    /// True when any configuration sets `key` to YES.
    public func isEnabled(_ key: String) -> Bool {
        configurations.values.contains { ($0[key] ?? "").uppercased() == "YES" }
    }

    /// Layers settings bottom-up (`$(inherited)` refers to the layer below), adds builtins, then expands variables.
    public static func resolve(layers: [[String: String]], builtins: [String: String]) -> [String: String] {
        var merged = builtins
        for layer in layers {
            for (rawKey, value) in layer.sorted(by: { $0.key < $1.key }) {
                let (key, conditional) = splitCondition(rawKey)
                // ponytail: conditional keys ([sdk=…], [arch=…]) only fill gaps; full condition matching is not modelled.
                if conditional, layer[key] != nil || merged[key] != nil { continue }
                let below = merged[key] ?? ""
                merged[key] = replacingInherited(value, with: below)
            }
        }
        var out: [String: String] = [:]
        for (key, value) in merged { out[key] = expand(value, in: merged) }
        return out
    }

    /// `KEY[sdk=iphoneos*]` -> (`KEY`, true).
    static func splitCondition(_ key: String) -> (String, Bool) {
        guard let bracket = key.firstIndex(of: "[") else { return (key, false) }
        return (String(key[..<bracket]), true)
    }

    static func replacingInherited(_ value: String, with below: String) -> String {
        var v = value
        for token in ["$(inherited)", "${inherited}", "$(INHERITED)"] {
            v = v.replacingOccurrences(of: token, with: below)
        }
        return v.trimmingCharacters(in: .whitespaces)
    }

    /// Expands `$(VAR)`, `${VAR}` and `$(VAR:op)`; unknown variables expand to "".
    public static func expand(_ value: String, in settings: [String: String], depth: Int = 0) -> String {
        guard value.contains("$") else { return value }
        guard depth < 8 else { return "" }  // runaway self-reference
        var out = ""
        var chars = Array(value)[...]
        while let c = chars.first {
            chars = chars.dropFirst()
            guard c == "$", let open = chars.first, open == "(" || open == "{" else { out.append(c); continue }
            let close: Character = open == "(" ? ")" : "}"
            var body = "", level = 1
            var rest = chars.dropFirst()
            while let d = rest.first {
                rest = rest.dropFirst()
                if d == open { level += 1 }
                if d == close { level -= 1; if level == 0 { break } }
                body.append(d)
            }
            chars = rest
            let parts = body.split(separator: ":", maxSplits: 1).map(String.init)
            let name = expand(parts.first ?? "", in: settings, depth: depth + 1)
            var resolved = expand(settings[name] ?? "", in: settings, depth: depth + 1)
            if parts.count > 1 { resolved = apply(operators: parts[1], to: resolved) }
            out += resolved
        }
        return out
    }

    private static func apply(operators: String, to value: String) -> String {
        var v = value
        for op in operators.split(separator: ",") {
            switch op {
            case "c99extidentifier", "identifier": v = c99Identifier(v)
            case "rfc1034identifier": v = String(v.map { $0.isLetter || $0.isNumber || $0 == "." ? $0 : "-" })
            case "lower": v = v.lowercased()
            case "upper": v = v.uppercased()
            default:
                if op.hasPrefix("default="), v.isEmpty { v = String(op.dropFirst("default=".count)) }
            }
        }
        return v
    }

    /// Xcode's `c99extidentifier`: non-identifier characters become `_`, a leading digit gets `_`.
    public static func c99Identifier(_ s: String) -> String {
        var out = String(s.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
        if let first = out.first, first.isNumber { out = "_" + out }
        return out
    }

    /// Splits a list-valued setting on whitespace, honouring double quotes.
    public static func splitList(_ value: String) -> [String] {
        var items: [String] = [], current = "", quoted = false
        for c in value {
            if c == "\"" { quoted.toggle(); continue }
            if c.isWhitespace && !quoted {
                if !current.isEmpty { items.append(current); current = "" }
            } else {
                current.append(c)
            }
        }
        if !current.isEmpty { items.append(current) }
        return items
    }
}
