import Foundation

/// Why a `--baseline` file could not be used (exit 2 on the command line).
public enum BaselineError: Error, CustomStringConvertible, Sendable, Equatable {
    case missing(String)
    case empty(String)
    case unparseable(String, String)
    case unsupportedVersion(String, Int?)

    public var description: String {
        switch self {
        case .missing(let path): "baseline file not found: \(path) (create it with `xcpurge baseline`)"
        case .empty(let path): "baseline file is empty: \(path) (regenerate it with `xcpurge baseline`)"
        case .unparseable(let path, let why): "baseline file is not valid: \(path): \(why)"
        case .unsupportedVersion(let path, let version):
            "baseline file \(path) has version \(version.map(String.init) ?? "none"); this xcpurge reads version \(BaselineFile.version)"
        }
    }
}

/// `.xcpurge-baseline.json`: the findings of one scan as identity keys with counts, plus what the scan was run
/// with, so a later `--baseline` run can hide them and report the fixed ones. Written by a hand-rolled renderer so
/// two runs on the same tree are byte-identical and every entry sits on its own line (merge-friendly diffs).
public struct BaselineFile: Sendable, Equatable {
    public static let version = 1
    public static let defaultName = ".xcpurge-baseline.json"

    public var toolName: String
    public var toolVersion: String
    /// ISO 8601 calendar date (`2026-10-30`, UTC): day precision, so regenerating an unchanged tree on the same day
    /// writes a byte-identical file. A full timestamp is accepted when reading.
    public var createdAt: String
    /// Categories that were scanned, sorted by name.
    public var categories: [Category]
    /// `fnv64:<16 hex>` over the settings that change what a scan reports (see `configHash(_:root:)`).
    public var configHash: String
    public var failOn: [String]
    public var minConfidence: Confidence
    /// Sorted by key; one entry per distinct key.
    public var entries: [BaselineEntry]

    public init(toolName: String = XcpurgeVersion.name, toolVersion: String = XcpurgeVersion.current, createdAt: String,
                categories: [Category], configHash: String, failOn: [String], minConfidence: Confidence,
                entries: [BaselineEntry]) {
        self.toolName = toolName
        self.toolVersion = toolVersion
        self.createdAt = createdAt
        self.categories = categories.sorted { $0.rawValue < $1.rawValue }
        self.configHash = configHash
        self.failOn = failOn
        self.minConfidence = minConfidence
        self.entries = entries.sorted()
    }

    // MARK: - Building

    /// Entries for `findings`: grouped by `FindingIdentity.key`, display fields from the first finding in report
    /// order, `count` for keys that several findings share (locale copies, identical dynamic lookups).
    public static func entries(for findings: [Finding]) -> [BaselineEntry] {
        var byKey: [String: BaselineEntry] = [:]
        for f in findings.sorted(by: Finding.reportOrder) {
            let key = f.key
            if var entry = byKey[key] {
                entry.count += 1
                byKey[key] = entry
            } else {
                byKey[key] = BaselineEntry(key: key, kind: f.kind, category: f.category, module: f.module, path: f.path,
                                           name: f.name, count: 1)
            }
        }
        return byKey.values.sorted()
    }

    /// A baseline of `findings` as scanned with `config` for `categories`.
    public static func make(findings: [Finding], categories: Set<Category>, config: Config, root: URL,
                            now: Date = Date()) -> BaselineFile {
        BaselineFile(createdAt: Self.timestamp(now), categories: Array(categories),
                     configHash: configHash(config, root: root), failOn: config.failOn, minConfidence: config.minConfidence,
                     entries: entries(for: findings))
    }

    /// Hash of the settings that decide which findings a scan produces: exclude, targets, includePods,
    /// ignoreTestReferences, retainPublic, localizationMacros, a non-default testFixtureDirectories and the project/workspace/package (root-relative).
    /// The `.xcpurgeignore` contents are not covered: ignoring something is how a baselined finding gets fixed.
    public static func configHash(_ config: Config, root: URL) -> String {
        let rootPath = root.standardizedFileURL.resolvingSymlinksInPath().path
        func rel(_ p: String?) -> String { p.map { $0.hasPrefix("/") ? RelPath.relative($0, to: rootPath) : $0 } ?? "" }
        var parts: [String] = [
            "exclude=" + config.exclude.sorted().joined(separator: ","),
            "targets=" + config.targets.sorted().joined(separator: ","),
            "includePods=\(config.includePods)",
            "ignoreTestReferences=\(config.ignoreTestReferences)",
            "retainPublic=\(config.retainPublic)",
            "localizationMacros=" + config.localizationMacros.sorted().joined(separator: ","),
            "project=" + rel(config.project),
            "workspace=" + rel(config.workspace),
            "package=" + rel(config.package),
        ]
        // Only a non-default list joins the hash, so baselines written before the key existed stay valid. Compared as
        // a set: order and duplicates do not change what is skipped.
        let fixtures = Set(config.testFixtureDirectories)
        if fixtures != Set(Config.defaultTestFixtureDirectories) {
            parts.append("testFixtureDirectories=" + fixtures.sorted().joined(separator: ","))
        }
        let hash = FindingIdentity.fnv1a64(parts.joined(separator: "\n"))
        let hex = String(hash, radix: 16)
        return "fnv64:" + String(repeating: "0", count: max(0, 16 - hex.count)) + hex
    }

    static func timestamp(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withFullDate, .withDashSeparatorInDate]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// Whole days between `createdAt` and `now`; nil when `createdAt` does not parse.
    public func ageDays(now: Date = Date()) -> Int? {
        guard let created = Self.date(createdAt) else { return nil }
        return max(0, Int(now.timeIntervalSince(created) / 86_400))
    }

    /// Reads a calendar date (UTC) or a full ISO 8601 timestamp, with or without fractional seconds.
    static func date(_ text: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.timeZone = TimeZone(identifier: "UTC")
        for options: ISO8601DateFormatter.Options in [[.withFullDate, .withDashSeparatorInDate], [.withInternetDateTime],
                                                      [.withInternetDateTime, .withFractionalSeconds]] {
            f.formatOptions = options
            if let date = f.date(from: text) { return date }
        }
        return nil
    }

    // MARK: - Rendering

    /// Pretty header, then one compact entry per line (keys sorted), entries sorted by key.
    public func render() -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func json<T: Encodable>(_ value: T) -> String {
            String(decoding: (try? encoder.encode(value)) ?? Data("null".utf8), as: UTF8.self)
        }
        var out = "{\n"
        out += "  \"version\": \(Self.version),\n"
        out += "  \"tool\": {\"name\": \(json(toolName)), \"version\": \(json(toolVersion))},\n"
        out += "  \"createdAt\": \(json(createdAt)),\n"
        out += "  \"categories\": \(json(categories)),\n"
        out += "  \"configHash\": \(json(configHash)),\n"
        out += "  \"failOn\": \(json(failOn)),\n"
        out += "  \"minConfidence\": \(json(minConfidence)),\n"
        if entries.isEmpty {
            out += "  \"entries\": []\n"
        } else {
            out += "  \"entries\": [\n"
            out += entries.sorted().map { "    " + json($0) }.joined(separator: ",\n")
            out += "\n  ]\n"
        }
        return out + "}\n"
    }

    public func write(to url: URL) throws {
        try Data(render().utf8).write(to: url, options: .atomic)
    }

    // MARK: - Reading

    private struct Raw: Decodable {
        struct Tool: Decodable { var name: String?; var version: String? }
        var version: Int?
        var tool: Tool?
        var createdAt: String?
        var categories: [Category]?
        var configHash: String?
        var failOn: [String]?
        var minConfidence: Confidence?
        var entries: [BaselineEntry]
    }

    /// Reads `url`; a missing, empty, unparseable or foreign-version file is an error (never a silent no-op).
    public static func load(_ url: URL) throws -> BaselineFile {
        let path = url.path
        guard FileManager.default.fileExists(atPath: path) else { throw BaselineError.missing(path) }
        let data: Data
        do { data = try Data(contentsOf: url) } catch { throw BaselineError.unparseable(path, "\(error)") }
        return try parse(data, path: path)
    }

    public static func parse(_ data: Data, path: String = defaultName) throws -> BaselineFile {
        guard !data.isEmpty, !String(decoding: data, as: UTF8.self).allSatisfy(\.isWhitespace) else {
            throw BaselineError.empty(path)
        }
        let raw: Raw
        do { raw = try JSONDecoder().decode(Raw.self, from: data) } catch {
            // The version check comes first so a newer format is reported as such, not as a parse error.
            if let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let version = object["version"] as? Int, version != Self.version {
                throw BaselineError.unsupportedVersion(path, version)
            }
            throw BaselineError.unparseable(path, Self.describe(error))
        }
        guard raw.version == Self.version else { throw BaselineError.unsupportedVersion(path, raw.version) }
        return BaselineFile(toolName: raw.tool?.name ?? XcpurgeVersion.name, toolVersion: raw.tool?.version ?? "unknown",
                            createdAt: raw.createdAt ?? "", categories: raw.categories ?? Array(Category.scannable),
                            configHash: raw.configHash ?? "", failOn: raw.failOn ?? [], minConfidence: raw.minConfidence ?? .low,
                            entries: raw.entries)
    }

    private static func describe(_ error: Error) -> String {
        if let decoding = error as? DecodingError {
            switch decoding {
            case .keyNotFound(let key, _): return "missing \"\(key.stringValue)\""
            case .typeMismatch(_, let ctx), .valueNotFound(_, let ctx), .dataCorrupted(let ctx):
                let path = ctx.codingPath.map(\.stringValue).joined(separator: ".")
                return path.isEmpty ? ctx.debugDescription : "\(path): \(ctx.debugDescription)"
            @unknown default: break
            }
        }
        return "\(error)"
    }
}
