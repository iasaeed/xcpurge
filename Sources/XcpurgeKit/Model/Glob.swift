import Foundation


/// gitignore-style path glob: `*`, `?`, `[abc]`, `**`; no slash = match any path component;
/// a match on a directory covers everything under it.
public struct Glob: Sendable, Hashable {
    public let pattern: String
    private let segments: [String]
    private let anchored: Bool

    public init(_ pattern: String) {
        var p = pattern.trimmingCharacters(in: .whitespaces)
        if p.hasPrefix("./") { p.removeFirst(2) }
        while p.hasSuffix("/") { p.removeLast() }
        self.pattern = pattern
        self.anchored = p.contains("/")
        if p.hasPrefix("/") { p.removeFirst() }
        self.segments = p.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
    }

    public func matches(_ path: String) -> Bool {
        let parts = path.split(separator: "/").map(String.init)
        guard !segments.isEmpty else { return false }
        if !anchored {
            return parts.contains { Self.matchSegment(Array(segments[0]), Array($0)) }
        }
        // Match the full path or any ancestor directory.
        for end in stride(from: parts.count, through: 1, by: -1)
        where Self.matchPath(segments[...], parts[0..<end]) {
            return true
        }
        return false
    }

    private static func matchPath(_ pat: ArraySlice<String>, _ path: ArraySlice<String>) -> Bool {
        guard let first = pat.first else { return path.isEmpty }
        if first == "**" {
            let rest = pat.dropFirst()
            var p = path
            while true {
                if matchPath(rest, p) { return true }
                if p.isEmpty { return false }
                p = p.dropFirst()
            }
        }
        guard let head = path.first, matchSegment(Array(first), Array(head)) else { return false }
        return matchPath(pat.dropFirst(), path.dropFirst())
    }

    static func matchSegment(_ p: [Character], _ s: [Character]) -> Bool {
        var pi = 0, si = 0, starP = -1, starS = 0
        while si < s.count {
            if pi < p.count, p[pi] == "[", let (ok, next) = matchClass(p, pi, s[si]) {
                if ok { pi = next; si += 1; continue }
            } else if pi < p.count, p[pi] == "?" || p[pi] == s[si] {
                pi += 1; si += 1; continue
            } else if pi < p.count, p[pi] == "*" {
                starP = pi; starS = si; pi += 1; continue
            }
            if starP >= 0 { pi = starP + 1; starS += 1; si = starS; continue }
            return false
        }
        while pi < p.count, p[pi] == "*" { pi += 1 }
        return pi == p.count
    }

    private static func matchClass(_ p: [Character], _ start: Int, _ c: Character) -> (Bool, Int)? {
        var i = start + 1
        var negate = false
        if i < p.count, p[i] == "!" || p[i] == "^" { negate = true; i += 1 }
        var matched = false
        var first = true
        while i < p.count, p[i] != "]" || first {
            first = false
            if i + 2 < p.count, p[i + 1] == "-", p[i + 2] != "]" {
                if p[i] <= c && c <= p[i + 2] { matched = true }
                i += 3
            } else {
                if p[i] == c { matched = true }
                i += 1
            }
        }
        guard i < p.count else { return nil }
        return (matched != negate, i + 1)
    }
}
