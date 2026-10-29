/// Reads `Package.swift` text without running swift (`--no-swift`, `XCPURGE_NO_SWIFT=1`, or swift failure).
/// Walks tokens for `.target(name:…)`-style calls and literal `path:`, `exclude:`, `resources:` and
/// `dependencies:` arguments. Computed manifests (loops, variables) are only partially understood.
public enum PackageManifestRegexFallback {
    static let targetCalls: [String: String] = [
        "target": "regular", "executableTarget": "executable", "testTarget": "test", "macro": "macro",
        "plugin": "plugin", "binaryTarget": "binary", "systemLibrary": "system",
    ]

    public static func parse(text: String, packageDir: String, rootPath: String) -> ProjectModel {
        let tokens = SwiftTokenizer.tokenize(text).tokens
        var targets: [ManifestTarget] = []
        var products: [String: [String]] = [:]
        var deps: [String: String] = [:]
        var name = RelPath.lastComponent(RelPath.join(rootPath, packageDir))
        var t = 0
        while t < tokens.count {
            let tok = tokens[t]
            guard t + 1 < tokens.count, tokens[t + 1].isPunct("("), let close = matching(tokens, open: t + 1) else { t += 1; continue }
            let args = arguments(tokens, from: t + 2, to: close)
            if tok.kind == .identifier, tok.text == "Package", let n = firstString(args["name"]) {
                name = n
            } else if tok.kind == .member, let type = targetCalls[tok.text], args["targets"] == nil,
                      let n = firstString(args["name"]) {
                var target = ManifestTarget(name: n, type: type, path: firstString(args["path"]))
                target.exclude = strings(args["exclude"])
                target.resources = resources(args["resources"])
                target.dependencies = dependencies(args["dependencies"])
                targets.append(target)
                t = close + 1
                continue
            } else if tok.kind == .member, ["library", "executable", "plugin"].contains(tok.text),
                      let n = firstString(args["name"]), args["targets"] != nil {
                products[n] = strings(args["targets"])
            } else if tok.kind == .member, tok.text == "package", let path = firstString(args["path"]) {
                let dir = RelPath.join(packageDir, path)
                let identity = (firstString(args["name"]) ?? RelPath.lastComponent(path)).lowercased()
                deps[identity] = dir
            }
            t += 1
        }
        return PackageManifest.build(name: name, packageDir: packageDir, rootPath: rootPath, targets: targets,
                                     products: products, dependencies: deps)
    }

    /// Index of the token closing the bracket at `open`.
    static func matching(_ tokens: [SwiftToken], open: Int) -> Int? {
        var depth = 0
        for k in open..<tokens.count where tokens[k].kind == .punct {
            switch tokens[k].text {
            case "(", "[", "{": depth += 1
            case ")", "]", "}":
                depth -= 1
                if depth == 0 { return k }
            default: break
            }
        }
        return nil
    }

    /// Splits call arguments at top-level commas into label -> token slice.
    static func arguments(_ tokens: [SwiftToken], from start: Int, to end: Int) -> [String: ArraySlice<SwiftToken>] {
        var out: [String: ArraySlice<SwiftToken>] = [:]
        var k = start, argStart = start, depth = 0
        func flush(_ upTo: Int) {
            guard argStart < upTo else { return }
            let slice = tokens[argStart..<upTo]
            if slice.count >= 2, slice[slice.startIndex].isName, slice[slice.startIndex + 1].isPunct(":") {
                out[slice[slice.startIndex].text] = slice.dropFirst(2)
            }
        }
        while k < end {
            let tok = tokens[k]
            if tok.kind == .punct {
                if "([{".contains(tok.text) { depth += 1 }
                else if ")]}".contains(tok.text) { depth -= 1 }
                else if tok.text == ",", depth == 0 { flush(k); argStart = k + 1 }
            }
            k += 1
        }
        flush(end)
        return out
    }

    static func firstString(_ slice: ArraySlice<SwiftToken>?) -> String? {
        slice?.first { $0.kind == .string && !$0.interpolated }?.text
    }

    static func strings(_ slice: ArraySlice<SwiftToken>?) -> [String] {
        (slice ?? []).filter { $0.kind == .string && !$0.interpolated }.map(\.text)
    }

    static func resources(_ slice: ArraySlice<SwiftToken>?) -> [PackageResource] {
        guard let slice else { return [] }
        var out: [PackageResource] = []
        var rule = PackageResource.Rule.process
        for tok in slice {
            if tok.kind == .member, let r = PackageResource.Rule(rawValue: tok.text) { rule = r }
            if tok.kind == .string, !tok.interpolated { out.append(PackageResource(path: tok.text, rule: rule)) }
        }
        return out
    }

    static func dependencies(_ slice: ArraySlice<SwiftToken>?) -> [ManifestTarget.Dependency] {
        guard let slice else { return [] }
        let tokens = Array(slice)
        var out: [ManifestTarget.Dependency] = []
        var k = 0
        while k < tokens.count {
            let tok = tokens[k]
            if tok.kind == .member, ["product", "target", "byName"].contains(tok.text),
               k + 1 < tokens.count, tokens[k + 1].isPunct("("), let close = matching(tokens, open: k + 1) {
                let args = arguments(tokens, from: k + 2, to: close)
                if let n = firstString(args["name"]) {
                    switch tok.text {
                    case "product": out.append(.product(name: n, package: firstString(args["package"])))
                    case "target": out.append(.target(n))
                    default: out.append(.byName(n))
                    }
                }
                k = close + 1
                continue
            }
            if tok.kind == .string, !tok.interpolated { out.append(.byName(tok.text)) }
            k += 1
        }
        return out
    }
}
